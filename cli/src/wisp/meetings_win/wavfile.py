from __future__ import annotations

import struct
import sys
from array import array
from pathlib import Path
from typing import Iterator

from wisp.meetings_win import audio as _audio
from wisp.meetings_win.audio import SAMPLE_RATE

HEADER_BYTES = 44


def _header(rate: int, channels: int, data_bytes: int) -> bytes:
    block = channels * 2
    return (b"RIFF" + struct.pack("<I", 36 + data_bytes) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * block, block, 16)
            + b"data" + struct.pack("<I", data_bytes))


class StereoWavWriter:
    def __init__(self, path: Path, rate: int = SAMPLE_RATE, channels: int = 2):
        self.path = Path(path)
        self._rate = rate
        self._channels = channels
        self._bytes = 0
        self._file = open(self.path, "wb")
        self._file.write(_header(rate, channels, 0))
        self._file.flush()

    @property
    def frames(self) -> int:
        return self._bytes // (2 * self._channels)

    def write(self, interleaved) -> None:
        np = _audio._numpy
        if np is not None:
            floats = np.asarray(interleaved, dtype=np.float32)
            data = np.clip(np.rint(floats * 32767), -32768, 32767).astype("<i2").tobytes()
        else:
            pcm = array("h", (max(-32768, min(32767, round(x * 32767))) for x in interleaved))
            if sys.byteorder == "big":
                pcm.byteswap()
            data = pcm.tobytes()
        self._file.write(data)
        self._bytes += len(data)

    def flush_header(self) -> None:
        self._file.flush()
        end = self._file.tell()
        self._file.seek(0)
        self._file.write(_header(self._rate, self._channels, self._bytes))
        self._file.seek(end)
        self._file.flush()

    def close(self) -> None:
        if self._file.closed:
            return
        self.flush_header()
        self._file.close()


def _layout(blob: bytes) -> tuple[int, int, int] | None:
    if len(blob) < 12 or blob[:4] != b"RIFF" or blob[8:12] != b"WAVE":
        return None
    position = 12
    channels = rate = 0
    while position + 8 <= len(blob):
        tag = blob[position:position + 4]
        size = struct.unpack("<I", blob[position + 4:position + 8])[0]
        body = position + 8
        if tag == b"fmt " and body + 16 <= len(blob):
            _, channels, rate = struct.unpack("<HHI", blob[body:body + 8])
        if tag == b"data":
            return (channels, rate, body) if channels and rate else None
        position = body + size + (size & 1)
    return None


def repair_header(path: Path) -> int:
    path = Path(path)
    try:
        with open(path, "r+b") as handle:
            layout = _layout(handle.read(4096))
            if layout is None:
                return 0
            channels, rate, offset = layout
            handle.seek(0, 2)
            size = handle.tell()
            frames = max(0, size - offset) // (2 * channels)
            data_bytes = frames * 2 * channels
            handle.seek(4)
            handle.write(struct.pack("<I", offset - 8 + data_bytes))
            handle.seek(offset - 4)
            handle.write(struct.pack("<I", data_bytes))
            return frames
    except OSError:
        return 0


def info(path: Path) -> tuple[int, int, int] | None:
    try:
        with open(path, "rb") as handle:
            layout = _layout(handle.read(4096))
            if layout is None:
                return None
            channels, rate, offset = layout
            handle.seek(0, 2)
            return rate, channels, max(0, handle.tell() - offset) // (2 * channels)
    except OSError:
        return None


def _lanes(raw: bytes, channels: int) -> tuple[array, ...]:
    np = _audio._numpy
    if np is not None:
        shaped = np.frombuffer(raw, dtype="<i2").reshape(-1, channels).astype(np.float32) / 32767
        return tuple(_audio.from_numpy(shaped[:, c]) for c in range(channels))
    pcm = array("h")
    pcm.frombytes(raw)
    if sys.byteorder == "big":
        pcm.byteswap()
    return tuple(array("f", (x / 32767 for x in pcm[c::channels])) for c in range(channels))


def read_blocks(path: Path, block_frames: int = SAMPLE_RATE) -> Iterator[tuple[array, ...]]:
    found = info(path)
    if found is None:
        return
    _, channels, frames = found
    with open(path, "rb") as handle:
        layout = _layout(handle.read(4096))
        handle.seek(layout[2])
        remaining = frames
        while remaining > 0:
            count = min(block_frames, remaining)
            raw = handle.read(count * 2 * channels)
            got = len(raw) // (2 * channels)
            if got == 0:
                return
            yield _lanes(raw[:got * 2 * channels], channels)
            remaining -= got


def read_frames(path: Path, start: int, count: int) -> tuple[array, ...]:
    found = info(path)
    if found is None or count <= 0:
        return ()
    _, channels, frames = found
    first = max(0, start)
    last = min(frames, start + count)
    lanes = [array("f", bytes(4 * count)) for _ in range(channels)]
    if last > first:
        with open(path, "rb") as handle:
            layout = _layout(handle.read(4096))
            handle.seek(layout[2] + first * 2 * channels)
            raw = handle.read((last - first) * 2 * channels)
        got = _lanes(raw[:len(raw) // (2 * channels) * 2 * channels], channels)
        for channel in range(channels):
            lanes[channel][first - start:first - start + len(got[channel])] = got[channel]
    return tuple(lanes)
