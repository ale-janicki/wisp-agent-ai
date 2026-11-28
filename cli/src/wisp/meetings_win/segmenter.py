from __future__ import annotations

from array import array
from dataclasses import dataclass

from wisp.meetings_win.audio import SPEECH_RATE, rms


@dataclass(frozen=True)
class SegmenterConfig:
    frame_samples: int = 480
    on_rms: float = 0.003
    off_rms: float = 0.0021
    min_speech_seconds: float = 0.1
    redemption_seconds: float = 0.5
    pre_pad_seconds: float = 0.3
    post_pad_seconds: float = 0.4
    max_segment_seconds: float = 20.0
    cut_search_seconds: float = 2.0
    floor_multiplier: float = 3.0
    floor_window_seconds: float = 10.0
    max_on_rms: float = 0.05
    cut_overlap_seconds: float = 0.5
    max_noisy_cuts: int = 2

    @staticmethod
    def sensitive() -> "SegmenterConfig":
        return SegmenterConfig(on_rms=0.0012, off_rms=0.00084)

    @property
    def off_ratio(self) -> float:
        return self.off_rms / self.on_rms if self.on_rms > 0 else 0.7

    def samples(self, seconds: float) -> int:
        return round(seconds * SPEECH_RATE)


@dataclass(frozen=True)
class Opened:
    start_sample: int


@dataclass(frozen=True)
class Segment:
    start_sample: int
    samples: array


@dataclass(frozen=True)
class Dropped:
    pass


@dataclass(frozen=True)
class Noise:
    start_sample: int
    end_sample: int


class SpeechSegmenter:
    def __init__(self, config: SegmenterConfig | None = None):
        self._config = config = config or SegmenterConfig()
        self._frame = max(1, config.frame_samples)
        self._min_speech = config.samples(config.min_speech_seconds)
        self._redemption = config.samples(config.redemption_seconds)
        self._pre_pad = config.samples(config.pre_pad_seconds)
        self._post_pad = config.samples(config.post_pad_seconds)
        self._max_segment = config.samples(config.max_segment_seconds)
        self._cut_search = config.samples(config.cut_search_seconds)
        self._cut_overlap = config.samples(config.cut_overlap_seconds)
        self._floor_capacity = max(1, config.samples(config.floor_window_seconds) // max(1, config.frame_samples))
        self._floor_levels: list[float] = []
        self._floor_tick = 0
        self._on = config.on_rms
        self._off = config.off_rms
        self._noisy_cuts = 0
        self._noise_run = False
        self._noise_start = 0
        self._buffer = array("f")
        self._buffer_start = 0
        self._processed = 0
        self._total = 0
        self._last_emitted_end = 0
        self._is_open = False
        self._is_continuation = False
        self._announced = False
        self._candidate = 0
        self._emit_from = 0
        self._last_voiced_end = 0

    @property
    def total_samples(self) -> int:
        return self._total

    @property
    def has_open_segment(self) -> bool:
        return self._is_open

    def append(self, samples) -> list:
        self._buffer.extend(samples)
        self._total += len(samples)
        events: list = []
        frame = self._frame
        while self._processed + frame <= self._total:
            start = self._processed
            end = start + frame
            self._processed = end
            level = self._rms(start, end)
            if not self._is_open:
                if level < self._on:
                    self._record_floor(level)
                    continue
                self._open(start)
            elif level >= self._off:
                self._last_voiced_end = end
            elif end - self._last_voiced_end >= self._redemption:
                self._close(events)
                continue
            self._announce_if_needed(events)
            if end - self._emit_from >= self._max_segment:
                self._force_cut(end, events)
        self._trim()
        return events

    def flush(self) -> list:
        events: list = []
        if self._is_open:
            self._close(events)
        self._processed = self._total
        self._trim()
        return events

    def skip_gap(self, samples: int) -> list:
        events = self.flush()
        self._total += samples
        self._processed = self._total
        self._last_emitted_end = self._total
        self._buffer_start = self._total
        self._buffer = array("f")
        return events

    def _open(self, start: int) -> None:
        self._is_open = True
        self._is_continuation = False
        self._announced = False
        self._candidate = start
        self._emit_from = max(start - self._pre_pad, self._last_emitted_end, self._buffer_start)
        self._last_voiced_end = start + self._frame

    def _has_enough_speech(self) -> bool:
        return self._last_voiced_end - self._candidate >= (self._frame if self._is_continuation else self._min_speech)

    def _announce_if_needed(self, events: list) -> None:
        if not self._is_open or self._announced or not self._has_enough_speech():
            return
        self._announced = True
        events.append(Opened(self._emit_from))

    def _close(self, events: list) -> None:
        try:
            if self._noise_run:
                self._finish_noise(min(self._last_voiced_end + self._post_pad, self._total), events)
                return
            if not self._has_enough_speech():
                if self._announced:
                    events.append(Dropped())
                return
            self._emit(self._emit_from, min(self._last_voiced_end + self._post_pad, self._total), events)
        finally:
            self._is_open = False
            self._noisy_cuts = 0

    def _emit(self, start: int, end: int, events: list) -> None:
        lower = max(start, self._buffer_start) - self._buffer_start
        upper = min(end, self._buffer_start + len(self._buffer)) - self._buffer_start
        self._last_emitted_end = max(self._last_emitted_end, end)
        if lower >= upper:
            events.append(Dropped())
            return
        events.append(Segment(self._buffer_start + lower, self._buffer[lower:upper]))

    def _force_cut(self, now: int, events: list) -> None:
        frame = self._frame
        best = now - frame
        best_level = float("inf")
        start = max(self._emit_from, now - self._cut_search)
        start += (now - start) % frame
        while start + frame <= now:
            level = self._rms(start, start + frame)
            if level <= best_level:
                best_level = level
                best = start
            start += frame
        quiet = best_level < self._off
        if not quiet and self._noisy_cuts >= self._config.max_noisy_cuts:
            self._mark_noise(now, events)
            return
        cut = best + frame // 2
        if quiet:
            self._finish_noise(self._emit_from, events)
        self._emit(self._emit_from, cut, events)
        self._is_continuation = True
        self._announced = False
        self._candidate = cut
        self._emit_from = cut if quiet else max(cut - self._cut_overlap, self._buffer_start)
        self._noisy_cuts = 0 if quiet else self._noisy_cuts + 1
        self._last_voiced_end = cut
        self._rescan_voiced(best + frame, now)
        self._announce_if_needed(events)

    def _mark_noise(self, now: int, events: list) -> None:
        if not self._noise_run:
            self._noise_run = True
            self._noise_start = self._emit_from
        events.append(Dropped())
        self._floor_levels = []
        index = now - self._frame
        while index >= self._emit_from and len(self._floor_levels) < self._floor_capacity:
            self._floor_levels.append(self._rms(index, index + self._frame))
            index -= self._frame
        self._update_thresholds(force=True)
        self._is_continuation = True
        self._announced = False
        self._candidate = now
        self._emit_from = now
        self._last_emitted_end = max(self._last_emitted_end, now)
        self._last_voiced_end = now

    def _finish_noise(self, end: int, events: list) -> None:
        if not self._noise_run:
            return
        self._noise_run = False
        if end > self._noise_start:
            events.append(Noise(self._noise_start, end))

    def _rescan_voiced(self, first: int, now: int) -> None:
        index = first
        while index + self._frame <= now:
            if self._rms(index, index + self._frame) >= self._off:
                self._last_voiced_end = index + self._frame
            index += self._frame

    def _record_floor(self, level: float) -> None:
        self._floor_levels.append(level)
        if len(self._floor_levels) > self._floor_capacity:
            del self._floor_levels[: len(self._floor_levels) - self._floor_capacity]
        self._floor_tick += 1
        if self._floor_tick % 16 == 0:
            self._update_thresholds(force=False)

    def _update_thresholds(self, force: bool) -> None:
        if not self._floor_levels or not (force or len(self._floor_levels) >= 33):
            return
        ordered = sorted(self._floor_levels)
        percentile = ordered[len(ordered) // 5]
        config = self._config
        self._on = min(max(config.on_rms, config.floor_multiplier * percentile), max(config.on_rms, config.max_on_rms))
        self._off = self._on * config.off_ratio

    def _rms(self, start: int, end: int) -> float:
        return rms(self._buffer[start - self._buffer_start:end - self._buffer_start])

    def _trim(self) -> None:
        keep = self._emit_from if self._is_open else max(self._buffer_start, self._processed - self._pre_pad)
        drop = min(max(0, keep - self._buffer_start), len(self._buffer))
        if drop > 0:
            del self._buffer[:drop]
            self._buffer_start += drop


@dataclass(frozen=True)
class StreamJob:
    channel: str
    kind: str
    start_sample: int
    samples: array
    end_sample: int | None = None

    @property
    def start_seconds(self) -> float:
        return self.start_sample / SPEECH_RATE

    @property
    def end_seconds(self) -> float:
        return (self.end_sample if self.end_sample is not None else self.start_sample) / SPEECH_RATE


class ChannelStreamer:
    def __init__(self, channel: str, config: SegmenterConfig | None = None):
        self.channel = channel
        self._segmenter = SpeechSegmenter(config)

    @property
    def total_samples(self) -> int:
        return self._segmenter.total_samples

    def append(self, samples) -> list[StreamJob]:
        return self._jobs(self._segmenter.append(samples))

    def flush(self) -> list[StreamJob]:
        return self._jobs(self._segmenter.flush())

    def skip_gap(self, samples: int) -> list[StreamJob]:
        return self._jobs(self._segmenter.skip_gap(samples))

    def _jobs(self, events: list) -> list[StreamJob]:
        empty = array("f")
        jobs = []
        for event in events:
            if isinstance(event, Opened):
                jobs.append(StreamJob(self.channel, "typing", event.start_sample, empty))
            elif isinstance(event, Segment):
                jobs.append(StreamJob(self.channel, "final", event.start_sample, event.samples))
            elif isinstance(event, Dropped):
                jobs.append(StreamJob(self.channel, "final", 0, empty))
            elif isinstance(event, Noise):
                jobs.append(StreamJob(self.channel, "noise", event.start_sample, empty, event.end_sample))
        return jobs


__all__ = ["ChannelStreamer", "Dropped", "Noise", "Opened", "Segment", "SegmenterConfig", "SpeechSegmenter",
           "StreamJob"]
