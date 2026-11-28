import threading
from array import array
from datetime import datetime, timezone

import pytest

from wisp.meetings_win.asr import RecognizeResult
from wisp.meetings_win.language import LanguagePicker
from wisp.meetings_win.transcriber import Cancelled, MeetingTranscriber, NoAudio
from wisp.meetings_win.transcript import NoiseRange, RecognizedSpan
from wisp.meetings_win.wavfile import StereoWavWriter

R = 48_000
STARTED = datetime(2026, 5, 1, 13, 0, tzinfo=timezone.utc)


def quiet(seconds):
    return array("f", bytes(4 * round(seconds * R)))


def loud(seconds, amp=0.1):
    return array("f", [amp] * round(seconds * R))


def write_audio(folder, left, right):
    longest = max(len(left), len(right))
    left = left + array("f", bytes(4 * (longest - len(left))))
    right = right + array("f", bytes(4 * (longest - len(right))))
    writer = StereoWavWriter(folder / "audio.wav")
    for start in range(0, longest, R):
        chunk = array("f")
        for a, b in zip(left[start:start + R], right[start:start + R]):
            chunk.extend([a, b])
        writer.write(chunk)
    writer.close()


class Fake:
    engine_name = "fake"

    def __init__(self, gate=None):
        self.calls = []
        self.gate = gate

    def transcribe(self, samples, language):
        self.calls.append((len(samples), max(samples), language))
        if self.gate:
            self.gate()
        return RecognizeResult([RecognizedSpan(f"fala {len(self.calls)}", 0.2, 0.9, 0.9)], "pt", 0.9)

    def unload(self):
        pass


def test_the_final_pass_transcribes_each_voice_segment_once_per_channel(tmp_path):
    write_audio(tmp_path, quiet(1) + loud(1) + quiet(3), quiet(4) + loud(1) + quiet(1))
    fake = Fake()
    progress = []
    doc = MeetingTranscriber(fake, LanguagePicker("pt")).transcribe(tmp_path, STARTED, "both", 6.0, progress.append)
    assert [(s["speaker"], s["text"]) for s in doc["segments"]] == [("eu", "fala 1"), ("outros", "fala 2")]
    assert doc["segments"][0]["start"] == pytest.approx(0.9, abs=0.05)
    assert doc["segments"][1]["start"] == pytest.approx(3.9, abs=0.05)
    assert doc["engine"] == "fake" and doc["language"] == "pt" and doc["duration_s"] >= 6.0
    assert len(fake.calls) == 2 and progress[-1] == 1.0 and progress == sorted(progress)


def test_a_channel_the_meeting_did_not_record_is_skipped(tmp_path):
    write_audio(tmp_path, quiet(1) + loud(1) + quiet(2), quiet(1) + loud(1) + quiet(2))
    fake = Fake()
    doc = MeetingTranscriber(fake, LanguagePicker("pt")).transcribe(tmp_path, STARTED, "mic", 4.0)
    assert [s["speaker"] for s in doc["segments"]] == ["eu"] and len(fake.calls) == 1


def test_missing_audio_is_a_clear_error(tmp_path):
    with pytest.raises(NoAudio, match="Não encontrei o áudio"):
        MeetingTranscriber(Fake(), LanguagePicker("pt")).transcribe(tmp_path, STARTED, "both", 1)


def test_cancel_stops_the_pass_with_a_cancelled_error(tmp_path):
    write_audio(tmp_path, quiet(1) + loud(1) + quiet(2), quiet(4))
    cancel = threading.Event()
    cancel.set()
    with pytest.raises(Cancelled):
        MeetingTranscriber(Fake(), LanguagePicker("pt")).transcribe(tmp_path, STARTED, "both", 4, cancel=cancel)


def test_the_pause_gate_runs_before_every_recognizer_call(tmp_path):
    write_audio(tmp_path, quiet(1) + loud(1) + quiet(2), quiet(1) + loud(1) + quiet(2))
    gates = []
    MeetingTranscriber(Fake(), LanguagePicker("pt"), pause=lambda: gates.append(1)).transcribe(tmp_path, STARTED, "both", 4)
    assert len(gates) == 2


def test_the_speakers_copy_on_the_mic_is_dropped_from_the_final_pass_too(tmp_path):
    pattern = [1, 0, 1, 1, 0, 1, 1, 0, 1]
    system = array("f")
    for on in pattern:
        system.extend(loud(0.25) if on else quiet(0.25))
    copy = array("f", (x * 0.4 for x in system))
    write_audio(tmp_path, quiet(1) + copy + quiet(2), quiet(1) + system + quiet(2))
    fake = Fake()
    doc = MeetingTranscriber(fake, LanguagePicker("pt")).transcribe(tmp_path, STARTED, "both", 5.5)
    assert [s["speaker"] for s in doc["segments"]] == ["outros"] and len(fake.calls) == 1


def test_noise_ranges_are_re_read_from_the_file_in_pieces(tmp_path):
    write_audio(tmp_path, quiet(1) + loud(3) + quiet(1), quiet(5))
    fake = Fake()
    segments = MeetingTranscriber(fake, LanguagePicker("pt")).transcribe_ranges(
        tmp_path, [NoiseRange("mic", 1.0, 4.0)])
    assert len(segments) == 1 and segments[0].speaker == "eu"
    assert fake.calls[0][0] == pytest.approx(3 * 16_000, abs=480)
    assert segments[0].start == pytest.approx(1.2, abs=0.02)


def test_a_long_noise_range_is_cut_in_20_second_pieces_with_half_a_second_of_overlap(tmp_path):
    write_audio(tmp_path, quiet(0.5) + loud(45) + quiet(0.5), quiet(46))
    fake = Fake()
    MeetingTranscriber(fake, LanguagePicker("pt")).transcribe_ranges(tmp_path, [NoiseRange("mic", 0.5, 45.5)])
    sizes = [c[0] for c in fake.calls]
    assert sizes[0] == 20 * 16_000 and sizes[1] == 20 * 16_000
    assert sum(sizes) == pytest.approx(45 * 16_000 + 2 * 8_000, abs=2_000) and len(sizes) == 3


def test_the_final_pass_re_reads_the_noise_it_finds(tmp_path):
    write_audio(tmp_path, quiet(0.5) + loud(70) + quiet(1), quiet(72))
    fake = Fake()
    doc = MeetingTranscriber(fake, LanguagePicker("pt")).transcribe(tmp_path, STARTED, "both", 71.5)
    assert len(doc["segments"]) >= 1
    assert sum(c[0] for c in fake.calls) > 60 * 16_000
