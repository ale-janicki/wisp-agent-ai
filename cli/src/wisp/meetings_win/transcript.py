from __future__ import annotations

import json
import os
import tempfile
import time
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path

CHANNELS = ("mic", "system")
SPEAKER = {"mic": "eu", "system": "outros"}
DISPLAY = {"eu": "Você", "outros": "Outros"}
CHANNEL_OF = {"eu": "mic", "outros": "system"}

TRANSCRIPT_FILE = "transcript.json"
LIVE_FILE = "transcript.live.json"
PARAKEET_BACKUP_FILE = "transcript.parakeet.json"

MIN_SPARSE_SECONDS = 120.0
MIN_SPARSE_RATIO = 0.05
SPARSE_NOTICE = "Pouca fala detectada nesta gravação. Refiz a transcrição com mais sensibilidade; confira o texto."
SILENT_NOTICE = ("Quase nenhuma fala foi detectada, mesmo com a escuta mais sensível. "
                 "Confira se o microfone e o áudio da chamada estavam ligados.")


def speaker_name(speaker: str) -> str:
    return DISPLAY.get(speaker, speaker)


def clock(seconds: float) -> str:
    total = max(0, int(seconds))
    hours, rest = divmod(total, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


@dataclass(frozen=True)
class RecognizedSpan:
    text: str
    start: float
    end: float
    confidence: float | None = None


@dataclass(frozen=True)
class MeetingSegment:
    start: float
    end: float
    speaker: str
    text: str
    confidence: float | None = None
    is_final: bool = True

    @property
    def channel(self) -> str | None:
        return CHANNEL_OF.get(self.speaker)

    @property
    def speaker_name(self) -> str:
        return speaker_name(self.speaker)

    def to_json(self) -> dict:
        out = {"start": self.start, "end": self.end, "speaker": self.speaker, "text": self.text}
        if self.confidence is not None:
            out["confidence"] = self.confidence
        return out

    @staticmethod
    def from_json(raw: dict) -> "MeetingSegment":
        return MeetingSegment(float(raw["start"]), float(raw["end"]), str(raw["speaker"]), str(raw["text"]),
                              raw.get("confidence"))


@dataclass(frozen=True)
class NoiseRange:
    channel: str
    start: float
    end: float


def _normalized_word(word: str) -> str:
    return "".join(c for c in word.lower() if c.isalnum())


def _drop_repeated_prefix(text: str, previous: str, max_words: int) -> str:
    words = text.split()
    before = [w for w in map(_normalized_word, previous.split()) if w]
    current = [_normalized_word(w) for w in words]
    limit = min(max_words, len(before), len(current))
    for size in range(limit, 0, -1):
        if before[-size:] == current[:size]:
            return " ".join(words[size:])
    return text


class TranscriptMerger:
    MAX_OVERLAP_WORDS = 12
    OVERLAP_TOLERANCE_SECONDS = 0.75

    def __init__(self):
        self.finals: list[MeetingSegment] = []
        self._partials: dict[str, MeetingSegment] = {}

    @property
    def snapshot(self) -> list[MeetingSegment]:
        live = [p for p in self._partials.values() if p.text]
        return sorted([*self.finals, *live], key=lambda s: (s.start, s.speaker))

    @property
    def last_final_end(self) -> dict[str, float]:
        out: dict[str, float] = {}
        for segment in self.finals:
            if segment.channel:
                out[segment.channel] = max(out.get(segment.channel, 0.0), segment.end)
        return out

    def _last(self, channel: str) -> MeetingSegment | None:
        speaker = SPEAKER[channel]
        return next((s for s in reversed(self.finals) if s.speaker == speaker), None)

    def _trimmed(self, text: str, start: float, channel: str) -> str:
        last = self._last(channel)
        if last is not None and start < last.end + self.OVERLAP_TOLERANCE_SECONDS:
            return _drop_repeated_prefix(text, last.text, self.MAX_OVERLAP_WORDS)
        return text

    def set_partial(self, span: RecognizedSpan | None, channel: str) -> None:
        text = span.text.strip() if span else ""
        if not text:
            self._partials.pop(channel, None)
            return
        trimmed = self._trimmed(text, span.start, channel)
        if not trimmed:
            self._partials.pop(channel, None)
            return
        self._partials[channel] = MeetingSegment(span.start, span.end, SPEAKER[channel], trimmed, span.confidence, False)

    def commit(self, spans: list[RecognizedSpan], channel: str) -> None:
        self._partials.pop(channel, None)
        for span in spans:
            text = span.text.strip()
            if not text:
                continue
            text = self._trimmed(text, span.start, channel)
            if not text:
                continue
            self.finals.append(MeetingSegment(span.start, max(span.end, span.start), SPEAKER[channel], text,
                                              span.confidence, True))
        self.finals.sort(key=lambda s: (s.start, s.speaker))


def merge_adjacent(segments: list[MeetingSegment], max_gap: float = 1.5, max_characters: int = 320) -> list[MeetingSegment]:
    out: list[MeetingSegment] = []
    for segment in sorted(segments, key=lambda s: (s.start, s.speaker)):
        text = " ".join(segment.text.split())
        if not text:
            continue
        last = out[-1] if out else None
        if last and last.speaker == segment.speaker and segment.start - last.end <= max_gap \
                and len(last.text) + len(text) < max_characters:
            confidence = min(last.confidence, segment.confidence) \
                if last.confidence is not None and segment.confidence is not None else last.confidence
            out[-1] = replace(last, text=last.text + " " + text, end=max(last.end, segment.end), confidence=confidence)
        else:
            out.append(replace(segment, text=text))
    return out


def speech_ratio(segments: list[MeetingSegment], duration: float) -> float:
    if duration <= 0:
        return 0.0
    covered = 0.0
    edge = float("-inf")
    for segment in sorted(segments, key=lambda s: s.start):
        if segment.end <= segment.start:
            continue
        start = max(segment.start, edge)
        if segment.end > start:
            covered += segment.end - start
        edge = max(edge, segment.end)
    return covered / duration


def is_sparse(segments: list[MeetingSegment], duration: float) -> bool:
    return not segments or (duration > MIN_SPARSE_SECONDS and speech_ratio(segments, duration) < MIN_SPARSE_RATIO)


def document(started_at: datetime | str, duration: float, engine: str, segments: list[MeetingSegment],
             language: str = "auto", failed_segments: int | None = None,
             noise_ranges: list[NoiseRange] | None = None) -> dict:
    doc = {
        "version": 1,
        "started_at": started_at if isinstance(started_at, str) else iso(started_at),
        "duration_s": duration,
        "language": language,
        "engine": engine,
        "segments": [s.to_json() for s in segments],
    }
    if failed_segments:
        doc["failed_segments"] = failed_segments
    if noise_ranges:
        doc["noise_ranges"] = [{"channel": n.channel, "start": n.start, "end": n.end} for n in noise_ranges]
    return doc


def segments_of(doc: dict) -> list[MeetingSegment]:
    return [MeetingSegment.from_json(s) for s in doc.get("segments") or [] if isinstance(s, dict)]


def noise_of(doc: dict) -> list[NoiseRange]:
    return [NoiseRange(str(n["channel"]), float(n["start"]), float(n["end"]))
            for n in doc.get("noise_ranges") or [] if isinstance(n, dict) and n.get("channel") in CHANNELS]


def plain_text(doc_or_segments) -> str:
    segments = segments_of(doc_or_segments) if isinstance(doc_or_segments, dict) else doc_or_segments
    return "\n".join(f"[{clock(s.start)}] {s.speaker_name}: {s.text}" for s in segments)


def title_of(markdown: str) -> str | None:
    for line in markdown.splitlines():
        stripped = line.strip()
        if stripped.startswith("# ") and stripped[2:].strip():
            return stripped[2:].strip()
    return None


def raw_note(title: str, doc: dict, reason: str) -> str:
    return f"# {title}\n\n> Nota não gerada: {reason}\n\n## Transcrição\n\n{plain_text(doc)}\n"


def _replace(source: str, target: Path) -> None:
    for attempt in range(8):
        try:
            os.replace(source, target)
            return
        except PermissionError:
            if attempt == 7:
                raise
            time.sleep(0.02 * (attempt + 1))


def write_private(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass
        _replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def dumps(value: dict) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def transcript_path(folder: Path, live: bool = False) -> Path:
    return Path(folder) / (LIVE_FILE if live else TRANSCRIPT_FILE)


def write_transcript(folder: Path, doc: dict, live: bool = False) -> None:
    write_private(transcript_path(folder, live), dumps(doc))


def read_transcript(folder: Path, live: bool = False) -> dict:
    data = json.loads(transcript_path(folder, live).read_text("utf-8"))
    if not isinstance(data, dict):
        raise ValueError("transcript has no object at the top")
    return data
