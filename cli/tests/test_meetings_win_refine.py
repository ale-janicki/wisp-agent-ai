import math
import threading
from array import array
from datetime import datetime, timezone

import pytest

from wisp.meetings_win.asr import RecognizeResult
from wisp.meetings_win.hallucination import ChannelEnvelope, collapse_loops, filter_spans, is_nordic_gibberish, normalized
from wisp.meetings_win.language import engine_of
from wisp.meetings_win.refine import PostCallRefiner, HighQualityDecimator
from wisp.meetings_win.transcript import RecognizedSpan
from wisp.meetings_win.wavfile import StereoWavWriter

R = 48_000
STARTED = datetime(2026, 5, 1, 13, 0, tzinfo=timezone.utc)


def span(text, start, end):
    return RecognizedSpan(text, start, end)


def test_normalization_folds_accents_case_and_punctuation():
    assert normalized("  Legendas, pela Comunidade… AMARA.ORG! ") == "legendas pela comunidade amara org"
    assert normalized("Não é") == "nao e"


def test_the_envelope_is_the_mean_square_of_half_second_windows():
    env = ChannelEnvelope([0.0, 0.04, 0.0, 0.0])
    assert env.rms(0.5, 1.0) == pytest.approx(0.2)
    assert env.rms(0.0, 2.0) == pytest.approx(math.sqrt(0.01))
    assert env.rms(50, 60) == 0.0
    assert ChannelEnvelope([]).rms(0, 1) == 0.0


def test_phrases_whisper_invents_over_silence_are_dropped_but_real_sentences_stay():
    env = ChannelEnvelope([0.0] * 20)
    kept, dropped = filter_spans([span("Legendas pela comunidade Amara.org", 0, 2), span("Vamos fechar o contrato hoje", 3, 5),
                                  span("Obrigado por assistir!", 6, 7)], env, "pt")
    assert [s.text for s in kept] == ["Vamos fechar o contrato hoje"] and dropped == 2


def test_a_short_filler_goes_only_when_the_segment_is_silent():
    silent, loud = ChannelEnvelope([0.0] * 10), ChannelEnvelope([0.01] * 10)
    assert filter_spans([span("Obrigado.", 0, 1)], silent, "pt")[0] == []
    assert [s.text for s in filter_spans([span("Obrigado.", 0, 1)], loud, "pt")[0]] == ["Obrigado."]


def test_loops_collapse_and_three_identical_lines_in_a_row_become_one():
    assert collapse_loops("sim sim sim sim sim e então") == "sim e então"
    assert collapse_loops("um dois três um dois três um dois três um dois três fim") == "um dois três fim"
    assert collapse_loops("sim sim sim e não") == "sim sim sim e não"
    env = ChannelEnvelope([0.01] * 10)
    kept, dropped = filter_spans([span("tá bom", 0, 1), span("tá bom", 1, 2), span("tá bom", 2, 3), span("certo", 3, 4)], env, "pt")
    assert [s.text for s in kept] == ["tá bom", "certo"] and dropped == 2


def test_icelandic_gibberish_is_dropped_only_for_portuguese_and_spanish():
    text = "ég veit ekki hvað það er"
    assert is_nordic_gibberish(text) and not is_nordic_gibberish("o Jorge está bem")
    env = ChannelEnvelope([0.01] * 4)
    assert filter_spans([span(text, 0, 2)], env, "pt")[0] == []
    assert filter_spans([span(text, 0, 2)], env, "es")[0] == []
    assert len(filter_spans([span(text, 0, 2)], env, "en")[0]) == 1


def test_the_high_quality_decimator_keeps_a_voice_tone_and_removes_one_above_the_new_nyquist():
    def rms_after(freq):
        n = R
        samples = array("f", (math.sin(2 * math.pi * freq * i / R) for i in range(n)))
        out = HighQualityDecimator().process(samples)
        body = out[2000:-2000]
        return math.sqrt(sum(x * x for x in body) / len(body))

    assert rms_after(1000) == pytest.approx(math.sqrt(0.5), abs=0.03)
    assert rms_after(12_000) < 0.05


def test_the_decimator_gives_the_same_result_however_the_input_is_cut():
    samples = array("f", (math.sin(2 * math.pi * 800 * i / R) for i in range(R)))
    whole = HighQualityDecimator().process(samples)
    cut = HighQualityDecimator()
    parts = array("f")
    for start in range(0, R, 7_001):
        parts.extend(cut.process(samples[start:start + 7_001]))
    assert len(parts) == len(whole)
    assert list(parts) == pytest.approx(list(whole), abs=1e-4)


class Installed:
    def __init__(self, ok=True):
        self.ok = ok
        self.folder = lambda model_id: "/models/" + model_id

    def is_installed(self, model_id):
        return self.ok


class Fake:
    engine_name = "whisper-large-v3"

    def __init__(self, texts=None):
        self.calls = []
        self.unloaded = 0
        self.texts = texts

    def transcribe(self, samples, language, should_stop=None):
        self.calls.append((len(samples), language))
        spans = [RecognizedSpan(t, s, e) for t, s, e in (self.texts or [("revisado", 0.5, 2.0)])]
        return RecognizeResult(spans, "pt", 0.99)

    def unload(self):
        self.unloaded += 1


def write_audio(folder, left, right):
    writer = StereoWavWriter(folder / "audio.wav")
    for start in range(0, len(left), R):
        chunk = array("f")
        for a, b in zip(left[start:start + R], right[start:start + R]):
            chunk.extend([a, b])
        writer.write(chunk)
    writer.close()


def tone(seconds, amp=0.1):
    return array("f", (amp * math.sin(2 * math.pi * 300 * i / R) for i in range(round(seconds * R))))


def quiet(seconds):
    return array("f", bytes(4 * round(seconds * R)))


def original():
    return {"version": 1, "started_at": "2026-05-01T13:00:00Z", "duration_s": 5.0, "language": "pt", "engine": "whisper-small",
            "segments": [{"start": 1.0, "end": 2.0, "speaker": "eu", "text": "ao vivo"}], "failed_segments": 1}


def refiner(recognizer, tmp_path, ok=True, recording=lambda: False, language="pt", engine="whisperLargeV3", sleep=lambda s: None):
    return PostCallRefiner(engine_of(engine), language, recognizer, Installed(ok), is_recording=recording, sleep=sleep)


def test_refine_replaces_the_live_text_with_the_large_model_per_channel(tmp_path):
    write_audio(tmp_path, quiet(1) + tone(2) + quiet(2), quiet(5))
    fake = Fake()
    progress = []
    result = refiner(fake, tmp_path).refine(tmp_path, {"sources": "both"}, original(), progress.append)
    assert result.notice is None
    doc = result.document
    assert [(s["speaker"], s["text"]) for s in doc["segments"]] == [("eu", "revisado"), ("outros", "revisado")]
    assert doc["engine"] == "whisper-large-v3" and doc["language"] == "pt" and "failed_segments" not in doc
    assert [c[1] for c in fake.calls] == ["pt", "pt"] and progress[-1] == 1.0


def test_only_the_recorded_channels_are_refined(tmp_path):
    write_audio(tmp_path, quiet(1) + tone(2) + quiet(2), quiet(5))
    fake = Fake()
    result = refiner(fake, tmp_path).refine(tmp_path, {"sources": "system"}, original(), lambda f: None)
    assert [s["speaker"] for s in result.document["segments"]] == ["outros"] and len(fake.calls) == 1


def test_a_long_channel_is_cut_in_five_minute_windows_with_a_second_of_overlap(tmp_path):
    write_audio(tmp_path, quiet(650), quiet(650))
    fake = Fake([("x", 0.0, 0.5)])
    refiner(fake, tmp_path).refine(tmp_path, {"sources": "mic"}, original(), lambda f: None)
    sizes = [c[0] for c in fake.calls]
    assert sizes[:2] == [300 * 16_000, 301 * 16_000] and len(sizes) == 3
    assert sum(sizes) == pytest.approx(650 * 16_000 + 2 * 16_000, abs=64)


def test_window_offsets_put_the_spans_at_the_right_time_and_the_join_does_not_repeat_words(tmp_path):
    write_audio(tmp_path, quiet(620), quiet(620))
    state = {"n": 0}

    class Windows(Fake):
        def transcribe(self, samples, language, should_stop=None):
            state["n"] += 1
            if state["n"] == 1:
                return RecognizeResult([RecognizedSpan("fim da primeira janela agora", 295.0, 300.5)])
            if state["n"] == 2:
                return RecognizeResult([RecognizedSpan("primeira janela agora e depois", 0.0, 1.5)])
            return RecognizeResult([])

    result = refiner(Windows(), tmp_path).refine(tmp_path, {"sources": "mic"}, original(), lambda f: None)
    texts = [s["text"] for s in result.document["segments"]]
    assert texts == ["fim da primeira janela agora e depois"]


def test_a_missing_model_audio_or_speech_keeps_the_live_transcript_with_a_notice(tmp_path):
    result = refiner(Fake(), tmp_path, ok=False).refine(tmp_path, {}, original(), lambda f: None)
    assert result.document is None and "não foi baixado" in result.notice and "mantive a transcrição ao vivo" in result.notice
    result = refiner(Fake(), tmp_path).refine(tmp_path, {}, original(), lambda f: None)
    assert result.notice == "Não achei o áudio para revisar a transcrição; mantive a transcrição ao vivo."
    write_audio(tmp_path, quiet(2), quiet(2))
    empty = Fake([("Legendas pela comunidade Amara.org", 0.0, 1.0)])
    result = refiner(empty, tmp_path).refine(tmp_path, {}, original(), lambda f: None)
    assert result.document is None and result.notice == "O Whisper não achou fala nessa gravação; mantive a transcrição ao vivo."
    assert result.dropped == 2


def test_engine_off_does_nothing(tmp_path):
    result = refiner(Fake(), tmp_path, engine="off").refine(tmp_path, {}, original(), lambda f: None)
    assert result.document is None and result.notice is None


def test_a_failure_or_a_cancel_never_throws_and_keeps_the_live_transcript(tmp_path):
    write_audio(tmp_path, quiet(2), quiet(2))

    class Boom(Fake):
        def transcribe(self, samples, language, should_stop=None):
            raise RuntimeError("cuda out of memory")

    result = refiner(Boom(), tmp_path).refine(tmp_path, {}, original(), lambda f: None)
    assert result.document is None and "Não consegui revisar a transcrição (cuda out of memory)" in result.notice
    cancel = threading.Event()
    cancel.set()
    result = refiner(Fake(), tmp_path).refine(tmp_path, {}, original(), lambda f: None, cancel=cancel)
    assert result.notice == "A revisão da transcrição foi cancelada; mantive a transcrição ao vivo."


def test_it_waits_while_a_recording_runs_and_frees_the_large_model_first(tmp_path):
    write_audio(tmp_path, quiet(1) + tone(1) + quiet(1), quiet(3))
    answers = iter([True, True, False])
    naps = []
    fake = Fake()
    refiner(fake, tmp_path, recording=lambda: next(answers, False), sleep=naps.append).refine(
        tmp_path, {"sources": "mic"}, original(), lambda f: None)
    assert fake.unloaded == 1 and len(naps) == 2


def test_the_language_is_the_setting_else_what_live_locked_and_auto_when_unknown(tmp_path):
    write_audio(tmp_path, quiet(1) + tone(1) + quiet(1), quiet(3))
    fake = Fake()
    doc = original() | {"language": "en"}
    refiner(fake, tmp_path, language="auto").refine(tmp_path, {"sources": "mic"}, doc, lambda f: None)
    assert fake.calls[0][1] == "en"
    fake2 = Fake()
    refiner(fake2, tmp_path, language="auto").refine(tmp_path, {"sources": "mic"}, original() | {"language": "auto"}, lambda f: None)
    assert fake2.calls[0][1] is None


def test_the_speakers_echo_on_the_mic_is_left_out_of_the_refined_text(tmp_path):
    pattern = [1, 0, 1, 1, 0, 1, 1, 0, 1]
    system = array("f")
    for on in pattern:
        system.extend(tone(0.25, 0.1) if on else quiet(0.25))
    copy = array("f", (x * 0.4 for x in system))
    write_audio(tmp_path, quiet(1) + copy + quiet(1), quiet(1) + system + quiet(1))
    fake = Fake([("eco", 1.0, 3.25)])
    result = refiner(fake, tmp_path).refine(tmp_path, {"sources": "both"}, original(), lambda f: None)
    assert [s["speaker"] for s in result.document["segments"]] == ["outros"]


def test_a_recording_that_starts_mid_window_interrupts_the_decode_and_the_window_is_redone_after_it(tmp_path):
    from wisp.meetings_win.asr import RecognitionInterrupted

    write_audio(tmp_path, quiet(1) + tone(1) + quiet(1), quiet(3))
    state = {"calls": 0}

    class Interrupted(Fake):
        def transcribe(self, samples, language, should_stop=None):
            state["calls"] += 1
            if state["calls"] == 1:
                assert should_stop is not None
                raise RecognitionInterrupted()
            return super().transcribe(samples, language, should_stop)

    answers = iter([False, True, True, False])
    naps = []
    fake = Interrupted()
    result = refiner(fake, tmp_path, recording=lambda: next(answers, False), sleep=naps.append).refine(
        tmp_path, {"sources": "mic"}, original(), lambda f: None)
    assert state["calls"] == 2 and fake.unloaded == 1 and naps
    assert [s["text"] for s in result.document["segments"]] == ["revisado"]
