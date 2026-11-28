from array import array

import pytest

from wisp.meetings_win.bleed import BleedDetector, ChannelHistory
from wisp.meetings_win.segmenter import (ChannelStreamer, Dropped, Noise, Opened, Segment, SegmenterConfig,
                                         SpeechSegmenter)
from wisp.meetings_win.transcript import (MeetingSegment, RecognizedSpan, TranscriptMerger, is_sparse, speech_ratio,
                                          merge_adjacent)

R = 16_000


def silence(seconds):
    return array("f", bytes(4 * round(seconds * R)))


def tone(seconds, amp=0.1):
    return array("f", ([amp, -amp] * (round(seconds * R) // 2 + 1))[: round(seconds * R)])


def feed(segmenter, *parts):
    events = []
    for part in parts:
        events += segmenter.append(part)
    return events


def test_silence_makes_no_events_and_no_inference():
    assert feed(SpeechSegmenter(), silence(3)) == []


def test_a_burst_is_announced_then_cut_with_300ms_before_and_400ms_after():
    events = feed(SpeechSegmenter(), silence(0.96), tone(0.96), silence(1.5))
    assert events[0] == Opened(10_560)
    assert isinstance(events[1], Segment)
    assert events[1].start_sample == 10_560
    assert len(events[1].samples) == 37_120 - 10_560
    assert len(events) == 2


def test_a_click_shorter_than_100ms_is_dropped_without_inference():
    assert feed(SpeechSegmenter(), silence(1), tone(0.03), silence(1)) == []


def test_a_pause_shorter_than_the_redemption_stays_one_segment():
    events = feed(SpeechSegmenter(), silence(0.5), tone(1), silence(0.3), tone(1), silence(1))
    assert [type(e) for e in events if isinstance(e, Segment)] == [Segment]


def test_long_speech_is_cut_at_20_seconds_and_continues_as_a_new_segment():
    segmenter = SpeechSegmenter()
    events = feed(segmenter, silence(0.5), tone(25), silence(1)) + segmenter.flush()
    segments = [e for e in events if isinstance(e, Segment)]
    assert len(segments) == 2
    assert len(segments[0].samples) <= 20 * R + 480
    assert segments[1].start_sample < segments[0].start_sample + len(segments[0].samples)


def test_a_cut_prefers_a_quiet_frame_inside_the_last_two_seconds():
    segmenter = SpeechSegmenter()
    events = feed(segmenter, silence(0.5), tone(19), silence(0.3), tone(6), silence(1))
    first = next(e for e in events if isinstance(e, Segment))
    end = first.start_sample + len(first.samples)
    assert 19.5 * R <= end <= 19.8 * R + 480


def test_continuous_noise_is_reported_as_a_noise_range_and_not_sent_to_the_recognizer():
    segmenter = SpeechSegmenter()
    events = feed(segmenter, silence(0.5), tone(70)) + segmenter.flush()
    assert any(isinstance(e, Noise) for e in events)
    assert any(isinstance(e, Dropped) for e in events)
    noise = next(e for e in events if isinstance(e, Noise))
    assert noise.end_sample > noise.start_sample


def test_sensitive_config_hears_what_the_default_misses():
    quiet = tone(1, 0.002)
    assert feed(SpeechSegmenter(), silence(1), quiet, silence(1)) == []
    events = feed(SpeechSegmenter(SegmenterConfig.sensitive()), silence(1), quiet, silence(1))
    assert any(isinstance(e, Segment) for e in events)


def test_steady_room_noise_raises_the_on_level_instead_of_opening_segments():
    noise = tone(8, 0.004)
    segmenter = SpeechSegmenter()
    events = feed(segmenter, noise, tone(1, 0.004), silence(1))
    assert not any(isinstance(e, Segment) for e in events[2:])


def test_skip_gap_flushes_and_moves_the_timeline():
    segmenter = SpeechSegmenter()
    segmenter.append(tone(1))
    events = segmenter.skip_gap(R * 5)
    assert any(isinstance(e, Segment) for e in events)
    assert segmenter.total_samples == R * 6


def test_streamer_maps_events_to_jobs():
    streamer = ChannelStreamer("mic")
    jobs = streamer.append(silence(0.96)) + streamer.append(tone(0.96)) + streamer.append(silence(1.5))
    assert [j.kind for j in jobs] == ["typing", "final"]
    assert jobs[1].channel == "mic" and jobs[1].start_seconds == pytest.approx(10_560 / R)


def seg(start, end, text, speaker="eu", final=True):
    return MeetingSegment(start, end, speaker, text, None, final)


def test_merger_trims_the_words_repeated_at_a_join():
    merger = TranscriptMerger()
    merger.commit([RecognizedSpan("olá, como vai você", 0, 2)], "mic")
    merger.commit([RecognizedSpan("Como vai você hoje", 2.3, 4)], "mic")
    assert [s.text for s in merger.finals] == ["olá, como vai você", "hoje"]


def test_merger_drops_a_fully_repeated_span_and_keeps_far_ones():
    merger = TranscriptMerger()
    merger.commit([RecognizedSpan("bom dia", 0, 1)], "mic")
    merger.commit([RecognizedSpan("bom dia", 1.2, 2)], "mic")
    merger.commit([RecognizedSpan("bom dia", 9, 10)], "mic")
    assert [s.start for s in merger.finals] == [0, 9]


def test_merger_never_compares_across_channels():
    merger = TranscriptMerger()
    merger.commit([RecognizedSpan("bom dia", 0, 1)], "mic")
    merger.commit([RecognizedSpan("bom dia", 1.1, 2)], "system")
    assert [s.speaker for s in merger.finals] == ["eu", "outros"]


def test_a_partial_is_replaced_by_the_next_and_dropped_by_a_final():
    merger = TranscriptMerger()
    merger.set_partial(RecognizedSpan("…", 1, 1), "mic")
    merger.set_partial(RecognizedSpan("…", 2, 2), "mic")
    assert [(s.start, s.is_final) for s in merger.snapshot] == [(2, False)]
    merger.commit([RecognizedSpan("oi", 1, 2)], "mic")
    assert [s.is_final for s in merger.snapshot] == [True]


def test_finals_stay_sorted_by_start_and_last_final_end_is_per_channel():
    merger = TranscriptMerger()
    merger.commit([RecognizedSpan("b", 5, 6)], "mic")
    merger.commit([RecognizedSpan("a", 1, 2)], "system")
    assert [s.text for s in merger.finals] == ["a", "b"]
    assert merger.last_final_end == {"mic": 6, "system": 2}


def test_merge_adjacent_joins_one_speaker_within_a_second_and_a_half():
    out = merge_adjacent([seg(0, 1, "a"), seg(1.5, 2, "b"), seg(2.1, 3, "x", "outros"), seg(6, 7, "c")])
    assert [(s.speaker, s.text) for s in out] == [("eu", "a b"), ("outros", "x"), ("eu", "c")]
    assert out[0].end == 2


def test_merge_adjacent_respects_the_character_cap_and_skips_blanks():
    long = "x" * 200
    out = merge_adjacent([seg(0, 1, long), seg(1, 2, long), seg(2, 3, "   ")])
    assert len(out) == 2


def test_speech_ratio_counts_overlaps_once_and_sparse_needs_a_long_recording():
    segments = [seg(0, 10, "a"), seg(5, 15, "b")]
    assert speech_ratio(segments, 100) == pytest.approx(0.15)
    assert is_sparse([], 10)
    assert not is_sparse(segments, 100)
    assert is_sparse([seg(0, 5, "a")], 600)
    assert not is_sparse([seg(0, 5, "a")], 100)


def envelope(pattern, repeat, amp):
    out = array("f")
    for _ in range(repeat):
        for loud in pattern:
            out.extend(tone(0.25, amp) if loud else silence(0.25))
    return out


def test_bleed_detects_the_speakers_copy_on_the_mic_and_keeps_double_talk():
    pattern = [1, 0, 1, 1, 0, 0, 1, 0]
    system = envelope(pattern, 1, 0.1)
    history = ChannelHistory(R * 30)
    history.append(silence(0.3) + system + silence(0.3))
    start = int(0.3 * R)
    copy = array("f", (x * 0.4 for x in system))
    assert BleedDetector.is_bleed(copy, start, history)
    loud = array("f", (x * 1.4 for x in system))
    assert not BleedDetector.is_bleed(loud, start, history)
    other = envelope([0, 1, 0, 0, 1, 1, 0, 1], 1, 0.04)
    assert not BleedDetector.is_bleed(other, start, history)


def test_bleed_never_judges_short_segments_or_unknown_history():
    system = envelope([1, 0, 1, 0], 1, 0.1)
    history = ChannelHistory(R * 30)
    history.append(silence(0.3) + system + silence(0.3))
    short = array("f", (x * 0.4 for x in system[: R // 2]))
    assert not BleedDetector.is_bleed(short, int(0.3 * R), history)
    assert not BleedDetector.is_bleed(array("f", (x * 0.4 for x in system)), 10 * R, ChannelHistory(R * 30))


def test_history_returns_none_for_audio_that_was_dropped():
    history = ChannelHistory(100)
    history.append(array("f", range(250)))
    assert history.window(0, 50) is None
    assert list(history.window(200, 210)) == list(range(200, 210))
    assert list(history.window(250, 252)) == [0.0, 0.0]
    history.skip(10)
    assert history.window(255, 258) is None
