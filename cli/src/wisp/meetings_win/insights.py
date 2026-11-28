from __future__ import annotations

from dataclasses import dataclass
from datetime import timezone, tzinfo

from wisp.meetings_win.transcript import MeetingSegment, clock, parse_iso, speaker_name

MONOLOGUE_GAP = 4.0
INTERJECTION_WORDS = 2
ONGOING_WINDOW = 8.0
MINIMUM_SPEECH_FOR_RATE = 10.0
BOOKMARK_LINES_BEFORE = 3
BOOKMARK_LINES_AFTER = 2


@dataclass
class Stats:
    metrics: dict
    ongoing: tuple[str, float] | None
    last_question_at: float | None


def _word_count(text: str) -> int:
    return len(text.split())


def _question_count(text: str) -> int:
    count = 0
    previous = False
    for char in text:
        mark = char == "?"
        if mark and not previous:
            count += 1
        previous = mark
    return count


def _covered(segments: list[MeetingSegment], limit: float = float("inf")) -> float:
    total = 0.0
    end = float("-inf")
    for segment in sorted(segments, key=lambda s: s.start):
        start = max(segment.start, end)
        stop = min(segment.end, limit)
        if stop > start:
            total += stop - start
        end = max(end, segment.end)
    return total


def _rate(words: int, seconds: float) -> float:
    return words / (seconds / 60) if seconds >= MINIMUM_SPEECH_FOR_RATE else 0.0


def _runs(spoken: list[MeetingSegment]) -> list[list]:
    runs: list[list] = []
    for segment in spoken:
        channel = segment.channel
        if channel is None:
            continue
        if runs:
            current = runs[-1]
            if current[0] == channel and segment.start - current[2] <= MONOLOGUE_GAP:
                current[2] = max(current[2], segment.end)
                continue
            if current[0] != channel and _word_count(segment.text) <= INTERJECTION_WORDS:
                continue
        runs.append([channel, segment.start, segment.end])
    return runs


def compute_metrics(segments: list[MeetingSegment], elapsed: float) -> Stats:
    spoken = sorted((s for s in segments if s.is_final and s.channel and s.end >= s.start and _word_count(s.text) > 0),
                    key=lambda s: (s.start, s.speaker))
    you = {"words": 0, "speaking_s": 0.0, "wpm": 0.0, "questions": 0, "longest_monologue_s": 0.0}
    others = dict(you)
    last_question = None
    for segment in spoken:
        asked = _question_count(segment.text)
        if asked:
            last_question = max(last_question or 0.0, segment.start)
        side = you if segment.channel == "mic" else others
        side["words"] += _word_count(segment.text)
        side["questions"] += asked
    you["speaking_s"] = _covered([s for s in spoken if s.channel == "mic"])
    others["speaking_s"] = _covered([s for s in spoken if s.channel == "system"])
    you["wpm"] = _rate(you["words"], you["speaking_s"])
    others["wpm"] = _rate(others["words"], others["speaking_s"])
    runs = _runs(spoken)
    you["longest_monologue_s"] = max((r[2] - r[1] for r in runs if r[0] == "mic"), default=0.0)
    others["longest_monologue_s"] = max((r[2] - r[1] for r in runs if r[0] == "system"), default=0.0)
    duration = max(elapsed, max((s.end for s in spoken), default=0.0))
    silence = max(0.0, duration - _covered(spoken, duration))
    ongoing = None
    if runs and elapsed - runs[-1][2] <= ONGOING_WINDOW:
        ongoing = (runs[-1][0], runs[-1][2] - runs[-1][1])
    return Stats({"duration_s": duration, "you": you, "others": others, "silence_s": silence}, ongoing, last_question)


@dataclass(frozen=True)
class Nudge:
    kind: str
    text: str


class NudgeEngine:
    DEFAULT_GAP = 300.0
    SHARE_LIMIT = 0.75
    MINIMUM_SPEECH_FOR_SHARE = 300.0
    MONOLOGUE_SECONDS = 180.0
    QUESTION_SILENCE = 600.0

    def __init__(self, minimum_gap: float = DEFAULT_GAP):
        self.minimum_gap = minimum_gap
        self._last_fired: float | None = None
        self._last_by_kind: dict[str, float] = {}

    def evaluate(self, stats: Stats, elapsed: float) -> Nudge | None:
        if self._last_fired is not None and elapsed - self._last_fired < self.minimum_gap:
            return None
        nudge = self._candidate(stats, elapsed)
        if nudge is None:
            return None
        last = self._last_by_kind.get(nudge.kind)
        if last is not None and elapsed - last < self.minimum_gap * 2:
            return None
        self._last_fired = elapsed
        self._last_by_kind[nudge.kind] = elapsed
        return nudge

    def _candidate(self, stats: Stats, elapsed: float) -> Nudge | None:
        if stats.ongoing and stats.ongoing[0] == "mic" and stats.ongoing[1] >= self.MONOLOGUE_SECONDS:
            return Nudge("monologue", f"Monólogo de {int(stats.ongoing[1] / 60)} min")
        you = stats.metrics["you"]["speaking_s"]
        others = stats.metrics["others"]["speaking_s"]
        spoken = you + others
        share = you / spoken if spoken > 0 else 0.0
        if spoken >= self.MINIMUM_SPEECH_FOR_SHARE and share >= self.SHARE_LIMIT:
            return Nudge("talkShare", f"Você está falando {round(share * 100)}% do tempo")
        quiet = elapsed - (stats.last_question_at or 0.0)
        if elapsed >= self.QUESTION_SILENCE and quiet >= self.QUESTION_SILENCE:
            return Nudge("noQuestion", f"Nenhuma pergunta há {int(quiet / 60)} min")
        return None


class RecordingLimitClock:
    WARNING_LEAD = 300.0

    def __init__(self, limit: float):
        self.limit = limit
        self._started: float | None = None
        self._paused_total = 0.0
        self._paused_since: float | None = None
        self._warned = False
        self._reached = False

    def start(self, now: float) -> None:
        self._started = now

    def pause(self, now: float) -> None:
        if self._paused_since is None:
            self._paused_since = now

    def resume(self, now: float) -> None:
        if self._paused_since is None:
            return
        self._paused_total += max(0.0, now - self._paused_since)
        self._paused_since = None

    def active(self, now: float) -> float:
        if self._started is None:
            return 0.0
        ongoing = max(0.0, now - self._paused_since) if self._paused_since is not None else 0.0
        return max(0.0, now - self._started - self._paused_total - ongoing)

    def remaining(self, now: float) -> float:
        return max(0.0, self.limit - self.active(now))

    def tick(self, now: float) -> tuple[str, float | None] | None:
        if self.limit <= 0 or self._reached:
            return None
        left = self.remaining(now)
        if left <= 0:
            self._reached = True
            return ("reached", None)
        if not self._warned and self.limit > self.WARNING_LEAD and left <= self.WARNING_LEAD:
            self._warned = True
            return ("warning", left)
        return None


def surrounding(segments: list[MeetingSegment], moment: float) -> list[MeetingSegment]:
    spoken = sorted((s for s in segments if s.is_final and s.text.strip()), key=lambda s: s.start)
    before = [s for s in spoken if s.start <= moment][-BOOKMARK_LINES_BEFORE:]
    after = [s for s in spoken if s.start > moment][:BOOKMARK_LINES_AFTER]
    return before + after


def pause_label(pause: dict, tz: tzinfo | None = None) -> str:
    def hour(value: str) -> str:
        return parse_iso(value).astimezone(tz).strftime("%H:%M")

    try:
        start = hour(pause["started_at"])
    except (KeyError, ValueError):
        return "Pausado"
    if not pause.get("ended_at"):
        return f"Pausado desde {start}"
    return f"Pausado {start}–{hour(pause['ended_at'])}"


def segment_line(segment: MeetingSegment) -> dict:
    return {"id": f"{segment.speaker}-{round(segment.start * 1000)}" if segment.is_final else f"{segment.speaker}-partial",
            "time": clock(segment.start), "speaker": segment.speaker_name, "text": segment.text,
            "is_partial": not segment.is_final, "is_mine": segment.channel == "mic",
            "is_bookmark": False, "is_pause": False}


def bookmark_lines(segments: list[MeetingSegment], bookmarks: list[dict], pauses: list[dict] | None = None,
                   tz: tzinfo | None = None) -> list[dict]:
    marks = []
    for mark in bookmarks or []:
        marks.append((float(mark.get("time") or 0), str(mark.get("id") or ""), {
            "id": f"bookmark-{mark.get('id')}", "time": clock(float(mark.get("time") or 0)), "speaker": "Marcador",
            "text": str(mark.get("label") or "") or "Momento marcado", "is_partial": False, "is_mine": False,
            "is_bookmark": True, "is_pause": False}))
    for pause in pauses or []:
        position = float(pause.get("at_s") or 0)
        marks.append((position, f"pause-{pause.get('started_at')}", {
            "id": f"pause-{pause.get('started_at')}", "time": clock(position), "speaker": "Pausa",
            "text": pause_label(pause, tz), "is_partial": False, "is_mine": False, "is_bookmark": False,
            "is_pause": True}))
    marks.sort(key=lambda m: (m[0], m[1]))
    out: list[dict] = []
    index = 0
    for segment in segments:
        while index < len(marks) and marks[index][0] < segment.start:
            out.append(marks[index][2])
            index += 1
        out.append(segment_line(segment))
    out.extend(m[2] for m in marks[index:])
    return out


__all__ = ["Nudge", "NudgeEngine", "RecordingLimitClock", "Stats", "bookmark_lines", "compute_metrics", "pause_label",
           "segment_line", "speaker_name", "surrounding", "timezone"]
