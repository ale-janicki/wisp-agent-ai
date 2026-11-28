from __future__ import annotations

import shutil
import threading
import time
import uuid
from array import array
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Protocol

from wisp.meetings_win import recordings
from wisp.meetings_win.audio import (SAMPLE_RATE, CaptureGate, CaptureRing, LinearResampler, LiveAudioAligner, StereoMixer,
                                     mono_downmix, rms)
from wisp.meetings_win.insights import RecordingLimitClock
from wisp.meetings_win.transcript import iso
from wisp.meetings_win.wavfile import StereoWavWriter

TICK_SECONDS = 0.05
MIN_FREE_BYTES = 200 * 1024 * 1024
STALL_SECONDS = 5.0
SILENCE_SECONDS = 10.0
HEALTH_SECONDS = 5.0
HEADER_SECONDS = 5.0
LEVEL_FLOOR_DB = -60.0

MESSAGES = {
    "mic_stalled": "o microfone parou",
    "system_stalled": "o áudio do computador parou",
    "system_silent": "não estou ouvindo o áudio do computador: confira a saída de som e o volume",
    "overrun": "o computador está sobrecarregado e partes do áudio foram perdidas",
}


class RecorderError(Exception):
    pass


class Source(Protocol):
    label: str

    def start(self, ring: CaptureRing) -> None: ...

    def stop(self) -> None: ...


def normalized_level(level: float) -> float:
    if level <= 0:
        return 0.0
    import math

    return min(1.0, max(0.0, (20 * math.log10(level) - LEVEL_FLOOR_DB) / -LEVEL_FLOOR_DB))


class _Lane:
    def __init__(self, channel: str, source: Source | None):
        self.channel = channel
        self.source = source
        self.ring = CaptureRing()
        self.resampler: LinearResampler | None = None
        self.rate = 0.0
        self.arrived = 0
        self.level = 0.0
        self.silent_for = 0
        self.silent = False
        self.last_progress: float | None = None
        self.seen = 0
        self.stalled = False


class MeetingRecorder:
    def __init__(self, root: Path, sources: str, mic: Source | None, system: Source | None, language: str | None = None,
                 limit_seconds: float = 7200.0, clock: Callable[[], float] = time.perf_counter,
                 now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
                 free_bytes: Callable[[Path], int] = lambda path: shutil.disk_usage(path).free, live=None,
                 on_event: Callable[..., None] = lambda *a, **k: None, detected_app: str | None = None):
        self.root = Path(root)
        self.sources = sources
        self.mic, self.system = mic, system
        self._language = language
        self._clock, self._now, self._free = clock, now, free_bytes
        self._live = live
        self._on_event = on_event
        self._detected_app = detected_app
        self._limit = RecordingLimitClock(limit_seconds)
        self._gate = CaptureGate()
        self._mixer = StereoMixer()
        self._aligner = LiveAudioAligner()
        self._lanes = {"mic": _Lane("mic", mic if sources != "system" else None),
                       "system": _Lane("system", system if sources != "mic" else None)}
        self._lock = threading.RLock()
        self.folder: Path | None = None
        self._writer: StereoWavWriter | None = None
        self._thread: threading.Thread | None = None
        self._stop_thread = threading.Event()
        self._started_at = 0.0
        self._last_health = 0.0
        self._last_header = 0.0
        self._pauses: list[dict] = []
        self._bookmarks: list[dict] = []
        self._started: list[Source] = []
        self._stopped = False
        self.fatal: str | None = None
        self.paused = False

    def start(self, run_thread: bool = True) -> Path:
        started = self._now()
        self.root.mkdir(parents=True, exist_ok=True)
        if self._free(self.root) < MIN_FREE_BYTES:
            raise RecorderError("Pouco espaço em disco: libere pelo menos 200 MB para gravar.")
        folder = recordings.create_folder(self.root, started)
        try:
            lane = self._lanes
            meta = recordings.new_meta(
                started, mic=lane["mic"].source.label if lane["mic"].source else None,
                system=lane["system"].source.label if lane["system"].source else None, sources=self.sources,
                detected_app=self._detected_app, language=self._language)
            recordings.write_meta(folder, meta)
            self._writer = StereoWavWriter(folder / "audio.wav")
            for name in ("mic", "system"):
                source = lane[name].source
                if source is not None:
                    source.start(lane[name].ring)
                    self._started.append(source)
        except BaseException:
            for source in reversed(self._started):
                try:
                    source.stop()
                except Exception:
                    pass
            if self._writer is not None:
                self._writer.close()
            shutil.rmtree(folder, ignore_errors=True)
            raise
        self.folder = folder
        self._started_at = self._last_health = self._last_header = self._clock()
        self._limit.start(self._started_at)
        if run_thread:
            self._thread = threading.Thread(target=self._loop, name="wisp-recorder", daemon=True)
            self._thread.start()
        return folder

    def _loop(self) -> None:
        while not self._stop_thread.wait(TICK_SECONDS):
            try:
                self.tick()
            except Exception as problem:
                self._fail(f"a gravação falhou: {problem}")
                return

    def abort(self) -> None:
        self._stop_sources()
        if self._writer is not None:
            self._writer.close()

    def _stop_sources(self) -> None:
        self._stop_thread.set()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(timeout=5)
        for source in reversed(self._started):
            try:
                source.stop()
            except Exception:
                pass
        self._started = []

    def stop(self, progress: Callable[[float], None] | None = None) -> dict:
        if self.folder is None or self._writer is None:
            raise RecorderError("não há gravação em andamento")
        now = self._clock()
        if self.paused:
            self.resume()
        self._stop_sources()
        with self._lock:
            self._drain(now)
            tail = self._mixer.pull(flush=True)
            failure = None
            try:
                if len(tail):
                    self._writer.write(tail)
                    self._frames_written += len(tail) // 2
                self._writer.close()
            except OSError as problem:
                failure = f"não consegui gravar o áudio: {problem}"
        frames = self._frames_written
        duration = frames / SAMPLE_RATE
        pauses, bookmarks = list(self._pauses), list(self._bookmarks)

        def finish(meta: dict) -> None:
            meta["duration_s"] = duration
            meta["status"] = recordings.FAILED if (failure or self.fatal and frames == 0) else recordings.TRANSCRIBING
            if failure or (self.fatal and frames == 0):
                meta["failure"] = failure or self.fatal
            if pauses:
                meta["pauses"] = pauses
            if bookmarks:
                meta["bookmarks"] = bookmarks

        recordings.update_meta(self.folder, finish)
        if progress:
            progress(1.0)
        self._stopped = True
        return {"folder": self.folder, "duration_s": duration, "failure": failure or (self.fatal if frames == 0 else None)}

    _frames_written = 0

    def tick(self, now: float | None = None) -> None:
        now = self._clock() if now is None else now
        with self._lock:
            if self._writer is None or self._stopped:
                return
            self._drain(now)
            pulled = self._mixer.pull()
            if len(pulled):
                try:
                    self._writer.write(pulled)
                except OSError as problem:
                    self._fail(f"não consegui gravar o áudio: {problem}")
                    return
                self._frames_written += len(pulled) // 2
            if now - self._last_header >= HEADER_SECONDS:
                self._last_header = now
                self._writer.flush_header()
            if now - self._last_health >= HEALTH_SECONDS:
                self._last_health = now
                self._health(now)
            self._watch(now)
            event = self._limit.tick(now)
            if event:
                kind, detail = event
                self._on_event("limit_warning" if kind == "warning" else "limit_reached", detail)

    def _drain(self, now: float) -> None:
        for lane in self._lanes.values():
            lane.level *= 0.8
            while (slot := lane.ring.pop()) is not None:
                lane.arrived += len(slot.samples)
                adjusted = self._gate.admit(slot.time)
                if adjusted is None:
                    continue
                mono = mono_downmix(slot.samples, slot.channels)
                if lane.resampler is None or slot.rate != lane.rate:
                    lane.resampler, lane.rate = LinearResampler(slot.rate, SAMPLE_RATE), slot.rate
                out = lane.resampler.process(mono)
                if not len(out):
                    continue
                lane.level = max(lane.level, normalized_level(rms(out)))
                self._silence(lane, out)
                if lane.channel == "mic":
                    self._mixer.push_mic(out, at=adjusted)
                else:
                    self._mixer.push_system(out, at=adjusted)
                if self._live is not None:
                    aligned = self._aligner.align(out, lane.channel, adjusted)
                    if aligned.gap_seconds:
                        self._live.skip_gap(seconds=aligned.gap_seconds, channel=lane.channel)
                    if len(aligned.samples):
                        self._live.push48k(aligned.samples, lane.channel)

    def _silence(self, lane: _Lane, samples: array) -> None:
        if lane.channel != "system":
            return
        if any(abs(x) > 1e-6 for x in samples):
            lane.silent_for = 0
            lane.silent = False
            return
        lane.silent_for += len(samples)
        if lane.silent_for >= SILENCE_SECONDS * SAMPLE_RATE:
            lane.silent = True

    def _watch(self, now: float) -> None:
        for lane in self._lanes.values():
            if lane.source is None:
                continue
            if lane.last_progress is None:
                lane.last_progress, lane.seen = now, lane.arrived
            elif lane.arrived > lane.seen:
                lane.last_progress, lane.seen = now, lane.arrived
                lane.stalled = False
            elif now - lane.last_progress >= STALL_SECONDS:
                lane.stalled = True

    def _health(self, now: float) -> None:
        try:
            free = self._free(self.folder)
        except OSError:
            return
        if free < MIN_FREE_BYTES:
            self._fail("O espaço em disco acabou: a gravação parou.")

    def _fail(self, reason: str) -> None:
        if self.fatal is None:
            self.fatal = reason
            self._on_event("fatal", reason)

    def warnings(self) -> list[str]:
        out = []
        mic, system = self._lanes["mic"], self._lanes["system"]
        if mic.stalled:
            out.append(MESSAGES["mic_stalled"])
        if system.stalled:
            out.append(MESSAGES["system_stalled"])
        if system.source is not None and system.silent:
            out.append(MESSAGES["system_silent"])
        if any(lane.ring.overruns for lane in self._lanes.values()):
            out.append(MESSAGES["overrun"])
        return out

    def levels(self) -> dict:
        return {"mic": self._lanes["mic"].level, "system": self._lanes["system"].level}

    def elapsed(self) -> float:
        return self._limit.active(self._clock())

    def pause(self) -> None:
        with self._lock:
            if self.paused:
                return
            now = self._clock()
            self.paused = True
            self._gate.pause(now)
            self._limit.pause(now)
            self._pauses.append({"at_s": self._limit.active(now), "started_at": iso(self._now())})
            if self._live is not None:
                self._live.flush_open_segments()
            self._save_pauses()

    def resume(self) -> None:
        with self._lock:
            if not self.paused:
                return
            now = self._clock()
            self.paused = False
            self._gate.resume(now)
            self._limit.resume(now)
            if self._pauses and "ended_at" not in self._pauses[-1]:
                self._pauses[-1]["ended_at"] = iso(self._now())
            self._save_pauses()

    def _save_pauses(self) -> None:
        if self.folder is not None:
            pauses = list(self._pauses)
            try:
                recordings.update_meta(self.folder, lambda m: m.update(pauses=pauses))
            except (OSError, ValueError):
                pass

    def bookmark(self, label: str = "") -> dict:
        mark = {"id": str(uuid.uuid4()), "time": self.elapsed(), "label": label.strip()}
        self._bookmarks.append(mark)
        return mark

    @property
    def bookmarks(self) -> list[dict]:
        return list(self._bookmarks)

    @property
    def pauses(self) -> list[dict]:
        return list(self._pauses)
