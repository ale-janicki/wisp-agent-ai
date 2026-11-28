import threading
import types
from array import array

import pytest

from wisp.meetings_win import asr
from wisp.meetings_win.asr import FasterWhisperRecognizer, ModelHost, RecognizerUnavailable, Runtime, choose_runtime


def test_cuda_is_chosen_when_present_with_the_best_supported_type_else_cpu_int8():
    supported = {"cuda": {"float32", "int8", "int8_float32"}, "cpu": {"float32", "int8", "int8_float32"}}
    assert choose_runtime(1, supported) == ("cuda", "int8")
    supported["cuda"] = {"float16", "int8_float16", "int8", "float32"}
    assert choose_runtime(1, supported) == ("cuda", "float16")
    assert choose_runtime(0, supported) == ("cpu", "int8")
    assert choose_runtime(1, {"cuda": set(), "cpu": {"float32"}}) == ("cpu", "float32")


def test_the_host_never_holds_two_models_and_reloads_on_a_switch():
    live = {"now": 0, "peak": 0, "loads": []}

    def loader(key):
        live["now"] += 1
        live["peak"] = max(live["peak"], live["now"])
        live["loads"].append(key)
        return types.SimpleNamespace(key=key)

    def unloader(model):
        live["now"] -= 1

    host = ModelHost(loader, unloader)
    with host.lease("small") as one:
        assert one.key == "small"
    with host.lease("small"):
        pass
    with host.lease("large-v3") as two:
        assert two.key == "large-v3"
    with host.lease("small"):
        pass
    assert live["loads"] == ["small", "large-v3", "small"] and live["peak"] == 1
    host.unload()
    assert live["now"] == 0 and host.loaded is None


def test_two_threads_cannot_use_the_host_at_once():
    host = ModelHost(lambda key: object(), lambda model: None)
    inside = []
    overlap = []

    def work(key):
        with host.lease(key):
            inside.append(key)
            if len(inside) > 1:
                overlap.append(True)
            threading.Event().wait(0.02)
            inside.remove(key)

    threads = [threading.Thread(target=work, args=(k,)) for k in ("small", "large-v3", "small")]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert overlap == []


class FakeModel:
    def __init__(self, fail=None):
        self.calls = []
        self.fail = fail

    def transcribe(self, audio, **options):
        self.calls.append((len(audio), options))
        if self.fail:
            raise RuntimeError(self.fail)
        segment = types.SimpleNamespace(text=" Olá mundo ", start=0.5, end=2.0, avg_logprob=-0.2, no_speech_prob=0.1)
        return iter([segment]), types.SimpleNamespace(language="pt", language_probability=0.93)


class Store:
    def __init__(self, tmp_path):
        self.folder = lambda model_id: tmp_path / model_id
        self.is_installed = lambda model_id: True


def recognizer(model, tmp_path, runtime=None, profile="live"):
    host = ModelHost(lambda key: model, lambda m: None)
    return FasterWhisperRecognizer("small", Store(tmp_path), host, "whisper-small", runtime or Runtime("cpu", "int8"),
                                   profile=profile)


def test_live_profile_is_greedy_without_vad_and_returns_language_and_confidence(tmp_path):
    model = FakeModel()
    result = recognizer(model, tmp_path).transcribe(array("f", [0.1] * 16_000), "pt")
    (count, options), = model.calls
    assert count == 16_000
    assert options["language"] == "pt" and options["beam_size"] == 1 and options["vad_filter"] is False
    assert options["condition_on_previous_text"] is False
    assert [(s.text, s.start, s.end) for s in result.spans] == [("Olá mundo", 0.5, 2.0)]
    assert result.spans[0].confidence == pytest.approx(0.8187, abs=1e-3)
    assert result.language == "pt" and result.probability == pytest.approx(0.93)


def test_refine_profile_uses_beam_search_and_the_silero_vad(tmp_path):
    model = FakeModel()
    recognizer(model, tmp_path, profile="refine").transcribe(array("f", [0.1] * 160), None)
    options = model.calls[0][1]
    assert options["language"] is None and options["beam_size"] == 5 and options["vad_filter"] is True


def test_empty_audio_makes_no_call(tmp_path):
    model = FakeModel()
    assert recognizer(model, tmp_path).transcribe(array("f"), "pt").spans == []
    assert model.calls == []


def test_a_cuda_runtime_error_falls_back_to_cpu_once_and_keeps_going(tmp_path):
    loaded = []

    def load(folder, runtime):
        loaded.append(runtime.device)
        return FakeModel("Library cublas64_12.dll is not found") if runtime.device == "cuda" else FakeModel()

    runtime = Runtime("cuda", "int8")
    host = ModelHost(lambda key: load(key, runtime), lambda m: None)
    rec = FasterWhisperRecognizer("small", Store(tmp_path), host, "whisper-small", runtime)
    result = rec.transcribe(array("f", [0.1] * 160), "pt")
    assert [s.text for s in result.spans] == ["Olá mundo"]
    assert runtime.device == "cpu" and runtime.compute_type == "int8" and "cublas" in runtime.notice
    assert loaded == ["cuda", "cpu"]


def test_a_missing_model_is_a_clear_error_and_a_missing_library_too(tmp_path, monkeypatch):
    class Missing(Store):
        def __init__(self, tmp):
            super().__init__(tmp)
            self.is_installed = lambda model_id: False

    host = ModelHost(lambda key: FakeModel(), lambda m: None)
    rec = FasterWhisperRecognizer("small", Missing(tmp_path), host, "whisper-small", Runtime("cpu", "int8"))
    with pytest.raises(RecognizerUnavailable, match="modelo"):
        rec.transcribe(array("f", [0.1] * 160), "pt")
    monkeypatch.setitem(__import__("sys").modules, "faster_whisper", None)
    with pytest.raises(RecognizerUnavailable, match="faster-whisper"):
        asr.load_faster_whisper(tmp_path, Runtime("cpu", "int8"))


def test_unload_releases_the_model(tmp_path):
    model = FakeModel()
    rec = recognizer(model, tmp_path)
    rec.transcribe(array("f", [0.1] * 160), "pt")
    rec.unload()
    assert rec._host.loaded is None


def test_the_decode_stops_between_chunks_when_asked(tmp_path):
    from wisp.meetings_win.asr import RecognitionInterrupted

    class Chunks(FakeModel):
        def transcribe(self, audio, **options):
            segments = (types.SimpleNamespace(text=f"parte {n}", start=n, end=n + 1, avg_logprob=-0.1, no_speech_prob=0.0)
                        for n in range(5))
            return segments, types.SimpleNamespace(language="pt", language_probability=0.9)

    rec = recognizer(Chunks(), tmp_path, profile="refine")
    seen = {"n": 0}

    def stop():
        seen["n"] += 1
        return seen["n"] > 2

    with pytest.raises(RecognitionInterrupted):
        rec.transcribe(array("f", [0.1] * 160), "pt", should_stop=stop)
    assert seen["n"] == 3
