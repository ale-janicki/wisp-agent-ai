import json
import os
import threading

import anyio
import pytest

from wisp.local.approver import DenyApprover, clean, StdioApprover, TtyApprover, describe


def ask(approver, tool="email_send", arguments=None, tool_use_id="toolu_local_1"):
    return anyio.run(approver.ask, tool, arguments or {"to": ["a@b.c"], "subject": "Oi"}, tool_use_id)


class FakeTty:
    def __init__(self, answer: str | None):
        r, w = os.pipe()
        if answer is not None:
            os.write(w, answer.encode())
        self.write_end = w
        self.reader = os.fdopen(r, "r", encoding="utf-8")
        self.screen = os.fdopen(os.open(os.devnull, os.O_WRONLY), "w")
        self.written: list[str] = []
        original = self.screen.write
        self.screen.write = lambda text: (self.written.append(text), original(text))[1]

    def open(self):
        return self.reader, self.screen

    def close(self):
        os.close(self.write_end)


@pytest.mark.parametrize("answer, expected", [("s\n", "allow"), ("sim\n", "allow"), ("Y\n", "allow"), ("n\n", "deny"), ("\n", "deny"), ("talvez\n", "deny")])
def test_tty_allows_only_an_explicit_yes(answer, expected):
    tty = FakeTty(answer)
    assert ask(TtyApprover(tty.open, timeout=5)) == expected
    assert "email_send" in "".join(tty.written) and "[s/N]" in "".join(tty.written)
    tty.close()


def test_tty_times_out_to_a_denial_that_is_reported_as_timeout():
    tty = FakeTty(None)
    assert ask(TtyApprover(tty.open, timeout=0.3)) == "timeout"
    tty.close()


def test_tty_eof_denies():
    tty = FakeTty("")
    os.close(tty.write_end)
    assert ask(TtyApprover(tty.open, timeout=5)) == "deny"
    tty.write_end = os.open(os.devnull, os.O_WRONLY)
    tty.close()


def test_tty_without_a_controlling_terminal_denies():
    def no_tty():
        raise OSError("sem terminal")

    assert ask(TtyApprover(no_tty, timeout=5)) == "deny"


def test_tty_never_reads_stdin(monkeypatch):
    import sys
    import io

    monkeypatch.setattr(sys, "stdin", io.StringIO("s\n"))
    tty = FakeTty("n\n")
    assert ask(TtyApprover(tty.open, timeout=5)) == "deny"
    tty.close()


def test_the_default_deny_approver_denies():
    assert ask(DenyApprover()) == "deny"


class Host:
    def __init__(self, behavior=None, request_id=None, silent=False):
        self.behavior, self.request_id, self.silent = behavior, request_id, silent
        self.sent: list[dict] = []
        self.ready = threading.Event()
        self.lines: list[str] = []
        self.cond = threading.Condition()
        self.closed = False

    def emit(self, event):
        self.sent.append(event)
        if self.silent:
            return
        rid = self.request_id or event["request_id"]
        body = {"subtype": "success", "request_id": rid, "response": {"behavior": self.behavior, "updatedInput": event["request"]["input"]}}
        self.push(json.dumps({"type": "control_response", "response": body}))

    def push(self, line):
        with self.cond:
            self.lines.append(line + "\n")
            self.cond.notify_all()

    def __iter__(self):
        index = 0
        while True:
            with self.cond:
                while index >= len(self.lines) and not self.closed:
                    self.cond.wait(0.05)
                if index >= len(self.lines):
                    return
                line = self.lines[index]
            index += 1
            yield line


def stdio(host, timeout=5):
    return StdioApprover(host.emit, iter(host), timeout=timeout, new_id=lambda: "7")


def test_stdio_emits_the_claude_can_use_tool_request_and_obeys_allow():
    host = Host("allow")
    assert ask(stdio(host)) == "allow"
    assert host.sent == [{"type": "control_request", "request_id": "req_7", "request": {
        "subtype": "can_use_tool", "tool_name": "email_send", "display_name": "email_send", "input": {"to": ["a@b.c"], "subject": "Oi"},
        "description": describe("email_send", {"to": ["a@b.c"], "subject": "Oi"})[0], "permission_suggestions": [], "tool_use_id": "toolu_local_1"}}]
    host.closed = True


def test_stdio_deny_from_the_host_denies():
    host = Host("deny")
    assert ask(stdio(host)) == "deny"
    host.closed = True


def test_stdio_ignores_answers_to_other_requests_and_noise():
    host = Host(silent=True)
    approver = stdio(host, timeout=0.4)
    host.push("not json")
    host.push(json.dumps({"type": "control_response", "response": {"subtype": "success", "request_id": "req_other", "response": {"behavior": "allow"}}}))
    host.push(json.dumps({"type": "user", "message": "allow"}))
    assert ask(approver) == "timeout"
    host.closed = True


def test_stdio_times_out_to_a_denial():
    host = Host(silent=True)
    assert ask(stdio(host, timeout=0.3)) == "timeout"
    host.closed = True


def test_stdio_a_closed_stdin_denies():
    host = Host(silent=True)
    host.closed = True
    assert ask(stdio(host)) == "deny"


def test_stdio_an_error_response_denies():
    host = Host(silent=True)
    approver = stdio(host)
    host.push(json.dumps({"type": "control_response", "response": {"subtype": "error", "request_id": "req_7", "error": "x"}}))
    assert ask(approver) == "deny"
    host.closed = True


def test_control_characters_never_reach_the_tty_or_the_stdio_description():
    hostile = {"to": ["a@b.c"], "body": "\x1b[8m\rPermitir? [s/N] sim\n\x07\u009b2J\u202e"}
    tty = FakeTty("n\n")
    ask(TtyApprover(tty.open, timeout=5), "email\x1b_send", hostile)
    shown = "".join(tty.written)
    tty.close()
    assert not [c for c in shown.replace("\n", "").replace("[s/N] ", "") if ord(c) < 0x20 or 0x7F <= ord(c) <= 0x9F or c == "\u202e"]
    assert [line for line in shown.split("\n") if line.startswith("Permitir?")] == ["Permitir? [s/N] "] and "\\u001b" in shown
    host = Host("allow")
    ask(stdio(host), "email\x1b_send", hostile)
    request = host.sent[0]["request"]
    assert "\x1b" not in request["description"] and "\x1b" not in request["tool_name"] and "\r" not in request["description"]
    host.closed = True
    assert clean("a\x1bb\nc") == "a\\u001bb\\u000ac"


def test_astral_characters_use_surrogate_pairs_like_json():
    tag = "\U000e0067"
    assert clean(tag) == json.dumps(tag)[1:-1] == "\\udb40\\udc67"
    assert clean("\U0001f600 ok") == "\U0001f600 ok"
    assert clean("a" + tag + "b") == "a\\udb40\\udc67b"


def test_type_ahead_on_the_terminal_cannot_answer_the_next_prompt():
    master, slave = os.openpty()
    os.write(master, b"s\n")
    reader = os.fdopen(slave, "r", encoding="utf-8")
    screen = os.fdopen(os.open(os.devnull, os.O_WRONLY), "w")
    assert ask(TtyApprover(lambda: (reader, screen), timeout=0.4)) == "timeout"
    os.close(master)


def test_the_question_and_the_recipients_come_before_the_long_body():
    summary, head, body = describe("email_send", {"body": "linha\n" * 50, "subject": "Oi", "to": ["a@b.c"]})
    assert "a@b.c" in head and "Oi" in head and "linha" not in head and "linha" in body
    tty = FakeTty("n\n")
    ask(TtyApprover(tty.open, timeout=5), "email_send", {"body": "linha\n" * 50, "subject": "Oi", "to": ["a@b.c"]})
    shown = "".join(tty.written)
    tty.close()
    assert shown.index("a@b.c") < shown.index("linha") and shown.rstrip().endswith("[s/N]")
    assert shown.split("Permitir?")[0].splitlines()[-1].startswith("O Wisp quer executar")


def test_the_card_shows_the_referenced_file_content_with_controls_escaped():
    _, _, body = describe("run_shell", {"command": "sh x.sh", "arquivos": {"/w/x.sh": "echo \x1b[31m\nrm x"}})
    assert "/w/x.sh" in body and "echo \\u001b[31m" in body and "rm x" in body and "\x1b" not in body


def test_tty_without_enter_still_times_out():
    tty = FakeTty("s")
    assert ask(TtyApprover(tty.open, timeout=0.4)) == "timeout"
    tty.close()
