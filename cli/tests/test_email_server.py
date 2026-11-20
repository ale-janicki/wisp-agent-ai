import asyncio
import json
import os
import subprocess
import sys

import pytest

from wisp.email.mail_app import MailError, MailSummary
from wisp.email.server import ToolFailure, build_server, email_list, email_read, email_search, email_send

ROW = MailSummary('["a",["INBOX"],1]', "a", "INBOX", "x@y.z", "Oi", "2026-01-01T00:00:00Z", True)


class FakeMail:
    def __init__(self, error=None):
        self.sent = []
        self.error = error

    def list(self, mailbox="INBOX", limit=20):
        if self.error:
            raise self.error
        return [ROW]

    def read(self, message_id):
        return ROW

    def search(self, query, limit=20):
        return [ROW]

    def send(self, to, subject, body, cc=[]):
        self.sent.append((to, subject, body, cc))


def _send(mail, to=("a@b.c",)):
    return email_send(mail, list(to), "Teste", "corpo", ["d@e.f"])


def test_send_goes_straight_to_mail():
    mail = FakeMail()
    assert _send(mail) == "enviado"
    assert mail.sent == [(["a@b.c"], "Teste", "corpo", ["d@e.f"])]


@pytest.mark.parametrize("to", [["a@b.c, x@y.z"], ["a@b.c;x@y.z"], ["Ana <a@b.c>"], ["a@b.c\nbcc: x@y.z"], []])
def test_bad_recipients_never_reach_mail(to):
    mail = FakeMail()
    with pytest.raises(ToolFailure):
        _send(mail, to)
    assert mail.sent == []


def test_mail_failure_is_tool_text():
    mail = FakeMail()
    mail.send = lambda *a, **k: (_ for _ in ()).throw(MailError("o Mail recusou"))
    with pytest.raises(ToolFailure, match="o Mail recusou"):
        _send(mail)


def test_read_tools_need_no_approval():
    mail = FakeMail()
    assert email_list(mail)[0]["subject"] == "Oi"
    assert email_read(mail, ROW.id)["subject"] == "Oi"
    assert email_search(mail, "oi")[0]["id"] == ROW.id


def test_mail_error_is_tool_text():
    with pytest.raises(ToolFailure, match="o Mail não respondeu"):
        email_list(FakeMail(MailError("o Mail não respondeu em 30 s")))


def test_server_exposes_tools_and_flags_error():
    server = build_server(FakeMail(MailError("falhou")))
    names = {t.name for t in asyncio.run(server.list_tools())}
    assert names == {"email_list", "email_read", "email_search", "email_send"}
    result = asyncio.run(server.call_tool("email_list", {}))
    assert result.is_error is True and result.content[0].text == "falhou"


SERVER = """
from wisp.email.server import build_server
class Mail:
    def send(self, *a):
        import sys; print("SENT", file=sys.stderr, flush=True)
build_server(Mail()).run("stdio")
"""


def _rpc(id, method, params=None):
    msg = {"jsonrpc": "2.0", "method": method, **({"id": id} if id is not None else {}), "params": params or {}}
    return (json.dumps(msg) + "\n").encode()


def test_send_never_touches_the_approvals_folder(fake_home):
    """Over real stdio: the call returns and the mail goes out with no approvals folder created or read."""
    state = fake_home / ".local/state/wisp"
    init = {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}
    call = {"name": "email_send", "arguments": {"to": ["a@b.c"], "subject": "s", "body": "b"}}
    stdin = _rpc(1, "initialize", init) + _rpc(None, "notifications/initialized") + _rpc(2, "tools/call", call)
    done = subprocess.run([sys.executable, "-c", SERVER], input=stdin, capture_output=True, timeout=30,
                          env={**os.environ, "HOME": str(fake_home)}, start_new_session=True)
    assert b"SENT" in done.stderr
    assert not (state / "approvals").exists()
