import asyncio
import json
import os
import signal
import subprocess
import sys
import time

import anyio
import pytest

from wisp import approvals

from wisp.email.mail_app import MailError, MailSummary
from wisp.email.server import ToolFailure, build_server, email_list, email_read, email_search, email_send
from wisp.paths import WispPaths

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


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _send(home, mail, outcome, thread=None, calls=None):
    async def request(paths, tool, summary, detail, *, thread=None, act=None):
        (calls if calls is not None else []).append((tool, summary, detail, thread))
        if outcome == "allow":
            await act()
        return outcome

    return asyncio.run(email_send(mail, request, _paths(home), ["a@b.c"], "Teste", "corpo", ["d@e.f"], thread=thread))


def test_send_waits_for_allow(fake_home):
    mail, calls = FakeMail(), []
    assert _send(fake_home, mail, "allow", 7, calls) == "enviado"
    assert mail.sent == [(["a@b.c"], "Teste", "corpo", ["d@e.f"])]
    tool, summary, detail, thread = calls[0]
    assert (tool, summary, thread) == ("email_send", "enviar e-mail para a@b.c: Teste", 7)
    assert "a@b.c" in detail and "d@e.f" in detail and "corpo" in detail


def test_send_denied_never_sends(fake_home):
    mail = FakeMail()
    assert _send(fake_home, mail, "deny") == "o usuário negou o envio"
    assert mail.sent == []


def test_send_timeout(fake_home):
    mail = FakeMail()
    assert _send(fake_home, mail, "timeout") == "não enviado: ninguém aprovou"
    assert mail.sent == []


def test_approval_dir_error_never_sends(fake_home):
    from wisp.approvals import ApprovalDirError

    async def request(*a, **k):
        raise ApprovalDirError("symlink")

    mail = FakeMail()
    with pytest.raises(ToolFailure, match="não enviado"):
        asyncio.run(email_send(mail, request, _paths(fake_home), ["a@b.c"], "s", "b"))
    assert mail.sent == []


def test_read_tools_need_no_approval():
    mail = FakeMail()
    assert email_list(mail)[0]["subject"] == "Oi"
    assert email_read(mail, ROW.id)["subject"] == "Oi"
    assert email_search(mail, "oi")[0]["id"] == ROW.id


def test_mail_error_is_tool_text():
    with pytest.raises(ToolFailure, match="o Mail não respondeu"):
        email_list(FakeMail(MailError("o Mail não respondeu em 30 s")))


def test_server_exposes_tools_and_flags_error():
    async def allow(*a, **k):
        return "allow"

    server = build_server(FakeMail(MailError("falhou")), allow, None, thread=None)
    names = {t.name for t in asyncio.run(server.list_tools())}
    assert names == {"email_list", "email_read", "email_search", "email_send"}
    result = asyncio.run(server.call_tool("email_list", {}))
    assert result.is_error is True and result.content[0].text == "falhou"


def test_cancelled_send_withdraws_the_request(fake_home):
    paths, mail = _paths(fake_home), FakeMail()
    directory = paths.state / "approvals"

    async def go():
        with anyio.move_on_after(0.3):
            await email_send(mail, approvals.request_async, paths, ["a@b.c"], "s", "b")
        return "cancelled"

    async def watch():
        async with anyio.create_task_group() as tg:
            seen = []

            async def probe():
                for _ in range(100):
                    if list(directory.glob("*.json")):
                        seen.append(True)
                        return
                    await anyio.sleep(0.01)

            tg.start_soon(probe)
            result = await go()
        return result, seen

    result, seen = anyio.run(watch)
    assert result == "cancelled" and seen == [True]
    assert [f for f in directory.iterdir() if f.suffix != ".done"] == []
    assert mail.sent == []


SERVER = """
import sys
from wisp.email.server import build_server
from wisp.approvals import request_async
from wisp.paths import WispPaths
class Mail:
    def send(self, *a):
        raise SystemExit("sent")
build_server(Mail(), request_async, WispPaths.current(), None).run("stdio")
"""


def _rpc(id, method, params=None):
    msg = {"jsonrpc": "2.0", "method": method, **({"id": id} if id is not None else {}), "params": params or {}}
    return (json.dumps(msg) + "\n").encode()


def test_server_exits_and_withdraws_when_stdin_closes(fake_home):
    directory = _paths(fake_home).state / "approvals"
    proc = subprocess.Popen([sys.executable, "-c", SERVER], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True, env=dict(os.environ))
    try:
        init = {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}
        proc.stdin.write(_rpc(1, "initialize", init) + _rpc(None, "notifications/initialized"))
        proc.stdin.write(_rpc(2, "tools/call", {"name": "email_send", "arguments": {"to": ["a@b.c"], "subject": "s", "body": "b"}}))
        proc.stdin.flush()
        deadline = time.monotonic() + 15
        while not list(directory.glob("*.json")) and time.monotonic() < deadline:
            time.sleep(0.05)
        assert list(directory.glob("*.json")), "the request never appeared"
        proc.stdin.close()
        proc.wait(timeout=10)
        assert [f for f in directory.iterdir() if f.suffix != ".done"] == []
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()


def test_failed_send_leaves_a_failed_tombstone(fake_home):
    paths = _paths(fake_home)

    def decide_soon():
        for _ in range(200):
            time.sleep(0.01)
            ids = [p.stem for p in (paths.state / "approvals").glob("*.json")] if (paths.state / "approvals").is_dir() else []
            if ids and approvals.decide(paths, ids[0], True):
                return

    import threading
    t = threading.Thread(target=decide_soon)
    t.start()
    mail = FakeMail(error=None)
    mail.send = lambda *a, **k: (_ for _ in ()).throw(MailError("o Mail recusou"))

    async def go():
        return await email_send(mail, lambda *a, **k: approvals.request_async(*a, poll=0.01, **k), paths, ["a@b.c"], "s", "b")

    with pytest.raises(ToolFailure, match="o Mail recusou"):
        asyncio.run(go())
    t.join()
    files = list((paths.state / "approvals").iterdir())
    assert [f.suffix for f in files] == [".done"]
    assert json.loads(files[0].read_text())["outcome"] == "failed"
