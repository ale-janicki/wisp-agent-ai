import json
import os
import sys

import pytest

from wisp.serve.engines import codex, local
from wisp.serve.engines.codex import CodexDecoder, CodexNotFound


def lines(*objects):
    return [json.dumps(o) for o in objects]


def run(decoder, *objects):
    return [e for line in lines(*objects) for e in decoder.decode(line)]


def test_decoder_follows_a_normal_turn_like_the_macs():
    decoder = CodexDecoder(model="gpt-x")
    events = run(
        decoder,
        {"type": "thread.started", "thread_id": "t-1"}, {"type": "turn.started"},
        {"type": "item.started", "item": {"id": "i0", "type": "command_execution", "command": "ls -la"}},
        {"type": "item.completed", "item": {"id": "i0", "type": "command_execution", "aggregated_output": "x",
                                             "exit_code": 0, "status": "completed"}},
        {"type": "item.started", "item": {"id": "i1", "type": "mcp_tool_call", "server": "wisp-brain", "tool": "search"}},
        {"type": "item.completed", "item": {"id": "i1", "type": "mcp_tool_call", "status": "failed",
                                             "error": {"message": "boom"}}},
        {"type": "item.started", "item": {"id": "i2", "type": "web_search", "query": "wisp"}},
        {"type": "item.completed", "item": {"id": "i3", "type": "file_change", "changes": [{"path": "/a/b.txt"}]}},
        {"type": "item.completed", "item": {"id": "i4", "type": "agent_message", "text": "pronto"}},
        {"type": "turn.completed", "usage": {}})
    kinds = [e.kind for e in events]
    assert kinds == ["initialized", "engine_session", "thinking", "tool_use", "tool_result", "tool_use", "tool_result",
                     "tool_use", "tool_use", "tool_result", "text", "result"]
    assert events[0].data == {"session_id": "", "model": "gpt-x", "subscription": True}
    assert events[1].data == {"engine": "codex", "id": "t-1"}
    assert events[3].data["input"] == {"command": "ls -la"} and events[3].data["name"] == "Bash"
    assert events[5].data["name"] == "wisp-brain.search"
    assert events[6].data == {"tool_use_id": "i1", "is_error": True, "text": "boom"}
    assert events[7].data["name"] == "WebSearch" and events[8].data["name"] == "Edit"
    assert events[8].data["input"] == {"file_path": "/a/b.txt"}
    assert events[-1].data["text"] == "pronto" and events[-1].data["is_error"] is False
    assert decoder.thread_id == "t-1" and decoder.finished and decoder.closing(0, "") == []


def test_decoder_marks_declined_or_nonzero_commands_as_errors_and_failed_turns():
    decoder = CodexDecoder()
    [bad] = run(decoder, {"type": "item.completed", "item": {"id": "a", "type": "command_execution", "exit_code": 2,
                                                              "status": "completed", "aggregated_output": "no"}})
    assert bad.data["is_error"] is True
    [declined] = run(decoder, {"type": "item.completed", "item": {"id": "b", "type": "command_execution",
                                                                  "status": "declined"}})
    assert declined.data["is_error"] is True
    run(decoder, {"type": "error", "message": "rate limited"})
    [failed] = run(decoder, {"type": "turn.failed", "error": {"message": "falhou"}})
    assert failed.data["is_error"] is True and failed.data["text"] == "falhou"
    assert CodexDecoder().decode("not json")[0].kind == "malformed"


def test_closing_explains_an_incomplete_lost_or_logged_out_codex():
    assert CodexDecoder().closing(0, "")[0].data["text"] == "o Codex terminou sem concluir o turno"
    lost = CodexDecoder(resumed=True).closing(1, "session not found")[0].data["text"]
    assert lost == "codex session not found: the saved conversation will be replayed"
    started = CodexDecoder(resumed=True)
    started.decode(json.dumps({"type": "turn.started"}))
    assert started.closing(3, "boom")[0].data["text"] == "codex saiu com código 3: boom"
    out = CodexDecoder(resumed=True).closing(1, "Not logged in")[0].data["text"]
    assert out == "codex saiu com código 1: Not logged in\nConserto: rodar `codex login` no Terminal."
    assert CodexDecoder().closing(5, "")[0].data["text"] == "codex saiu com código 5"


def test_arguments_match_the_macs_codex_command(tmp_path):
    args = codex.arguments("/w", "auto", ["/extra"], "be nice", "/bin/wisp", "thread-9", set(), platform="linux")
    assert args[:7] == ["exec", "--json", "--skip-git-repo-check", "-C", "/w", "--sandbox", "workspace-write"]
    assert args[7:9] == ["--add-dir", "/extra"] and args[9:11] == ["-c", 'developer_instructions="be nice"']
    assert args[-3:] == ["resume", "thread-9", "-"]
    assert codex.sandbox_arguments(None) == ["--sandbox", "read-only"]
    assert codex.sandbox_arguments("default") == ["--sandbox", "read-only"]
    assert codex.sandbox_arguments("bypassPermissions") == ["--sandbox", "workspace-write"]
    plain = codex.arguments("/w", None, [], "", "/bin/wisp", None, set(), platform="linux")
    assert "resume" not in plain and "developer_instructions" not in " ".join(plain) and plain[-1] == "-"


def test_mcp_overrides_skip_servers_the_user_owns_and_the_mac_only_server_off_the_mac():
    on_mac = codex.mcp_overrides("/bin/wisp", frozenset({"wisp-brain"}), allow_changes=False, platform="darwin")
    assert not any(o.startswith("mcp_servers.wisp-brain.") for o in on_mac)
    tools = next(o for o in on_mac if o.startswith("mcp_servers.wisp-mac.enabled_tools="))
    assert '"mac_send"' not in tools and '"mac_screenshot"' in tools
    windows = codex.mcp_overrides("C:\\w\\wisp.exe", frozenset(), True, platform="win32")
    assert not any("wisp-mac" in o for o in windows)
    assert 'mcp_servers.wisp-email.command="C:\\\\w\\\\wisp.exe"' in windows
    brain = next(o for o in windows if o.startswith("mcp_servers.wisp-brain.env_vars="))
    assert "APPDATA" in brain and "WISP_CONFIG" in brain
    assert 'mcp_servers.wisp-email.env_vars=["WISP_TELEGRAM_THREAD", "WISP_APPROVAL_SOCKET"]' in windows


def test_toml_strings_escape_what_toml_needs():
    assert codex.toml_string('a"b\\c\nd\te\x01') == '"a\\"b\\\\c\\nd\\te\\u0001"'


def test_workspace_is_never_the_home_folder_or_above_it(tmp_path):
    home = tmp_path / "home"
    project = home / "proj"
    project.mkdir(parents=True)
    wisp = home / "Wisp"
    wisp.mkdir()
    assert codex.safe_directory(str(project), str(home)) == os.path.realpath(project)
    assert codex.safe_directory(str(home), str(home)) is None
    assert codex.safe_directory(str(tmp_path), str(home)) is None, "an ancestor of the home folder"
    assert codex.safe_directory(os.path.abspath(os.sep), str(home)) is None
    assert codex.safe_directory(str(tmp_path / "missing"), str(home)) is None
    assert codex.safe_directory("  ", str(home)) is None and codex.safe_directory(None, str(home)) is None
    assert codex.workspace(str(home), str(wisp), str(home)) == os.path.realpath(wisp)
    assert codex.workspace(None, str(home), str(home)) is None
    assert codex.extra_directories(str(project), [str(wisp), str(project), str(project / "sub"), str(wisp)],
                                   str(home)) == [os.path.realpath(wisp)]


def test_configured_model_reads_the_top_level_key_only(tmp_path):
    (tmp_path / "config.toml").write_text('model = "gpt-5"\n[profiles.x]\nmodel = "other"\n', encoding="utf-8")
    assert codex.configured_model(env={"CODEX_HOME": str(tmp_path)}) == "gpt-5"
    assert codex.configured_model(env={"CODEX_HOME": str(tmp_path / "nope")}) == ""


def test_environment_adds_the_executable_folder_and_wisp_bin(tmp_path):
    env = codex.environment(str(tmp_path / "bin" / "codex"), {"A": "1"}, "/x/wisp", {"PATH": "/usr/bin"}, "linux")
    assert env["PATH"] == f"/usr/bin:{tmp_path / 'bin'}" and env["A"] == "1" and env["WISP_BIN"] == "/x/wisp"
    if sys.platform == "win32":
        win = codex.environment("C:\\n\\codex.cmd", None, None, {"PATH": "C:\\a"}, "win32")
        assert win["PATH"] == "C:\\a;C:\\n"


def test_locate_codex_follows_the_macs_search_and_the_windows_shims(tmp_path):
    name = "codex"
    exe = tmp_path / name
    exe.write_text("#!/bin/sh\n")
    exe.chmod(0o755)
    assert codex.locate_codex(str(exe), env={}, platform="linux", home=str(tmp_path / "nohome")) == str(exe)
    with pytest.raises(CodexNotFound, match="não existe ou não é executável"):
        codex.locate_codex(str(tmp_path / "missing"), env={}, platform="linux", home=str(tmp_path))
    assert codex.locate_codex(None, env={"PATH": str(tmp_path)}, platform="linux", home=str(tmp_path / "nohome")) == str(exe)
    bun = tmp_path / "h" / ".bun" / "bin"
    bun.mkdir(parents=True)
    (bun / name).write_text("x")
    (bun / name).chmod(0o755)
    assert codex.locate_codex(None, env={"PATH": ""}, platform="linux", home=str(tmp_path / "h")) == str(bun / name)
    with pytest.raises(CodexNotFound, match="Codex não encontrado"):
        codex.locate_codex(None, env={"PATH": ""}, platform="linux", home=str(tmp_path / "empty"))
    (tmp_path / "codex.cmd").write_text("@echo off\r\n")
    assert codex.locate_codex(None, env={"PATH": str(tmp_path)}, platform="win32",
                              home=str(tmp_path / "nohome")) == os.path.join(str(tmp_path), "codex.cmd")


def test_a_cmd_shim_is_resolved_to_node_or_refused_never_run_through_cmd():
    shim = ('@ECHO off\r\nSETLOCAL\r\nIF EXIST "%dp0%\\node.exe" (\r\n  SET "_prog=%dp0%\\node.exe"\r\n) ELSE (\r\n'
            '  SET "_prog=node"\r\n)\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & '
            '"%_prog%"  "%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n')
    exists = lambda path: not path.endswith("node.exe")  # noqa: E731
    got = codex.launch_prefix("C:\\n\\codex.cmd", "win32", which=lambda name: "C:\\node\\node.exe", exists=exists,
                              read=lambda path: shim)
    assert got == ["C:\\node\\node.exe", "C:\\n\\node_modules\\@openai\\codex\\bin\\codex.js"]
    with pytest.raises(CodexNotFound) as error:
        codex.launch_prefix("C:\\n\\codex.cmd", "win32", read=lambda path: "@echo off\r\nstart evil\r\n")
    assert "Codex" in str(error.value) and "Claude" not in str(error.value) and "codex.exe" in str(error.value)
    assert codex.launch_prefix("/usr/bin/codex", "linux") == ["/usr/bin/codex"]


def test_readiness_notes_are_the_macs_words():
    assert codex.Readiness(False, False).note() == "o Codex não está instalado neste computador; esta conversa roda no Claude"
    assert codex.Readiness(True, False).note() == "o Codex não está com o login feito neste computador; esta conversa roda no Claude"
    assert codex.Readiness(True, True, False).note() == (
        "o Codex está com o envio de e-mail sem a trava de aprovação; rode `wisp harness sync`; esta conversa roda no Claude")
    assert codex.Readiness(True, True, True, "x").note() == "o Codex não roda aqui: x; esta conversa roda no Claude"
    assert not codex.Readiness(True, True, True, "x").ready and codex.Readiness(True, True).ready


def test_local_readiness_parses_the_cli_lines_and_phrases_the_note():
    ready = local.parse_readiness(b'{"type":"ready","ready":true}\n')
    assert ready.ready and ready.missing is None
    waiting = local.parse_readiness(b'noise\n{"type":"ready","ready":false,"missing":"sem modelo"}\n')
    assert not waiting.ready and waiting.note() == (
        "a IA local não está pronta (sem modelo); esta conversa roda no Claude. Ajustes > Modelo resolve.")
    failed = local.parse_readiness(b'{"type":"error","message":"quebrou"}\n')
    assert (failed.ready, failed.missing) == (False, "quebrou")
    assert local.parse_readiness(b"") is None and local.parse_readiness(b"[1]\n") is None
    assert local.Readiness(False).note() == "a IA local não está pronta (sem detalhe); esta conversa roda no Claude. Ajustes > Modelo resolve."
    assert local.check(None, {}).missing == "não achei o comando do Wisp"


def test_local_arguments_are_the_macs():
    assert local.arguments("oi", "abc", "auto") == [
        "local", "chat", "--message=oi", "--approvals", "stdio", "--no-record", "--recorded", "--surface", "app",
        "--mode", "auto", "--conversation", "abc"]
    assert "--conversation" not in local.arguments("oi", "", "default")
