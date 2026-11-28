from __future__ import annotations

import math
import threading
from array import array
from collections import deque
from dataclasses import dataclass
from operator import mul

try:
    import numpy as _numpy
except ImportError:  # pragma: no cover
    _numpy = None

SAMPLE_RATE = 48_000
SPEECH_RATE = 16_000
MAX_CHANNELS = 4


def _view(samples):
    if _numpy is None or not isinstance(samples, array) or samples.typecode != "f":
        return None
    return _numpy.frombuffer(samples, dtype=_numpy.float32)


def from_numpy(values) -> array:
    out = array("f")
    out.frombytes(_numpy.ascontiguousarray(values, dtype=_numpy.float32).tobytes())
    return out


def rms(samples) -> float:
    count = len(samples)
    if count == 0:
        return 0.0
    view = _view(samples)
    if view is not None:
        return float(_numpy.sqrt(_numpy.dot(view, view) / count))
    return math.sqrt(sum(map(mul, samples, samples)) / count)


def mean_squares(samples, size: int) -> list[float]:
    blocks = len(samples) // size
    view = _view(samples)
    if view is not None and blocks:
        shaped = view[:blocks * size].reshape(blocks, size).astype(_numpy.float64)
        return (shaped * shaped).mean(axis=1).tolist()
    return [sum(x * x for x in samples[i * size:(i + 1) * size]) / size for i in range(blocks)]


def mono_downmix(interleaved, channels: int) -> array:
    if channels <= 0:
        return array("f")
    if channels == 1:
        return array("f", interleaved)
    frames = len(interleaved) // channels
    view = _view(interleaved) if isinstance(interleaved, array) else None
    if view is not None:
        return from_numpy(view[:frames * channels].reshape(frames, channels).mean(axis=1))
    scale = 1 / channels
    out = array("f", bytes(4 * frames))
    for channel in range(channels):
        lane = interleaved[channel:frames * channels:channels]
        for index in range(frames):
            out[index] += lane[index]
    for index in range(frames):
        out[index] *= scale
    return out


class LinearResampler:
    def __init__(self, input_rate: float, output_rate: float = SAMPLE_RATE):
        self._identity = input_rate == output_rate or input_rate <= 0 or output_rate <= 0
        self._step = 1.0 if self._identity else input_rate / output_rate
        self._buffer = array("f")
        self._position = 0.0

    def process(self, data) -> array:
        if self._identity:
            return array("f", data)
        buffer = self._buffer
        buffer.extend(data)
        position = self._position
        step = self._step
        count = len(buffer)
        if _numpy is not None:
            lane = _numpy.frombuffer(buffer, dtype=_numpy.float32)
            estimate = max(0, math.ceil((count - 1 - position) / step) + 1)
            where = position + step * _numpy.arange(estimate)
            where = where[where < count - 1]
            low = where.astype(_numpy.int64)
            fraction = (where - low).astype(_numpy.float32)
            out = from_numpy(lane[low] + (lane[low + 1] - lane[low]) * fraction)
            del lane
            position = position + step * len(where)
            consumed = min(int(position), count)
            del buffer[:consumed]
            self._position = position - consumed
            return out
        out = array("f")
        while int(position) + 1 < count:
            index = int(position)
            fraction = position - index
            out.append(buffer[index] + (buffer[index + 1] - buffer[index]) * fraction)
            position += step
        consumed = min(int(position), count)
        del buffer[:consumed]
        self._position = position - consumed
        return out


class Decimator48To16:
    def __init__(self):
        self._carry = array("f")

    def process(self, data) -> array:
        carry = self._carry
        carry.extend(data)
        groups = len(carry) // 3
        if groups == 0:
            return array("f")
        view = _view(carry)
        if view is not None:
            out = from_numpy(view[:groups * 3].reshape(groups, 3).mean(axis=1))
            del view
            del carry[:groups * 3]
            return out
        out = array("f", ((carry[i] + carry[i + 1] + carry[i + 2]) / 3 for i in range(0, groups * 3, 3)))
        del carry[:groups * 3]
        return out


@dataclass(frozen=True)
class RingSlot:
    samples: array
    channels: int
    rate: float
    time: float


class CaptureRing:
    def __init__(self, slot_frames: int = 4096, slot_count: int = 48):
        self._slot_frames = slot_frames
        self._slot_count = slot_count
        self._slots: deque[RingSlot] = deque()
        self.overruns = 0

    def push(self, interleaved, channels: int, rate: float, time: float) -> None:
        if channels <= 0 or rate <= 0:
            return
        frames = len(interleaved) // channels
        stored = min(channels, MAX_CHANNELS)
        offset = 0
        while offset < frames:
            if len(self._slots) >= self._slot_count:
                self.overruns += 1
                return
            count = min(self._slot_frames, frames - offset)
            if stored == channels:
                chunk = array("f", interleaved[offset * channels:(offset + count) * channels])
            else:
                chunk = array("f")
                for frame in range(offset, offset + count):
                    chunk.extend(interleaved[frame * channels:frame * channels + stored])
            self._slots.append(RingSlot(chunk, stored, rate, time + offset / rate))
            offset += count

    def pop(self) -> RingSlot | None:
        try:
            return self._slots.popleft()
        except IndexError:
            return None


class CaptureGate:
    def __init__(self):
        self._cuts: list[tuple[float, float]] = []
        self._open_since: float | None = None

    @property
    def is_paused(self) -> bool:
        return self._open_since is not None

    def pause(self, now: float) -> None:
        if self._open_since is None:
            self._open_since = now

    def resume(self, now: float) -> None:
        if self._open_since is None:
            return
        self._cuts.append((self._open_since, max(self._open_since, now)))
        self._open_since = None

    def admit(self, time: float) -> float | None:
        if self._open_since is not None and time >= self._open_since:
            return None
        shift = 0.0
        for start, end in self._cuts:
            if time >= end:
                shift += end - start
            elif time >= start:
                return None
        return time - shift


class StereoMixer:
    def __init__(self, max_skew_frames: int = SAMPLE_RATE // 2, tolerance_frames: int = SAMPLE_RATE // 40):
        self._max_skew = max(0, max_skew_frames)
        self._tolerance = max(0, tolerance_frames)
        self._mic = array("f")
        self._system = array("f")
        self._origin: float | None = None
        self._pending_mic: list[tuple[float, array]] = []
        self._pending_system: list[tuple[float, array]] = []
        self._emitted = 0

    def push_mic(self, samples, at: float) -> None:
        self._push(samples, at, self._pending_mic, True)

    def push_system(self, samples, at: float) -> None:
        self._push(samples, at, self._pending_system, False)

    def _push(self, samples, at: float, pending: list, is_mic: bool) -> None:
        if self._origin is None:
            pending.append((at, array("f", samples)))
            self._resolve_origin(force=False)
            return
        self._place(samples, at, is_mic)

    def pull(self, flush: bool = False) -> array:
        if self._origin is None and flush:
            self._resolve_origin(force=True)
        if self._origin is None:
            return array("f")
        shorter = min(len(self._mic), len(self._system))
        longer = max(len(self._mic), len(self._system))
        frames = longer if flush else max(shorter, longer - self._max_skew)
        if frames <= 0:
            return array("f")
        out = array("f", bytes(8 * frames))
        mic_count = min(frames, len(self._mic))
        system_count = min(frames, len(self._system))
        out[0:mic_count * 2:2] = self._mic[:mic_count]
        out[1:system_count * 2:2] = self._system[:system_count]
        del self._mic[:mic_count]
        del self._system[:system_count]
        self._emitted += frames
        return out

    def _resolve_origin(self, force: bool) -> None:
        mic_frames = sum(len(s) for _, s in self._pending_mic)
        system_frames = sum(len(s) for _, s in self._pending_system)
        both = bool(self._pending_mic) and bool(self._pending_system)
        if not (force or both or mic_frames > self._max_skew or system_frames > self._max_skew):
            return
        firsts = [pending[0][0] for pending in (self._pending_mic, self._pending_system) if pending]
        if not firsts:
            return
        self._origin = min(firsts)
        for at, samples in self._pending_mic:
            self._place(samples, at, True)
        for at, samples in self._pending_system:
            self._place(samples, at, False)
        self._pending_mic = []
        self._pending_system = []

    def _place(self, samples, at: float, is_mic: bool) -> None:
        position = round((at - (self._origin if self._origin is not None else at)) * SAMPLE_RATE)
        lane = self._mic if is_mic else self._system
        chunk = array("f", samples)
        start = position
        if start < self._emitted:
            cut = min(self._emitted - start, len(chunk))
            chunk = chunk[cut:]
            start += cut
        end = self._emitted + len(lane)
        if start > end + self._tolerance:
            lane.extend(array("f", bytes(4 * (start - end))))
        elif start < end - self._tolerance:
            chunk = chunk[min(end - start, len(chunk)):]
        lane.extend(chunk)


@dataclass(frozen=True)
class AlignedChunk:
    samples: array
    gap_seconds: float | None = None


class LiveAudioAligner:
    TOLERANCE_FRAMES = 1_200
    MAX_FILL_SECONDS = 2.0

    def __init__(self):
        self._lock = threading.Lock()
        self._origin: float | None = None
        self._ends: dict[str, int] = {}

    def align(self, samples, channel: str, at: float) -> AlignedChunk:
        with self._lock:
            base = at if self._origin is None else self._origin
            self._origin = base
            cap = int(self.MAX_FILL_SECONDS * SAMPLE_RATE)
            start = round((at - base) * SAMPLE_RATE)
            first = channel not in self._ends
            end = self._ends.get(channel, 0)
            data = array("f", samples)
            if start < 0:
                kept = data[-start:]
                self._ends[channel] = len(kept)
                return AlignedChunk(kept)
            if start > end + (0 if first else self.TOLERANCE_FRAMES):
                gap = start - end
                self._ends[channel] = start + len(data)
                if gap > cap:
                    return AlignedChunk(data, gap / SAMPLE_RATE)
                return AlignedChunk(array("f", bytes(4 * gap)) + data)
            if start < end - self.TOLERANCE_FRAMES:
                kept = data[end - start:]
                self._ends[channel] = end + len(kept)
                return AlignedChunk(kept)
            self._ends[channel] = end + len(data)
            return AlignedChunk(data)
