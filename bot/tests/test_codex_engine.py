import asyncio
import json
from pathlib import Path

import pytest

from wisp_bot import bot, claude_runner, codex_runner, engine
from wisp_bot.engine import Result, Status
from wisp_bot.store import Store
from wisp_bot.transcript import Transcripts

CONTRACT = Path(__file__).parents[2] / "cli/tests/fixtures/contract"
THREAD = "0199a213-81c0-7800-8aa1-bbab2a035a53"
SESSION = "11111111-1111-4111-8111-111111111111"


def _events(name):
    return [json.loads(l) for l in (CONTRACT / name).read_text("utf-8").splitlines() if l]


def _fake_codex(tmp_path, fixture, code=0, log=None):
    lines = (CONTRACT / fixture).read_text("utf-8")
    fake = tmp_path / "codex"
    record = f'echo "$@" > {log}\ncat > {log}.stdin\n' if log else "cat > /dev/null\n"
    fake.write_text(f"#!/bin/sh\n{record}cat <<'EOF'\n{lines}EOF\nexit {code}\n")
    fake.chmod(0o755)
    return str(fake)


def test_the_documented_stream_decodes_to_labels_text_and_thread():
    stream = codex_runner.Stream()
    emitted = [e for event in _events("codex-exec-stream-from-docs.jsonl") for e in stream.feed(event)]
    assert stream.thread_id == THREAD and stream.completed and stream.failure is None
    assert [v for k, v in emitted if k == "label"] == ["rodando um comando", "usando wisp-email", "editando notas.md"]
    assert stream.message.startswith("Repo contains docs")


def test_a_failed_stream_keeps_the_failure_and_no_text():
    stream = codex_runner.Stream()
    for event in _events("codex-exec-failed-from-docs.jsonl"):
        stream.feed(event)
    assert stream.failure == "stream disconnected before completion" and stream.message is None


@pytest.mark.parametrize("mode,expected", [
    ("auto", ["--sandbox", "workspace-write"]),
    ("bypassPermissions", ["--sandbox", "workspace-write"]),
    ("default", ["--sandbox", "read-only"]),
    ("anything-else", ["--sandbox", "read-only"]),
])
def test_permission_modes_map_to_codex_flags_and_never_to_full_access(mode, expected):
    assert codex_runner.permission_args(mode) == expected
    assert "danger-full-access" not in codex_runner.permission_args(mode)


def test_the_workspace_is_never_home_or_a_parent_of_home(tmp_path):
    wisp = tmp_path / "Wisp"
    wisp.mkdir()
    home = Path.home()
    project = home / "project"
    project.mkdir()
    assert codex_runner.workspace("~", wisp) == wisp
    assert codex_runner.workspace(str(home), wisp) == wisp
    assert codex_runner.workspace(str(home.parent), wisp) == wisp
    assert codex_runner.workspace("/", wisp) == wisp
    assert codex_runner.workspace(str(tmp_path / "missing"), wisp) == wisp
    assert codex_runner.workspace(str(project), wisp) == project.resolve()


def test_command_uses_documented_flags_stdin_prompt_and_resume(tmp_path, monkeypatch):
    root = tmp_path / "work"
    root.mkdir()
    fresh = codex_runner.command(root=root, mode="auto", extra_prompt="EXTRA", session=None)
    assert fresh[1:6] == ["exec", "--json", "--skip-git-repo-check", "-C", str(root)]
    assert "--approve-for-me" not in fresh and fresh[-1] == "-" and "resume" not in fresh
    instructions = next(a for a in fresh if a.startswith("developer_instructions="))
    assert "EXTRA" in instructions and "Telegram" in instructions
    resumed = codex_runner.command(root=root, mode="bypassPermissions", extra_prompt="", session=THREAD)
    assert resumed[-3:] == ["resume", THREAD, "-"] and resumed[resumed.index("--sandbox") + 1] == "workspace-write"


def test_a_turn_runs_the_fake_binary_and_returns_session_text_and_labels(tmp_path, monkeypatch):
    log = tmp_path / "argv"
    monkeypatch.setattr(codex_runner, "CODEX_BIN", _fake_codex(tmp_path, "codex-exec-stream-from-docs.jsonl", log=log))
    monkeypatch.setattr(codex_runner, "permission_mode", lambda: "auto")
    monkeypatch.setattr(codex_runner, "configured_model", lambda: "gpt-test")
    labels, texts = [], []
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(tmp_path), started=False, timeout=20,
                                       on_event=labels.append, on_text=texts.append))
    assert res.ok and res.engine == "codex" and res.session_id == THREAD and res.model == "gpt-test"
    assert res.text == "Repo contains docs, sdk, and examples directories."
    assert labels == ["rodando um comando", "usando wisp-email", "editando notas.md"] and len(texts) == 1
    assert Path(f"{log}.stdin").read_text() == "oi"
    assert "--approve-for-me" not in log.read_text() and "--sandbox workspace-write" in log.read_text()


def test_a_failed_turn_reports_the_error(tmp_path, monkeypatch):
    monkeypatch.setattr(codex_runner, "CODEX_BIN", _fake_codex(tmp_path, "codex-exec-failed-from-docs.jsonl", code=1))
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(tmp_path), started=False, timeout=20))
    assert not res.ok and "stream disconnected" in res.text and not res.resume_failed


def test_resume_that_never_starts_a_turn_is_marked_for_rebuild(tmp_path, monkeypatch):
    fake = tmp_path / "codex"
    fake.write_text("#!/bin/sh\ncat >/dev/null\necho 'Error: thread not found' >&2\nexit 1\n")
    fake.chmod(0o755)
    monkeypatch.setattr(codex_runner, "CODEX_BIN", str(fake))
    res = asyncio.run(codex_runner.run("oi", session_id=THREAD, cwd=str(tmp_path), started=True, timeout=20))
    assert res.resume_failed and not res.ok


def test_timeout_kills_the_whole_process_group(tmp_path, monkeypatch):
    fake = tmp_path / "codex"
    fake.write_text("#!/bin/sh\nsleep 37 &\nsleep 37\n")
    fake.chmod(0o755)
    monkeypatch.setattr(codex_runner, "CODEX_BIN", str(fake))
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(tmp_path), started=False, timeout=1))
    assert not res.ok and "estourou" in res.text
    import subprocess
    assert subprocess.run(["pgrep", "-f", "sleep 37"], capture_output=True).returncode != 0


class _Fake:
    def __init__(self, name, status):
        self.name, self._status, self.calls = name, status, []

    async def status(self):
        return self._status

    async def run(self, prompt, **kw):
        self.calls.append((prompt, kw["session_id"], kw["started"]))
        return Result(True, "ok", session_id=THREAD, model="m", engine=self.name)


def test_active_engine_reads_modelos_toml_and_defaults_to_claude(tmp_path):
    assert engine.active_name(tmp_path) == "claude"
    (tmp_path / "modelos.toml").write_text('ativo = "codex"\n')
    assert engine.active_name(tmp_path) == "codex"
    (tmp_path / "modelos.toml").write_text("ativo = [")
    assert engine.active_name(tmp_path) == "claude"


@pytest.mark.parametrize("status,words", [(Status(False, False), "não está instalado"), (Status(True, False), "login")])
def test_active_engine_not_ready_runs_on_claude_and_says_so(tmp_path, monkeypatch, status, words):
    (tmp_path / "modelos.toml").write_text('ativo = "codex"\n')
    monkeypatch.setattr(engine, "_status_cache", {})
    monkeypatch.setattr(codex_runner.CODEX, "status", _Fake("codex", status).status)
    chosen, note = asyncio.run(engine.resolve(tmp_path))
    assert chosen.name == "claude" and "Codex" in note and words in note and "Claude" in note


def test_active_engine_ready_runs_on_codex(tmp_path, monkeypatch):
    (tmp_path / "modelos.toml").write_text('ativo = "codex"\n')
    monkeypatch.setattr(engine, "_status_cache", {})
    monkeypatch.setattr(codex_runner.CODEX, "status", _Fake("codex", Status(True, True)).status)
    chosen, note = asyncio.run(engine.resolve(tmp_path))
    assert chosen.name == "codex" and note is None


def _topic(tmp_path, monkeypatch):
    store = Store(tmp_path / "topics.json")
    store.get_or_create("1:7", "t", str(tmp_path))
    store.mark_started("1:7")
    topic = store.get("1:7")
    log = Transcripts(tmp_path / "conversas")
    monkeypatch.setattr(bot, "transcripts", log)
    monkeypatch.setattr(bot, "store", store)
    return store, topic, log


def test_switch_from_claude_to_codex_primes_a_fresh_codex_session_from_the_transcript(tmp_path, monkeypatch):
    store, topic, log = _topic(tmp_path, monkeypatch)
    log.user(topic.session_id, "capital da França?", "app")
    log.assistant(topic.session_id, "Paris.", "app", "claude", "claude-opus-4-8")
    codex, notes = _Fake("codex", Status(True, True)), []

    async def note():
        notes.append(1)
    res, same = asyncio.run(bot.codex_com_memoria(topic, codex, "e a da Itália?", "e a da Itália?", note, cwd="x"))
    prompt, sid, started = codex.calls[0]
    assert not started and sid == "" and "Assistant: Paris." in prompt and prompt.endswith("e a da Itália?")
    assert notes == [1] and same.session_id == topic.session_id
    assert log.engine_session(topic.session_id, "codex") == THREAD


def test_codex_follow_up_resumes_its_own_session_without_priming(tmp_path, monkeypatch):
    store, topic, log = _topic(tmp_path, monkeypatch)
    log.user(topic.session_id, "oi", "telegram")
    log.assistant(topic.session_id, "ola", "telegram", "codex", "m")
    log.engine_started(topic.session_id, THREAD, "codex", "new")
    codex = _Fake("codex", Status(True, True))

    async def note():
        raise AssertionError("no note on a plain resume")
    asyncio.run(bot.codex_com_memoria(topic, codex, "de novo", "de novo", note, cwd="x"))
    assert codex.calls == [("de novo", THREAD, True)]


def test_switch_back_to_claude_rebuilds_through_the_same_path_as_a_lost_session(tmp_path, monkeypatch):
    store, topic, log = _topic(tmp_path, monkeypatch)
    log.user(topic.session_id, "oi", "telegram")
    log.assistant(topic.session_id, "ola do codex", "telegram", "codex", "m")
    calls, notes, moved = [], [], []

    async def claude(prompt, **kw):
        calls.append((prompt, kw["session_id"], kw["started"]))
        return Result(True, "ok", model="m")
    monkeypatch.setattr(bot, "claude_run", claude)

    async def note():
        notes.append(1)

    async def relock(sid):
        moved.append(sid)
    old = topic.session_id
    res, new = asyncio.run(bot.claude_com_memoria("1:7", topic, "e agora?", "e agora?", True, note, relock,
                                                  switched=True, cwd="x"))
    assert len(calls) == 1 and calls[0][1] == new.session_id != old and calls[0][2] is False
    assert "Assistant: ola do codex" in calls[0][0] and moved == [new.session_id] and notes == [1]
    assert log.find(new.session_id) == old


def test_a_non_fatal_error_event_does_not_fail_a_turn_that_completes(tmp_path, monkeypatch):
    monkeypatch.setattr(codex_runner, "CODEX_BIN", _fake_codex(tmp_path, "codex-exec-nonfatal-error-from-docs.jsonl"))
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(tmp_path), started=False, timeout=20))
    assert res.ok and res.text == "Done." and res.session_id == THREAD


def test_exit_zero_without_turn_completed_is_not_ok(tmp_path, monkeypatch):
    monkeypatch.setattr(codex_runner, "CODEX_BIN", _fake_codex(tmp_path, "codex-exec-incomplete-from-docs.jsonl"))
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(tmp_path), started=False, timeout=20))
    assert not res.ok and "sem concluir" in res.text and not res.resume_failed


def test_add_dirs_are_resolved_and_never_home_or_above(tmp_path):
    home = Path.home().resolve()
    root = tmp_path / "root"
    root.mkdir()
    wisp = tmp_path / "Wisp"
    wisp.mkdir()
    (tmp_path / "brain-link").symlink_to(home)
    (tmp_path / "elsewhere").mkdir()
    (tmp_path / "real-link").symlink_to(tmp_path / "elsewhere")
    assert codex_runner.extra_dirs(root, tmp_path / "brain-link", wisp) == [str(wisp.resolve())]
    assert codex_runner.extra_dirs(root, home.parent, wisp) == [str(wisp.resolve())]
    assert codex_runner.extra_dirs(root, Path("/"), wisp) == [str(wisp.resolve())]
    assert codex_runner.extra_dirs(root, tmp_path / "real-link", wisp) == [
        str(wisp.resolve()), str((tmp_path / "elsewhere").resolve())]


def test_workspace_resolves_symlinks_and_empty_cwd_uses_the_fallback(tmp_path):
    home = Path.home().resolve()
    wisp = tmp_path / "Wisp"
    wisp.mkdir()
    (tmp_path / "home-link").symlink_to(home)
    assert codex_runner.workspace("", wisp) == wisp.resolve()
    assert codex_runner.workspace("   ", wisp) == wisp.resolve()
    assert codex_runner.workspace(str(tmp_path / "home-link"), wisp) == wisp.resolve()


def test_no_safe_workspace_means_no_codex_turn(tmp_path, monkeypatch):
    home = Path.home().resolve()
    link = tmp_path / "wisp-link"
    link.symlink_to(home)
    assert codex_runner.workspace("~", link) is None
    assert codex_runner.workspace("", home.parent) is None
    monkeypatch.setattr(codex_runner, "_CFG", type("C", (), {"wisp_dir": link, "brain": link, "codex_bin": None})())
    spawned = []

    async def boom(*a, **k):
        spawned.append(a)
        raise AssertionError("must not spawn")
    monkeypatch.setattr(codex_runner.asyncio, "create_subprocess_exec", boom)
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(home), started=False, timeout=5))
    assert not res.ok and "pasta de trabalho segura" in res.text and spawned == []


def test_unsafe_wisp_folder_makes_codex_not_ready_and_the_turn_runs_on_claude(tmp_path, monkeypatch):
    home = Path.home().resolve()
    link = tmp_path / "wisp-link"
    link.symlink_to(home)
    (tmp_path / "modelos.toml").write_text('ativo = "codex"\n')
    monkeypatch.setattr(engine, "_status_cache", {})
    monkeypatch.setattr(codex_runner, "_CFG", type("C", (), {"wisp_dir": link, "brain": link, "codex_bin": None})())
    monkeypatch.setattr(codex_runner, "codex_bin", lambda: "/usr/bin/true")
    chosen, note = asyncio.run(engine.resolve(tmp_path))
    assert chosen.name == "claude" and "pasta de trabalho segura" in note


def test_every_codex_launch_carries_the_whole_email_server_as_overrides_before_resume(tmp_path):
    contract = json.loads((CONTRACT / "codex-mcp-overrides.json").read_text("utf-8"))
    assert codex_runner.mcp_overrides(contract["wisp_bin"]) == contract["overrides"]
    assert codex_runner.mcp_overrides(contract["wisp_bin"], allow_changes=False) == contract["overrides_read_only"]
    root = tmp_path / "work"
    root.mkdir()
    for session in (None, THREAD):
        for mode in ("default", "manual", "auto", "bypassPermissions", "qualquer"):
            cmd = codex_runner.command(root=root, mode=mode, extra_prompt="", session=session, wisp_bin=contract["wisp_bin"])
            wanted = contract["overrides"] if mode in ("auto", "bypassPermissions") else contract["overrides_read_only"]
            for override in wanted:
                assert cmd[cmd.index(override) - 1] == "-c"
            tools = [c for c in cmd if c.startswith("mcp_servers.wisp-mac.enabled_tools=")]
            assert len(tools) == 1 and ("mac_send" in tools[0]) == (mode in ("auto", "bypassPermissions"))
            if session:
                assert cmd.index(wanted[-1]) < cmd.index("resume")


def test_the_fake_binary_receives_the_overrides_on_a_real_turn(tmp_path, monkeypatch):
    log = tmp_path / "argv"
    monkeypatch.setattr(codex_runner, "CODEX_BIN", _fake_codex(tmp_path, "codex-exec-stream-from-docs.jsonl", log=log))
    monkeypatch.setattr(codex_runner, "WISP_BIN", "/opt/wisp/venv/bin/wisp")
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(tmp_path), started=False, timeout=20))
    seen = log.read_text()
    assert res.ok and 'WISP_SEND_GATE' not in seen
    assert 'mcp_servers.wisp-email.command="/opt/wisp/venv/bin/wisp"' in seen


def test_the_codex_process_env_carries_the_same_wisp_bin_as_the_email_overrides(tmp_path, monkeypatch):
    log = tmp_path / "argv"
    fake = Path(_fake_codex(tmp_path, "codex-exec-stream-from-docs.jsonl", log=log))
    fake.write_text(fake.read_text().replace("cat > /dev/null", "").replace(f'echo "$@" > {log}', f'echo "$@" > {log}; echo "$WISP_BIN" > {log}.bin'))
    monkeypatch.setattr(codex_runner, "CODEX_BIN", str(fake))
    monkeypatch.setattr(codex_runner, "WISP_BIN", "/opt/wisp/venv/bin/wisp")
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(tmp_path), started=False, timeout=20, env={"WISP_BIN": "/elsewhere"}))
    assert res.ok and (tmp_path / "argv.bin").read_text().strip() == "/opt/wisp/venv/bin/wisp"
    assert 'mcp_servers.wisp-email.command="/opt/wisp/venv/bin/wisp"' in log.read_text()


def _planted(home, body='[mcp_servers.wisp-email]\ncommand = "x"\n'):
    root = home / "work" / "proj"
    (root / "sub").mkdir(parents=True)
    (root / ".codex").mkdir()
    (root / ".codex/config.toml").write_text(body)
    return root, root / "sub"


@pytest.mark.parametrize("body", [
    '[mcp_servers.wisp-email]\ncommand = "x"\n',
    'mcp_servers.wisp-email.command = "x"\n',
    'mcp_servers = { wisp-email = { command = "x" } }\n',
    "broken [",
])
def test_a_project_config_that_defines_the_email_server_or_does_not_parse_is_a_conflict_naming_the_file(tmp_path, body):
    home = tmp_path / "home"
    root, sub = _planted(home, body)
    assert str(root / ".codex/config.toml") in codex_runner.project_conflict(sub, home)
    assert codex_runner.project_conflict(None, home) is None


def test_other_servers_the_home_folder_and_folders_above_home_are_not_a_conflict(tmp_path):
    home = tmp_path / "home"
    root, sub = _planted(home, '[mcp_servers.other]\ncommand = "y"\n')
    assert codex_runner.project_conflict(sub, home) is None
    (home / ".codex").mkdir()
    (home / ".codex/config.toml").write_text('[mcp_servers.wisp-email]\ncommand = "x"\n')
    (tmp_path / ".codex").mkdir()
    (tmp_path / ".codex/config.toml").write_text('[mcp_servers.wisp-email]\ncommand = "x"\n')
    assert codex_runner.project_conflict(sub, home) is None


def test_a_planted_project_server_makes_the_turn_fall_back_to_claude_with_a_note(tmp_path, monkeypatch):
    home = tmp_path / "home"
    root, sub = _planted(home)
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
    codex = _Fake("codex", Status(True, True))
    chosen, note = bot.codex_ou_claude(codex, None, str(sub))
    assert chosen.name == "claude" and "Codex" in note and str(root / ".codex/config.toml") in note and "Claude" in note
    clean = tmp_path / "home" / "work" / "clean"
    clean.mkdir()
    chosen, note = bot.codex_ou_claude(codex, None, str(clean))
    assert chosen is codex and note is None
    claude = _Fake("claude", Status(True, True))
    assert bot.codex_ou_claude(claude, "x", str(sub)) == (claude, "x")


def test_the_runner_itself_refuses_to_launch_with_a_planted_server_and_never_runs_codex(tmp_path, monkeypatch):
    home = tmp_path / "home"
    root, sub = _planted(home)
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
    log = tmp_path / "argv"
    monkeypatch.setattr(codex_runner, "CODEX_BIN", _fake_codex(tmp_path, "codex-exec-stream-from-docs.jsonl", log=log))
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(sub), started=False, timeout=20))
    assert not res.ok and res.engine == "codex" and str(root / ".codex/config.toml") in res.text
    assert not log.exists()


def test_a_brain_server_the_user_owns_gets_no_launch_override_but_the_email_one_stays(tmp_path, monkeypatch):
    home = tmp_path / "codex"
    home.mkdir()
    monkeypatch.setenv("CODEX_HOME", str(home))
    (home / "config.toml").write_text('[mcp_servers.wisp-brain]\ncommand = "mine"\n')
    assert codex_runner.user_owned_servers() == frozenset({"wisp-brain"})
    root = tmp_path / "work"
    root.mkdir()
    cmd = codex_runner.command(root=root, mode="default", extra_prompt="", session=None, wisp_bin="/opt/wisp")
    assert any(a.startswith("mcp_servers.wisp-email.") for a in cmd) and not any(a.startswith("mcp_servers.wisp-brain.") for a in cmd)
    (home / "config.toml").write_text(
        '[mcp_servers.other]\ncommand = "x"\n# wisp:begin\n[mcp_servers.wisp-brain]\ncommand = "ours"\n# wisp:end\n')
    assert codex_runner.user_owned_servers() == frozenset()
    cmd = codex_runner.command(root=root, mode="default", extra_prompt="", session=None, wisp_bin="/opt/wisp")
    assert any(a.startswith("mcp_servers.wisp-brain.") for a in cmd)
