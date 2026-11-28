import threading
from array import array
from datetime import datetime, timezone

import pytest

from wisp.meetings_win import recordings
from wisp.meetings_win.recorder import MeetingRecorder, RecorderError
from wisp.meetings_win.wavfile import info, read_blocks

R = 48_000
START = datetime(2026, 5, 1, 13, 30, 5, tzinfo=timezone.utc)


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class FakeSource:
    def __init__(self, label, fail=None):
        self.label, self.fail = label, fail
        self.ring = None
        self.started = self.stopped = False

    def start(self, ring):
        if self.fail:
            raise RuntimeError(self.fail)
        self.ring, self.started = ring, True

    def stop(self):
        self.stopped = True

    def feed(self, value, seconds, at, rate=R):
        self.ring.push(array("f", [value] * round(seconds * rate)), channels=1, rate=rate, time=at)


class Live:
    def __init__(self):
        self.pushed, self.gaps, self.flushes = [], [], 0

    def push48k(self, samples, channel):
        self.pushed.append((channel, len(samples)))

    def skip_gap(self, seconds, channel):
        self.gaps.append((channel, round(seconds, 2)))

    def flush_open_segments(self):
        self.flushes += 1


def recorder(tmp_path, sources="both", mic=None, system=None, clock=None, free=10**12, live=None, limit=7200, events=None):
    clock = clock or Clock()
    return MeetingRecorder(
        tmp_path / "r", sources, mic if mic is not None else FakeSource("Microfone X"),
        system if system is not None else FakeSource("Alto-falantes Y"), language="pt", limit_seconds=limit, clock=clock,
        now=lambda: START, free_bytes=lambda path: free, live=live,
        on_event=(lambda kind, detail=None: events.append((kind, detail))) if events is not None else (lambda *a: None)), clock


def test_start_creates_the_folder_with_a_recording_meta_and_starts_both_sources(tmp_path):
    rec, _ = recorder(tmp_path)
    folder = rec.start(run_thread=False)
    meta = recordings.read_meta(folder)
    assert meta["status"] == "recording" and meta["sources"] == "both" and meta["language"] == "pt"
    assert meta["devices"] == {"mic": "Microfone X", "system": "Alto-falantes Y"}
    assert (folder / "audio.wav").exists() and rec.mic.started and rec.system.started
    rec.abort()


def test_an_unused_source_is_never_started(tmp_path):
    rec, _ = recorder(tmp_path, sources="mic")
    rec.start(run_thread=False)
    assert rec.mic.started and not rec.system.started
    assert recordings.read_meta(rec.folder)["devices"] == {"mic": "Microfone X", "system": None}
    rec.abort()


def test_a_source_that_fails_removes_the_folder_and_stops_what_had_started(tmp_path):
    mic, system = FakeSource("m"), FakeSource("s", fail="sem acesso")
    rec, _ = recorder(tmp_path, mic=mic, system=system)
    with pytest.raises(RuntimeError, match="sem acesso"):
        rec.start(run_thread=False)
    assert mic.stopped and not list((tmp_path / "r").iterdir())


def test_less_than_200_mb_free_refuses_to_start_and_leaves_nothing(tmp_path):
    rec, _ = recorder(tmp_path, free=100 * 1024 * 1024)
    with pytest.raises(RecorderError, match="espaço"):
        rec.start(run_thread=False)
    assert list((tmp_path / "r").iterdir()) == []


def test_a_tick_mixes_mic_left_and_system_right_aligned_by_capture_time(tmp_path):
    rec, clock = recorder(tmp_path)
    folder = rec.start(run_thread=False)
    rec.mic.feed(0.5, 0.5, at=1000.0)
    rec.system.feed(0.25, 0.5, at=1000.0)
    clock.now = 1001.0
    rec.tick()
    result = rec.stop()
    left = [x for block in read_blocks(folder / "audio.wav", R) for x in block[0]]
    right = [x for block in read_blocks(folder / "audio.wav", R) for x in block[1]]
    assert len(left) == len(right) == R // 2
    assert left[100] == pytest.approx(0.5, abs=1e-3) and right[100] == pytest.approx(0.25, abs=1e-3)
    assert result["duration_s"] == pytest.approx(0.5)
    meta = recordings.read_meta(folder)
    assert meta["status"] == "transcribing" and meta["duration_s"] == pytest.approx(0.5)


def test_the_mic_at_another_rate_and_in_stereo_is_brought_to_48k_mono(tmp_path):
    rec, clock = recorder(tmp_path, sources="mic")
    folder = rec.start(run_thread=False)
    rec.mic.ring.push(array("f", [0.2, 0.4] * 4410), channels=2, rate=44_100, time=1000.0)
    clock.now = 1001.0
    rec.tick()
    rec.stop()
    left = [x for block in read_blocks(folder / "audio.wav", R) for x in block[0]]
    assert len(left) == pytest.approx(4800, abs=3) and left[50] == pytest.approx(0.3, abs=1e-3)


def test_a_pause_cuts_the_span_out_of_the_audio_and_is_recorded_in_the_meta(tmp_path):
    rec, clock = recorder(tmp_path)
    folder = rec.start(run_thread=False)
    rec.mic.feed(0.5, 1.0, at=1000.0)
    rec.system.feed(0.5, 1.0, at=1000.0)
    clock.now = 1001.0
    rec.tick()
    rec.pause()
    assert rec.paused
    rec.mic.feed(0.9, 2.0, at=1001.0)
    rec.system.feed(0.9, 2.0, at=1001.0)
    clock.now = 1003.0
    rec.tick()
    rec.resume()
    rec.mic.feed(0.3, 1.0, at=1003.0)
    rec.system.feed(0.3, 1.0, at=1003.0)
    clock.now = 1004.0
    rec.tick()
    result = rec.stop()
    left = [x for block in read_blocks(folder / "audio.wav", R) for x in block[0]]
    assert len(left) == pytest.approx(2 * R, abs=10)
    assert max(left) == pytest.approx(0.5, abs=1e-3) and left[R + 100] == pytest.approx(0.3, abs=1e-3)
    pause, = recordings.read_meta(folder)["pauses"]
    assert pause["at_s"] == pytest.approx(1.0) and pause["started_at"] and pause["ended_at"]
    assert rec.elapsed() == pytest.approx(2.0)
    assert result["duration_s"] == pytest.approx(2.0)


def test_a_pause_left_open_is_closed_at_stop(tmp_path):
    rec, clock = recorder(tmp_path)
    folder = rec.start(run_thread=False)
    rec.pause()
    rec.stop()
    assert recordings.read_meta(folder)["pauses"][0]["ended_at"]


def test_bookmarks_keep_the_elapsed_time_and_are_saved_at_stop(tmp_path):
    rec, clock = recorder(tmp_path)
    folder = rec.start(run_thread=False)
    clock.now = 1012.5
    mark = rec.bookmark("preço")
    assert mark["time"] == pytest.approx(12.5) and mark["label"] == "preço"
    rec.stop()
    saved, = recordings.read_meta(folder)["bookmarks"]
    assert saved["id"] == mark["id"] and saved["time"] == pytest.approx(12.5)


def test_warnings_stall_silence_and_overrun_in_portuguese(tmp_path):
    rec, clock = recorder(tmp_path)
    rec.start(run_thread=False)
    rec.mic.feed(0.1, 0.1, at=1000.0)
    clock.now = 1000.1
    rec.tick()
    assert rec.warnings() == []
    clock.now = 1006.0
    rec.tick()
    assert "o microfone parou" in rec.warnings() and "o áudio do computador parou" in rec.warnings()
    for second in range(11):
        rec.system.feed(0.0, 1.0, at=1006.0 + second)
        clock.now = 1007.0 + second
        rec.tick()
    assert any("não estou ouvindo o áudio do computador" in w for w in rec.warnings())
    rec.system.feed(0.3, 0.5, at=1017.0)
    clock.now = 1017.5
    rec.tick()
    assert not any("não estou ouvindo" in w for w in rec.warnings())
    for _ in range(80):
        rec.system.ring.push(array("f", [0.1] * 4096), 1, R, 1018.0)
    assert any("sobrecarregado" in w for w in (rec.tick() or rec.warnings()))
    rec.abort()


def test_the_limit_warns_once_with_five_minutes_left_and_then_asks_to_stop(tmp_path):
    events = []
    rec, clock = recorder(tmp_path, limit=900, events=events)
    rec.start(run_thread=False)
    clock.now = 1000.0 + 610
    rec.tick()
    clock.now += 1
    rec.tick()
    assert [k for k, _ in events] == ["limit_warning"]
    clock.now = 1000.0 + 901
    rec.tick()
    assert [k for k, _ in events][-1] == "limit_reached"
    rec.abort()


def test_a_write_failure_or_a_full_disk_is_fatal_and_reported(tmp_path):
    events = []
    free = {"v": 10**12}
    clock = Clock()
    rec = MeetingRecorder(tmp_path / "r", "both", FakeSource("m"), FakeSource("s"), clock=clock, now=lambda: START,
                          free_bytes=lambda p: free["v"], on_event=lambda kind, detail=None: events.append((kind, detail)))
    rec.start(run_thread=False)
    free["v"] = 50 * 1024 * 1024
    clock.now += 6
    rec.tick()
    assert events and events[-1][0] == "fatal" and "espaço" in events[-1][1]
    rec.abort()


def test_live_gets_each_channel_aligned_and_a_long_gap_is_reported_not_buffered(tmp_path):
    live = Live()
    rec, clock = recorder(tmp_path, live=live)
    rec.start(run_thread=False)
    rec.mic.feed(0.1, 0.5, at=1000.0)
    rec.system.feed(0.1, 0.5, at=1000.0)
    rec.mic.feed(0.1, 0.5, at=1009.0)
    clock.now = 1010.0
    rec.tick()
    assert sum(n for c, n in live.pushed if c == "mic") == 48_000 and sum(n for c, n in live.pushed if c == "system") == 24_000
    assert len(live.gaps) == 1
    assert live.gaps and live.gaps[0][0] == "mic" and live.gaps[0][1] == pytest.approx(8.5, abs=0.1)
    rec.abort()


def test_pausing_flushes_what_the_live_pass_has_open(tmp_path):
    live = Live()
    rec, _ = recorder(tmp_path, live=live)
    rec.start(run_thread=False)
    rec.pause()
    assert live.flushes == 1
    rec.abort()


def test_levels_follow_the_loudest_recent_chunk_per_source(tmp_path):
    rec, clock = recorder(tmp_path)
    rec.start(run_thread=False)
    rec.mic.feed(0.1, 0.2, at=1000.0)
    clock.now = 1000.2
    rec.tick()
    levels = rec.levels()
    assert 0.5 < levels["mic"] < 0.9 and levels["system"] == 0
    rec.abort()


def test_the_thread_runs_ticks_by_itself_and_stop_joins_it(tmp_path):
    rec, clock = recorder(tmp_path)
    folder = rec.start()
    rec.mic.feed(0.2, 0.3, at=1000.0)
    rec.system.feed(0.2, 0.3, at=1000.0)
    threading.Event().wait(0.3)
    rec.stop()
    assert info(folder / "audio.wav")[2] > 0
    assert not rec._thread.is_alive()
