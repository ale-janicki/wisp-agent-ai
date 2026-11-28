from __future__ import annotations

import threading
from datetime import datetime
from pathlib import Path
from typing import Callable

from wisp.meetings_win.audio import SPEECH_RATE, Decimator48To16
from wisp.meetings_win.bleed import BleedConfig, BleedDetector, ChannelHistory
from wisp.meetings_win.language import LanguagePicker
from wisp.meetings_win.segmenter import ChannelStreamer, SegmenterConfig, StreamJob
from wisp.meetings_win.transcript import (CHANNELS, MeetingSegment, NoiseRange, RecognizedSpan, TranscriptMerger, document,
                                          write_transcript)


class TranscriptStore:
    def __init__(self, started_at: datetime, engine: str, language: str = "auto", folder: Path | None = None):
        self._lock = threading.Lock()
        self._merger = TranscriptMerger()
        self._failed = 0
        self._noise: list[NoiseRange] = []
        self._started_at = started_at
        self._engine = engine
        self._folder = folder
        self.language = language

    def attach(self, folder: Path) -> None:
        self._folder = folder

    @property
    def snapshot(self) -> list[MeetingSegment]:
        with self._lock:
            return self._merger.snapshot

    @property
    def finals(self) -> list[MeetingSegment]:
        with self._lock:
            return list(self._merger.finals)

    def set_partial(self, span: RecognizedSpan | None, channel: str) -> None:
        with self._lock:
            self._merger.set_partial(span, channel)

    def commit(self, spans: list[RecognizedSpan], channel: str) -> None:
        with self._lock:
            self._merger.commit(spans, channel)
            saved = self._document()
        self._save(saved)

    def record_noise(self, noise: NoiseRange) -> None:
        with self._lock:
            self._noise.append(noise)
            saved = self._document()
        self._save(saved)

    def record_failure(self) -> None:
        with self._lock:
            self._failed += 1

    def document(self, duration: float | None = None) -> dict:
        with self._lock:
            return self._document(duration)

    def _document(self, duration: float | None = None) -> dict:
        finals = self._merger.finals
        spoken = max((s.end for s in finals), default=0.0)
        return document(self._started_at, spoken if duration is None else duration, self._engine, list(finals),
                        self.language, self._failed, list(self._noise))

    def _save(self, doc: dict) -> None:
        if self._folder is not None:
            try:
                write_transcript(self._folder, doc, live=True)
            except OSError:
                pass


class LiveTranscriber:
    LAG_THRESHOLD = 3

    def __init__(self, recognizer, store: TranscriptStore, language: LanguagePicker | None = None,
                 config: SegmenterConfig | None = None, bleed: BleedConfig | None = None, channels=CHANNELS,
                 on_update: Callable[[list[MeetingSegment]], None] = lambda _: None,
                 on_failure: Callable[[str], None] = lambda _: None, on_lag: Callable[[bool], None] = lambda _: None):
        self._recognizer = recognizer
        self._store = store
        self._language = language or LanguagePicker("pt")
        self._on_update, self._on_failure, self._on_lag = on_update, on_failure, on_lag
        self._bleed = bleed or BleedConfig()
        self._history = ChannelHistory(int(self._bleed.history_seconds * SPEECH_RATE))
        self._streamers = {c: ChannelStreamer(c, config) for c in channels}
        self._decimators: dict[str, Decimator48To16] = {}
        self._pending: list[StreamJob] = []
        self._lag = False
        self._failure_reported = False
        self._lock = threading.Lock()
        self._wake = threading.Condition(self._lock)
        self._closing = False
        self._cancelled = False
        self._worker = threading.Thread(target=self._run, name="wisp-live-transcriber", daemon=True)
        self._worker.start()

    @property
    def has_failed(self) -> bool:
        with self._lock:
            return self._failure_reported

    def push48k(self, samples, channel: str) -> None:
        with self._lock:
            decimator = self._decimators.setdefault(channel, Decimator48To16())
            out = decimator.process(samples)
        self.push16k(out, channel)

    def push16k(self, samples, channel: str) -> None:
        if len(samples) == 0:
            return
        with self._lock:
            if channel == "system":
                self._history.append(samples)
            streamer = self._streamers.get(channel)
            jobs = streamer.append(samples) if streamer else []
        self._enqueue(jobs)

    def skip_gap(self, seconds: float, channel: str) -> None:
        with self._lock:
            self._decimators[channel] = Decimator48To16()
            count = int(seconds * SPEECH_RATE)
            if channel == "system":
                self._history.skip(count)
            streamer = self._streamers.get(channel)
            jobs = streamer.skip_gap(count) if streamer else []
        self._enqueue(jobs)

    def flush_open_segments(self) -> None:
        with self._lock:
            jobs = []
            for channel, streamer in self._streamers.items():
                self._decimators[channel] = Decimator48To16()
                jobs += streamer.flush()
        self._enqueue(jobs)

    def finish(self) -> list[MeetingSegment]:
        with self._lock:
            jobs = []
            for streamer in self._streamers.values():
                jobs += streamer.flush()
        self._enqueue(jobs)
        with self._wake:
            self._closing = True
            self._wake.notify_all()
        self._worker.join()
        return self._store.snapshot

    def cancel(self) -> None:
        with self._wake:
            self._pending.clear()
            self._cancelled = True
            self._closing = True
            self._wake.notify_all()

    def stop_and_wait(self) -> None:
        self.cancel()
        self._worker.join()

    def _behind(self) -> bool:
        return sum(1 for j in self._pending if j.kind == "final") >= self.LAG_THRESHOLD

    def _enqueue(self, jobs: list[StreamJob]) -> None:
        if not jobs:
            return
        changed = None
        with self._wake:
            for job in jobs:
                if job.kind == "typing" and any(p.channel == job.channel for p in self._pending):
                    continue
                self._pending.append(job)
            behind = self._behind()
            if behind != self._lag:
                self._lag = behind
                changed = behind
            self._wake.notify_all()
        if changed is not None:
            self._on_lag(changed)

    def _take(self) -> StreamJob | None:
        with self._wake:
            while not self._pending:
                if self._closing:
                    return None
                self._wake.wait()
            job = self._pending.pop(0)
            behind = self._behind()
            changed = behind if behind != self._lag else None
            self._lag = behind
        if changed is not None:
            self._on_lag(changed)
        return job

    def _run(self) -> None:
        while (job := self._take()) is not None:
            if self._cancelled:
                return
            self._process(job)

    def _is_bleed(self, job: StreamJob) -> bool:
        with self._lock:
            window = BleedDetector.system_window(job.start_sample, len(job.samples), self._history, self._bleed)
        return window is not None and BleedDetector.judge(job.samples, window, self._bleed)

    def _publish(self) -> None:
        self._on_update(self._store.snapshot)

    def _process(self, job: StreamJob) -> None:
        if job.kind == "typing":
            self._store.set_partial(RecognizedSpan("…", job.start_seconds, job.start_seconds), job.channel)
            self._publish()
            return
        if job.kind == "noise":
            self._store.record_noise(NoiseRange(job.channel, job.start_seconds, job.end_seconds))
            return
        if len(job.samples) == 0 or (job.channel == "mic" and self._is_bleed(job)):
            self._store.commit([], job.channel)
            self._publish()
            return
        try:
            result = self._recognizer.transcribe(job.samples, self._language.code())
            if self._cancelled:
                return
            self._language.observe(result.language, result.probability)
            self._store.language = self._language.code() or "auto"
            offset = job.start_seconds
            self._store.commit([RecognizedSpan(s.text, s.start + offset, s.end + offset, s.confidence)
                                for s in result.spans], job.channel)
            self._publish()
        except Exception as problem:
            with self._lock:
                first = not self._failure_reported
                self._failure_reported = True
            self._store.record_failure()
            self._store.commit([], job.channel)
            self._publish()
            if first:
                self._on_failure(str(problem))
