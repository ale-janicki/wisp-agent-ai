import sys
from array import array

import pytest

from wisp.meetings_win import capture_win
from wisp.meetings_win.audio import CaptureRing
from wisp.meetings_win.capture_win import CaptureUnavailable, PortAudioSource, microphone_blocked_message

PA_FLOAT32 = 1
PA_CONTINUE = 0


class Stream:
    def __init__(self, options):
        self.options = options
        self.callback = options["stream_callback"]
        self.active = True
        self.closed = False

    def stop_stream(self):
        self.active = False

    def close(self):
        self.closed = True

    def deliver(self, samples, rate=None, channels=None):
        data = array("f", samples).tobytes()
        frames = len(samples) // (channels or self.options["channels"])
        return self.callback(data, frames, {}, 0)


class FakePortAudio:
    paFloat32 = PA_FLOAT32
    paContinue = PA_CONTINUE
    paWASAPI = 13

    def __init__(self):
        self.streams = []
        self.terminated = False
        self.default_input = {"index": 3, "name": "Microfone (USB)", "maxInputChannels": 1, "defaultSampleRate": 44100.0}
        self.default_loopback = {"index": 7, "name": "Alto-falantes [Loopback]", "maxInputChannels": 2,
                                 "defaultSampleRate": 48000.0, "isLoopbackDevice": True}
        self.fail_open = None

    def PyAudio(self):
        return self

    def get_host_api_info_by_type(self, kind):
        assert kind == self.paWASAPI
        return {"defaultInputDevice": self.default_input["index"] if self.default_input else -1}

    def get_device_info_by_index(self, index):
        assert self.default_input and index == self.default_input["index"]
        return self.default_input

    def get_default_wasapi_loopback(self):
        if self.default_loopback is None:
            raise OSError("no default loopback")
        return self.default_loopback

    def open(self, **options):
        if self.fail_open:
            raise OSError(self.fail_open)
        stream = Stream(options)
        self.streams.append(stream)
        return stream

    def terminate(self):
        self.terminated = True


class Clock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


def source(kind, pa=None, clock=None):
    pa = pa or FakePortAudio()
    clock = clock or Clock()
    return PortAudioSource(kind, module=pa, clock=clock), pa, clock


def test_the_mic_opens_the_default_wasapi_input_at_its_own_rate_and_channels():
    mic, pa, _ = source("mic")
    mic.start(CaptureRing(), run_thread=False)
    options = pa.streams[0].options
    assert options["input"] is True and options["input_device_index"] == 3
    assert options["rate"] == 44100 and options["channels"] == 1 and options["format"] == PA_FLOAT32
    assert mic.label == "Microfone (USB)"


def test_the_loopback_opens_the_default_output_as_an_input():
    system, pa, _ = source("system")
    system.start(CaptureRing(), run_thread=False)
    options = pa.streams[0].options
    assert options["input_device_index"] == 7 and options["rate"] == 48000 and options["channels"] == 2
    assert system.label == "Alto-falantes"


def test_the_callback_stamps_the_start_of_the_chunk_and_never_blocks():
    mic, pa, clock = source("system")
    ring = CaptureRing()
    mic.start(ring, run_thread=False)
    clock.now = 105.0
    result = pa.streams[0].deliver([0.1, 0.2] * 480)
    assert result == (None, PA_CONTINUE)
    slot = ring.pop()
    assert slot.channels == 2 and slot.rate == 48000
    assert slot.time == pytest.approx(105.0 - 480 / 48000)
    assert list(slot.samples)[:2] == pytest.approx([0.1, 0.2])


def test_a_loopback_that_delivers_nothing_is_filled_with_silence_so_the_file_never_stalls():
    system, pa, clock = source("system")
    ring = CaptureRing()
    system.start(ring, run_thread=False)
    pa.streams[0].deliver([0.1, 0.1] * 480)
    clock.now = 100.01
    system.step()
    first = [ring.pop(), ring.pop()]
    assert first[1] is None
    clock.now = 101.0
    system.step()
    zeros = []
    while (slot := ring.pop()) is not None:
        zeros.append(slot)
    assert zeros and all(max(s.samples) == 0.0 for s in zeros)
    covered = sum(len(s.samples) // s.channels for s in zeros)
    assert covered == pytest.approx(0.9 * 48000, abs=48000 * 0.12)
    assert zeros[0].time == pytest.approx(100.0 + 0.01, abs=0.05)


def test_the_mic_is_not_padded_with_silence():
    mic, pa, clock = source("mic")
    ring = CaptureRing()
    mic.start(ring, run_thread=False)
    clock.now = 110.0
    mic.step()
    assert ring.pop() is None


def test_a_change_of_the_default_device_reopens_the_stream_on_the_new_one():
    mic, pa, clock = source("system")
    ring = CaptureRing()
    mic.start(ring, run_thread=False)
    pa.default_loopback = {"index": 9, "name": "Fones [Loopback]", "maxInputChannels": 2, "defaultSampleRate": 44100.0,
                           "isLoopbackDevice": True}
    clock.now = 103.0
    mic.step()
    assert pa.streams[0].closed and len(pa.streams) == 2
    assert pa.streams[1].options["input_device_index"] == 9 and pa.streams[1].options["rate"] == 44100
    assert mic.label == "Fones"
    pa.streams[1].deliver([0.3, 0.3] * 441)
    assert ring.pop().rate == 44100


def test_stop_closes_the_stream_and_terminates_portaudio():
    mic, pa, _ = source("mic")
    mic.start(CaptureRing(), run_thread=False)
    mic.stop()
    assert pa.streams[0].closed and pa.terminated
    mic.stop()


def test_a_blocked_microphone_gets_the_windows_privacy_hint():
    mic, pa, _ = source("mic")
    pa.fail_open = "[Errno -9999] Unanticipated host error"
    with pytest.raises(CaptureUnavailable, match="Privacidade e segurança"):
        mic.start(CaptureRing(), run_thread=False)
    assert pa.terminated
    assert "Microfone" in microphone_blocked_message()


def test_no_default_device_is_a_clear_error():
    mic, pa, _ = source("mic")
    pa.default_input = None
    with pytest.raises(CaptureUnavailable, match="microfone"):
        mic.start(CaptureRing(), run_thread=False)
    system, pa2, _ = source("system")
    pa2.default_loopback = None
    with pytest.raises(CaptureUnavailable, match="saída de áudio"):
        system.start(CaptureRing(), run_thread=False)


@pytest.mark.skipif(sys.platform == "win32", reason="the real module only exists on Windows")
def test_without_the_windows_module_a_source_says_what_is_missing(monkeypatch):
    monkeypatch.setitem(sys.modules, "pyaudiowpatch", None)
    with pytest.raises(CaptureUnavailable, match="PyAudioWPatch"):
        PortAudioSource("mic").start(CaptureRing(), run_thread=False)
    assert capture_win.load_portaudio is not None
