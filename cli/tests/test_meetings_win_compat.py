import threading
from datetime import datetime, timezone
from pathlib import Path

from wisp import reuniao, reuniao_brain
from wisp.config import WispConfig
from wisp.meetings_win import recordings
from wisp.meetings_win.language import LanguagePicker
from wisp.meetings_win.pipeline import MeetingPipeline, NoteOutcome
from wisp.meetings_win.transcriber import MeetingTranscriber
from wisp.meetings_win.transcript import read_transcript, write_transcript
from wisp.runner import RunResult

STARTED = datetime(2026, 5, 1, 13, 30, 5, tzinfo=timezone.utc)
ANSWERS = {
    "visao": "# Fechamento do orçamento\n\n## Resumo\nDefinido.",
    "pontos": "## Pontos principais\n### Orçamento\n- Você: propôs fechar hoje.",
    "acoes": "## Ações\n- [ ] Enviar planilha — responsável: Outros — prazo: sexta",
}


class Engine:
    def __init__(self):
        self.lock = threading.Lock()
        self.calls = 0

    def run(self, argv, *, stdin=None, timeout=60, env=None, cwd=None):
        if argv[1:] == ["--version"]:
            return RunResult(list(argv), 0, "claude 1", "")
        system = argv[argv.index("--append-system-prompt") + 1]
        kind = next(kind for kind, prompt, _ in reuniao.SECTIONS if prompt == system)
        with self.lock:
            self.calls += 1
        return RunResult(list(argv), 0, ANSWERS[kind], "")


class InProcessNotes:
    def __init__(self, cfg, runner):
        self.cfg, self.runner = cfg, runner

    def write_note(self, folder, cancel=None):
        report = reuniao.make_note(self.cfg, self.runner, folder)
        return NoteOutcome(report["gerada"], report["motivo"], report["titulo"])


def build_folder(tmp_path):
    folder = tmp_path / "reunioes" / "2026-05-01_13-30-05"
    folder.mkdir(parents=True)
    meta = recordings.new_meta(STARTED, mic="Microfone", system="Alto-falantes", sources="both", language="pt")
    meta.update(status="transcribing", duration_s=95.0,
                bookmarks=[{"id": "b1", "time": 12.0, "label": "preço"}],
                pauses=[{"at_s": 40.0, "started_at": "2026-05-01T13:31:00Z", "ended_at": "2026-05-01T13:36:00Z"}],
                checklist=[{"id": "c1", "text": "Revisar proposta", "done": True}, {"id": "c2", "text": "Falar do prazo", "done": False}])
    recordings.write_meta(folder, meta)
    live = {"version": 1, "started_at": "2026-05-01T13:30:05Z", "duration_s": 95.0, "language": "pt", "engine": "whisper-small",
            "segments": [{"start": 2.0, "end": 6.0, "speaker": "eu", "text": "Vamos fechar o orçamento hoje?"},
                         {"start": 12.5, "end": 16.0, "speaker": "outros", "text": "Pode ser, mando a planilha até sexta."},
                         {"start": 50.0, "end": 55.0, "speaker": "eu", "text": "Combinado então."}]}
    write_transcript(folder, live, live=True)
    return folder


def test_the_existing_note_writer_reads_what_the_port_leaves_in_the_folder(tmp_path):
    folder = build_folder(tmp_path)
    cfg = WispConfig(wisp_dir=str(tmp_path / "wisp"))
    engine = Engine()
    MeetingPipeline(MeetingTranscriber(None, LanguagePicker("pt")), InProcessNotes(cfg, engine)).process(folder)
    note = (folder / "nota.md").read_text("utf-8")
    assert note.startswith("---\ntipo: reuniao\ndata: 2026-05-01T13:30:05Z\nduracao: 1:35\n")
    assert "resumo_gerado: sim" in note and "# Fechamento do orçamento" in note
    assert "## Métricas" in note and "Tempo de fala: Você" in note
    assert "## Marcadores" in note and "### 0:12 preço" in note and "> [0:12] Você" not in note
    assert "[0:12] Outros: Pode ser, mando a planilha até sexta." in note
    assert "## Checklist" in note and "- [x] Revisar proposta" in note and "- [ ] Falar do prazo" in note
    assert "— Pausado " in note and "[0:40]" in note.split("— Pausado ")[0].splitlines()[-1]
    assert "[0:50] Você: Combinado então." in note
    assert engine.calls == 3
    meta = recordings.read_meta(folder)
    assert meta["status"] == "noted" and meta["note_state"] == "generated" and meta["title"] == "Fechamento do orçamento"
    assert read_transcript(folder)["segments"][0]["speaker"] == "eu"


def test_the_existing_brain_writer_files_the_note_under_the_meeting_start(tmp_path):
    folder = build_folder(tmp_path)
    cfg = WispConfig(wisp_dir=str(tmp_path / "wisp"))
    MeetingPipeline(MeetingTranscriber(None, LanguagePicker("pt")), InProcessNotes(cfg, Engine())).process(folder)
    brain = tmp_path / "brain"
    brain.mkdir()
    report = reuniao_brain.sync(folder, brain, [], timezone.utc, tmp_path / "home")
    saved = Path(report["nota"])
    assert report["criada"] is True and saved.parent == brain / "meetings"
    assert saved.name == "2026-05-01-13h30m-fechamento-do-orcamento.md"
    text = saved.read_text("utf-8")
    assert "tipo: reuniao" in text and "sync: wisp-reuniao" in text and "# Fechamento do orçamento" in text
    assert "[Transcrição completa](" in text
