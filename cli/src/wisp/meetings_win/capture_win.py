from __future__ import annotations

import threading
import time
from array import array
from typing import Callable

from wisp.meetings_win.audio import CaptureRing

POLL_SECONDS = 2.0
STEP_SECONDS = 0.05
IDLE_BEFORE_SILENCE = 0.15
SILENCE_MARGIN = 0.1
BLOCKED_HINTS = ("-9999", "-9996", "-9985", "unanticipated host error", "invalid device", "access")


class CaptureUnavailable(Exception):
    pass


def microphone_blocked_message() -> str:
    return ("O Windows não deixou o Wisp usar o microfone: libere em Configurações > Privacidade e segurança > Microfone "
            "(e permita apps de desktop).")


def load_portaudio():
    try:
        import pyaudiowpatch
    except ImportError as problem:
        raise CaptureUnavailable("A captura de áudio do Windows precisa do PyAudioWPatch, que não está instalado.") from problem
    return pyaudiowpatch


def _short(name: str) -> str:
    return name.split(" [Loopback]")[0].strip()


class PortAudioSource:
    def __init__(self, kind: str, module=None, clock: Callable[[], float] = time.perf_counter):
        self.kind = kind
        self.label = ""
        self._module = module
        self._clock = clock
        self._pa = None
        self._stream = None
        self._device: dict | None = None
        self._ring: CaptureRing | None = None
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._halt = threading.Event()
        self._last_data = 0.0
        self._covered = 0.0
        self._last_poll = 0.0
        self._silent_ok = kind == "system"

    def start(self, ring: CaptureRing, run_thread: bool = True) -> None:
        module = self._module or load_portaudio()
        self._module = module
        self._ring = ring
        self._pa = module.PyAudio()
        try:
            self._open(self._default_device())
        except CaptureUnavailable:
            self._terminate()
            raise
        except Exception as problem:
            self._terminate()
            raise CaptureUnavailable(self._explain(problem)) from problem
        now = self._clock()
        self._last_data = self._covered = self._last_poll = now
        if run_thread:
            self._halt.clear()
            self._thread = threading.Thread(target=self._run, name=f"wisp-capture-{self.kind}", daemon=True)
            self._thread.start()

    def stop(self) -> None:
        self._halt.set()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(timeout=5)
        self._thread = None
        with self._lock:
            self._close_stream()
        self._terminate()

    def _default_device(self) -> dict:
        pa, module = self._pa, self._module
        if self.kind == "mic":
            try:
                host = pa.get_host_api_info_by_type(module.paWASAPI)
                index = host.get("defaultInputDevice", -1)
                device = pa.get_device_info_by_index(index) if index is not None and index >= 0 else None
            except (OSError, ValueError, AssertionError):
                device = None
            if not device or device.get("maxInputChannels", 0) < 1:
                raise CaptureUnavailable("Não achei um microfone: ligue um e escolha como entrada padrão do Windows.")
            return device
        try:
            return pa.get_default_wasapi_loopback()
        except (OSError, ValueError, LookupError):
            raise CaptureUnavailable("Não achei uma saída de áudio para ouvir: confira o dispositivo de som do Windows.") from None

    def _open(self, device: dict) -> None:
        rate = int(device["defaultSampleRate"])
        channels = max(1, int(device["maxInputChannels"]))
        stream = self._pa.open(format=self._module.paFloat32, channels=channels, rate=rate, input=True,
                               input_device_index=device["index"], frames_per_buffer=max(256, rate // 50),
                               stream_callback=self._callback)
        with self._lock:
            self._close_stream()
            self._stream = stream
            self._device = device
            self.label = _short(str(device.get("name", ""))) or self.label

    def _close_stream(self) -> None:
        stream, self._stream = self._stream, None
        if stream is not None:
            try:
                stream.stop_stream()
            except Exception:
                pass
            try:
                stream.close()
            except Exception:
                pass

    def _terminate(self) -> None:
        pa, self._pa = self._pa, None
        if pa is not None:
            try:
                pa.terminate()
            except Exception:
                pass

    def _explain(self, problem: Exception) -> str:
        text = str(problem).lower()
        if self.kind == "mic" and any(hint in text for hint in BLOCKED_HINTS):
            return microphone_blocked_message()
        return f"Não consegui abrir o áudio ({problem})."

    def _callback(self, data, frames, time_info, status):
        device = self._device or {}
        rate = float(int(device.get("defaultSampleRate", 48000)))
        channels = max(1, int(device.get("maxInputChannels", 1)))
        now = self._clock()
        samples = array("f")
        samples.frombytes(data)
        start = now - frames / rate
        if self._ring is not None and len(samples):
            self._ring.push(samples, channels, rate, start)
        self._last_data = now
        self._covered = max(self._covered, now)
        return (None, self._module.paContinue)

    def _run(self) -> None:
        while not self._halt.wait(STEP_SECONDS):
            try:
                self.step()
            except Exception:
                pass

    def step(self) -> None:
        now = self._clock()
        if now - self._last_poll >= POLL_SECONDS:
            self._last_poll = now
            self._follow_default_device()
        if self._silent_ok and now - self._last_data > IDLE_BEFORE_SILENCE and self._ring is not None and self._device:
            rate = float(int(self._device["defaultSampleRate"]))
            channels = max(1, int(self._device["maxInputChannels"]))
            upto = now - SILENCE_MARGIN
            if upto > self._covered:
                frames = int((upto - self._covered) * rate)
                if frames > 0:
                    self._ring.push(array("f", bytes(4 * frames * channels)), channels, rate, self._covered)
                    self._covered += frames / rate

    def _follow_default_device(self) -> None:
        if self._pa is None:
            return
        try:
            device = self._default_device()
        except CaptureUnavailable:
            return
        current = self._device or {}
        if device.get("index") == current.get("index") and device.get("defaultSampleRate") == current.get("defaultSampleRate"):
            return
        try:
            self._open(device)
        except Exception:
            return
        self._last_data = self._covered = self._clock()
