import json
import sys
import textwrap
import threading
from array import array
from datetime import datetime, timezone
from pathlib import Path

import pytest

from wisp.meetings_win import recordings
from wisp.meetings_win.asr import RecognizeResult
from wisp.meetings_win.language import LanguagePicker
from wisp.meetings_win.pipeline import (MeetingPipeline, NoteBusy, NoteOutcome, SubprocessBrainWriter,
                                        SubprocessNoteWriter)
from wisp.meetings_win.refine import RefineResult
from wisp.meetings_win.transcriber import Cancelled, MeetingTranscriber
from wisp.meetings_win.transcript import (SILENT_NOTICE, SPARSE_NOTICE, RecognizedSpan, read_transcript, write_transcript)
from wisp.meetings_win.wavfile import StereoWavWriter

R = 48_000
STARTED = datetime(2026, 5, 1, 13, 0, tzinfo=timezone.utc)


def quiet(seconds):
    return array("f", bytes(4 * round(seconds * R)))


def loud(seconds, amp=0.1):
    return array("f", [amp] * round(seconds * R))


def write_audio(folder, left, right):
    writer = StereoWavWriter(folder / "audio.wav")
    for start in range(0, len(left), R):
        chunk = array("f")
        for a, b in zip(left[start:start + R], right[start:start + R]):
            chunk.extend([a, b])
        writer.write(chunk)
    writer.close()


class Recognizer:
    engine_name = "fake-final"

    def __init__(self, fail=False):
        self.calls = 0
        self.fail = fail

    def transcribe(self, samples, language):
        self.calls += 1
        if self.fail:
            raise RuntimeError("model missing")
        return RecognizeResult([RecognizedSpan("texto final", 0.2, 0.9)], "pt", 0.9)

    def unload(self):
        pass


class Notes:
    def __init__(self, outcome=None, error=None, write=True):
        self.outcome = outcome or NoteOutcome(True, None, "Título gerado")
        self.error, self.write, self.calls = error, write, 0

    def write_note(self, folder, cancel=None):
        self.calls += 1
        if self.error:
            raise self.error
        if self.write and self.outcome.generated:
            (folder / "nota.md").write_text("# Título gerado\n\n## Resumo\n\nok\n", encoding="utf-8")
        return self.outcome


class Brain:
    def __init__(self, error=None):
        self.error, self.calls = error, 0

    def sync_note(self, folder, cancel=None):
        self.calls += 1
        if self.error:
            raise self.error
        return Path("/brain/meetings/x.md")


def new_folder(tmp_path, status="transcribing", live=None, audio=True, **meta):
    folder = tmp_path / "m"
    folder.mkdir()
    base = recordings.new_meta(STARTED, sources="both")
    base.update({"status": status, "duration_s": 6.0, **meta})
    recordings.write_meta(folder, base)
    if live is not None:
        write_transcript(folder, live, live=True)
    if audio:
        write_audio(folder, quiet(1) + loud(1) + quiet(4), quiet(4) + loud(1) + quiet(1))
    return folder


def live_doc(n=2, duration=6.0, **extra):
    segments = [{"start": float(i), "end": float(i) + 0.9, "speaker": "eu", "text": f"ao vivo {i}"} for i in range(n)]
    return {"version": 1, "started_at": "2026-05-01T13:00:00Z", "duration_s": duration, "language": "pt",
            "engine": "whisper-small", "segments": segments, **extra}


def pipeline(notes=None, brain=None, recognizer=None, refiner=None):
    return MeetingPipeline(MeetingTranscriber(recognizer or Recognizer(), LanguagePicker("pt")), notes or Notes(), brain, refiner)


def test_a_trusted_live_transcript_becomes_the_final_one_and_the_final_pass_is_skipped(tmp_path):
    folder = new_folder(tmp_path, live=live_doc(duration=6.0))
    recognizer = Recognizer()
    brain = Brain()
    stages = []
    pipeline(recognizer=recognizer, brain=brain).process(folder, lambda kind, f: stages.append(kind))
    assert recognizer.calls == 0
    assert not (folder / "transcript.live.json").exists()
    assert [s["text"] for s in read_transcript(folder)["segments"]] == ["ao vivo 0 ao vivo 1"]
    meta = recordings.read_meta(folder)
    assert meta["status"] == "noted" and meta["note_state"] == "generated" and meta["title"] == "Título gerado"
    assert meta["note_file"] == "nota.md" and meta["brain_note"] == str(Path("/brain/meetings/x.md")) and "brain_error" not in meta
    assert meta["metrics"]["you"]["words"] == 6
    assert "writing_note" in stages and brain.calls == 1


def test_a_live_pass_with_failed_segments_or_a_cut_short_recording_runs_the_final_pass(tmp_path):
    folder = new_folder(tmp_path, live=live_doc(failed_segments=2))
    recognizer = Recognizer()
    pipeline(recognizer=recognizer).process(folder)
    assert recognizer.calls == 2
    assert {s["text"] for s in read_transcript(folder)["segments"]} == {"texto final"}
    other = tmp_path / "other"
    other.mkdir()
    folder = new_folder(other, status="interrompida", live=live_doc())
    recognizer = Recognizer()
    pipeline(recognizer=recognizer).process(folder)
    assert recognizer.calls == 2


def test_a_sparse_live_transcript_reruns_with_more_sensitivity_and_says_so(tmp_path):
    folder = new_folder(tmp_path, live=live_doc(n=1, duration=600.0), duration_s=600.0)
    write_audio(folder, quiet(1) + loud(1) + quiet(8), quiet(10))
    recognizer = Recognizer()
    pipeline(recognizer=recognizer).process(folder)
    assert recognizer.calls == 1
    assert recordings.read_meta(folder)["notice"] == SPARSE_NOTICE


def test_no_speech_at_all_says_so_and_writes_no_note(tmp_path):
    folder = new_folder(tmp_path)
    write_audio(folder, quiet(130), quiet(130))
    recordings.update_meta(folder, lambda m: m.update(duration_s=130.0))
    notes = Notes()
    pipeline(notes=notes).process(folder)
    meta = recordings.read_meta(folder)
    assert meta["status"] == "transcribed" and meta["failure"] == "nenhuma fala detectada nessa gravação"
    assert meta["notice"] == SILENT_NOTICE and notes.calls == 0 and not (folder / "nota.md").exists()


def test_a_recognizer_failure_marks_the_meeting_failed_with_the_reason_and_raises(tmp_path):
    folder = new_folder(tmp_path)
    with pytest.raises(RuntimeError):
        pipeline(recognizer=Recognizer(fail=True)).process(folder)
    meta = recordings.read_meta(folder)
    assert meta["status"] == "failed" and meta["failure"] == "não consegui transcrever: model missing"


def test_a_note_that_was_not_generated_leaves_a_raw_note_with_the_transcript(tmp_path):
    folder = new_folder(tmp_path, live=live_doc())
    notes = Notes(NoteOutcome(False, "a IA local não está pronta: sem modelo"), write=False)
    pipeline(notes=notes).process(folder)
    meta = recordings.read_meta(folder)
    assert meta["status"] == "noted" and meta["note_state"] == "raw"
    assert meta["failure"] == "nota não gerada: a IA local não está pronta: sem modelo"
    text = (folder / "nota.md").read_text("utf-8")
    assert "> Nota não gerada: a IA local não está pronta: sem modelo" in text and "[0:00] Você: ao vivo 0" in text
    assert meta["title"] == "Reunião"


def test_an_engine_that_throws_is_the_same_as_one_that_did_not_generate(tmp_path):
    folder = new_folder(tmp_path, live=live_doc())
    pipeline(notes=Notes(error=RuntimeError("boom"))).process(folder)
    assert recordings.read_meta(folder)["note_state"] == "raw"
    assert "boom" in (folder / "nota.md").read_text("utf-8")


def test_a_note_already_being_written_elsewhere_is_busy_and_propagates(tmp_path):
    folder = new_folder(tmp_path, live=live_doc())
    with pytest.raises(NoteBusy, match="já está sendo gerada"):
        pipeline(notes=Notes(error=NoteBusy())).process(folder)


def test_a_brain_failure_never_fails_the_meeting_and_is_kept_as_brain_error(tmp_path):
    folder = new_folder(tmp_path, live=live_doc())
    pipeline(brain=Brain(error=RuntimeError("sem permissão"))).process(folder)
    meta = recordings.read_meta(folder)
    assert meta["status"] == "noted" and meta["brain_error"] == "sem permissão" and "brain_note" not in meta


def test_a_deferred_summary_syncs_the_brain_without_a_note(tmp_path):
    folder = new_folder(tmp_path, live=live_doc(), summary_deferred=True)
    notes, brain = Notes(), Brain()
    pipeline(notes=notes, brain=brain).process(folder)
    assert notes.calls == 0 and brain.calls == 1 and not (folder / "nota.md").exists()
    assert recordings.read_meta(folder)["status"] == "transcribed"


def test_a_noted_meeting_with_its_note_is_left_alone_and_a_recording_is_not_touched(tmp_path):
    folder = new_folder(tmp_path, status="noted")
    (folder / "nota.md").write_text("# x", encoding="utf-8")
    notes = Notes()
    pipeline(notes=notes).process(folder)
    assert notes.calls == 0
    other = tmp_path / "r"
    other.mkdir()
    rec = new_folder(other, status="recording")
    pipeline(notes=notes).process(rec)
    assert notes.calls == 0 and recordings.read_meta(rec)["status"] == "recording"


def test_regenerate_note_rewrites_only_the_note(tmp_path):
    folder = new_folder(tmp_path, live=live_doc())
    p = pipeline()
    p.process(folder)
    recognizer_calls = p.transcriber.recognizer.calls
    notes = Notes(NoteOutcome(True, None, "Outro título"))
    MeetingPipeline(p.transcriber, notes).regenerate_note(folder)
    assert notes.calls == 1 and recordings.read_meta(folder)["title"] == "Outro título"
    assert p.transcriber.recognizer.calls == recognizer_calls


def test_the_post_call_refine_replaces_the_text_and_keeps_the_live_one_as_a_backup(tmp_path):
    folder = new_folder(tmp_path, live=live_doc())

    class Refiner:
        def refine(self, folder, meta, original, progress, cancel=None):
            progress(0.5)
            return RefineResult(dict(original, segments=[{"start": 0.0, "end": 1.0, "speaker": "eu", "text": "revisado"}],
                                    engine="whisper-large-v3"))

    stages = []
    pipeline(refiner=lambda meta: Refiner()).process(folder, lambda kind, f: stages.append(kind))
    assert [s["text"] for s in read_transcript(folder)["segments"]] == ["revisado"]
    backup = json.loads((folder / "transcript.parakeet.json").read_text("utf-8"))
    assert backup["segments"][0]["text"] == "ao vivo 0 ao vivo 1"
    assert "refining" in stages and "notice" not in recordings.read_meta(folder)


def test_a_refine_notice_is_kept_and_the_live_transcript_stays(tmp_path):
    folder = new_folder(tmp_path, live=live_doc())

    class Refiner:
        def refine(self, *args, **kwargs):
            return RefineResult(notice="O modelo Whisper large-v3 não foi baixado; mantive a transcrição ao vivo.")

    pipeline(refiner=lambda meta: Refiner()).process(folder)
    assert "não foi baixado" in recordings.read_meta(folder)["notice"]
    assert [s["text"] for s in read_transcript(folder)["segments"]] == ["ao vivo 0 ao vivo 1"]
    assert not (folder / "transcript.parakeet.json").exists()


def test_improve_transcript_runs_the_full_pass_on_any_meeting_and_rewrites_the_note(tmp_path):
    folder = new_folder(tmp_path, status="noted")
    write_transcript(folder, live_doc())
    (folder / "nota.md").write_text("# velho", encoding="utf-8")
    recognizer = Recognizer()
    notes = Notes(NoteOutcome(True, None, "Novo"))
    pipeline(notes=notes, recognizer=recognizer).improve_transcript(folder)
    assert recognizer.calls == 2 and notes.calls == 1
    assert {s["text"] for s in read_transcript(folder)["segments"]} == {"texto final"}
    assert recordings.read_meta(folder)["title"] == "Novo"


def test_the_noise_the_live_pass_flagged_is_re_read_and_merged_in(tmp_path):
    live = live_doc(n=2, duration=6.0, noise_ranges=[{"channel": "system", "start": 4.0, "end": 5.0}])
    folder = new_folder(tmp_path, live=live)
    recognizer = Recognizer()
    pipeline(recognizer=recognizer).process(folder)
    assert recognizer.calls == 1
    texts = [s["text"] for s in read_transcript(folder)["segments"]]
    assert any("texto final" in t for t in texts) and any("ao vivo" in t for t in texts)
    assert "noise_ranges" not in read_transcript(folder)


def test_cancelling_keeps_the_meeting_waiting_for_the_next_run(tmp_path):
    folder = new_folder(tmp_path)
    cancel = threading.Event()
    cancel.set()
    with pytest.raises(Cancelled):
        pipeline().process(folder, cancel=cancel)
    assert recordings.read_meta(folder)["status"] == "transcribing"


def script(tmp_path, body):
    path = tmp_path / "fake_wisp.py"
    path.write_text(textwrap.dedent(body), encoding="utf-8")
    return [sys.executable, str(path)]


def test_the_note_writer_runs_wisp_reuniao_nota_and_reads_its_json_line(tmp_path):
    argv = script(tmp_path, """
        import json, sys
        assert sys.argv[1:3] == ["reuniao", "nota"], sys.argv
        print(json.dumps({"nota": sys.argv[3] + "/nota.md", "gerada": True, "motivo": None, "titulo": "Plano", "motor": "claude"}))
    """)
    outcome = SubprocessNoteWriter(argv).write_note(tmp_path)
    assert outcome == NoteOutcome(True, None, "Plano")


def test_the_note_writer_maps_busy_and_failures(tmp_path):
    busy = script(tmp_path, """
        import json, sys
        print(json.dumps({"erro": "já tem uma nota", "ocupado": True}), file=sys.stderr)
        sys.exit(3)
    """)
    with pytest.raises(NoteBusy):
        SubprocessNoteWriter(busy).write_note(tmp_path)
    failed = script(tmp_path, """
        import json, sys
        print(json.dumps({"erro": "a transcrição está vazia", "ocupado": False}), file=sys.stderr)
        sys.exit(1)
    """)
    outcome = SubprocessNoteWriter(failed).write_note(tmp_path)
    assert outcome.generated is False and outcome.reason == "a transcrição está vazia"
    broken = script(tmp_path, "import sys; sys.exit(7)")
    assert "7" in SubprocessNoteWriter(broken).write_note(tmp_path).reason


def test_cancelling_kills_the_note_process_tree_and_raises(tmp_path):
    argv = script(tmp_path, "import time; time.sleep(60)")
    cancel = threading.Event()
    threading.Timer(0.3, cancel.set).start()
    started = datetime.now()
    with pytest.raises(Cancelled):
        SubprocessNoteWriter(argv).write_note(tmp_path, cancel=cancel)
    assert (datetime.now() - started).total_seconds() < 10


def test_the_brain_writer_passes_the_brain_folder_and_returns_the_saved_path(tmp_path):
    argv = script(tmp_path, """
        import json, sys
        assert sys.argv[1:3] == ["reuniao", "brain"] and sys.argv[4:] == ["--brain", "/the/brain"], sys.argv
        print(json.dumps({"nota": "/the/brain/meetings/x.md", "criada": True}))
    """)
    assert SubprocessBrainWriter(argv, brain=lambda: "/the/brain").sync_note(tmp_path) == Path("/the/brain/meetings/x.md")
    failing = script(tmp_path, """
        import json, sys
        print(json.dumps({"erro": "sem permissão para acessar o brain"}), file=sys.stderr)
        sys.exit(1)
    """)
    with pytest.raises(RuntimeError, match="sem permissão"):
        SubprocessBrainWriter(failing, brain=lambda: None).sync_note(tmp_path)
