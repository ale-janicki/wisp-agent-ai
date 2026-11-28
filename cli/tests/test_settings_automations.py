import json
import os
import stat
import sys
from dataclasses import replace

import pytest

from wisp.jobs.taskscheduler import RUNNING, TaskSchedulerJobs
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult
from wisp.serve.features.settings import automations, store

WINDOWS = sys.platform == "win32"


def ok(out="", exit=0):
    return RunResult([], exit, out, "")


def csv_row(label, status="Ready", last="0"):
    cols = ["PC", f"\\{label}", "N/A", status, "x", "x", last, "a", "c", "N/A", "N/A", "Enabled"]
    return ",".join(f'"{c}"' for c in cols) + "\n"


@pytest.fixture
def env(fake_home, monkeypatch):
    monkeypatch.setenv("WISP_DATA_DIR", str(fake_home / "data"))
    config = WispPaths.current().config
    config.mkdir(parents=True, exist_ok=True)
    return fake_home, config


def profile(config, **blocks):
    (config / "profile.json").write_text(json.dumps({"persona": {"name": "A", "language": "pt-BR"}, "agent": {"cwd": "~"}, "blocks": blocks}))


def schtasks(monkeypatch, home, script):
    runner = FakeRunner(script)
    windows = WispPaths.for_os("Windows", home, {"APPDATA": str(home / "AppData/Roaming"), "LOCALAPPDATA": str(home / "AppData/Local")})
    manager = TaskSchedulerJobs(replace(windows, state=home / "state"), runner, user="PC\\a")
    monkeypatch.setattr(automations, "task_manager", lambda: manager)
    return runner


def test_routines_unavailable_without_registry_or_prefixes(env):
    _, config = env
    profile(config)
    assert automations.routines() == {"available": False, "rows": [], "running": 0}


def test_routines_discovered_by_prefix_and_merged_with_the_registry(env, monkeypatch):
    home, config = env
    registry = home / "routines.json"
    registry.write_text(json.dumps({"jobs": [
        {"label": "ai.wisp.bot", "name": "Bot", "description": "Telegram", "plist": "x", "logs": [str(home / "bot.log")]},
        {"label": "ai.wisp.gone", "name": "Gone", "plist": "x"},
    ]}))
    profile(config, routines={"registry": str(registry), "prefixes": ["ai.wisp."], "status": "x"})
    runner = schtasks(monkeypatch, home, {
        ("schtasks.exe", "/Query", "/FO"): ok(csv_row("ai.wisp.bot", "Running", str(RUNNING)) + csv_row("ai.wisp.news", "Ready", "1") + csv_row("Other.task")),
        ("schtasks.exe", "/Query", "/TN"): ok("<Task xmlns='http://schemas.microsoft.com/windows/2004/02/mit/task'><Triggers><LogonTrigger/></Triggers><Settings><RestartOnFailure/></Settings></Task>"),
    })
    data = automations.routines()
    assert [(r["label"], r["name"], r["state"], r["installed"]) for r in data["rows"]] == [
        ("ai.wisp.bot", "Bot", "running", True), ("ai.wisp.gone", "Gone", "missing", False), ("ai.wisp.news", "news", "failed", True)]
    assert data["running"] == 1
    bot, gone, news = data["rows"]
    assert bot["description"] == "Telegram" and bot["logs"] == [str(home / "bot.log")] and bot["always_on"]
    assert gone["summary"] == "tarefa não instalada"
    assert news["summary"] == "aguardando · saída 1"
    assert runner.calls[0] == ["schtasks.exe", "/Query", "/FO", "CSV", "/V", "/NH"]


def test_routines_with_a_broken_registry_say_so(env):
    home, config = env
    (home / "r.json").write_text("{not json")
    profile(config, routines={"registry": str(home / "r.json")})
    assert automations.routines()["error"] == 'Não consegui ler as rotinas: o registro de rotinas não está no formato {"jobs": [...]}'
    profile(config, routines={"registry": str(home / "missing.json")})
    assert automations.routines()["error"].startswith("Não consegui ler as rotinas: não consegui ler")


def test_toggle_turns_a_routine_off_and_on_with_schtasks(env, monkeypatch):
    home, config = env
    profile(config, routines={"prefixes": ["ai.wisp."]})
    runner = schtasks(monkeypatch, home, {
        ("schtasks.exe", "/Query", "/FO"): ok(csv_row("ai.wisp.bot")),
        ("schtasks.exe", "/Query", "/TN"): ok("<Task xmlns='http://schemas.microsoft.com/windows/2004/02/mit/task'><Triggers><LogonTrigger/></Triggers><Settings><RestartOnFailure/></Settings></Task>"),
        ("schtasks.exe", "/End"): ok(exit=1),
        ("schtasks.exe", "/Change"): ok(),
        ("schtasks.exe", "/Run"): ok(),
    })
    assert automations.toggle_routine("ai.wisp.bot", False) == {"ok": True}
    assert ["schtasks.exe", "/Change", "/TN", "ai.wisp.bot", "/DISABLE"] in runner.calls
    runner.calls.clear()
    assert automations.toggle_routine("ai.wisp.bot", True) == {"ok": True}
    assert runner.calls[-2:] == [["schtasks.exe", "/Change", "/TN", "ai.wisp.bot", "/ENABLE"], ["schtasks.exe", "/Run", "/TN", "ai.wisp.bot"]]


def test_toggle_refuses_a_label_that_is_not_one_of_the_listed_routines(env, monkeypatch):
    home, config = env
    profile(config, routines={"prefixes": ["ai.wisp."]})
    runner = schtasks(monkeypatch, home, {("schtasks.exe", "/Query", "/FO"): ok(csv_row("ai.wisp.bot"))})
    assert automations.toggle_routine("Microsoft\\Windows\\Defrag", False)["ok"] is False
    assert not any(c[1] == "/Change" for c in runner.calls)


def test_toggle_failure_names_the_routine(env, monkeypatch):
    home, config = env
    profile(config, routines={"prefixes": ["ai.wisp."]})
    schtasks(monkeypatch, home, {("schtasks.exe", "/Query", "/FO"): ok(csv_row("ai.wisp.bot")), ("schtasks.exe", "/Change"): RunResult([], 1, "", "Acesso negado")})
    assert automations.toggle_routine("ai.wisp.bot", False) == {"ok": False, "error": "Não consegui desligar bot: Acesso negado"}


def test_log_tails_only_a_log_the_routine_owns(env, monkeypatch):
    home, config = env
    log = home / "bot.log"
    log.write_text("\n".join(f"line {n}" for n in range(80)) + "\n")
    registry = home / "r.json"
    registry.write_text(json.dumps({"jobs": [{"label": "ai.wisp.bot", "plist": "x", "logs": [str(log), str(home / "err.log")]}]}))
    profile(config, routines={"registry": str(registry)})
    schtasks(monkeypatch, home, {("schtasks.exe", "/Query", "/FO"): ok(csv_row("ai.wisp.bot")), ("schtasks.exe", "/Query", "/TN"): ok(exit=1)})
    answer = automations.routine_log("ai.wisp.bot", 0)
    assert answer["ok"] and answer["lines"][0] == "line 30" and answer["lines"][-1] == "line 79" and len(answer["lines"]) == 50
    missing = automations.routine_log("ai.wisp.bot", 1)
    assert missing["ok"] is False and missing["error"] == f"Este log ainda não existe: {home / 'err.log'}"
    assert automations.routine_log("other", 0)["ok"] is False


def test_log_skips_the_cut_first_line_of_a_big_file(env, monkeypatch):
    home, config = env
    log = home / "big.log"
    log.write_text(("x" * 99 + "\n") * 2000)
    registry = home / "r.json"
    registry.write_text(json.dumps({"jobs": [{"label": "ai.wisp.bot", "plist": "x", "logs": [str(log)]}]}))
    profile(config, routines={"registry": str(registry)})
    schtasks(monkeypatch, home, {("schtasks.exe", "/Query", "/FO"): ok(csv_row("ai.wisp.bot")), ("schtasks.exe", "/Query", "/TN"): ok(exit=1)})
    assert all(len(line) == 99 for line in automations.routine_log("ai.wisp.bot", 0)["lines"])


HOOKS = {"hooks": [
    {"id": "b", "event": "PreToolUse", "command": "guard", "script": "guard.py", "summary": "bloqueia", "matcher": "Bash", "locked": True},
    {"id": "a", "event": "SessionStart", "command": "line one\nline two " + "x" * 80, "enabled": False},
    {"id": "c", "event": "Custom", "command": "c"},
], "orphans": []}


def test_hooks_are_grouped_by_moment_with_titles_and_locks(env, monkeypatch):
    _, config = env
    profile(config, hooks={"list": "wisp hooks list", "disable": "wisp hooks off {id}"})
    runner = FakeRunner({("cmd.exe", "/d", "/s", "/c", "wisp hooks list") if automations.WINDOWS else ("/bin/sh", "-c", "wisp hooks list"): ok(json.dumps(HOOKS))})
    monkeypatch.setattr(automations, "runner", lambda: runner)
    data = automations.hooks()
    assert [g["title"] for g in data["groups"]] == ["Início da sessão", "Antes de cada ferramenta", "Custom"]
    first = data["groups"][0]["hooks"][0]
    assert first["title"].endswith("…") and len(first["title"]) == 60 and first["enabled"] is False
    guard = data["groups"][1]["hooks"][0]
    assert guard["title"] == "guard.py" and guard["detail"] == "bloqueia · Bash" and guard["locked"]
    assert (data["count"], data["locked"], data["can_disable"], data["can_enable"]) == (3, 1, True, False)


def test_hooks_unavailable_without_a_list_command(env):
    _, config = env
    profile(config)
    assert automations.hooks()["available"] is False


def test_hooks_bad_json_and_failing_command_are_reported(env, monkeypatch):
    _, config = env
    profile(config, hooks={"list": "L"})
    key = ("cmd.exe", "/d", "/s", "/c", "L") if automations.WINDOWS else ("/bin/sh", "-c", "L")
    monkeypatch.setattr(automations, "runner", lambda: FakeRunner({key: ok("nope")}))
    assert automations.hooks()["error"].startswith("Não consegui ler os hooks")
    monkeypatch.setattr(automations, "runner", lambda: FakeRunner({key: RunResult([], 2, "", "boom")}))
    assert automations.hooks()["error"] == "Não consegui listar os hooks: boom"


def test_toggle_hook_quotes_the_id_and_refuses_locked_or_unknown(env, monkeypatch):
    _, config = env
    profile(config, hooks={"list": "L", "disable": "off {id}", "enable": "on {id}"})
    prefix = ("cmd.exe", "/d", "/s", "/c") if automations.WINDOWS else ("/bin/sh", "-c")
    quoted = '"a"' if automations.WINDOWS else "'a'"
    runner = FakeRunner({(*prefix, "L"): ok(json.dumps(HOOKS)), (*prefix, f"on {quoted}"): ok()})
    monkeypatch.setattr(automations, "runner", lambda: runner)
    assert automations.toggle_hook("a", True) == {"ok": True}
    assert [*prefix, f"on {quoted}"] in runner.calls
    assert automations.toggle_hook("b", False)["ok"] is False
    assert automations.toggle_hook("zzz; rm -rf", False)["ok"] is False
    assert not any("rm -rf" in " ".join(c) for c in runner.calls)


def test_first_comment_reads_hash_rem_and_colon_styles():
    assert automations.first_comment("#!/bin/sh\n\n# Faz isso\nexec x\n") == "Faz isso"
    assert automations.first_comment("@echo off\nrem x") is None
    assert automations.first_comment("REM Limpa tudo\n@echo off") == "Limpa tudo"
    assert automations.first_comment(":: Outro\n") == "Outro"
    assert automations.first_comment("echo hi\n# late") is None
    assert automations.first_comment("#\n#  \n## real\n") == "real"


def test_commands_lists_executables_with_their_first_comment(env):
    home, config = env
    folder = home / "cmds"
    folder.mkdir()
    runnable = folder / ("go.cmd" if automations.WINDOWS else "go")
    runnable.write_text("#!/bin/sh\n# Roda o fluxo\n")
    (folder / ".hidden").write_text("x")
    (folder / "sub").mkdir()
    (folder / "data.txt").write_text("not executable")
    if not automations.WINDOWS:
        runnable.chmod(runnable.stat().st_mode | stat.S_IXUSR)
    profile(config, commands={"dirs": [str(folder), str(home / "none")]})
    data = automations.commands()
    assert data["available"] and data["entries"] == [{"name": runnable.name, "detail": "Roda o fluxo", "path": str(runnable)}]


def test_mcp_claude_precedence_disabled_and_secrets_never_leave(env):
    home, _ = env
    project = home / "proj"
    project.mkdir()
    (project / ".mcp.json").write_text(json.dumps({"mcpServers": {"p": {"command": "node", "env": {"TOKEN": "s3cret"}}, "dup": {"url": "https://a.example/mcp"}}}))
    (home / ".claude.json").write_text(json.dumps({
        "mcpServers": {"u": {"type": "sse", "url": "https://h.example/sse", "headers": {"Authorization": "s3cret"}}, "dup": {"command": "x"},
                       "wisp-brain": {"command": "C:\\bin\\wisp.exe", "args": ["mcp", "brain"]}, "off": {"command": "y", "disabled": True}},
        "projects": {str(project): {"disabledMcpServers": ["u"], "mcpServers": {"proj-own": {"command": "py"}}}},
    }))
    servers = automations.mcp_claude(str(home), str(project))
    by = {s["name"]: s for s in servers}
    assert by["proj-own"]["scope"] == "projeto" and by["p"]["transport"] == "stdio · node"
    assert by["dup"]["transport"] == "http · a.example"
    assert by["u"]["transport"] == "sse · h.example" and by["u"]["disabled"] is True
    assert by["wisp-brain"]["installed_by_wisp"] is True and by["off"]["disabled"] is True
    assert "s3cret" not in json.dumps(servers)
    assert [s["name"] for s in servers].count("dup") == 1


def test_mcp_codex_reads_toml_tables(env):
    home, _ = env
    (home / ".codex").mkdir()
    (home / ".codex/config.toml").write_text('[mcp_servers.fs]\ncommand = "npx"\nargs = ["x"]\n[mcp_servers.fs.env]\nK = "v"\n[mcp_servers.web]\nurl = "https://w.example/mcp"\nenabled = false\n')
    got = {s["name"]: s for s in automations.mcp_codex(str(home))}
    assert got["fs"]["transport"] == "stdio · npx" and got["web"]["disabled"] is True and "v" not in json.dumps(got)


def test_mcp_local_lists_built_ins_and_tool_files(env):
    home, _ = env
    (home / "ferramentas").mkdir()
    (home / "ferramentas/calc.toml").write_text('name = "calc"\ncommand = "calc.exe --x"\n')
    (home / "ferramentas/dup.toml").write_text('name = "wisp-email"\ncommand = "z"\n')
    assert [s["name"] for s in automations.mcp_local(home)] == ["wisp-email", "wisp-brain", "calc"]


def test_mcp_servers_follow_the_active_engine(env):
    home, config = env
    (config / "wisp.json").write_text(json.dumps({"wisp_dir": str(home / "Wisp")}))
    (home / "Wisp").mkdir()
    (home / "Wisp/modelos.toml").write_text('ativo = "local"\n')
    assert automations.mcp_servers()["engine"] == "local"


def test_version_line_trims_and_caps():
    assert automations.version_line("\n  git version 2.4  \nmore") == "git version 2.4"
    assert len(automations.version_line("v" * 200)) == 80
    assert automations.version_line("  \n") is None


@pytest.mark.skipif(WINDOWS, reason="builds a POSIX script as the fake tool")
def test_clis_finds_installed_tools_on_the_path_and_lists_the_rest_as_missing(env, monkeypatch):
    home, _ = env
    bin_dir = home / "bin"
    bin_dir.mkdir()
    tool = bin_dir / "jq"
    tool.write_text("#!/bin/sh\necho jq-1.7\n")
    tool.chmod(0o755)
    monkeypatch.setenv("PATH", str(bin_dir))
    automations._versions.clear()
    data = automations.clis(force=True)
    assert data["installed"] == [{"name": "jq", "directory": "~/bin", "version": "jq-1.7", "auth": None}]
    assert "git" in data["missing"] and "jq" not in data["missing"]
    assert os.path.exists(tool)


def test_a_hook_id_with_a_trailing_newline_is_refused_even_when_listed(env, monkeypatch):
    _, config = env
    profile(config, hooks={"list": "L", "enable": "on {id}"})
    prefix = ("cmd.exe", "/d", "/s", "/c") if automations.WINDOWS else ("/bin/sh", "-c")
    listing = {"hooks": [{"id": "d\n", "event": "Stop", "command": "d", "enabled": False}]}
    runner = FakeRunner({(*prefix, "L"): ok(json.dumps(listing))})
    monkeypatch.setattr(automations, "runner", lambda: runner)
    assert automations.toggle_hook("d\n", True)["ok"] is False
    assert len(runner.calls) == 1
