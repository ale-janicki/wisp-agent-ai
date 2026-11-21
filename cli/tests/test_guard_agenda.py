import io
import json
from pathlib import Path

import pytest

from wisp.cli import main
from wisp.guard_agenda import hook_guard_agenda


HOME = Path("/home/u")
ENV = {"WISP_BIN": "/venv/bin/wisp"}


def _kind(command, tool="Bash"):
    decision = hook_guard_agenda({"tool_name": tool, "tool_input": {"command": command}}, env=ENV, home=HOME)
    return decision["hookSpecificOutput"]["permissionDecision"] if decision else None


ALLOWED = [
    '"$WISP_BIN" agenda eventos --hoje',
    '"$WISP_BIN" agenda eventos --semana --calendario "Trabalho Pessoal"',
    "$WISP_BIN agenda eventos --hoje",
    '"${WISP_BIN}" agenda eventos --hoje',
    '"$WISP_BIN" agenda eventos --de 2026-11-20 --ate 2026-11-27',
    '"$WISP_BIN" agenda lembretes --pendentes',
    '"$WISP_BIN" agenda calendarios',
    '"$WISP_BIN" agenda permissao',
    '"$WISP_AGENDA_BIN" eventos --hoje',
    "~/.local/bin/wisp agenda eventos --hoje",
    "/home/u/.local/bin/wisp agenda eventos --hoje",
    "/venv/bin/wisp agenda eventos --hoje",
    "/Applications/Wisp.app/Contents/Helpers/wisp-agenda eventos --hoje",
    "~/Applications/Wisp.app/Contents/Helpers/wisp-agenda lembretes",
]
ASKED = [
    '"$WISP_BIN" agenda criar-evento --titulo X --inicio 2026-11-20T10:00 --fim 2026-11-20T11:00',
    '"$WISP_BIN" agenda editar-evento abc --titulo Y',
    '"$WISP_BIN" agenda apagar-evento abc',
    '"$WISP_BIN" agenda apagar-evento abc --serie --confirmo',
    '"$WISP_BIN" agenda criar-lembrete --titulo X',
    '"$WISP_BIN" agenda concluir-lembrete abc',
    '"$WISP_AGENDA_BIN" apagar-evento abc',
    "/Applications/Wisp.app/Contents/Helpers/wisp-agenda apagar-evento abc",
    "/tmp/x/wisp agenda eventos",
    "./wisp agenda eventos",
    "mywisp agenda eventos",
    "/tmp/wisp-agenda eventos",
    "./wisp-agenda eventos --hoje",
    "wisp agenda eventos --semana",
    "/tmp/Wisp.app/Contents/Helpers/wisp-agenda eventos",
    '"~/.local/bin/wisp" agenda eventos',
    'X=1 "$WISP_BIN" agenda eventos',
    '"$WISP_BIN" agenda eventos --calendario *',
    '"$WISP_BIN" agenda eventos {a,b}',
    'wisp ag""enda eventos',
    'a=ag; wisp ${a}enda eventos',
    '"$WISP_BIN" a* apagar-evento abc',
    '"$WISP_BIN" "a"genda apagar-evento abc',
    '"$WISP_AGENDA_BIN" ap*',
    'eval "$WISP_BIN agenda apagar-evento abc"',
    'eval $WISP_BIN agenda apagar-evento abc',
    '"$WISP_BIN" ${SUB} abc',
    '"$WISP_BIN" agenda "apagar-""evento" abc',
    '"$WISP_BIN" agenda eventos --hoje; "$WISP_BIN" agenda apagar-evento abc',
    '"$WISP_BIN" agenda eventos --hoje && echo ok',
    '"$WISP_BIN" agenda eventos --hoje | cat',
    '"$WISP_BIN" agenda $(echo apagar-evento) abc',
    'S=apagar-evento; "$WISP_BIN" agenda $S abc',
    '"$WISP_BIN" agenda permissao --pedir',
    '"$WISP_BIN" agenda',
    '"$WISP_BIN" agenda desconhecido',
    'echo x; wisp agenda eventos',
]
UNRELATED = [
    "ls -la",
    "cat agenda.md",
    "grep -r agendamento .",
    "git status",
    '"$WISP_BIN" topic enviar --thread="$WISP_TOPIC_THREAD" /tmp/a.pdf',
    "cat wisp.md",
]


@pytest.mark.parametrize("command", ALLOWED)
def test_read_only_agenda_commands_are_auto_allowed(command):
    assert _kind(command) == "allow"


@pytest.mark.parametrize("command", ASKED)
def test_every_other_agenda_command_asks_the_user(command):
    assert _kind(command) == "ask"


@pytest.mark.parametrize("command", UNRELATED)
def test_other_commands_are_left_to_the_normal_flow(command):
    assert _kind(command) is None


def test_only_the_shell_tool_is_judged():
    assert _kind('"$WISP_BIN" agenda apagar-evento abc', tool="Read") is None
    assert hook_guard_agenda({"tool_name": "Bash", "tool_input": "x"}) is None


def test_cli_prints_the_decision_and_exits_0(monkeypatch, capsys):
    payload = {"tool_name": "Bash", "tool_input": {"command": '"$WISP_BIN" agenda apagar-evento abc'}}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    assert main(["hook", "guard-agenda"]) == 0
    out = json.loads(capsys.readouterr().out)["hookSpecificOutput"]
    assert (out["hookEventName"], out["permissionDecision"]) == ("PreToolUse", "ask")
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"}})))
    assert main(["hook", "guard-agenda"]) == 0
    assert capsys.readouterr().out == ""


def test_cli_fails_closed_on_unreadable_input(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert main(["hook", "guard-agenda"]) == 2
