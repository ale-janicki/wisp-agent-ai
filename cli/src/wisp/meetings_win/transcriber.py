from __future__ import annotations

import threading
from array import array
from datetime import datetime
from pathlib import Path
from typing import Callable, Iterator

from wisp.meetings_win.audio import SPEECH_RATE, Decimator48To16, LinearResampler
from wisp.meetings_win.bleed import BleedConfig, BleedDetector, ChannelHistory
from wisp.meetings_win.language import LanguagePicker
from wisp.meetings_win.segmenter import ChannelStreamer, SegmenterConfig, StreamJob
from wisp.meetings_win.transcript import (CHANNELS, NoiseRange, RecognizedSpan, TranscriptMerger, document, merge_adjacent)
from wisp.meetings_win.wavfile import SAMPLE_RATE, info, read_blocks

AUDIO_FILE = "audio.wav"
PIECE_SAMPLES = 20 * SPEECH_RATE
PIECE_OVERLAP = SPEECH_RATE // 2
MINIMUM_PIECE_SAMPLES = SPEECH_RATE // 10


class Cancelled(Exception):
    pass


class NoAudio(Exception):
    def __init__(self):
        super().__init__("Não encontrei o áudio dessa gravação.")


def audio_path(folder: Path) -> Path | None:
    path = Path(folder) / AUDIO_FILE
    return path if path.exists() else None


def uses(channel: str, sources: str) -> bool:
    return sources != ("system" if channel == "mic" else "mic")


def read_channels(audio: Path) -> Iterator[tuple[dict[str, array], float]]:
    found = info(audio)
    if found is None:
        raise NoAudio()
    rate, channels, frames = found
    reducers = [Decimator48To16() if rate == SAMPLE_RATE else LinearResampler(rate, SPEECH_RATE) for _ in range(2)]
    done = 0
    for block in read_blocks(audio, SAMPLE_RATE):
        out = {}
        for index, channel in enumerate(CHANNELS):
            if index < channels:
                out[channel] = reducers[index].process(block[index])
        done += len(block[0])
        yield out, done / max(1, frames)


class _Piece:
    def __init__(self, start: int = 0, samples: array | None = None, fresh: int = 0):
        self.start, self.samples, self.fresh = start, samples if samples is not None else array("f"), fresh


class MeetingTranscriber:
    def __init__(self, recognizer, language: LanguagePicker | None = None, config: SegmenterConfig | None = None,
                 bleed: BleedConfig | None = None, pause: Callable[[], None] | None = None):
        self.recognizer = recognizer
        self.language = language or LanguagePicker("pt")
        self.config = config
        self.bleed = bleed or BleedConfig()
        self.pause = pause

    def with_config(self, config: SegmenterConfig | None) -> "MeetingTranscriber":
        return MeetingTranscriber(self.recognizer, self.language, config, self.bleed, self.pause)

    def _recognize(self, samples, offset_seconds: float, channel: str, merger: TranscriptMerger,
                   cancel: threading.Event | None) -> None:
        if cancel is not None and cancel.is_set():
            raise Cancelled()
        if self.pause is not None:
            self.pause()
        result = self.recognizer.transcribe(samples, self.language.code())
        self.language.observe(result.language, result.probability)
        merger.commit([RecognizedSpan(s.text, s.start + offset_seconds, s.end + offset_seconds, s.confidence)
                       for s in result.spans], channel)

    def transcribe(self, folder: Path, started_at: datetime, sources: str = "both", duration: float = 0.0,
                   progress: Callable[[float], None] = lambda _: None, cancel: threading.Event | None = None) -> dict:
        audio = audio_path(folder)
        if audio is None:
            raise NoAudio()
        merger = TranscriptMerger()
        streamers = {c: ChannelStreamer(c, self.config) for c in CHANNELS if uses(c, sources)}
        noise: list[NoiseRange] = []
        history = ChannelHistory(int(self.bleed.history_seconds * SPEECH_RATE))

        def run(jobs: list[StreamJob]) -> None:
            for job in jobs:
                if job.kind == "noise":
                    noise.append(NoiseRange(job.channel, job.start_seconds, job.end_seconds))
            for job in jobs:
                if len(job.samples) == 0:
                    continue
                if cancel is not None and cancel.is_set():
                    raise Cancelled()
                if job.channel == "mic" and BleedDetector.is_bleed(job.samples, job.start_sample, history, self.bleed):
                    continue
                self._recognize(job.samples, job.start_seconds, job.channel, merger, cancel)

        for block, fraction in read_channels(audio):
            if cancel is not None and cancel.is_set():
                raise Cancelled()
            for channel in sorted(block, key=lambda c: c != "system"):
                if channel == "system":
                    history.append(block[channel])
                if channel in streamers:
                    run(streamers[channel].append(block[channel]))
            progress(fraction * 0.98)
        for channel in CHANNELS:
            if channel in streamers:
                run(streamers[channel].flush())
        if noise:
            self._fill(noise, audio, merger, lambda f: progress(0.98 + f * 0.02), cancel)
        progress(1.0)
        tidy = merge_adjacent(merger.finals)
        spoken = max((s.end for s in tidy), default=0.0)
        return document(started_at, max(duration, spoken), self.recognizer.engine_name, tidy,
                        self.language.code() or "auto")

    def transcribe_ranges(self, folder: Path, ranges: list[NoiseRange], progress: Callable[[float], None] = lambda _: None,
                          cancel: threading.Event | None = None):
        audio = audio_path(folder)
        if audio is None:
            raise NoAudio()
        merger = TranscriptMerger()
        self._fill(ranges, audio, merger, progress, cancel)
        return list(merger.finals)

    def _fill(self, ranges: list[NoiseRange], audio: Path, merger: TranscriptMerger, progress, cancel) -> None:
        wanted: dict[str, list[tuple[int, int]]] = {}
        for r in ranges:
            wanted.setdefault(r.channel, []).append((int(r.start * SPEECH_RATE), int(r.end * SPEECH_RATE)))
        position: dict[str, int] = {}
        pieces: dict[str, _Piece] = {}
        history = ChannelHistory(int(self.bleed.history_seconds * SPEECH_RATE))

        def flush(channel: str, piece: _Piece) -> None:
            if piece.fresh < MINIMUM_PIECE_SAMPLES:
                return
            if channel == "mic" and BleedDetector.is_bleed(piece.samples, piece.start, history, self.bleed):
                return
            self._recognize(piece.samples, piece.start / SPEECH_RATE, channel, merger, cancel)

        for block, fraction in read_channels(audio):
            if cancel is not None and cancel.is_set():
                raise Cancelled()
            if "mic" in wanted and "system" in block:
                history.append(block["system"])
            for channel, samples in block.items():
                if channel not in wanted:
                    continue
                first = position.get(channel, 0)
                last = first + len(samples)
                piece = pieces.get(channel) or _Piece()
                cursor = first
                for lo, hi in sorted(wanted[channel]):
                    a, b = max(lo, first), min(hi, last)
                    if b <= a:
                        continue
                    if a > cursor:
                        if piece.fresh > 0:
                            flush(channel, piece)
                        piece = _Piece()
                    index, run = a, samples[a - first:b - first]
                    while len(run):
                        take = run[:max(1, PIECE_SAMPLES - len(piece.samples))]
                        run = run[len(take):]
                        if not len(piece.samples):
                            piece.start = index
                        piece.samples.extend(take)
                        piece.fresh += len(take)
                        index += len(take)
                        if len(piece.samples) >= PIECE_SAMPLES:
                            flush(channel, piece)
                            keep = piece.samples[-PIECE_OVERLAP:]
                            piece = _Piece(index - len(keep), array("f", keep), 0)
                    cursor = b
                if cursor < last:
                    if piece.fresh > 0:
                        flush(channel, piece)
                    piece = _Piece()
                position[channel] = last
                pieces[channel] = piece
            progress(fraction)
        for channel, piece in pieces.items():
            if piece.fresh > 0:
                flush(channel, piece)
