import json
from datetime import timezone
from pathlib import Path

import pytest

from wisp import reuniao, reuniao_brain
from wisp.brain_index import NoteRow
from wisp.cli import main
from wisp.config import WispConfig

UTC = timezone.utc
EVENT = {
    "title": "Alinhamento do roadmap",
    "calendar": "Trabalho",
    "organizer": {"name": "Ana Souza", "email": "ana@example.com"},
    "attendees": [
        {"name": "Ana Souza", "email": "ana@example.com"},
        {"name": "Bruno Lima", "email": "bruno@example.com"},
        {"name": "Carla Dias", "email": "carla@example.com"},
        {"name": "", "email": "dani@example.com"},
    ],
    "notes": "Pauta: revisar o orçamento",
    "url": "https://meet.example.com/abc",
}
NOTA = (
    "# Roadmap fechado\n\n## Resumo\nAna Souza propôs o plano do Projeto Aurora.\n\n"
    "## Pontos principais\n### Prazo\n- Outros: Aurora entra em março.\n\n"
    "## Ações\n- [ ] Enviar plano — responsável: Bruno — prazo: sexta\n\n"
    "## Métricas\n\n- Tempo de fala: Você 40%\n\n## Transcrição\n\n[0:00] Você: oi\n"
)


def row(rel, title=None, aliases=()):
    stem = Path(rel).stem
    return NoteRow(rel, title or stem, stem, tuple(aliases))


ROWS = [
    row("pessoas/Ana Souza.md"),
    row("pessoas/Bruno Lima.md", aliases=("Bruno",)),
    row("pessoas/Carla Dias.md"),
    row("clientes/Carla Dias.md"),
    row("projetos/Projeto Aurora.md", aliases=("Aurora",)),
    row("meetings/2027-01-01 08h00 Alinhamento do roadmap.md"),
]


def recording(tmp_path, *, event=EVENT, generated=True, brain_note=None, name="rec"):
    folder = tmp_path / name
    folder.mkdir()
    meta = {"started_at": "2027-01-15T08:00:00Z", "duration_s": 3725, "note_state": "generated" if generated else None}
    if event is not None:
        meta["event"] = event
    if brain_note:
        meta["brain_note"] = str(brain_note)
    (folder / "meta.json").write_text(json.dumps(meta), "utf-8")
    (folder / "transcript.json").write_text("{}", "utf-8")
    if generated:
        (folder / "nota.md").write_text(NOTA, "utf-8")
    return folder


def brain_of(tmp_path):
    brain = tmp_path / "brain"
    brain.mkdir()
    return brain


def tree(root: Path):
    return sorted(str(p.relative_to(root)) for p in root.rglob("*"))


def test_attendee_with_one_note_links_to_it(tmp_path):
    brain = brain_of(tmp_path)
    result = reuniao_brain.sync(recording(tmp_path), brain, ROWS, UTC)
    text = Path(result["nota"]).read_text("utf-8")
    assert "**Participantes:** [[Ana Souza]], [[Bruno Lima]], Carla Dias, dani@example.com" in text


def test_ambiguous_attendee_stays_plain_text(tmp_path):
    names = reuniao_brain.Names(ROWS)
    assert names.lookup("Carla Dias") is None
    assert names.link_name("Carla Dias", "carla@example.com") == "Carla Dias"


def test_unknown_attendee_is_plain_and_no_stub_is_created(tmp_path):
    brain = brain_of(tmp_path)
    reuniao_brain.sync(recording(tmp_path), brain, [], UTC)
    assert tree(brain) == ["meetings", "meetings/2027-01-15-08h00m-alinhamento-do-roadmap.md"]
    text = (brain / "meetings" / "2027-01-15-08h00m-alinhamento-do-roadmap.md").read_text("utf-8")
    assert "[[" not in text


def test_alias_and_email_match(tmp_path):
    names = reuniao_brain.Names([row("pessoas/Bruno Lima.md", aliases=("Bruno", "bruno@example.com"))])
    assert names.link_name("Bruno", None) == "[[Bruno Lima|Bruno]]"
    assert names.link_name("", "bruno@example.com") == "[[Bruno Lima|bruno@example.com]]"


def test_summary_links_people_and_projects_but_not_headings(tmp_path):
    brain = brain_of(tmp_path)
    result = reuniao_brain.sync(recording(tmp_path), brain, ROWS, UTC)
    text = Path(result["nota"]).read_text("utf-8")
    assert "[[Ana Souza]] propôs o plano do [[Projeto Aurora]]." in text
    assert "Aurora entra em março" in text
    assert "[[Projeto Aurora|Aurora]]" not in text
    assert "responsável: [[Bruno Lima|Bruno]]" in text
    assert "## Resumo\n" in text and "Métricas" not in text


def test_no_link_to_lowercase_words_or_meeting_notes(tmp_path):
    names = reuniao_brain.Names([row("notas/orçamento.md"), row("meetings/Reunião X.md")])
    assert names.link_text("falamos do orçamento e da Reunião X") == "falamos do orçamento e da Reunião X"
    accented = reuniao_brain.Names([row("pessoas/João Pereira.md")])
    assert accented.link_text("Falou com Joao Pereira hoje") == "Falou com [[João Pereira|Joao Pereira]] hoje"


def test_existing_links_and_code_are_left_alone():
    names = reuniao_brain.Names(ROWS)
    text = "[[Ana Souza]] e `Ana Souza` e https://x.example/Ana-Souza e Bruno Lima"
    assert names.link_text(text) == "[[Ana Souza]] e `Ana Souza` e https://x.example/Ana-Souza e [[Bruno Lima]]"


def test_file_name_and_frontmatter(tmp_path):
    brain = brain_of(tmp_path)
    result = reuniao_brain.sync(recording(tmp_path), brain, ROWS, UTC)
    path = Path(result["nota"])
    assert path.name == "2027-01-15-08h00m-alinhamento-do-roadmap.md"
    assert path.parent == (brain / "meetings").resolve()
    text = path.read_text("utf-8")
    head = text.split("---")[1]
    for line in ("tipo: reuniao", "data: 2027-01-15 08:00", "duracao: 1:02:05", 'calendario: "Trabalho"',
                 'organizador: "Ana Souza <ana@example.com>"', 'link: "https://meet.example.com/abc"', "resumo_gerado: sim"):
        assert line in head
    assert '  - "Bruno Lima <bruno@example.com>"' in head
    assert f'gravacao: "{tmp_path / "rec"}"' in head
    assert f"({(tmp_path / 'rec' / 'nota.md').as_uri()})" in text
    assert "> Pauta: revisar o orçamento" in text


def test_title_is_made_safe_for_a_file_name(tmp_path):
    brain = brain_of(tmp_path)
    folder = recording(tmp_path, event={"title": 'Plano: "Q1" / [draft]?'})
    path = Path(reuniao_brain.sync(folder, brain, [], UTC)["nota"])
    assert path.name == "2027-01-15-08h00m-plano-q1-draft.md"


def test_never_overwrites_an_existing_note(tmp_path):
    brain = brain_of(tmp_path)
    meetings = brain / "meetings"
    meetings.mkdir()
    taken = meetings / "2027-01-15-08h00m-alinhamento-do-roadmap.md"
    taken.write_text("minha nota", "utf-8")
    first = Path(reuniao_brain.sync(recording(tmp_path), brain, [], UTC)["nota"])
    second = Path(reuniao_brain.sync(recording(tmp_path, name="rec2"), brain, [], UTC)["nota"])
    assert taken.read_text("utf-8") == "minha nota"
    assert first.name == "2027-01-15-08h00m-alinhamento-do-roadmap-2.md"
    assert second.name == "2027-01-15-08h00m-alinhamento-do-roadmap-3.md"


def test_without_event_uses_summary_title(tmp_path):
    brain = brain_of(tmp_path)
    path = Path(reuniao_brain.sync(recording(tmp_path, event=None), brain, ROWS, UTC)["nota"])
    assert path.name == "2027-01-15-08h00m-roadmap-fechado.md"
    assert "Participantes" not in path.read_text("utf-8")


def test_manual_flow_writes_placeholder_then_fills_the_same_note(tmp_path):
    brain = brain_of(tmp_path)
    folder = recording(tmp_path, generated=False)
    first = reuniao_brain.sync(folder, brain, ROWS, UTC)
    path = Path(first["nota"])
    text = path.read_text("utf-8")
    assert first["criada"] and not first["resumo"]
    assert reuniao_brain.PLACEHOLDER in text and "resumo_gerado: nao" in text
    assert f"({(folder / 'transcript.json').as_uri()})" in text
    assert "[[Ana Souza]]" in text

    meta = json.loads((folder / "meta.json").read_text("utf-8"))
    meta.update(note_state="generated", brain_note=str(path))
    (folder / "meta.json").write_text(json.dumps(meta), "utf-8")
    (folder / "nota.md").write_text(NOTA, "utf-8")
    second = reuniao_brain.sync(folder, brain, ROWS, UTC)
    assert second == {"nota": str(path.resolve()), "criada": False, "resumo": True}
    filled = path.read_text("utf-8")
    assert reuniao_brain.PLACEHOLDER not in filled and "resumo_gerado: sim" in filled
    assert "[[Projeto Aurora]]" in filled
    assert sorted(p.name for p in (brain / "meetings").iterdir()) == [path.name]


def test_fill_keeps_user_edits_and_skips_when_placeholder_is_gone(tmp_path):
    brain = brain_of(tmp_path)
    folder = recording(tmp_path, generated=False)
    path = Path(reuniao_brain.sync(folder, brain, [], UTC)["nota"])
    edited = path.read_text("utf-8").replace(reuniao_brain.PLACEHOLDER, "escrevi meu resumo")
    path.write_text(edited, "utf-8")
    meta = json.loads((folder / "meta.json").read_text("utf-8"))
    meta.update(note_state="generated", brain_note=str(path))
    (folder / "meta.json").write_text(json.dumps(meta), "utf-8")
    (folder / "nota.md").write_text(NOTA, "utf-8")
    result = reuniao_brain.sync(folder, brain, [], UTC)
    assert result["criada"] is False and result["resumo"] is False
    assert path.read_text("utf-8") == edited


def test_a_note_without_the_marker_is_never_updated(tmp_path):
    brain = brain_of(tmp_path)
    (brain / "meetings").mkdir()
    foreign = brain / "meetings" / "copia manual.md"
    foreign.write_text("---\ntipo: reuniao\n---\ncopia", "utf-8")
    folder = recording(tmp_path, brain_note=foreign)
    result = reuniao_brain.sync(folder, brain, [], UTC)
    assert result["criada"] is True
    assert foreign.read_text("utf-8") == "---\ntipo: reuniao\n---\ncopia"


def test_only_the_meetings_folder_is_written(tmp_path):
    brain = brain_of(tmp_path)
    (brain / "pessoas").mkdir()
    (brain / "pessoas" / "Ana Souza.md").write_text("ana", "utf-8")
    (brain / "index.md").write_text("indice", "utf-8")
    folder = recording(tmp_path)
    before = {p: p.read_bytes() for p in brain.rglob("*") if p.is_file()}
    reuniao_brain.sync(folder, brain, ROWS, UTC)
    after = {p: p.read_bytes() for p in brain.rglob("*") if p.is_file()}
    created = set(after) - set(before)
    assert len(created) == 1 and next(iter(created)).parent == (brain / "meetings").resolve()
    assert all(after[p] == before[p] for p in before)
    assert sorted(p.name for p in tmp_path.iterdir() if p.name != "home") == ["brain", "rec"]
    assert sorted(p.name for p in folder.iterdir()) == ["meta.json", "nota.md", "transcript.json"]


def test_missing_brain_creates_nothing(tmp_path):
    with pytest.raises(reuniao.Falha):
        reuniao_brain.sync(recording(tmp_path), tmp_path / "nope", [], UTC)
    assert not (tmp_path / "nope").exists()


def test_meetings_folder_pointing_outside_the_brain_is_refused(tmp_path):
    brain = brain_of(tmp_path)
    outside = tmp_path / "fora"
    outside.mkdir()
    (brain / "meetings").symlink_to(outside)
    with pytest.raises(reuniao.Falha):
        reuniao_brain.sync(recording(tmp_path), brain, [], UTC)
    assert list(outside.iterdir()) == []


def test_cli_command_writes_the_note(tmp_path, monkeypatch, capsys):
    brain = brain_of(tmp_path)
    folder = recording(tmp_path)
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setattr("wisp.cli._load_config_or_default", lambda: (WispConfig(), None))
    assert main(["reuniao", "brain", str(folder), "--brain", str(brain)]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["criada"] is True and Path(report["nota"]).parent == (brain / "meetings").resolve()


def test_index_line_is_appended_when_the_index_exists(tmp_path):
    brain = brain_of(tmp_path)
    (brain / "meetings").mkdir()
    index = brain / "meetings" / "meetings-index.md"
    index.write_text("# Reuniões\n- [[antiga]] — Antiga (2026-01-01)", "utf-8")
    result = reuniao_brain.sync(recording(tmp_path), brain, ROWS, UTC)
    assert result["indice"] is True
    assert index.read_text("utf-8") == (
        "# Reuniões\n- [[antiga]] — Antiga (2026-01-01)\n"
        "- [[2027-01-15-08h00m-alinhamento-do-roadmap]] — Alinhamento do roadmap (2027-01-15)\n"
    )


def test_index_is_not_created_when_missing(tmp_path):
    brain = brain_of(tmp_path)
    result = reuniao_brain.sync(recording(tmp_path), brain, ROWS, UTC)
    assert result["indice"] is False
    assert not (brain / "meetings" / "meetings-index.md").exists()


def test_resync_does_not_duplicate_the_index_line(tmp_path):
    brain = brain_of(tmp_path)
    (brain / "meetings").mkdir()
    index = brain / "meetings" / "meetings-index.md"
    index.write_text("", "utf-8")
    folder = recording(tmp_path, generated=False)
    path = Path(reuniao_brain.sync(folder, brain, ROWS, UTC)["nota"])
    meta = json.loads((folder / "meta.json").read_text("utf-8"))
    meta.update(note_state="generated", brain_note=str(path))
    (folder / "meta.json").write_text(json.dumps(meta), "utf-8")
    (folder / "nota.md").write_text(NOTA, "utf-8")
    reuniao_brain.sync(folder, brain, ROWS, UTC)
    reuniao_brain.sync(folder, brain, ROWS, UTC)
    assert index.read_text("utf-8").count("[[2027-01-15-08h00m-alinhamento-do-roadmap]]") == 1


def test_index_line_sanitizes_the_title():
    moment = reuniao_brain.started_at({"started_at": "2027-01-15T08:00:00Z"}, UTC)
    assert reuniao_brain.index_line("n", "A [[b]] | c\nd", moment) == "- [[n]] — A b c d (2027-01-15)"
