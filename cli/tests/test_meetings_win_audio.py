from array import array

import pytest

from wisp.meetings_win.audio import (CaptureGate, CaptureRing, Decimator48To16, LinearResampler, LiveAudioAligner,
                                     StereoMixer, mono_downmix, rms)

RATE = 48_000


def fl(values):
    return array("f", values)


def test_rms_of_a_constant_and_of_nothing():
    assert rms(fl([0.5] * 100)) == pytest.approx(0.5)
    assert rms(fl([])) == 0.0


def test_mono_downmix_averages_interleaved_channels():
    assert list(mono_downmix(fl([1, 3, 2, 4]), 2)) == [2.0, 3.0]
    assert list(mono_downmix(fl([1, 2, 3]), 1)) == [1.0, 2.0, 3.0]
    assert list(mono_downmix(fl([1, 2]), 0)) == []


def test_resampler_same_rate_is_a_pass_through():
    data = fl([0.1, 0.2, 0.3])
    assert list(LinearResampler(48_000, 48_000).process(data)) == list(data)


def test_resampler_result_does_not_depend_on_how_the_input_is_cut():
    source = fl([((i * 37) % 100) / 100 for i in range(4410)])
    whole = list(LinearResampler(44_100).process(source))
    cut = LinearResampler(44_100)
    pieces = []
    for start in range(0, len(source), 777):
        pieces += list(cut.process(source[start:start + 777]))
    assert len(pieces) == len(whole)
    assert pieces == pytest.approx(whole)


def test_resampler_upsamples_by_interpolating():
    out = LinearResampler(24_000, 48_000).process(fl([0.0, 1.0, 0.0]))
    assert list(out)[:3] == pytest.approx([0.0, 0.5, 1.0])


def test_decimator_is_a_three_to_one_box_average_across_chunks():
    d = Decimator48To16()
    assert list(d.process(fl([3, 3, 3, 6, 6]))) == [3.0]
    assert list(d.process(fl([6, 9, 9, 9]))) == [6.0, 9.0]


def test_ring_keeps_order_and_splits_into_slots():
    ring = CaptureRing(slot_frames=4, slot_count=8)
    ring.push(fl(range(10)), channels=1, rate=RATE, time=1.0)
    slots = []
    while (slot := ring.pop()) is not None:
        slots.append(slot)
    assert [len(s.samples) for s in slots] == [4, 4, 2]
    assert [s.time for s in slots] == pytest.approx([1.0, 1.0 + 4 / RATE, 1.0 + 8 / RATE])
    assert [x for s in slots for x in s.samples] == list(range(10))


def test_a_full_ring_drops_and_counts_the_overrun_instead_of_blocking():
    ring = CaptureRing(slot_frames=4, slot_count=2)
    ring.push(fl(range(12)), channels=1, rate=RATE, time=0.0)
    assert ring.overruns == 1
    assert len(list(iter(ring.pop, None))) == 2


def test_ring_stores_at_most_four_channels():
    ring = CaptureRing(slot_frames=4, slot_count=2)
    ring.push(fl(range(12)), channels=6, rate=RATE, time=0.0)
    slot = ring.pop()
    assert slot.channels == 4


def test_gate_drops_the_paused_span_and_shifts_what_follows():
    gate = CaptureGate()
    assert gate.admit(1.0) == 1.0
    gate.pause(10.0)
    assert gate.is_paused and gate.admit(10.5) is None
    gate.resume(14.0)
    assert gate.admit(9.9) == 9.9
    assert gate.admit(12.0) is None
    assert gate.admit(14.0) == pytest.approx(10.0)
    assert gate.admit(20.0) == pytest.approx(16.0)


def test_mixer_waits_for_both_sources_then_aligns_by_time():
    mixer = StereoMixer()
    mixer.push_mic(fl([1.0] * 480), at=100.0)
    assert list(mixer.pull()) == []
    mixer.push_system(fl([2.0] * 480), at=100.0 + 0.1)
    out = mixer.pull(flush=True)
    assert len(out) // 2 == 4800 + 480
    assert out[0] == 1.0 and out[1] == 0.0
    assert out[4800 * 2 + 1] == 2.0 and out[4799 * 2 + 1] == 0.0


def test_mixer_places_a_small_start_skew_as_contiguous():
    mixer = StereoMixer()
    mixer.push_mic(fl([1.0] * 480), at=100.0)
    mixer.push_system(fl([2.0] * 480), at=100.0 + 0.01)
    out = mixer.pull(flush=True)
    assert len(out) // 2 == 480 and out[1] == 2.0


def test_mixer_contiguous_chunks_inside_tolerance_insert_nothing():
    mixer = StereoMixer()
    mixer.push_mic(fl([1.0] * 480), at=0.0)
    mixer.push_system(fl([1.0] * 480), at=0.0)
    mixer.push_mic(fl([1.0] * 480), at=0.010 + 0.0003)
    out = mixer.pull(flush=True)
    assert len(out) // 2 == 960


def test_mixer_pads_a_real_gap_with_silence_and_drops_overlap():
    mixer = StereoMixer()
    mixer.push_mic(fl([1.0] * 480), at=0.0)
    mixer.push_system(fl([1.0] * 480), at=0.0)
    mixer.push_mic(fl([1.0] * 480), at=0.110)
    out = mixer.pull(flush=True)
    mic = [out[i * 2] for i in range(len(out) // 2)]
    assert len(mic) == round(0.110 * RATE) + 480
    assert mic[480] == 0.0 and mic[5279] == 0.0 and mic[5280] == 1.0

    over = StereoMixer()
    over.push_mic(fl([1.0] * 4800), at=0.0)
    over.push_system(fl([1.0] * 4800), at=0.0)
    over.push_mic(fl([2.0] * 4800), at=0.05)
    out = over.pull(flush=True)
    assert len(out) // 2 == 4800 + 2400
    assert out[(4800 + 10) * 2] == 2.0 and out[4790 * 2] == 1.0


def test_mixer_does_not_stall_when_one_source_goes_quiet():
    mixer = StereoMixer()
    mixer.push_mic(fl([1.0] * 48_000), at=0.0)
    mixer.push_system(fl([1.0] * 480), at=0.0)
    out = mixer.pull()
    assert len(out) // 2 == 48_000 - 24_000


def test_mixer_with_only_one_source_resolves_after_max_skew():
    mixer = StereoMixer()
    mixer.push_mic(fl([1.0] * 20_000), at=5.0)
    assert list(mixer.pull()) == []
    assert len(mixer.pull(flush=True)) == 40_000


def test_aligner_pads_small_gaps_and_reports_long_ones():
    aligner = LiveAudioAligner()
    first = aligner.align(fl([1.0] * 480), "mic", at=10.0)
    assert len(first.samples) == 480 and first.gap_seconds is None
    padded = aligner.align(fl([1.0] * 480), "mic", at=10.0 + 0.5)
    assert len(padded.samples) == 24_000 - 480 + 480 and padded.gap_seconds is None
    far = aligner.align(fl([1.0] * 480), "mic", at=10.0 + 9.0)
    assert len(far.samples) == 480 and far.gap_seconds == pytest.approx(9.0 - 0.51, abs=0.01)


def test_aligner_trims_overlap_and_audio_before_the_shared_origin():
    aligner = LiveAudioAligner()
    aligner.align(fl([1.0] * 4800), "mic", at=10.0)
    trimmed = aligner.align(fl([2.0] * 4800), "mic", at=10.05)
    assert len(trimmed.samples) == 2400
    early = aligner.align(fl([3.0] * 480), "system", at=9.99)
    assert len(early.samples) == 0


def test_the_pure_python_paths_give_the_same_numbers_as_the_numpy_ones(monkeypatch, tmp_path):
    import math

    from wisp.meetings_win import audio
    from wisp.meetings_win.wavfile import StereoWavWriter, read_blocks

    if audio._numpy is None:
        pytest.skip("numpy is not installed here")
    source = fl(math.sin(i / 7) * 0.3 for i in range(9_000))
    stereo = fl(math.sin(i / 5) * 0.2 for i in range(6_000))

    def run():
        out = {
            "rms": rms(source), "mean_squares": audio.mean_squares(source, 1_000),
            "mono": list(mono_downmix(stereo, 2)),
            "resample": list(LinearResampler(44_100).process(source)),
            "decimate": list(Decimator48To16().process(source)),
        }
        writer = StereoWavWriter(tmp_path / f"{len(out)}-{id(out)}.wav")
        writer.write(stereo)
        writer.close()
        out["wav"] = [x for block in read_blocks(writer.path, 1_000) for lane in block for x in lane]
        return out

    fast = run()
    monkeypatch.setattr(audio, "_numpy", None)
    slow = run()
    for key in fast:
        assert slow[key] == pytest.approx(fast[key], abs=1e-4), key
