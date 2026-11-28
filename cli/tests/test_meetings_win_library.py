import json
import os
import struct
from array import array
from datetime import datetime, timedelta, timezone

import pytest

from wisp.meetings_win import janitor, recordings
from wisp.meetings_win.wavfile import StereoWavWriter, read_blocks, repair_header

START = datetime(2026, 5, 1, 13, 30, 5, tzinfo=timezone.utc)


def make(root, name, **meta):
    folder = root / name
    folder.mkdir(parents=True)
    base = recordings.new_meta(START, sources="both")
    base.update(meta)
    recordings.write_meta(folder, base)
    return folder


def test_folder_name_is_the_local_start_time_and_a_second_one_gets_a_suffix(tmp_path):
    first = recordings.create_folder(tmp_path / "r", START)
    second = recordings.create_folder(tmp_path / "r", START)
    local = START.astimezone().strftime("%Y-%m-%d_%H-%M-%S")
    assert first.name == local and second.name == f"{local}-2"


def test_meta_roundtrip_keeps_keys_the_mac_wrote_and_updates_atomically(tmp_path):
    folder = make(tmp_path, "a", webhook_sent_at="2026-05-01T14:00:00Z", extra_from_mac={"x": 1})
    meta = recordings.update_meta(folder, lambda m: m.update(status="noted", title="T"))
    again = recordings.read_meta(folder)
    assert again == meta and again["extra_from_mac"] == {"x": 1} and again["status"] == "noted"
    assert again["started_at"] == "2026-05-01T13:30:05Z" and again["version"] == 1


def test_list_is_newest_first_and_skips_folders_without_a_readable_meta(tmp_path):
    make(tmp_path, "old", started_at="2026-04-01T10:00:00Z")
    make(tmp_path, "new", started_at="2026-05-02T10:00:00Z")
    (tmp_path / "stray").mkdir()
    (tmp_path / "broken").mkdir()
    (tmp_path / "broken" / "meta.json").write_text("{nope")
    (tmp_path / "new" / "nota.md").write_text("# n")
    entries = recordings.list_meetings(tmp_path)
    assert [e.id for e in entries] == ["new", "old"]
    assert entries[0].has_note and not entries[0].has_transcript
    assert recordings.list_meetings(tmp_path / "missing") == []


def test_what_needs_processing(tmp_path):
    make(tmp_path, "t", status="transcribing")
    make(tmp_path, "i", status="interrompida")
    make(tmp_path, "r", status="recording")
    make(tmp_path, "n", status="noted")
    make(tmp_path, "f", status="failed")
    done = make(tmp_path, "d", status="transcribed")
    (done / "transcript.json").write_text("{}")
    deferred = make(tmp_path, "s", status="transcribed", summary_deferred=True)
    (deferred / "transcript.json").write_text("{}")
    failed_note = make(tmp_path, "x", status="transcribed", failure="nota não gerada")
    (failed_note / "transcript.json").write_text("{}")
    assert sorted(e.id for e in recordings.pending(tmp_path)) == ["d", "i", "t"]
    assert sorted(e.id for e in recordings.pending(tmp_path, excluding={"d"})) == ["i", "t"]


def test_row_model_in_portuguese(tmp_path):
    folder = make(tmp_path, "a", status="transcribing", duration_s=125.0)
    row = recordings.row_model(recordings.list_meetings(tmp_path)[0], working=False, tz=timezone.utc)
    assert row["title"] == "Reunião de 01/05 às 13:30"
    assert row["date_text"] == "01/05 13:30" and row["duration_text"] == "2:05"
    assert row["badge"] == {"label": "transcrevendo", "tone": "working"}
    recordings.update_meta(folder, lambda m: m.update(status="transcribed", title="Plano"))
    (folder / "nota.md").write_text("# x")
    row = recordings.row_model(recordings.list_meetings(tmp_path)[0], working=True, tz=timezone.utc)
    assert row["title"] == "Plano" and row["badge"] == {"label": "gerando nota", "tone": "working"}
    assert recordings.badge("recording", False, False) == {"label": "gravando", "tone": "recording"}
    assert recordings.badge("failed", False, False) == {"label": "falhou", "tone": "failed"}
    assert recordings.badge("transcribed", False, False) == {"label": "transcrito", "tone": "ready"}


def test_brain_button():
    assert recordings.brain_button("/x/n.md", True) == {"label": "Abrir no brain", "opens_note": True}
    assert recordings.brain_button("/x/n.md", False) == {"label": "Salvar no brain", "opens_note": False}
    assert recordings.brain_button(None, True)["label"] == "Salvar no brain"


def test_wav_writer_reader_roundtrip_and_header_repair_after_a_crash(tmp_path):
    path = tmp_path / "audio.wav"
    writer = StereoWavWriter(path)
    left = array("f", [0.5, -0.5, 0.25, 0.0])
    right = array("f", [0.1, 0.2, 0.3, 0.4])
    interleaved = array("f")
    for a, b in zip(left, right):
        interleaved.extend([a, b])
    writer.write(interleaved)
    writer.flush_header()
    writer.write(interleaved)
    writer._file.flush()
    assert repair_header(path) == 8
    blocks = list(read_blocks(path, block_frames=3))
    got_left = [x for l, _ in blocks for x in l]
    assert len(got_left) == 8 and got_left[:4] == pytest.approx([0.5, -0.5, 0.25, 0.0], abs=1e-3)
    assert [round(x, 3) for x in blocks[0][1]] == pytest.approx([0.1, 0.2, 0.3], abs=1e-3)
    writer.close()
    assert path.stat().st_size == 44 + 8 * 4


def test_repair_of_a_file_with_no_audio_is_zero(tmp_path):
    path = tmp_path / "audio.wav"
    path.write_bytes(b"")
    assert repair_header(path) == 0
    path.write_bytes(b"RIFF" + struct.pack("<I", 0) + b"WAVE")
    assert repair_header(path) == 0


def test_recovery_marks_cut_short_recordings_interrupted_and_empty_ones_failed(tmp_path):
    cut = make(tmp_path, "cut", status="recording")
    writer = StereoWavWriter(cut / "audio.wav")
    writer.write(array("f", [0.1, 0.1] * 48_000))
    writer._file.flush()
    empty = make(tmp_path, "empty", status="recording")
    live = make(tmp_path, "live", status="recording")
    done = make(tmp_path, "done", status="noted")
    recovered = recordings.recover(tmp_path, active={"live"})
    assert {r["id"] for r in recovered} == {"cut", "empty"}
    assert recordings.read_meta(cut)["status"] == "interrompida"
    assert recordings.read_meta(cut)["duration_s"] == pytest.approx(1.0)
    assert recordings.read_meta(empty)["status"] == "failed"
    assert "interrompida antes de gravar áudio" in recordings.read_meta(empty)["failure"]
    assert recordings.read_meta(live)["status"] == "recording" and recordings.read_meta(done)["status"] == "noted"
    writer.close()


NOW = START + timedelta(days=10)


def noted(root, name, brain, **meta):
    folder = make(root, name, status="noted", note_state="generated", brain_note=str(brain), **meta)
    return folder


def test_janitor_clamps_days_and_reads_the_date_from_the_folder_name(tmp_path):
    assert janitor.clamp(-3) == 0 and janitor.clamp(9000) == 365 and janitor.clamp(14) == 14
    got = janitor.recording_date(None, "2026-05-01_13-30-05-2")
    assert got.strftime("%Y-%m-%d %H:%M:%S") == "2026-05-01 13:30:05"


def test_only_generated_noted_meetings_with_a_brain_note_and_old_enough_are_eligible(tmp_path):
    brain = tmp_path / "brain" / "n.md"
    brain.parent.mkdir()
    brain.write_text("x")
    root = tmp_path / "r"
    noted(root, "ok", brain)
    noted(root, "young", brain, started_at=iso_ago(2))
    make(root, "raw", status="noted", note_state="raw", brain_note=str(brain))
    noted(root, "err", brain, brain_error="boom")
    make(root, "nobrain", status="noted", note_state="generated")
    entries = recordings.list_meetings(root)
    eligible = janitor.eligible(entries, now=NOW, days=7)
    assert [e.id for e in eligible] == ["ok"]
    assert janitor.eligible(entries, now=NOW, days=0) == []
    assert janitor.eligible(entries, now=NOW, days=7, excluded={"ok"}) == []


def iso_ago(days):
    return (NOW - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")


def test_a_brain_note_inside_the_recording_folder_is_never_eligible(tmp_path):
    folder = make(tmp_path / "r", "a", status="noted", note_state="generated")
    inside = folder / "nota.md"
    inside.write_text("x")
    recordings.update_meta(folder, lambda m: m.update(brain_note=str(inside)))
    assert janitor.eligible(recordings.list_meetings(tmp_path / "r"), now=NOW, days=7) == []


def test_clean_rewrites_the_transcript_link_then_trashes(tmp_path):
    root = tmp_path / "r"
    brain = tmp_path / "brain" / "n.md"
    brain.parent.mkdir()
    folder = noted(root, "a", brain)
    brain.write_text(f"# t\n\n## Transcrição\n\n[Transcrição completa]({folder.as_posix()}/nota.md)\n")
    trashed = []
    outcome = janitor.clean(recordings.list_meetings(root)[0], NOW, 7, trash=trashed.append, tz=timezone.utc)
    assert outcome == ("removed", None) and trashed == [folder]
    text = brain.read_text()
    assert "Transcrição apagada em 11/05/2026 (limpeza automática após 7 dias)." in text
    assert "[Transcrição completa]" not in text


def test_clean_skips_when_a_link_points_to_another_folder_or_the_note_changes(tmp_path):
    root = tmp_path / "r"
    brain = tmp_path / "brain" / "n.md"
    brain.parent.mkdir()
    folder = noted(root, "a", brain)
    brain.write_text("[Transcrição completa](/somewhere/else/nota.md)\n")
    trashed = []
    assert janitor.clean(recordings.list_meetings(root)[0], NOW, 7, trash=trashed.append) == ("skipped", None)
    brain.write_text(f"[Transcrição completa]({folder.as_posix()}/nota.md)\n")

    def edit():
        brain.write_text("changed meanwhile\n")
        os.utime(brain, (1, 1))

    assert janitor.clean(recordings.list_meetings(root)[0], NOW, 7, trash=trashed.append, before_write=edit) \
        == ("skipped", None)
    assert trashed == [] and brain.read_text() == "changed meanwhile\n"


def test_clean_without_any_link_just_trashes_and_a_failing_trash_is_reported(tmp_path):
    root = tmp_path / "r"
    brain = tmp_path / "brain" / "n.md"
    brain.parent.mkdir()
    noted(root, "a", brain)
    brain.write_text("# no link\n")

    def boom(_):
        raise OSError("locked")

    assert janitor.clean(recordings.list_meetings(root)[0], NOW, 7, trash=boom) == ("failed", "locked")


def test_run_reports_removed_and_failures(tmp_path):
    root = tmp_path / "r"
    brain = tmp_path / "brain" / "n.md"
    brain.parent.mkdir()
    brain.write_text("# n\n")
    noted(root, "a", brain)
    noted(root, "b", brain)
    seen = []

    def trash(path):
        seen.append(path.name)
        if path.name == "b":
            raise OSError("in use")

    report = janitor.run([root], now=NOW, days=7, trash=trash)
    assert report == {"removed": ["a"], "failures": ["b: in use"]}
    assert sorted(seen) == ["a", "b"]


def test_a_home_relative_link_is_matched_and_a_foreign_one_is_counted(tmp_path):
    home = tmp_path / "home with space"
    folder = home / "Wisp" / "reunioes" / "a"
    folder.mkdir(parents=True)
    note = "[Transcrição completa](~/Wisp/reunioes/a/nota.md)"
    scan = janitor.scan_transcript_links(note, folder, NOW, 7, home=home, tz=timezone.utc)
    assert scan["foreign"] == 0 and "apagada" in scan["text"]
    encoded = "[Transcrição completa](~/home%20x/nota.md)"
    assert janitor.scan_transcript_links(encoded, folder, NOW, 7, home=home)["foreign"] == 1


def test_json_files_are_what_the_mac_reads(tmp_path):
    folder = make(tmp_path, "a")
    raw = json.loads((folder / "meta.json").read_text())
    assert raw["mode"] == "call" and raw["devices"] == {"mic": None, "system": None}
