import pytest
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


def test_config_block_has_no_gate_switch_and_forwards_the_socket_the_host_sets():
    table = tomllib.loads(render_config_block("/opt/wisp/venv/bin/wisp"))["mcp_servers"]["wisp-email"]
    assert "env" not in table
    assert "WISP_APPROVAL_SOCKET" in table["env_vars"] and "WISP_TELEGRAM_THREAD" in table["env_vars"]
    assert table["tool_timeout_sec"] > 620


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


def _block_text(**swap):
    text = render_config_block("/opt/wisp/venv/bin/wisp")
    for old, new in swap.items():
        text = text.replace(old, new)
    return text


def test_a_fresh_block_passes_the_send_gate_check():
    from wisp.setup.codex import gate_problem_in
    assert gate_problem_in(render_config_block("/opt/wisp/venv/bin/wisp")) is None


@pytest.mark.parametrize("text", [
    None,
    "model = 'x'\n",
    "not toml [",
    '[mcp_servers.wisp-email]\ncommand = "wisp"\nargs = ["mcp", "email"]\nenv_vars = ["WISP_TELEGRAM_THREAD"]\n',
    '[mcp_servers.wisp-email]\ncommand = "wisp"\nenv = { WISP_SEND_GATE = "broker" }\n',
    '[mcp_servers.wisp-email]\ncommand = "wisp"\nenv = { WISP_SEND_GATE = "broker" }\nenv_vars = ["WISP_TELEGRAM_THREAD"]\n',
    'mcp_servers = { other = { command = "x" } }\n',
])
def test_a_missing_old_or_hand_kept_block_fails_the_send_gate_check(text):
    from wisp.setup.codex import gate_problem_in
    assert "wisp harness sync" in gate_problem_in(text)


def test_a_hand_kept_block_with_the_gate_passes_even_with_table_style_env_vars():
    from wisp.setup.codex import gate_problem_in
    text = '[mcp_servers.wisp-email]\ncommand = "wisp"\nenv_vars = [{ name = "WISP_APPROVAL_SOCKET" }]\n'
    assert gate_problem_in(text) is None


def test_sync_reports_a_stale_foreign_block_and_leaves_it(fake_home):
    home = _codex(fake_home)
    (home / "config.toml").write_text('[mcp_servers.wisp-email]\ncommand = "other"\n')
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert result.state == "failed"
    assert any("wisp harness sync" in d.output for d in result.details)
    assert (home / "config.toml").read_text() == '[mcp_servers.wisp-email]\ncommand = "other"\n'


def test_sync_reports_a_stale_block_the_user_edited(fake_home):
    home = _codex(fake_home)
    sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    edited = (home / "config.toml").read_text().replace('env_vars = ["WISP_TELEGRAM_THREAD", "WISP_APPROVAL_SOCKET"]\n', 'env_vars = ["WISP_TELEGRAM_THREAD"]\n')
    (home / "config.toml").write_text(edited)
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert result.state == "failed" and any("trava" in d.output for d in result.details)
    assert (home / "config.toml").read_text() == edited


def test_a_synced_home_is_clean_and_the_check_command_agrees(fake_home, capsys, monkeypatch):
    home = _codex(fake_home)
    monkeypatch.setenv("CODEX_HOME", str(home))
    assert main(["codex", "check"]) == 1
    assert json.loads(capsys.readouterr().out)["ready"] is False
    result = sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert result.state == "updated" and not any("trava" in d.output for d in result.details)
    assert main(["codex", "check"]) == 0
    assert json.loads(capsys.readouterr().out) == {"ready": True, "problem": None, "project": None}


def test_overrides_match_the_contract_and_describe_the_same_server_as_the_block():
    contract = json.loads((CONTRACT / "codex-mcp-overrides.json").read_text())
    from wisp.setup.codex import mcp_overrides
    overrides = mcp_overrides(contract["wisp_bin"])
    assert overrides == contract["overrides"]
    built = {}
    for line in overrides:
        key, raw = line.split("=", 1)
        built[key.rsplit(".", 1)[1]] = tomllib.loads(f"_x_ = {raw}")["_x_"]
    rendered = tomllib.loads(render_config_block(contract["wisp_bin"]))["mcp_servers"]["wisp-email"]
    assert built == {**rendered, "enabled": True}
    assert "env" not in built and "WISP_APPROVAL_SOCKET" in built["env_vars"]
    assert built["tool_timeout_sec"] > 620 and built["default_tools_approval_mode"] == "approve"


def _project(tmp_path, home):
    root = home / "work" / "proj"
    (root / "sub").mkdir(parents=True)
    return root, root / "sub"


@pytest.mark.parametrize("body", [
    '[mcp_servers.wisp-email]\ncommand = "x"\n',
    'mcp_servers.wisp-email.command = "x"\n',
    'mcp_servers = { wisp-email = { command = "x" } }\n',
    '[mcp_servers."wisp-email"]\nurl = "http://x"\n',
    "not = toml [",
])
def test_a_project_config_that_defines_the_email_server_or_does_not_parse_blocks_codex_and_names_the_file(fake_home, tmp_path, body):
    from wisp.setup.codex import project_config_problem
    root, sub = _project(tmp_path, fake_home)
    (root / ".codex").mkdir()
    (root / ".codex/config.toml").write_text(body)
    problem = project_config_problem(sub, fake_home)
    assert problem and str(root / ".codex/config.toml") in problem
    assert project_config_problem(sub, fake_home) == project_config_problem(root, fake_home)


def test_unrelated_project_config_and_the_homes_own_codex_folder_do_not_block(fake_home):
    from wisp.setup.codex import project_config_problem
    root = fake_home / "work" / "proj"
    root.mkdir(parents=True)
    assert project_config_problem(root, fake_home) is None
    (root / ".codex").mkdir()
    (root / ".codex/config.toml").write_text('model = "x"\n[mcp_servers.other]\ncommand = "y"\n')
    assert project_config_problem(root, fake_home) is None
    (fake_home / ".codex").mkdir(exist_ok=True)
    (fake_home / ".codex/config.toml").write_text('[mcp_servers.wisp-email]\ncommand = "x"\n')
    assert project_config_problem(root, fake_home) is None


def test_the_parent_of_the_workspace_counts_but_home_and_above_do_not(fake_home):
    from wisp.setup.codex import project_config_problem
    work = fake_home / "work"
    leaf = work / "a" / "b"
    leaf.mkdir(parents=True)
    (work / ".codex").mkdir()
    (work / ".codex/config.toml").write_text('[mcp_servers.wisp-email]\ncommand = "x"\n')
    assert str(work / ".codex/config.toml") in project_config_problem(leaf, fake_home)
    (work / ".codex/config.toml").unlink()
    (fake_home.parent / ".codex").mkdir(exist_ok=True)
    (fake_home.parent / ".codex/config.toml").write_text('[mcp_servers.wisp-email]\ncommand = "x"\n')
    assert project_config_problem(leaf, fake_home) is None


def test_the_check_command_reports_the_project_file_when_asked(fake_home, capsys, monkeypatch):
    root = fake_home / "w"
    (root / ".codex").mkdir(parents=True)
    (root / ".codex/config.toml").write_text('[mcp_servers.wisp-email]\ncommand = "x"\n')
    monkeypatch.setenv("CODEX_HOME", str(_codex(fake_home)))
    sync_codex(_paths(fake_home), _cfg(fake_home), dry_run=False)
    assert main(["codex", "check", "--workspace", str(root)]) == 1
    out = json.loads(capsys.readouterr().out)
    assert out["ready"] is False and out["problem"] is None and str(root / ".codex/config.toml") in out["project"]
    (root / ".codex/config.toml").unlink()
    assert main(["codex", "check", "--workspace", str(root)]) == 0
