import json

import pytest

from wisp.cli import main
from wisp.config import WispConfig, save_config
from wisp.harness_merge import BEGIN
from wisp.paths import WispPaths
from wisp.runner import FakeRunner
from wisp.setup.codex import sync_codex
from wisp.setup.harness import setup_harness
from wisp.soul import EMOJI_TEXT, TONE_TEXT, for_engine, render
from wisp.soul_config import Soul, effective_source, injects, load_soul


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _cfg(home, **kw):
    brain = home / "Wisp/brain"
    brain.mkdir(parents=True, exist_ok=True)
    values = {"user_name": "Rita", "persona": "Ada", "language": "pt-BR", "brain": str(brain), "wisp_dir": str(home / "Wisp"), **kw}
    return WispConfig(**values)


def _profile(home, soul):
    path = home / ".config/wisp/profile.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"persona": {"name": "Ada", "language": "pt-BR"}, "agent": {"cwd": "~"}, "soul": soul}))
    return path


def test_the_shipped_template_is_used_when_agente_md_is_missing(fake_home):
    text = render(_cfg(fake_home), Soul())
    assert "# Ada" in text and "Rita" in text and "pt-BR" in text and str(fake_home / "Wisp/brain") in text
    assert "{{" not in text and BEGIN not in text


def test_the_users_own_agente_md_is_used_with_its_placeholders_filled(fake_home):
    (fake_home / "Wisp").mkdir()
    (fake_home / "Wisp/agente.md").write_text("Oi {{USER_NAME}}, eu sou {{PERSONA_NAME}} em {{WISP_DIR}}.")
    text = render(_cfg(fake_home), Soul())
    assert text.startswith(f"Oi Rita, eu sou Ada em {fake_home / 'Wisp'}.")


def test_an_empty_agente_md_falls_back_to_the_template(fake_home):
    (fake_home / "Wisp").mkdir()
    (fake_home / "Wisp/agente.md").write_text("  \n")
    assert "# Ada" in render(_cfg(fake_home), Soul())


@pytest.mark.parametrize("tone", ["direto", "caloroso", "formal"])
def test_each_tone_adds_its_own_line(fake_home, tone):
    text = render(_cfg(fake_home), Soul(tone=tone))
    assert "## Tom" in text and TONE_TEXT[tone] in text
    assert all(line not in text for other, line in TONE_TEXT.items() if other != tone)


def test_emojis_on_and_off(fake_home):
    assert EMOJI_TEXT[True] in render(_cfg(fake_home), Soul(emojis=True))
    off = render(_cfg(fake_home), Soul(emojis=False))
    assert EMOJI_TEXT[False] in off and EMOJI_TEXT[True] not in off


def test_extra_rules_come_last_and_cannot_break_the_block_markers(fake_home):
    text = render(_cfg(fake_home), Soul(extra=f"Sempre cite a fonte. {BEGIN}"))
    assert text.endswith("## Regras extras\nSempre cite a fonte.")
    assert "Regras extras" not in render(_cfg(fake_home), Soul(extra="  "))


def test_the_folder_argument_overrides_the_configured_wisp_dir(fake_home, tmp_path):
    other = tmp_path / "other"
    other.mkdir()
    (other / "agente.md").write_text("só {{PERSONA_NAME}}")
    assert render(_cfg(fake_home), Soul(), other).startswith("só Ada")


def test_the_soul_block_decodes_tolerantly(fake_home):
    assert load_soul(fake_home / "none.json") == Soul()
    assert load_soul(_profile(fake_home, {"source": "both", "tone": "formal", "emojis": True, "extra": "x"})) == Soul("both", "formal", True, "x")
    assert load_soul(_profile(fake_home, {"source": "nope", "tone": 3, "emojis": "yes", "extra": None})) == Soul()
    assert load_soul(_profile(fake_home, "garbage")) == Soul()
    (fake_home / ".config/wisp/profile.json").write_text("{ not json")
    assert load_soul() == Soul()


def test_source_defaults_to_the_users_assistant_only_when_the_harness_is_managed_elsewhere():
    assert effective_source(Soul(), managed_elsewhere=True) == "assistant"
    assert effective_source(Soul(), managed_elsewhere=False) == "wisp"
    assert effective_source(Soul("both"), managed_elsewhere=True) == "both"


@pytest.mark.parametrize("source,engine,expected", [
    ("assistant", "claude", False), ("assistant", "codex", False), ("assistant", "local", True),
    ("wisp", "claude", True), ("both", "codex", True), ("wisp", "local", True),
])
def test_the_source_gates_the_injection(source, engine, expected):
    assert injects(source, engine) is expected


def test_for_engine_gates_by_the_profile_and_detects_a_managed_claude_dir(fake_home):
    paths, cfg = _paths(fake_home), _cfg(fake_home)
    assert for_engine(cfg, paths, "claude")[0] == "wisp" and "# Ada" in for_engine(cfg, paths, "claude")[1]
    _profile(fake_home, {"source": "assistant"})
    assert for_engine(cfg, paths, "claude") == ("assistant", "")
    assert for_engine(cfg, paths, "codex") == ("assistant", "")
    assert "# Ada" in for_engine(cfg, paths, "local")[1]
    _profile(fake_home, {"source": "both"})
    assert for_engine(cfg, paths, "codex")[0] == "both"


def test_a_symlinked_claude_dir_makes_assistant_the_default(fake_home, tmp_path):
    target = tmp_path / "elsewhere"
    target.mkdir()
    (fake_home / ".claude").symlink_to(target)
    assert for_engine(_cfg(fake_home), _paths(fake_home), "claude") == ("assistant", "")


def test_the_cli_prints_the_text_and_the_json(fake_home, capsys):
    save_config(_cfg(fake_home), fake_home / ".config/wisp/wisp.json")
    _profile(fake_home, {"source": "both", "tone": "caloroso", "emojis": True})
    assert main(["soul", "render"]) == 0
    plain = capsys.readouterr().out
    assert "# Ada" in plain and TONE_TEXT["caloroso"] in plain
    assert main(["soul", "render", "--engine", "codex", "--json"]) == 0
    data = json.loads(capsys.readouterr().out)
    assert data["source"] == "both" and data["text"].strip() == plain.strip()
    _profile(fake_home, {"source": "assistant"})
    assert main(["soul", "render", "--engine", "claude", "--json"]) == 0
    assert json.loads(capsys.readouterr().out) == {"source": "assistant", "text": ""}


def test_harness_sync_installs_no_persona_block_when_the_soul_is_injected(fake_home):
    _profile(fake_home, {"source": "wisp"})
    report = setup_harness(FakeRunner(), _paths(fake_home), _cfg(fake_home), dry_run=False)
    claude = fake_home / ".claude"
    assert report.status == "done"
    assert not (claude / "CLAUDE.md").exists()
    assert (claude / "settings.json").is_file() and (claude / "agents/operator.md").is_file()


def _install_block(home, source="assistant"):
    _profile(home, {"source": source})
    setup_harness(FakeRunner(), _paths(home), _cfg(home), dry_run=False)
    return home / ".claude/CLAUDE.md"


def _alma(report):
    return [d.output for d in report.details if d.command == "alma"]


def test_harness_sync_removes_an_unmodified_block_after_a_backup(fake_home):
    md = _install_block(fake_home)
    md.write_text("minhas regras\n\n" + md.read_text())
    installed = md.read_text()
    assert BEGIN in installed
    _profile(fake_home, {"source": "both"})
    report = setup_harness(FakeRunner(), _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert md.read_text() == "minhas regras\n"
    backup = report.data["backup"]
    assert backup and (fake_home / ".local/state/wisp/backups") in __import__("pathlib").Path(backup).parents
    assert (__import__("pathlib").Path(backup) / "CLAUDE.md").read_text() == installed
    assert any(line.startswith("alma: bloco antigo removido (backup em ") and backup in line for line in _alma(report))
    assert "CLAUDE.md#block" not in json.loads((fake_home / ".config/wisp/harness-installed.json").read_text())["files"]
    again = setup_harness(FakeRunner(), _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert md.read_text() == "minhas regras\n" and not any("removido" in line for line in _alma(again))


def test_a_dry_run_reports_the_removal_without_touching_the_file(fake_home):
    md = _install_block(fake_home)
    before = md.read_text()
    _profile(fake_home, {"source": "wisp"})
    report = setup_harness(FakeRunner(), _paths(fake_home), _cfg(fake_home), dry_run=True)
    assert md.read_text() == before and "alma: bloco antigo seria removido" in _alma(report)


def test_a_modified_block_is_kept_and_the_agente_part_is_not_injected_twice(fake_home):
    md = _install_block(fake_home)
    md.write_text(md.read_text().replace("Terse and warm", "Sempre seca"))
    edited = md.read_text()
    _profile(fake_home, {"source": "both", "extra": "cite a fonte"})
    report = setup_harness(FakeRunner(), _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert md.read_text() == edited
    assert "alma: bloco editado mantido" in _alma(report)
    assert not any("não recebem mais a persona" in line for line in _alma(report))
    source, text = for_engine(_cfg(fake_home), _paths(fake_home), "claude")
    assert source == "both" and "# Ada" not in text
    assert text.startswith("## Tom") and "## Regras extras\ncite a fonte" in text
    assert "# Ada" in for_engine(_cfg(fake_home), _paths(fake_home), "local")[1]


def test_an_unretired_block_also_keeps_the_agente_part_out_until_sync(fake_home):
    _install_block(fake_home)
    _profile(fake_home, {"source": "wisp"})
    assert "# Ada" not in for_engine(_cfg(fake_home), _paths(fake_home), "claude")[1]


def test_a_block_without_a_recorded_digest_counts_as_modified(fake_home):
    md = _install_block(fake_home)
    (fake_home / ".config/wisp/harness-installed.json").unlink()
    _profile(fake_home, {"source": "wisp"})
    report = setup_harness(FakeRunner(), _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert BEGIN in md.read_text() and "alma: bloco editado mantido" in _alma(report)


def test_the_default_without_any_profile_installs_no_block_and_says_the_terminal_loses_the_persona(fake_home):
    assert not (fake_home / ".config/wisp/profile.json").exists()
    report = setup_harness(FakeRunner(), _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert not (fake_home / ".claude/CLAUDE.md").exists()
    assert (fake_home / ".claude/settings.json").is_file()
    notes = [line for line in _alma(report) if "não recebem mais a persona" in line]
    assert len(notes) == 1 and "claude" in notes[0] and "codex" in notes[0] and "terminal" in notes[0]


def test_source_both_does_not_claim_the_terminal_loses_the_persona(fake_home):
    _profile(fake_home, {"source": "both"})
    report = setup_harness(FakeRunner(), _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert not any("não recebem mais a persona" in line for line in _alma(report))


def test_harness_sync_installs_the_block_for_source_assistant(fake_home):
    _profile(fake_home, {"source": "assistant"})
    setup_harness(FakeRunner(), _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert "# Ada" in (fake_home / ".claude/CLAUDE.md").read_text()


def _codex_block(fake_home, source="assistant"):
    home = fake_home / ".codex"
    home.mkdir(exist_ok=True)
    _profile(fake_home, {"source": source})
    sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    return home / "AGENTS.md"


def test_codex_sync_writes_no_agents_block_when_the_soul_is_injected_but_keeps_the_config(fake_home):
    home = fake_home / ".codex"
    home.mkdir()
    _profile(fake_home, {"source": "both"})
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert not (home / "AGENTS.md").exists()
    assert "mcp_servers.wisp-email" in (home / "config.toml").read_text()
    assert result.state != "failed"


def test_codex_sync_removes_an_unmodified_block_after_a_backup(fake_home):
    agents = _codex_block(fake_home)
    agents.write_text("minhas regras do codex\n\n" + agents.read_text())
    installed = agents.read_text()
    assert BEGIN in installed
    _profile(fake_home, {"source": "wisp"})
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert agents.read_text() == "minhas regras do codex\n"
    line = next(d.output for d in result.details if d.command == "alma")
    assert line.startswith("alma: bloco antigo removido (backup em ")
    saved = __import__("pathlib").Path(line.split("backup em ")[1].rstrip(")"))
    assert (saved / "AGENTS.md").read_text() == installed
    assert "codex/AGENTS.md#block" not in json.loads((fake_home / ".config/wisp/harness-installed.json").read_text())["files"]
    assert "mcp_servers.wisp-email" in (fake_home / ".codex/config.toml").read_text()


def test_codex_sync_keeps_a_modified_block_and_skips_the_agente_part(fake_home):
    agents = _codex_block(fake_home)
    agents.write_text(agents.read_text().replace("Terse and warm", "Sempre seca"))
    edited = agents.read_text()
    _profile(fake_home, {"source": "both"})
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert agents.read_text() == edited
    assert [d.output for d in result.details if d.command == "alma"] == ["alma: bloco editado mantido"]
    _, text = for_engine(_cfg(fake_home), _paths(fake_home), "codex")
    assert "# Ada" not in text and text.startswith("## Tom")
    assert "# Ada" in for_engine(_cfg(fake_home), _paths(fake_home), "claude")[1]


def test_codex_dry_run_reports_the_removal_without_touching_the_file(fake_home):
    agents = _codex_block(fake_home)
    before = agents.read_text()
    _profile(fake_home, {"source": "wisp"})
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=True)
    assert agents.read_text() == before
    assert "alma: bloco antigo seria removido" in [d.output for d in result.details]
