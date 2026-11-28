import json
import threading
from array import array
from datetime import datetime, timezone

import pytest

from wisp.meetings_win.asr import RecognizeResult
from wisp.meetings_win.language import LanguagePicker
from wisp.meetings_win.live import LiveTranscriber, TranscriptStore
from wisp.meetings_win.transcript import RecognizedSpan

R48 = 48_000
STARTED = datetime(2026, 5, 1, 13, 0, tzinfo=timezone.utc)


def quiet(seconds):
    return array("f", bytes(4 * round(seconds * R48)))


def loud(seconds, amp=0.1):
    return array("f", [amp] * round(seconds * R48))


class Fake:
    engine_name = "fake"

    def __init__(self, words=("um", "dois", "tres", "quatro"), fail_on=None, gate=None, language=("pt", 0.9)):
        self.calls = []
        self.words = list(words)
        self.fail_on = fail_on
        self.gate = gate
        self.language = language

    def transcribe(self, samples, language):
        if self.gate:
            self.gate.wait(5)
        self.calls.append((len(samples), max(samples), language))
        if self.fail_on == len(self.calls):
            raise RuntimeError("model blew up")
        text = self.words[(len(self.calls) - 1) % len(self.words)]
        return RecognizeResult([RecognizedSpan(text, 0.2, 0.8, 0.9)], *self.language)

    def unload(self):
        pass


def make(recognizer, tmp_path, picker=None, channels=("mic", "system"), **hooks):
    store = TranscriptStore(STARTED, "fake", "pt", tmp_path)
    live = LiveTranscriber(recognizer, store, picker or LanguagePicker("pt"), channels=channels, **hooks)
    return live, store


def speak(live, channel, seconds=1.0, lead=1.0, tail=1.5):
    live.push48k(quiet(lead), channel)
    live.push48k(loud(seconds), channel)
    live.push48k(quiet(tail), channel)


def test_a_spoken_segment_becomes_a_final_line_at_its_own_time_and_is_saved_at_once(tmp_path):
    live, store = make(Fake(), tmp_path)
    speak(live, "mic")
    lines = live.finish()
    assert [(s.speaker, s.text, s.is_final) for s in lines] == [("eu", "um", True)]
    assert lines[0].start == pytest.approx(0.7 + 0.2, abs=0.05)
    saved = json.loads((tmp_path / "transcript.live.json").read_text("utf-8"))
    assert saved["segments"][0]["text"] == "um" and saved["engine"] == "fake" and saved["language"] == "pt"


def test_silence_costs_no_inference(tmp_path):
    recognizer = Fake()
    live, _ = make(recognizer, tmp_path)
    live.push48k(quiet(10), "mic")
    live.push48k(quiet(10), "system")
    live.finish()
    assert recognizer.calls == []


def test_a_typing_mark_shows_while_a_segment_is_open_and_the_final_replaces_it(tmp_path):
    gate = threading.Event()
    updates = []
    live, store = make(Fake(gate=gate), tmp_path, on_update=lambda snap: updates.append(list(snap)))
    live.push48k(quiet(1), "mic")
    live.push48k(loud(1), "mic")
    deadline = threading.Event()
    for _ in range(100):
        if any(s.text == "…" for snap in updates for s in snap):
            break
        deadline.wait(0.02)
    assert any(s.text == "…" and not s.is_final for snap in updates for s in snap)
    gate.set()
    live.push48k(quiet(1.5), "mic")
    lines = live.finish()
    assert [s.text for s in lines] == ["um"]


def test_a_recognizer_error_is_reported_once_counted_and_the_loop_continues(tmp_path):
    failures = []
    live, store = make(Fake(fail_on=1), tmp_path, on_failure=failures.append)
    speak(live, "mic")
    speak(live, "mic")
    lines = live.finish()
    assert failures == ["model blew up"] and live.has_failed
    assert [s.text for s in lines] == ["dois"]
    assert json.loads((tmp_path / "transcript.live.json").read_text("utf-8"))["failed_segments"] == 1


def test_finals_queue_up_and_lag_is_reported_at_three_waiting(tmp_path):
    gate = threading.Event()
    lag = []
    live, _ = make(Fake(gate=gate), tmp_path, on_lag=lag.append)
    for _ in range(5):
        speak(live, "mic", lead=0.2)
    assert lag and lag[0] is True
    gate.set()
    lines = live.finish()
    assert len(lines) == 5 and lag[-1] is False


PATTERN = [1, 0, 1, 1, 0, 1, 1, 0, 1]


def system_audio():
    out = array("f")
    for on in PATTERN:
        out.extend(loud(0.25, 0.1) if on else quiet(0.25))
    return out


def run_echo(tmp_path, mic_gain):
    recognizer = Fake()
    live, _ = make(recognizer, tmp_path)
    system = system_audio()
    live.push48k(quiet(1), "system")
    live.push48k(quiet(1), "mic")
    live.push48k(system, "system")
    live.push48k(array("f", (x * mic_gain for x in system)), "mic")
    live.push48k(quiet(1.5), "system")
    live.push48k(quiet(1.5), "mic")
    live.finish()
    return recognizer.calls


def test_the_speakers_copy_on_the_mic_is_not_transcribed(tmp_path):
    calls = run_echo(tmp_path, 0.4)
    assert len(calls) == 1 and calls[0][1] > 0.09


def test_louder_mic_on_top_of_the_system_audio_is_double_talk_and_is_kept(tmp_path):
    calls = run_echo(tmp_path, 1.4)
    assert len(calls) == 2


def test_auto_language_locks_after_two_confident_segments(tmp_path):
    recognizer = Fake(language=("en", 0.95))
    picker = LanguagePicker("auto")
    live, store = make(recognizer, tmp_path, picker)
    for _ in range(4):
        speak(live, "mic", lead=0.2)
    live.finish()
    assert [c[2] for c in recognizer.calls] == [None, None, "en", "en"]
    assert store.language == "en"


def test_cancel_drops_what_is_queued_and_stops_the_worker(tmp_path):
    gate = threading.Event()
    live, _ = make(Fake(gate=gate), tmp_path)
    for _ in range(4):
        speak(live, "mic", lead=0.2)
    gate.set()
    live.cancel()
    live.stop_and_wait()
    assert not live._worker.is_alive()


def test_a_long_gap_flushes_what_was_heard_and_skips_ahead_on_the_timeline(tmp_path):
    recognizer = Fake()
    live, _ = make(recognizer, tmp_path)
    live.push48k(quiet(0.5), "mic")
    live.push48k(loud(0.8), "mic")
    live.skip_gap(seconds=30, channel="mic")
    live.push48k(quiet(0.5), "mic")
    live.push48k(loud(0.8), "mic")
    live.push48k(quiet(1.5), "mic")
    lines = live.finish()
    assert len(lines) == 2 and lines[1].start > 30


def test_flushing_open_segments_closes_a_half_spoken_sentence(tmp_path):
    live, _ = make(Fake(), tmp_path)
    live.push48k(quiet(0.5), "mic")
    live.push48k(loud(1), "mic")
    live.flush_open_segments()
    lines = live.finish()
    assert [s.text for s in lines] == ["um"]


def test_noise_ranges_are_saved_for_the_final_pass(tmp_path):
    live, store = make(Fake(), tmp_path)
    live.push48k(quiet(0.5), "mic")
    live.push48k(loud(70), "mic")
    live.finish()
    saved = json.loads((tmp_path / "transcript.live.json").read_text("utf-8"))
    assert saved["noise_ranges"][0]["channel"] == "mic" and saved["noise_ranges"][0]["end"] > saved["noise_ranges"][0]["start"]
