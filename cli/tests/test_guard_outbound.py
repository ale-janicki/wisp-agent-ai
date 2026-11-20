import io
import json
import os
from pathlib import Path

import pytest

from wisp.cli import main
from wisp.guard_outbound import hook_guard_outbound
from wisp.paths import WispPaths


@pytest.fixture
def home(tmp_path):
    root = tmp_path / "home"
    root.mkdir(parents=True, exist_ok=True)
    return root


@pytest.fixture
def paths(home):
    return WispPaths(home, home / ".config/wisp", home / ".local/share/wisp/runtime", home / ".local/state/wisp", home / ".local/bin", None)


def _decide(paths, command, cwd=None, tool="Bash", **extra):
    tool_input = {"command": command} if tool == "Bash" else extra
    return hook_guard_outbound({"tool_name": tool, "tool_input": tool_input, "cwd": str(cwd or paths.home)}, paths)


MAIL_SENDS = [
    '''osascript -e 'tell application "Mail" to send (make new outgoing message with properties {subject:"x"})' ''',
    '''osascript -e 'tell application "Mail"' -e 'set m to make new outgoing message' -e 'send m' -e 'end tell' ''',
    '''/usr/bin/osascript -l JavaScript -e 'const m=Application("Mail").OutgoingMessage({subject:"x"}); m.send()' ''',
    '''osascript -l JavaScript -e "Application('Ma'+'il').outgoingMessages.push(1)"''',
    '''osascript -l JavaScript -e 'var a=Application(["Ma","il"].join("")); a.OutgoingMessage().send()' ''',
    '''osascript -e 'tell application id "com.apple.mail" to send theMessage' ''',
    '''o"sa"script -e 'tell application "Mail" to send m' ''',
    '''osascript <<EOF\ntell application "Mail"\nsend m\nend tell\nEOF''',
    '''env osascript -e 'TELL APPLICATION "MAIL" TO SEND M' ''',
    '''python3 -c "from wisp.email.mail_app import MailApp; MailApp(None).send(['a@b.c'], 's', 'b')"''',
    '''uv run python - <<EOF\nimport wisp.email.server as s\ns.email_send()\nEOF''',
    '''python -c "import importlib; importlib.import_module('wisp'+'.email')"''',
    '''python3 -c "from wisp import email"''',
    '''python3 -c "__import__('wisp.' + 'email')"''',
]

SERVER_STARTS = [
    "wisp mcp email",
    "~/.local/share/wisp/runtime/venv/bin/wisp mcp email",
    "uv run wisp mcp email",
    "WISP_APPROVAL_SOCKET=/tmp/x/b wisp mcp email",
    "python3 -m wisp mcp email",
    "python -m wisp.cli mcp email",
    "export WISP_APPROVAL_SOCKET=/tmp/x/b",
    "env WISP_APPROVAL_SOCKET=/tmp/x/b true",
    "echo $WISP_APPROVAL_SOCKET",
    "w'is'p m\\cp email",
    "ls && wisp mcp email",
]

MAIL_ALLOWED = [
    '''osascript -e 'tell application "Finder" to get name of home' ''',
    '''osascript -l JavaScript -e 'Application("Mail").inbox().messages().length' ''',
    '''osascript -e 'tell application "Mail" to get sender of message 1 of inbox' ''',
    "wisp email list --limit 3",
    "grep -rn wisp.email cli/src",
    "uv run pytest cli/tests/test_mail_app.py -q",
    "python3 -c 'print(1)'",
    "ls docs/approvals",
    "wisp email list --limit 3",
    "wisp topic status --json",
    "open https://example.com",
    "osascript -e 'display dialog \"oi\"'",
    "osascript -e 'tell application \"Finder\" to get name of home' && ls",
]


@pytest.mark.parametrize("command", MAIL_SENDS)
def test_mail_sends_from_scripts_are_blocked(paths, command):
    assert "email_send" in (_decide(paths, command) or "")


@pytest.mark.parametrize("command", MAIL_ALLOWED)
def test_reading_mail_and_unrelated_commands_pass(paths, command):
    assert _decide(paths, command) is None


def test_script_file_given_to_osascript_is_read(paths, tmp_path):
    script = tmp_path / "go.js"
    script.write_text('Application("Mail").OutgoingMessage({}).send()')
    assert _decide(paths, f"osascript -l JavaScript {script}")
    assert _decide(paths, "osascript -l JavaScript go.js", cwd=tmp_path)
    harmless = tmp_path / "ok.js"
    harmless.write_text('Application("Finder").name()')
    assert _decide(paths, f"osascript -l JavaScript {harmless}") is None


def test_python_script_file_importing_the_email_module_is_read(paths, tmp_path):
    script = tmp_path / "x.py"
    script.write_text("from wisp.email.mail_app import MailApp\n")
    assert _decide(paths, "python3 x.py", cwd=tmp_path)


def test_shell_script_file_running_osascript_is_read(paths, tmp_path):
    script = tmp_path / "x.sh"
    script.write_text('osascript -e \'tell application "Mail" to send m\'\n')
    assert _decide(paths, "bash x.sh", cwd=tmp_path)


def test_writing_scripts_and_touching_the_state_folder_pass(paths, home):
    """The folder-forgery checks are gone (approval now lives in Claude Code's prompt); file tools are never blocked."""
    assert _decide(paths, "cat ~/.local/state/wisp/approvals/abc.json") is None
    assert _decide(paths, "", tool="Write", file_path=str(home / "x.py"), content="import wisp.email.server\n# approvals decision") is None
    assert _decide(paths, "", tool="Read", file_path=str(home / ".local/state/wisp/x.json")) is None


def test_bad_payloads_pass(paths):
    assert hook_guard_outbound({}, paths) is None
    assert hook_guard_outbound({"tool_name": "Bash", "tool_input": "x"}, paths) is None
    assert hook_guard_outbound({"tool_name": "Bash", "tool_input": {"command": 3}}, paths) is None


def test_cli_exits_2_on_block_and_0_otherwise(fake_home, monkeypatch, capsys):
    block = {"tool_name": "Bash", "tool_input": {"command": 'osascript -e \'tell application "Mail" to send m\''}, "cwd": str(fake_home)}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(block)))
    assert main(["hook", "guard-outbound"]) == 2
    assert capsys.readouterr().err.startswith("wisp-guard:")
    ok = {"tool_name": "Bash", "tool_input": {"command": "ls"}, "cwd": str(fake_home)}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(ok)))
    assert main(["hook", "guard-outbound"]) == 0
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert main(["hook", "guard-outbound"]) == 2


MAILTO_OPENS = [
    "open mailto:a@b.c?subject=x",
    "open 'mailto:a@b.c'",
    "/usr/bin/open -a Mail \"mailto:a@b.c?body=hi\"",
    "ls && open MAILTO:a@b.c",
]


@pytest.mark.parametrize("command", SERVER_STARTS)
def test_starting_the_email_server_or_touching_the_socket_variable_is_blocked(paths, command):
    assert (_decide(paths, command) or "").startswith("wisp-guard:")


@pytest.mark.parametrize("command", MAILTO_OPENS)
def test_open_with_a_mailto_url_is_blocked(paths, command):
    assert "email_send" in (_decide(paths, command) or "")


def test_osascript_script_file_with_any_name_is_read_and_checked(paths, tmp_path):
    sends = tmp_path / "go"
    sends.write_text('tell application "Mail" to send m')
    assert _decide(paths, f"osascript {sends}")
    assert _decide(paths, "osascript go", cwd=tmp_path)
    assert _decide(paths, f"osascript -l AppleScript {sends} arg")
    assert _decide(paths, f"cd /tmp && osascript {sends} ; ls")
    reads = tmp_path / "read"
    reads.write_text('tell application "Mail" to get sender of message 1 of inbox')
    assert _decide(paths, f"osascript {reads}") is None
    other = tmp_path / "other"
    other.write_text('tell application "Finder" to get name of home')
    assert _decide(paths, f"osascript {other}") is None


@pytest.mark.parametrize("command", ["osascript missing-file", "osascript /nonexistent/dir/x", "osascript ."])
def test_osascript_file_that_cannot_be_read_is_blocked(paths, command):
    assert _decide(paths, command)


def test_osascript_with_inline_script_and_here_document_is_not_treated_as_a_file(paths):
    assert _decide(paths, "osascript -e 'beep'") is None
    assert _decide(paths, "osascript - <<EOF\nbeep\nEOF") is None


SERVER_SCRIPT = (
    "import subprocess\n"
    "subprocess.Popen([\"wisp\", \"mcp\", \"email\"], env={\"WISP_APPROVAL_SOCKET\": \"/tmp/x/b\"})\n"
)


@pytest.mark.parametrize("launcher", ["python3", "python", "{runtime}/venv/bin/python", "uv run python", "node", "ruby", "perl", "bash", "sh", "zsh"])
def test_a_script_given_to_an_interpreter_that_starts_the_server_is_blocked(paths, tmp_path, launcher):
    script = tmp_path / "srv.py"
    script.write_text(SERVER_SCRIPT)
    command = launcher.format(runtime=paths.runtime) + f" {script}"
    assert (_decide(paths, command) or "").startswith("wisp-guard:")
    assert _decide(paths, launcher.format(runtime=paths.runtime) + " srv.py", cwd=tmp_path)


def test_a_list_style_server_launch_in_a_script_is_blocked_without_the_variable(paths, tmp_path):
    script = tmp_path / "srv.py"
    script.write_text('import subprocess\nsubprocess.Popen(["wisp", "mcp", "email"])\n')
    assert (_decide(paths, f"python3 {script}") or "").startswith("wisp-guard:")


def test_a_harmless_script_passes_and_an_unreadable_one_is_blocked(paths, tmp_path):
    script = tmp_path / "ok.py"
    script.write_text("print(1)\n")
    assert _decide(paths, f"python3 {script}") is None
    assert _decide(paths, "python3 -c 'print(1)'") is None
    assert _decide(paths, "python3 -m pytest -q") is None
    assert _decide(paths, "python3 - <<EOF\nprint(1)\nEOF") is None
    assert _decide(paths, "python3 missing.py", cwd=tmp_path)
    big = tmp_path / "big.sh"
    big.write_text("#" * 1_000_001)
    assert _decide(paths, f"bash {big}")


def test_mcp_must_be_a_whole_word_after_wisp(paths):
    assert _decide(paths, "wisp mcp-list") is None
    assert _decide(paths, "wisp mcp") is not None
    assert _decide(paths, "wisp mcp email") is not None
    assert _decide(paths, "ls && wisp mcp") is not None
