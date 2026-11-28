from __future__ import annotations

import math
from array import array
from dataclasses import dataclass

from wisp.meetings_win.audio import SPEECH_RATE, rms


@dataclass(frozen=True)
class BleedConfig:
    frame_samples: int = 400
    max_lag_seconds: float = 0.15
    mic_active_rms: float = 0.002
    system_active_rms: float = 0.002
    min_overlap: float = 0.6
    min_correlation: float = 0.7
    max_level_ratio: float = 0.7
    min_frames: int = 40
    short_segment_frames: int = 80
    short_min_correlation: float = 0.85
    history_seconds: float = 90.0

    @property
    def max_lag_frames(self) -> int:
        return max(1, round(self.max_lag_seconds * SPEECH_RATE / self.frame_samples))

    @property
    def pad_samples(self) -> int:
        return self.max_lag_frames * self.frame_samples

    def required_correlation(self, frames: int) -> float:
        return max(self.min_correlation, self.short_min_correlation) if frames < self.short_segment_frames else self.min_correlation


class ChannelHistory:
    def __init__(self, capacity: int):
        self._capacity = max(1, capacity)
        self._ring = array("f")
        self._start = 0
        self.end = 0

    def append(self, new) -> None:
        if len(new) == 0:
            return
        if not self._ring:
            self._ring = array("f", bytes(4 * self._capacity))
        kept = new[-self._capacity:] if len(new) > self._capacity else new
        write = (self.end + len(new) - len(kept)) % self._capacity
        index = 0
        while index < len(kept):
            run = min(self._capacity - write, len(kept) - index)
            self._ring[write:write + run] = array("f", kept[index:index + run])
            index += run
            write = (write + run) % self._capacity
        self.end += len(new)
        self._start = max(self._start, self.end - self._capacity)

    def skip(self, count: int) -> None:
        self.end += max(0, count)
        self._start = self.end

    def window(self, start: int, stop: int) -> array | None:
        if stop <= start:
            return array("f")
        if start < self._start and self._start > 0:
            return None
        out = array("f", bytes(4 * (stop - start)))
        lower = max(start, self._start)
        upper = min(stop, self.end)
        while lower < upper:
            read = lower % self._capacity
            run = min(self._capacity - read, upper - lower)
            out[lower - start:lower - start + run] = self._ring[read:read + run]
            lower += run
        return out


def _envelope(samples, frames: int, frame: int) -> list[float]:
    return [rms(samples[i * frame:(i + 1) * frame]) for i in range(frames)]


def _correlation(a: list[float], b: list[float], offset: int) -> float:
    count = len(a)
    mean_a = sum(a) / count
    mean_b = sum(b[offset:offset + count]) / count
    cross = var_a = var_b = 0.0
    for index in range(count):
        x = a[index] - mean_a
        y = b[index + offset] - mean_b
        cross += x * y
        var_a += x * x
        var_b += y * y
    denominator = math.sqrt(var_a * var_b)
    return cross / denominator if denominator > 1e-12 else 0.0


class BleedDetector:
    @staticmethod
    def system_window(mic_start: int, mic_count: int, system: ChannelHistory, config: BleedConfig | None = None):
        config = config or BleedConfig()
        pad = config.pad_samples
        if mic_count < config.min_frames * config.frame_samples:
            return None
        return system.window(mic_start - pad, mic_start + mic_count + pad)

    @staticmethod
    def is_bleed(mic, mic_start: int, system: ChannelHistory, config: BleedConfig | None = None) -> bool:
        config = config or BleedConfig()
        window = BleedDetector.system_window(mic_start, len(mic), system, config)
        return window is not None and BleedDetector.judge(mic, window, config)

    @staticmethod
    def judge(mic, system_window, config: BleedConfig | None = None) -> bool:
        config = config or BleedConfig()
        frame = config.frame_samples
        lag_frames = config.max_lag_frames
        mic_frames = len(mic) // frame
        if mic_frames < config.min_frames or len(system_window) < (mic_frames + 2 * lag_frames) * frame:
            return False
        m = _envelope(mic, mic_frames, frame)
        s = _envelope(system_window, mic_frames + 2 * lag_frames, frame)
        if not any(x >= config.mic_active_rms for x in m) or not any(x >= config.system_active_rms for x in s):
            return False
        best_lag, best = 0, -1.0
        for lag in range(-lag_frames, lag_frames + 1):
            value = _correlation(m, s, lag_frames + lag)
            if value > best:
                best, best_lag = value, lag
        if best < config.required_correlation(mic_frames):
            return False
        active = overlapping = 0
        mic_energy = system_energy = 0.0
        for index in range(mic_frames):
            if m[index] < config.mic_active_rms:
                continue
            other = s[index + lag_frames + best_lag]
            active += 1
            if other >= config.system_active_rms:
                overlapping += 1
            mic_energy += m[index] * m[index]
            system_energy += other * other
        if active == 0 or overlapping / active < config.min_overlap:
            return False
        return math.sqrt(mic_energy) < math.sqrt(system_energy) * config.max_level_ratio
