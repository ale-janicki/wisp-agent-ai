from __future__ import annotations

import contextlib
import math
import threading
from dataclasses import dataclass, field
from typing import Callable, Iterator, Protocol

from wisp.meetings_win.transcript import RecognizedSpan

CUDA_TYPES = ("float16", "int8_float16", "int8", "float32")
CPU_TYPES = ("int8", "int8_float32", "float32")


class RecognizerUnavailable(Exception):
    pass


class RecognitionInterrupted(Exception):
    pass


@dataclass
class RecognizeResult:
    spans: list[RecognizedSpan]
    language: str | None = None
    probability: float | None = None


class SpeechRecognizer(Protocol):
    engine_name: str

    def transcribe(self, samples, language: str | None, should_stop: Callable[[], bool] | None = None) -> RecognizeResult: ...

    def unload(self) -> None: ...


def choose_runtime(cuda_devices: int, supported: dict[str, set[str]]) -> tuple[str, str]:
    if cuda_devices > 0:
        for kind in CUDA_TYPES:
            if kind in supported.get("cuda", set()):
                return "cuda", kind
    for kind in CPU_TYPES:
        if kind in supported.get("cpu", set()):
            return "cpu", kind
    return "cpu", "int8"


@dataclass
class Runtime:
    device: str
    compute_type: str
    notice: str | None = field(default=None)

    @staticmethod
    def detect() -> "Runtime":
        try:
            import ctranslate2
        except ImportError:
            return Runtime("cpu", "int8")
        try:
            cuda = ctranslate2.get_cuda_device_count()
        except Exception:
            cuda = 0
        supported = {}
        for device in ("cuda", "cpu"):
            try:
                supported[device] = set(ctranslate2.get_supported_compute_types(device)) if device == "cpu" or cuda else set()
            except Exception:
                supported[device] = set()
        return Runtime(*choose_runtime(cuda, supported))

    def fall_back_to_cpu(self, reason: str) -> None:
        self.device, self.compute_type = "cpu", "int8"
        self.notice = f"A GPU não funcionou ({reason}); usando a CPU."


class ModelHost:
    def __init__(self, loader: Callable[[str], object], unloader: Callable[[object], None] | None = None):
        self._loader = loader
        self._unloader = unloader or (lambda model: None)
        self._lock = threading.RLock()
        self._model = None
        self.loaded: str | None = None

    @contextlib.contextmanager
    def lease(self, key: str) -> Iterator[object]:
        with self._lock:
            if self.loaded != key:
                self._drop()
                self._model = self._loader(key)
                self.loaded = key
            yield self._model

    def reload(self, key: str) -> None:
        with self._lock:
            self._drop()
            self._model = self._loader(key)
            self.loaded = key

    def unload(self) -> None:
        with self._lock:
            self._drop()

    def _drop(self) -> None:
        if self._model is not None:
            self._unloader(self._model)
        self._model = None
        self.loaded = None


def add_cuda_dll_directories() -> None:
    import importlib.util
    import os
    import sys

    if sys.platform != "win32":
        return
    for package in ("nvidia.cublas", "nvidia.cudnn"):
        try:
            spec = importlib.util.find_spec(package)
        except (ImportError, ValueError):
            continue
        for base in (spec.submodule_search_locations or []) if spec else []:
            folder = os.path.join(base, "bin")
            if os.path.isdir(folder):
                os.add_dll_directory(folder)
                os.environ["PATH"] = folder + os.pathsep + os.environ.get("PATH", "")


def load_faster_whisper(folder, runtime: Runtime):
    try:
        add_cuda_dll_directories()
        from faster_whisper import WhisperModel
    except ImportError as problem:
        raise RecognizerUnavailable("o pacote faster-whisper não está instalado") from problem
    try:
        return WhisperModel(str(folder), device=runtime.device, compute_type=runtime.compute_type)
    except RuntimeError as problem:
        if runtime.device != "cuda":
            raise
        runtime.fall_back_to_cpu(str(problem)[:120])
        return WhisperModel(str(folder), device="cpu", compute_type="int8")


PROFILES = {
    "live": {"beam_size": 1, "vad_filter": False},
    "refine": {"beam_size": 5, "vad_filter": True, "vad_parameters": {"min_silence_duration_ms": 500}},
}


class FasterWhisperRecognizer:
    def __init__(self, model_id: str, store, host: ModelHost, engine_name: str, runtime: Runtime | None = None,
                 profile: str = "live"):
        self.model_id = model_id
        self.engine_name = engine_name
        self._store = store
        self._host = host
        self._runtime = runtime or Runtime.detect()
        self._profile = profile

    def transcribe(self, samples, language: str | None, should_stop: Callable[[], bool] | None = None) -> RecognizeResult:
        if len(samples) == 0:
            return RecognizeResult([])
        if not self._store.is_installed(self.model_id):
            raise RecognizerUnavailable(f"o modelo {self.model_id} ainda não foi baixado")
        try:
            return self._run(samples, language, should_stop)
        except RuntimeError as problem:
            if self._runtime.device != "cuda":
                raise
            self._runtime.fall_back_to_cpu(str(problem)[:120])
            self._host.unload()
            return self._run(samples, language, should_stop)

    def _run(self, samples, language: str | None, should_stop: Callable[[], bool] | None = None) -> RecognizeResult:
        import numpy

        audio = numpy.frombuffer(samples, dtype=numpy.float32) if hasattr(samples, "typecode") else numpy.asarray(samples, dtype=numpy.float32)
        with self._host.lease(self.model_id) as model:
            segments, info = model.transcribe(audio, language=language, condition_on_previous_text=False,
                                              **PROFILES[self._profile])
            spans = []
            for segment in segments:
                if should_stop is not None and should_stop():
                    raise RecognitionInterrupted()
                text = segment.text.strip()
                if text:
                    spans.append(RecognizedSpan(text, float(segment.start), float(segment.end),
                                                max(0.0, min(1.0, math.exp(segment.avg_logprob)))))
        return RecognizeResult(spans, getattr(info, "language", None), getattr(info, "language_probability", None))

    def unload(self) -> None:
        if self._host.loaded == self.model_id:
            self._host.unload()


def make_host(store, runtime: Runtime, load=load_faster_whisper) -> ModelHost:
    return ModelHost(lambda key: load(store.folder(key), runtime), lambda model: None)
