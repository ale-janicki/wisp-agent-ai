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


def test_osascript_target_that_is_not_a_readable_file_is_blocked_and_a_missing_one_is_not(paths, tmp_path):
    assert _decide(paths, "osascript .")
    assert _decide(paths, "osascript missing-file", cwd=tmp_path) is None
    locked = tmp_path / "locked"
    locked.write_text("beep")
    locked.chmod(0)
    try:
        assert _decide(paths, "osascript locked", cwd=tmp_path)
    finally:
        locked.chmod(0o600)


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
    assert _decide(paths, "python3 missing.py", cwd=tmp_path) is None
    big = tmp_path / "big.sh"
    big.write_text("#" * 1_000_001)
    assert _decide(paths, f"bash {big}")


def test_mcp_must_be_a_whole_word_after_wisp(paths):
    assert _decide(paths, "wisp mcp-list") is None
    assert _decide(paths, "wisp mcp") is not None
    assert _decide(paths, "wisp mcp email") is not None
    assert _decide(paths, "ls && wisp mcp") is not None


@pytest.mark.parametrize(
    "command",
    [
        "brew install node yarn",
        "echo python3 nonexist",
        "ls /usr/bin/python3 nofile",
        "which -a python3 foo",
        "apt install python3 python3-pip",
        "command -v python3 foo",
    ],
)
def test_an_interpreter_name_outside_command_position_is_not_a_command(paths, tmp_path, command):
    assert _decide(paths, command, cwd=tmp_path) is None


@pytest.mark.parametrize(
    "prefix",
    ["", "cd /tmp && ", "true; ", "false || ", "ls | ", "(", "\n", "env FOO=1 ", "sudo -u root ", "exec ", "nohup ", "timeout 5 ", "xargs ", "command ", "time ", "FOO=1 "],
)
def test_an_interpreter_in_command_position_or_after_a_wrapper_reads_its_file(paths, tmp_path, prefix):
    (tmp_path / "srv.py").write_text(SERVER_SCRIPT)
    assert (_decide(paths, f"{prefix}python3 srv.py", cwd=tmp_path) or "").startswith("wisp-guard:")


@pytest.mark.parametrize("command", ["bash -lc 'ls'", "zsh -lc 'ls'", "sh -ec 'ls'", "bash -ic 'ls'", "perl -le 'print 1'", "ruby -ne 'p 1'", "node -pe '1'", "osascript -e 'beep'"])
def test_a_short_flag_cluster_with_c_or_e_is_inline_code_and_reads_no_file(paths, tmp_path, command):
    assert _decide(paths, command, cwd=tmp_path) is None


@pytest.mark.parametrize("command", ["bash -lc 'wisp mcp email'", "sh -ec 'wisp mcp'", "bash -ic 'echo $WISP_APPROVAL_SOCKET'"])
def test_inline_text_of_a_flag_cluster_is_still_checked(paths, command):
    assert (_decide(paths, command) or "").startswith("wisp-guard:")


@pytest.mark.parametrize("command", ["cat runme | python3", "cat runme | python3 -", "python3 < runme", "python3 - < runme", "uv run runme", "uv run python runme", "uv run --with x python runme", "cat runme | sudo bash"])
def test_a_poc_in_an_extensionless_file_is_read_through_stdin_and_uv(paths, tmp_path, command):
    (tmp_path / "runme").write_text(SERVER_SCRIPT)
    assert (_decide(paths, command, cwd=tmp_path) or "").startswith("wisp-guard:")


def test_a_harmless_extensionless_file_through_stdin_and_uv_passes(paths, tmp_path):
    (tmp_path / "runme").write_text("print(1)\n")
    for command in ["cat runme | python3", "python3 < runme", "uv run runme", "uv run python runme", "cat runme | grep x"]:
        assert _decide(paths, command, cwd=tmp_path) is None


@pytest.mark.parametrize(
    "command",
    [
        "# run it\npython3 runme",
        "echo a#b; python3 runme",
        "echo hi # don't\npython3 runme",
        "# x\ncat runme | python3",
        "echo ok\n# c\nuv run runme",
    ],
)
def test_a_hash_never_hides_a_later_line(paths, tmp_path, command):
    (tmp_path / "runme").write_text(SERVER_SCRIPT)
    assert (_decide(paths, command, cwd=tmp_path) or "").startswith("wisp-guard:")


@pytest.mark.parametrize(
    "command",
    [
        "python3 -I runme",
        "python3 -E runme",
        "python3 -W ignore runme",
        "python3 -X dev runme",
        "python3 -Wignore runme",
        "python3 -B -u runme",
        "node -r pkg runme",
        "perl -I lib runme",
        "ruby -I lib -r json runme",
        "bash +x runme",
        "bash -o pipefail runme",
        "osascript -l JavaScript runme",
    ],
)
def test_each_interpreter_has_its_own_flag_tables(paths, tmp_path, command):
    (tmp_path / "runme").write_text(SERVER_SCRIPT)
    assert (_decide(paths, command, cwd=tmp_path) or "").startswith("wisp-guard:")


@pytest.mark.parametrize("command", ["python3 -m runme", "python3 -mrunme", "python3 -Im runme", "python3 -m pkg.runme"])
def test_a_python_module_is_resolved_in_the_cwd(paths, tmp_path, command):
    (tmp_path / "runme.py").write_text(SERVER_SCRIPT)
    package = tmp_path / "pkg" / "runme"
    package.mkdir(parents=True)
    (package / "__main__.py").write_text(SERVER_SCRIPT)
    assert (_decide(paths, command, cwd=tmp_path) or "").startswith("wisp-guard:")


def test_a_python_package_main_is_read_and_a_harmless_module_passes(paths, tmp_path):
    package = tmp_path / "runme"
    package.mkdir()
    (package / "__main__.py").write_text(SERVER_SCRIPT)
    assert _decide(paths, "python3 -m runme", cwd=tmp_path)
    (package / "__main__.py").write_text("print(1)\n")
    assert _decide(paths, "python3 -m runme", cwd=tmp_path) is None
    assert _decide(paths, "python3 -m missing", cwd=tmp_path) is None


@pytest.mark.parametrize("command", ["python3 -c 'print(1)'", "python3 -Ic 'print(1)'", "python3 -cprint(1)", "node -e '1'", "perl -Mstrict -e 1", "ruby -I lib -e 1"])
def test_inline_code_still_reads_no_file(paths, tmp_path, command):
    (tmp_path / "runme").write_text(SERVER_SCRIPT)
    assert _decide(paths, command + " runme", cwd=tmp_path) is None


HELPER_CALLS = [
    '"/Applications/Wisp.app/Contents/Helpers/wisp-mac" clicar --titulo Enviar --app Mail',
    "~/Applications/Wisp.app/Contents/Helpers/wisp-mac clicar --regex send",
    '"$WISP_MAC_BIN" tecla cmd+return',
    '${WISP_MAC_BIN} digitar "oi"',
    "WISP_MAC_BIN=/x/wisp-mac; $WISP_MAC_BIN menu 'Mensagem > Enviar'",
    "wisp-mac --app Mail clicar --titulo Send",
    "wisp-mac foco",
    "wisp-mac selftest",
    "cat > /tmp/a.sh <<'EOS'\n/x/wisp-mac clicar --titulo Enviar\nEOS\nbash /tmp/a.sh",
    "cd /Applications/Wisp.app/Contents/Helpers && ./wisp-mac clicar --titulo Enviar",
    "cd ~/Applications/Wisp.app/Contents/Helpers/ ; ./anything tecla return",
    "pushd /Applications/Wisp.app/Contents/Helpers && ./w arvore",
    "/Applications/Wisp.app/Contents/Hel*/wisp-mac clicar",
    "/Applications/Wisp.app/Contents/Helpers/wisp-m?c clicar",
    "/Applications/Wisp.app/Contents/*/wisp-mac clicar",
    "H=/Applications/Wisp.app/Contents; $H/Helpers/wisp-mac clicar",
    "A=/Applications/Wisp.app/Contents/Helpers; $A/wisp-mac clicar",
    "A=/Applications/Wisp.app/Contents/Helpers; ${A}/wisp-mac clicar",
    "P=/Applications/Wisp.app/Contents/Helpers/wisp-mac; $P clicar",
    "$A$B clicar --titulo Send",
    "$HOME/Applications/Wisp.app/Contents/Helpers/wisp-mac tecla return",
    "bash -c '/Applications/Wisp.app/Contents/Helpers/wisp-mac tecla return'",
    "env FOO=1 /Applications/Wisp.app/Contents/Helpers/wisp-mac clicar",
    "sudo /x/wisp-mac clicar",
    "ls && /x/wisp-mac clicar",
    '/x/Hel"pers/wisp-m"ac clicar',
]

HELPER_ALLOWED = [
    "wisp mac clicar --titulo OK",
    "wisp mac arvore",
    '"$WISP_BIN" mac arvore',
    '"$WISP_BIN" topic enviar --thread=1 /tmp/x',
    '"$WISP_AGENDA_BIN" permissao',
    "cd ~/repos/pessoal/wisp-mac && git log --oneline | grep menu",
    "ls ~/repos/pessoal/wisp-mac/app/MacControl",
    "ls /Applications/Wisp.app/Contents/Helpers/wisp-mac",
    "codesign -dvv /Applications/Wisp.app/Contents/Helpers/wisp-mac",
    "ls /tmp/*.log",
]


@pytest.mark.parametrize("command", HELPER_CALLS)
def test_calling_the_mac_helper_in_any_form_is_blocked(paths, command):
    assert "wisp-mac helper" in (_decide(paths, command) or "")


@pytest.mark.parametrize("command", HELPER_ALLOWED)
def test_ordinary_commands_and_wisp_mac_are_allowed(paths, command):
    assert _decide(paths, command) is None


def test_the_mac_mcp_server_cannot_be_started_by_hand(paths):
    assert "starting the email server" in (_decide(paths, "wisp mcp mac") or "")


UI_INLINE = [
    '''osascript -e 'tell application "System Events" to keystroke return' ''',
    '''osascript -e 'tell application "System Events" to key code 36' ''',
    '''osascript -e 'tell application "System Events" to click button "Send" of window 1' ''',
    '''osascript -e 'tell application "System Events"' -e 'keystroke "d" using {command down, shift down}' -e 'end tell' ''',
    '''osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); $.CGEventPost(0, 0)' ''',
    '''osascript -l JavaScript -e "ObjC.import('Cocoa')"''',
    '''osascript -l JavaScript -e 'Application("System Events").keyCode(36)' ''',
    '''/usr/bin/osascript -e 'TELL APPLICATION "SYSTEM EVENTS" TO CLICK BUTTON 1' ''',
    '''env osascript -e 'tell application "System Events" to keystroke "x"' ''',
    '''bash -c "osascript -e 'tell application \\"System Events\\" to keystroke return'"''',
    "osascript <<EOF\ntell application \"System Events\"\nkey code 36\nend tell\nEOF",
]
UI_SPLIT = '''osascript -e 'tell application "Sys"&"tem Events" to click button 1' '''


@pytest.mark.parametrize("command", UI_INLINE)
def test_osascript_driving_system_events_or_cgevent_inline_is_blocked(paths, command):
    assert "driving the screen" in (_decide(paths, command) or "")


def test_the_ui_detection_is_best_effort_and_a_split_application_name_gets_through(paths):
    assert _decide(paths, UI_SPLIT) is None


UI_SCRIPT_TEXT = 'tell application "System Events"\nkeystroke return\nend tell\n'
JXA_TEXT = 'ObjC.import("CoreGraphics");\n$.CGEventCreateKeyboardEvent(null, 36, true);\n'


@pytest.mark.parametrize("make", [
    lambda f: f"osascript {f}",
    lambda f: f"osascript < {f}",
    lambda f: f"cat {f} | osascript",
    lambda f: f"cat {f} | osascript -",
    lambda f: f"osascript -l JavaScript {f}",
    lambda f: f"cd /tmp && osascript {f}",
    lambda f: f"env osascript {f}",
])
@pytest.mark.parametrize("name,text", [("a.applescript", UI_SCRIPT_TEXT), ("b.scpt", JXA_TEXT), ("c.js", JXA_TEXT)])
def test_osascript_reading_a_ui_script_from_a_file_or_stdin_is_blocked(paths, home, make, name, text):
    (home / name).write_text(text)
    assert "driving the screen" in (_decide(paths, make(str(home / name))) or "")


@pytest.mark.parametrize("command", [
    "grep -rn 'System Events' docs",
    "echo osascript System Events keystroke",
    "git log --grep 'CGEvent'",
    '''osascript -e 'tell application "Finder" to get name of home' ''',
    '''osascript -e 'display dialog "oi"' ''',
])
def test_the_ui_detection_needs_osascript_in_command_position(paths, command):
    assert _decide(paths, command) is None


def test_a_harmless_script_file_is_allowed(paths, home):
    (home / "ok.applescript").write_text('tell application "Finder" to get name of home\n')
    assert _decide(paths, f"osascript {home / 'ok.applescript'}") is None
    assert _decide(paths, f"cat {home / 'ok.applescript'} | osascript") is None


def test_the_script_checker_of_the_mac_tools_can_skip_the_ui_rule(paths):
    payload = {"tool_name": "Bash", "tool_input": {"command": '''osascript -e 'tell application "System Events" to keystroke "a"' '''}, "cwd": str(paths.home)}
    assert hook_guard_outbound(payload, paths) is not None
    assert hook_guard_outbound(payload, paths, ui_scripts=False) is None
