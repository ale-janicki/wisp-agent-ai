from datetime import datetime, timezone

import pytest

from wisp.meetings_win.insights import (NudgeEngine, RecordingLimitClock, Stats, bookmark_lines, compute_metrics,
                                        pause_label, surrounding)
from wisp.meetings_win.transcript import MeetingSegment


def seg(start, end, text, speaker="eu", final=True):
    return MeetingSegment(start, end, speaker, text, None, final)


def test_metrics_speaking_time_wpm_questions_monologue_and_silence():
    twenty = " ".join("palavra" for _ in range(19)) + " certo?"
    stats = compute_metrics([seg(0, 12, twenty), seg(12.5, 14, "ok", "outros")], elapsed=20)
    you, others = stats.metrics["you"], stats.metrics["others"]
    assert you["words"] == 20 and you["questions"] == 1
    assert you["speaking_s"] == 12 and you["wpm"] == pytest.approx(100)
    assert others["speaking_s"] == 1.5 and others["wpm"] == 0
    assert you["longest_monologue_s"] == 12
    assert stats.metrics["silence_s"] == pytest.approx(6.5)
    assert stats.metrics["duration_s"] == 20
    assert stats.ongoing == ("mic", 12) and stats.last_question_at == 0


def test_a_run_of_question_marks_counts_once_and_partials_are_ignored():
    stats = compute_metrics([seg(0, 2, "o quê?! sério??"), seg(3, 4, "…", final=False)], elapsed=5)
    assert stats.metrics["you"]["questions"] == 2
    assert stats.metrics["you"]["words"] == 3


def test_overlapping_lines_are_counted_once_in_speaking_time():
    stats = compute_metrics([seg(0, 10, "a b"), seg(5, 12, "c d")], elapsed=12)
    assert stats.metrics["you"]["speaking_s"] == 12


def test_a_short_interjection_does_not_break_the_other_channels_monologue():
    stats = compute_metrics([seg(0, 5, "um dois três"), seg(5, 6, "aham", "outros"), seg(6, 11, "quatro cinco seis")], 11)
    assert stats.metrics["you"]["longest_monologue_s"] == 11


def stats_with(ongoing=None, you=0, others=0, last_question=None):
    metrics = {"duration_s": 0, "you": {"speaking_s": you}, "others": {"speaking_s": others}, "silence_s": 0}
    return Stats(metrics, ongoing, last_question)


def test_nudge_priority_and_spacing():
    engine = NudgeEngine()
    nudge = engine.evaluate(stats_with(ongoing=("mic", 200), you=250, others=10), elapsed=400)
    assert nudge.kind == "monologue" and nudge.text == "Monólogo de 3 min"
    assert engine.evaluate(stats_with(ongoing=("mic", 200)), elapsed=600) is None
    assert engine.evaluate(stats_with(ongoing=("mic", 200)), elapsed=750) is None
    assert engine.evaluate(stats_with(ongoing=("mic", 200)), elapsed=1000).kind == "monologue"


def test_talk_share_nudge_needs_five_minutes_of_speech_and_75_percent():
    assert NudgeEngine().evaluate(stats_with(you=200, others=10), elapsed=400) is None
    share = NudgeEngine().evaluate(stats_with(you=320, others=80), elapsed=401)
    assert share.kind == "talkShare" and share.text == "Você está falando 80% do tempo"
    assert NudgeEngine().evaluate(stats_with(you=250, others=150), elapsed=401) is None


def test_no_question_nudge_needs_ten_quiet_minutes():
    engine = NudgeEngine()
    assert engine.evaluate(stats_with(), elapsed=500) is None
    nudge = engine.evaluate(stats_with(last_question=0), elapsed=660)
    assert nudge.kind == "noQuestion" and nudge.text == "Nenhuma pergunta há 11 min"
    assert NudgeEngine().evaluate(stats_with(last_question=300), elapsed=700) is None


def test_the_limit_clock_warns_once_then_stops_once_and_ignores_pauses():
    clock = RecordingLimitClock(limit=1000)
    clock.start(0)
    assert clock.tick(100) is None
    assert clock.tick(700) == ("warning", 300)
    assert clock.tick(701) is None
    clock.pause(800)
    assert clock.tick(5000) is None
    clock.resume(5000)
    assert clock.active(5100) == pytest.approx(900)
    assert clock.tick(5200) == ("reached", None)
    assert clock.tick(5300) is None


def test_no_warning_for_a_limit_of_five_minutes_or_less_and_a_late_first_tick():
    short = RecordingLimitClock(limit=300)
    short.start(0)
    assert short.tick(10) is None
    assert short.tick(300) == ("reached", None)
    late = RecordingLimitClock(limit=1000)
    late.start(0)
    assert late.tick(1200) == ("reached", None)


def test_surrounding_takes_three_before_and_two_after():
    lines = [seg(i * 10, i * 10 + 5, f"l{i}") for i in range(8)]
    assert [s.text for s in surrounding(lines, 42)] == ["l2", "l3", "l4", "l5", "l6"]
    assert [s.text for s in surrounding(lines, 0)] == ["l0", "l1", "l2"]


def test_bookmarks_and_pauses_sit_before_the_first_later_line():
    segments = [seg(0, 5, "a"), seg(20, 25, "b"), seg(40, 45, "c")]
    marks = [{"id": "m1", "time": 21.0, "label": ""}, {"id": "m2", "time": 3.0, "label": "preço"}]
    pause = [{"started_at": "2026-05-01T13:00:00Z", "ended_at": "2026-05-01T13:05:00Z", "at_s": 30.0}]
    lines = bookmark_lines(segments, marks, pause, tz=timezone.utc)
    assert [(l["speaker"], l["text"]) for l in lines] == [
        ("Você", "a"), ("Marcador", "preço"), ("Você", "b"), ("Marcador", "Momento marcado"),
        ("Pausa", "Pausado 13:00–13:05"), ("Você", "c")]


def test_pause_labels_in_portuguese():
    start = datetime(2026, 5, 1, 13, 0, tzinfo=timezone.utc)
    end = datetime(2026, 5, 1, 13, 5, tzinfo=timezone.utc)
    assert pause_label({"started_at": "2026-05-01T13:00:00Z"}, tz=timezone.utc) == "Pausado desde 13:00"
    assert pause_label({"started_at": "2026-05-01T13:00:00Z", "ended_at": "2026-05-01T13:05:00Z"}, tz=timezone.utc) \
        == "Pausado 13:00–13:05"
    assert start < end
