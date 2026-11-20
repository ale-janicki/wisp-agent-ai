import json
import tomllib

from wisp.cli import main
from wisp.config import WispConfig, save_config
from wisp.doctor import run_doctor
from wisp.engines import read_active, write_active
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult
from wisp.setup.codex import render_agents_block, render_config_block, sync_codex

CONTRACT = __import__("pathlib").Path(__file__).parent / "fixtures/contract"


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _cfg(home):
    brain = home / "Wisp/brain"
    brain.mkdir(parents=True, exist_ok=True)
    return WispConfig(user_name="Rita", persona="Ada", brain=str(brain))


def _codex(home):
    (home / ".codex").mkdir(exist_ok=True)
    return home / ".codex"


def test_rendered_blocks_match_the_contract_fixtures():
    cfg = WispConfig(user_name="Rita", persona="Ada", brain="/srv/wisp/brain", wisp_dir="/srv/wisp")
    assert render_agents_block(cfg)[0] == (CONTRACT / "codex-agents-block.md").read_text()
    assert render_config_block("/opt/wisp/venv/bin/wisp") == (CONTRACT / "codex-config-block.toml").read_text()


def test_config_block_is_valid_toml_with_the_email_server_and_a_long_tool_timeout():
    table = tomllib.loads(render_config_block("/Users/ana maría/venv/bin/wisp"))["mcp_servers"]["wisp-email"]
    assert table["command"] == "/Users/ana maría/venv/bin/wisp" and table["args"] == ["mcp", "email"]
    assert table["tool_timeout_sec"] > 600 and table["default_tools_approval_mode"] == "approve"


def test_nothing_is_written_without_codex_or_the_codex_engine(fake_home):
    assert sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False).state == "skipped"
    assert not (fake_home / ".codex").exists()


def test_existing_codex_home_gets_both_blocks_and_user_text_survives(fake_home):
    home = _codex(fake_home)
    (home / "AGENTS.md").write_text("my rules\n")
    (home / "config.toml").write_text('model = "gpt-x"\n\n[projects."/a"]\ntrust_level = "trusted"\n')
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert result.state == "updated"
    agents = (home / "AGENTS.md").read_text()
    assert agents.startswith("my rules\n") and "# Ada" in agents and "Running under Codex" in agents
    config = tomllib.loads((home / "config.toml").read_text())
    assert config["model"] == "gpt-x" and config["projects"]["/a"]["trust_level"] == "trusted"
    assert config["mcp_servers"]["wisp-email"]["args"] == ["mcp", "email"]


def test_second_sync_changes_nothing(fake_home):
    home = _codex(fake_home)
    sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    before = {p.name: p.read_bytes() for p in home.iterdir()}
    assert sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False).state == "unchanged"
    assert {p.name: p.read_bytes() for p in home.iterdir()} == before


def test_user_edit_inside_the_block_is_kept_and_reported(fake_home):
    home = _codex(fake_home)
    sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    edited = (home / "AGENTS.md").read_text().replace("# Ada", "# Mine")
    (home / "AGENTS.md").write_text(edited)
    cfg = _cfg(fake_home)
    cfg.persona = "Bea"
    result = sync_codex(_paths(fake_home), cfg, dry_run=False)
    assert (home / "AGENTS.md").read_text() == edited
    assert any(d.command == "conflito" for d in result.details)


def test_persona_change_rewrites_an_untouched_block(fake_home):
    home = _codex(fake_home)
    sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    cfg = _cfg(fake_home)
    cfg.persona = "Bea"
    assert sync_codex(_paths(fake_home), cfg, dry_run=False).state == "updated"
    assert "# Bea" in (home / "AGENTS.md").read_text()


def test_a_server_the_user_defined_with_our_name_is_left_alone(fake_home):
    home = _codex(fake_home)
    mine = '[mcp_servers.wisp-email]\ncommand = "other"\n'
    (home / "config.toml").write_text(mine)
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert (home / "config.toml").read_text() == mine
    assert any(d.command == "e-mail" for d in result.details)


def test_broken_markers_stop_the_sync_without_writing(fake_home):
    home = _codex(fake_home)
    (home / "AGENTS.md").write_text("<!-- wisp:begin -->\nhalf\n")
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert result.state == "failed" and (home / "AGENTS.md").read_text() == "<!-- wisp:begin -->\nhalf\n"
    assert not (home / "config.toml").exists()


def test_symlinked_codex_file_is_refused(fake_home):
    home = _codex(fake_home)
    (fake_home / "elsewhere.md").write_text("x")
    (home / "AGENTS.md").symlink_to(fake_home / "elsewhere.md")
    assert sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False).state == "failed"
    assert (fake_home / "elsewhere.md").read_text() == "x"


def test_dry_run_writes_nothing(fake_home):
    home = _codex(fake_home)
    assert sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=True).state == "updated"
    assert list(home.iterdir()) == []


def test_modelos_toml_active_engine_round_trip_keeps_the_rest(fake_home):
    folder = fake_home / "Wisp"
    folder.mkdir()
    (folder / "modelos.toml").write_text('# note\nativo = "claude"  # which\n\n[local]\nativo = "x"\n')
    assert read_active(folder) == "claude"
    write_active(folder, "codex")
    assert read_active(folder) == "codex"
    assert (folder / "modelos.toml").read_text() == '# note\nativo = "codex"  # which\n\n[local]\nativo = "x"\n'


def test_active_engine_defaults_to_claude_when_missing_or_broken(fake_home):
    assert read_active(fake_home / "nowhere") == "claude"
    (fake_home / "Wisp").mkdir()
    (fake_home / "Wisp/modelos.toml").write_text("ativo = [")
    assert read_active(fake_home / "Wisp") == "claude"


def test_config_set_engine_writes_modelos_and_renders_codex(fake_home, capsys):
    save_config(_cfg(fake_home))
    assert main(["config", "set", "engine", "codex", "--json"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["status"] == "done" and report["data"]["engine"] == "codex"
    assert read_active(fake_home / "Wisp") == "codex"
    assert "wisp-email" in (fake_home / ".codex/config.toml").read_text()


def test_config_set_engine_refuses_an_unknown_engine(fake_home, capsys):
    save_config(_cfg(fake_home))
    assert main(["config", "set", "engine", "gpt", "--json"]) == 1
    assert json.loads(capsys.readouterr().out)["status"] == "failed"


def test_doctor_codex_checks_only_run_when_asked(fake_home):
    runner = FakeRunner({("/opt/homebrew/bin/codex", "--version"): RunResult([], 0, "codex 1", ""),
                         ("/opt/homebrew/bin/codex", "login", "status"): RunResult([], 1, "", "Not logged in")})
    paths, cfg = _paths(fake_home), WispConfig()
    assert "codex" not in {c.id for c in run_doctor(runner, paths, cfg)}
    checks = {c.id: c for c in run_doctor(runner, paths, cfg, {"codex", "codex_login"})}
    assert checks["codex"].ok is True and checks["codex_login"].ok is False


import pytest


@pytest.mark.parametrize("text", [
    '[mcp_servers.wisp-email]\ncommand = "other"\n',
    '[mcp_servers."wisp-email"]\ncommand = "other"\n',
    "[mcp_servers.'wisp-email']\ncommand = \"other\"\n",
    '[mcp_servers]\nwisp-email = { command = "other" }\n',
    'mcp_servers.wisp-email.command = "other"\n',
    'mcp_servers = { wisp-email = { command = "other" }, x = { command = "y" } }\n',
    '[mcp_servers]\n"wisp-email".command = "other"\n',
    '[ mcp_servers . wisp-email ]\ncommand = "other"\n',
])
def test_a_user_owned_server_is_found_in_every_toml_form(fake_home, text):
    home = _codex(fake_home)
    (home / "config.toml").write_text(text)
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert (home / "config.toml").read_text() == text
    assert any(d.command == "e-mail" for d in result.details)


def test_a_config_that_would_not_parse_after_the_merge_is_refused_untouched(fake_home):
    home = _codex(fake_home)
    text = 'mcp_servers = { other = { command = "x" } }\n'
    (home / "config.toml").write_text(text)
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert result.state == "failed" and (home / "config.toml").read_text() == text
    assert not (home / "AGENTS.md").exists()


def test_a_config_that_is_not_toml_is_refused_untouched(fake_home):
    home = _codex(fake_home)
    (home / "config.toml").write_text("model = [\n")
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert result.state == "failed" and (home / "config.toml").read_text() == "model = [\n"
    assert not (home / "AGENTS.md").exists()


def test_the_merged_config_always_parses_with_the_server_defined_once(fake_home):
    home = _codex(fake_home)
    (home / "config.toml").write_text('[mcp_servers.other]\ncommand = "x"\n')
    sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    servers = tomllib.loads((home / "config.toml").read_text())["mcp_servers"]
    assert set(servers) == {"other", "wisp-email"}
