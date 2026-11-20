import asyncio
import json
import os
import shutil
import socket
import tempfile
import threading
from pathlib import Path

import pytest

from wisp import send_gate as gate
from wisp.send_gate import Refused, ask_broker, gate_from_env
from wisp.email.server import ToolFailure, build_server, email_send

CONTRACT = json.loads((Path(__file__).parent / "fixtures/contract/approval-broker.json").read_text("utf-8"))
REQUEST = CONTRACT["request"]["input"]


class FakeHost:
    """A host that answers with whatever bytes it is told to, and records what the client sent."""

    def __init__(self, reply: bytes | None, delay: float = 0):
        self.folder = tempfile.mkdtemp(prefix="g-", dir="/tmp")
        self.path = os.path.join(self.folder, "b")
        self.reply, self.delay, self.received = reply, delay, []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        os.chmod(self.path, 0o600)
        self.listener.listen(4)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            with conn:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                self.received.append(data)
                if self.delay:
                    threading.Event().wait(self.delay)
                if self.reply is not None:
                    try:
                        conn.sendall(self.reply)
                    except OSError:
                        pass

    def close(self):
        self.listener.close()
        shutil.rmtree(self.folder, ignore_errors=True)


@pytest.fixture
def host():
    made = []

    def make(reply, delay=0):
        h = FakeHost(reply, delay)
        made.append(h)
        return h
    yield make
    for h in made:
        h.close()


def reply(msg) -> bytes:
    return json.dumps(msg).encode() + b"\n"


def test_contract_names_match_the_code():
    assert (gate.GATE_ENV, gate.BROKER, gate.SOCKET_ENV) == (CONTRACT["gate_env"], CONTRACT["gate_value"], CONTRACT["socket_env"])
    assert gate.OP_REQUEST == CONTRACT["request"]["op"] and gate.TOOL == CONTRACT["request"]["tool"]


def test_approve_returns_and_the_only_thing_sent_is_one_request_with_the_whole_mail(host):
    h = host(reply(CONTRACT["allow"]))
    ask_broker(h.path, REQUEST, 5)
    assert [json.loads(r) for r in h.received] == [CONTRACT["request"]]


def test_deny_raises_with_the_host_text_or_a_default(host):
    with pytest.raises(Refused, match="O usuário negou o envio."):
        ask_broker(host(reply(CONTRACT["deny"])).path, REQUEST, 5)
    with pytest.raises(Refused, match="não enviei"):
        ask_broker(host(reply({"decision": "deny"})).path, REQUEST, 5)


def test_timeout_refuses(host):
    with pytest.raises(Refused, match="ninguém aprovou a tempo"):
        ask_broker(host(None, delay=2).path, REQUEST, 0.3)


@pytest.mark.parametrize("path", [None, "", "relative/b", "/tmp/wisp-none-here/b"])
def test_no_socket_refuses(path):
    with pytest.raises(Refused, match="canal de aprovação"):
        ask_broker(path, REQUEST, 1)


def test_a_socket_in_a_shared_folder_or_a_plain_file_is_not_trusted(host, tmp_path):
    h = host(reply(CONTRACT["allow"]))
    os.chmod(h.folder, 0o755)
    with pytest.raises(Refused, match="canal de aprovação"):
        ask_broker(h.path, REQUEST, 1)
    plain = tmp_path / "f"
    plain.write_text("x")
    with pytest.raises(Refused, match="canal de aprovação"):
        ask_broker(str(plain), REQUEST, 1)


def test_a_dead_socket_refuses(host):
    h = host(reply(CONTRACT["allow"]))
    h.listener.close()
    with pytest.raises(Refused, match="canal de aprovação"):
        ask_broker(h.path, REQUEST, 1)


@pytest.mark.parametrize("raw", [
    b"", b"\n", b"not json\n", b"[]\n", b'"allow"\n', b"{}\n",
    reply({"decision": "approve"}), reply({"decision": "ALLOW"}), reply({"decision": True}),
    reply({"allow": True}), reply({"approved": True}), reply({"decision": ["allow"]}),
    b'{"decision": "allow"}',
    b"x" * 70000 + b"\n",
])
def test_malformed_replies_never_approve(host, raw):
    with pytest.raises(Refused):
        ask_broker(host(raw).path, REQUEST, 2)


def test_the_client_never_sends_anything_but_the_request_verb(host):
    h = host(reply(CONTRACT["allow"]))
    ask_broker(h.path, REQUEST, 5)
    sent = json.loads(h.received[0])
    assert sent["op"] == "request" and set(sent) == {"op", "tool", "input"}


class FakeMail:
    def __init__(self):
        self.sent = []

    def send(self, to, subject, body, cc=[]):
        self.sent.append((to, subject, body, cc))


def _send(mail, gate_fn):
    return email_send(mail, ["a@b.c"], "Oi", "corpo", ["d@e.f"], gate_fn)


def test_a_gated_send_goes_out_only_after_the_host_allows_and_shows_the_whole_request():
    mail, asked = FakeMail(), []
    assert _send(mail, asked.append) == "enviado"
    assert asked == [{"to": ["a@b.c"], "cc": ["d@e.f"], "subject": "Oi", "body": "corpo"}]
    assert mail.sent == [(["a@b.c"], "Oi", "corpo", ["d@e.f"])]


def test_a_refused_gate_means_nothing_is_sent_and_the_model_reads_why():
    mail = FakeMail()

    def no(request):
        raise Refused("não enviei: negado")
    with pytest.raises(ToolFailure, match="não enviei: negado"):
        _send(mail, no)
    assert mail.sent == []


def test_a_bad_recipient_is_rejected_before_the_host_is_asked():
    asked = []
    with pytest.raises(ToolFailure):
        email_send(FakeMail(), ["a@b.c, x@y.z"], "s", "b", None, asked.append)
    assert asked == []


def test_no_flag_means_no_gate_as_under_claude():
    assert gate_from_env({}) is None and gate_from_env({gate.GATE_ENV: ""}) is None


def test_broker_flag_without_a_socket_or_any_other_value_fails_closed():
    for env in ({gate.GATE_ENV: "broker"}, {gate.GATE_ENV: "broker", gate.SOCKET_ENV: "/tmp/nope/b"}, {gate.GATE_ENV: "off"}):
        mail = FakeMail()
        with pytest.raises(ToolFailure, match="não enviei"):
            _send(mail, gate_from_env(env))
        assert mail.sent == []


def test_over_the_mcp_server_in_broker_mode_a_denied_send_is_an_error_result_and_an_allowed_one_sends(host):
    for answer, ok in ((CONTRACT["deny"], False), (CONTRACT["allow"], True)):
        h = host(reply(answer))
        mail = FakeMail()
        server = build_server(mail, gate_from_env({gate.GATE_ENV: "broker", gate.SOCKET_ENV: h.path}))
        result = asyncio.run(server.call_tool("email_send", {"to": ["a@b.c"], "subject": "Oi", "body": "corpo"}))
        assert result.is_error is (not ok) and bool(mail.sent) is ok
        assert json.loads(h.received[0])["input"] == {"to": ["a@b.c"], "cc": [], "subject": "Oi", "body": "corpo"}
