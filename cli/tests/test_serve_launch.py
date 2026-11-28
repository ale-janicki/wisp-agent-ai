import ntpath

import pytest

from wisp.serve import claude_session
from wisp.serve.claude_session import ClaudeNotFound, resolve_launch

NODE_SHIM = (
    "@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\r\n"
    'IF EXIST "%dp0%\\node.exe" (\r\n  SET "_prog=%dp0%\\node.exe"\r\n) ELSE (\r\n  SET "_prog=node"\r\n'
    "  SET PATHEXT=%PATHEXT:;.JS;=;%\r\n)\r\n\r\n"
    "endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "
    '"%_prog%"  "%dp0%\\node_modules\\@anthropic-ai\\claude-code\\cli.js" %*\r\n'
)
EXE_SHIM = '@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n"%dp0%\\bin\\claude.exe" %*\r\n'

FOLDER = "C:\\Users\\me\\AppData\\Roaming\\npm"
CMD = FOLDER + "\\claude.cmd"
JS = FOLDER + "\\node_modules\\@anthropic-ai\\claude-code\\cli.js"


def launch(content, present, which=None):
    return resolve_launch(CMD, "win32", which=lambda name: which, exists=lambda p: p in present, read=lambda p: content)


def test_non_windows_and_native_exe_are_untouched():
    assert resolve_launch("/usr/bin/claude", "darwin") == ["/usr/bin/claude"]
    assert resolve_launch("C:\\x\\claude.cmd", "linux") == ["C:\\x\\claude.cmd"]
    assert resolve_launch("C:\\x\\claude.exe", "win32") == ["C:\\x\\claude.exe"]


def test_npm_shim_runs_node_on_the_js_entry():
    assert launch(NODE_SHIM, {JS}, which="C:\\nodejs\\node.exe") == ["C:\\nodejs\\node.exe", JS]


def test_node_beside_the_shim_wins_over_path():
    beside = ntpath.join(FOLDER, "node.exe")
    assert launch(NODE_SHIM, {JS, beside}, which="C:\\other\\node.exe") == [beside, JS]


def test_shim_pointing_at_an_exe_spawns_the_exe():
    exe = FOLDER + "\\bin\\claude.exe"
    assert launch(EXE_SHIM, {exe}) == [exe]


@pytest.mark.parametrize("content,present,which", [
    (NODE_SHIM, set(), "C:\\n\\node.exe"),
    (NODE_SHIM, {JS}, None),
    (EXE_SHIM, set(), None),
    ("@echo off\r\nclaude-real %*\r\n", set(), None),
    ('@echo off\r\n"C:\\evil.cmd" %*\r\n', {"C:\\evil.cmd"}, None),
    ("@echo off\r\necho hi\r\n", set(), None),
    ("", set(), None),
])
def test_unresolvable_cmd_is_refused_in_portuguese(content, present, which):
    with pytest.raises(ClaudeNotFound, match="instale a versão nativa"):
        launch(content, present, which)


def test_spawn_never_runs_a_batch_file_on_windows(monkeypatch):
    import asyncio
    monkeypatch.setattr(claude_session.sys, "platform", "win32")
    with pytest.raises(ClaudeNotFound):
        asyncio.run(claude_session.ClaudeProcess.spawn("C:\\x\\claude.cmd", [], ".", {}))


def test_a_batch_path_with_trailing_dots_or_spaces_is_still_a_batch():
    from wisp.serve.claude_session import _is_batch
    assert _is_batch("C:\\npm\\claude.cmd.") and _is_batch("C:\\npm\\claude.CMD ") and _is_batch("x.bat. .")
    assert not _is_batch("C:\\bin\\claude.exe")


def test_which_is_looked_up_when_called_so_a_patched_one_is_used(monkeypatch):
    import shutil
    monkeypatch.setattr(shutil, "which", lambda name: "C:\\patched\\node.exe")
    assert resolve_launch(CMD, "win32", exists=lambda p: p == JS, read=lambda p: NODE_SHIM) == ["C:\\patched\\node.exe", JS]
