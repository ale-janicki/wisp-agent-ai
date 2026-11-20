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
    (root / ".local/state/wisp/approvals").mkdir(parents=True)
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

MAIL_ALLOWED = [
    '''osascript -e 'tell application "Finder" to get name of home' ''',
    '''osascript -l JavaScript -e 'Application("Mail").inbox().messages().length' ''',
    '''osascript -e 'tell application "Mail" to get sender of message 1 of inbox' ''',
    "wisp email list --limit 3",
    "grep -rn wisp.email cli/src",
    "uv run pytest cli/tests/test_mail_app.py -q",
    "python3 -c 'print(1)'",
    "ls docs/approvals",
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


APPROVAL_COMMANDS = [
    "cat ~/.local/state/wisp/approvals/abc.json",
    "echo allow > ~/.local/state/wisp/approvals/{id}.decision",
    "echo allow > $HOME/.local/state/wisp/approvals/{id}.decision",
    "echo allow > ${HOME}/.local/state/wisp/approvals/{id}.decision",
    "echo allow > $XDG_STATE_HOME/wisp/approvals/{id}.decision",
    "echo allow > {home}/.local/state//wisp/approvals/{id}.decision",
    "echo allow > '{home}/.local/state/wisp/appro''vals/{id}.decision'",
    "echo allow > {home}/.local/state/wisp/approv\\als/{id}.decision",
    "cd approvals && printf allow > x.decision",
    "cd ~/.local/state/wisp/approvals && echo allow > {id}.decision",
    "cd ~/.local/state/wisp && echo allow > approvals/{id}.decision",
    "cd ~/.local/state && echo allow > wisp/approvals/{id}.decision",
    "echo allow > /tmp/x/{id}.decision",
    "ls ~/.local/state/wisp/approvals",
    "python3 -c \"open('{home}/.local/state/wisp/approvals/{id}.decision','w').write('allow')\"",
]


@pytest.mark.parametrize("template", APPROVAL_COMMANDS)
def test_bash_touching_the_approvals_folder_is_blocked(paths, home, template):
    command = template.replace("{home}", str(home)).replace("{id}", "a" * 32)
    assert "approvals folder" in (_decide(paths, command) or "")


def test_symlink_into_the_approvals_folder_is_followed(paths, home, tmp_path):
    link = tmp_path / "shortcut"
    link.symlink_to(home / ".local/state/wisp/approvals")
    assert _decide(paths, f"echo allow > {link}/{'a' * 32}.decision")
    assert _decide(paths, "", tool="Write", file_path=f"{link}/x.decision")


def test_relative_path_from_the_state_folder_is_blocked(paths, home):
    assert _decide(paths, "echo allow > approvals/x", cwd=home / ".local/state/wisp")
    assert _decide(paths, "ls approvals", cwd=home / ".local/state/wisp")


def test_unrelated_approvals_names_pass(paths, home):
    assert _decide(paths, "ls docs/approvals", cwd=home) is None
    assert _decide(paths, "git add cli/src/wisp/approvals.py") is None
    assert _decide(paths, "cat cli/src/wisp/approvals.py") is None
    assert _decide(paths, "grep -n approvals cli/src/wisp/approvals.py") is None
    assert _decide(paths, "cat ~/notes/approvals/list.md") is None


@pytest.mark.parametrize("tool,key", [("Write", "file_path"), ("Edit", "file_path"), ("MultiEdit", "file_path"),
                                       ("NotebookEdit", "notebook_path"), ("Read", "file_path"), ("Glob", "pattern")])
def test_file_tools_on_the_approvals_folder_are_blocked(paths, home, tool, key):
    target = str(home / ".local/state/wisp/approvals/x.decision")
    assert _decide(paths, "", tool=tool, **{key: target})
    assert _decide(paths, "", tool=tool, **{key: "~/.local/state/wisp/approvals/x.json"})


def test_file_tools_elsewhere_and_content_mentions_pass(paths, home):
    assert _decide(paths, "", tool="Write", file_path=str(home / "notes.md"),
                   content="the approvals live in ~/.local/state/wisp/approvals") is None
    assert _decide(paths, "", tool="Read", file_path=str(home / ".local/state/wisp/other.json")) is None


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
