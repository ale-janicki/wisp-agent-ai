import asyncio
import json
import os
import shutil
import socket
import subprocess
import sys
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


HOST_EXE = "/wisp/host"


@pytest.fixture
def trusted_host(monkeypatch):
    monkeypatch.setattr(gate, "_ancestors", lambda pid: [os.getpid()])
    monkeypatch.setattr(gate, "_exe_of", lambda pid: HOST_EXE)
    monkeypatch.setattr(gate, "_host_executables", lambda: {HOST_EXE})


SPOOF = (
    "import os,socket,sys\n"
    "d=sys.argv[1];p=d+'/b'\n"
    "s=socket.socket(socket.AF_UNIX);s.bind(p);os.chmod(p,0o600);s.listen(1);print('up',flush=True)\n"
    "c,_=s.accept();c.recv(65536);c.sendall(b'{\"decision\": \"allow\"}\\n')\n"
)


@pytest.fixture
def spoof():
    folder = tempfile.mkdtemp(prefix="s-", dir="/tmp")
    proc = subprocess.Popen([sys.executable, "-c", SPOOF, folder], stdout=subprocess.PIPE, text=True, start_new_session=True)
    assert proc.stdout.readline().strip() == "up"
    yield proc, os.path.join(folder, "b")
    proc.kill()
    proc.wait()
    shutil.rmtree(folder, ignore_errors=True)


@pytest.fixture
def host(trusted_host):
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
    assert gate.SOCKET_ENV == CONTRACT["socket_env"] and not hasattr(gate, "GATE_ENV")
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
    return email_send(mail, ["a@b.c"], "Oi", "corpo", ["d@e.f"], gate=gate_fn)


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
        email_send(FakeMail(), ["a@b.c, x@y.z"], "s", "b", None, gate=asked.append)
    assert asked == []


@pytest.mark.parametrize("env", [
    {}, {"WISP_SEND_GATE": ""}, {"WISP_SEND_GATE": "off"}, {"WISP_SEND_GATE": "broker"}, {"WISP_APPROVAL_SOCKET": ""},
    {"WISP_APPROVAL_SOCKET": "/tmp/nope/b"},
])
def test_an_unset_or_empty_environment_still_requires_approval_and_refuses_without_a_broker(env):
    mail = FakeMail()
    with pytest.raises(ToolFailure, match="não enviei"):
        _send(mail, gate_from_env(env))
    assert mail.sent == []


def test_no_environment_value_turns_the_gate_off():
    for env in ({}, {"WISP_SEND_GATE": ""}, {"WISP_SEND_GATE": "0"}, {"WISP_SEND_GATE": "off"}):
        assert callable(gate_from_env(env))


def test_over_the_mcp_server_a_denied_send_is_an_error_result_and_an_allowed_one_sends(host):
    for answer, ok in ((CONTRACT["deny"], False), (CONTRACT["allow"], True)):
        h = host(reply(answer))
        mail = FakeMail()
        server = build_server(mail, gate_from_env({gate.SOCKET_ENV: h.path}))
        result = asyncio.run(server.call_tool("email_send", {"to": ["a@b.c"], "subject": "Oi", "body": "corpo"}))
        assert result.is_error is (not ok) and bool(mail.sent) is ok
        assert json.loads(h.received[0])["input"] == {"to": ["a@b.c"], "cc": [], "subject": "Oi", "body": "corpo"}


def test_a_spoof_that_answers_allow_from_a_non_ancestor_process_is_refused(spoof):
    with pytest.raises(Refused, match="canal de aprovação"):
        ask_broker(spoof[1], REQUEST, 5)


def test_a_spoof_that_is_an_ancestor_but_not_a_wisp_executable_is_refused(spoof, monkeypatch):
    proc, path = spoof
    monkeypatch.setattr(gate, "_ancestors", lambda pid: [proc.pid])
    with pytest.raises(Refused, match="canal de aprovação"):
        ask_broker(path, REQUEST, 5)


def test_a_spoof_that_is_an_ancestor_and_a_wisp_executable_is_the_only_one_accepted(spoof, monkeypatch):
    proc, path = spoof
    monkeypatch.setattr(gate, "_ancestors", lambda pid: [proc.pid])
    monkeypatch.setattr(gate, "_host_executables", lambda: {os.path.realpath(gate._exe_of(proc.pid))})
    ask_broker(path, REQUEST, 5)


def test_the_real_process_lookups_agree_with_the_os():
    assert os.getppid() in gate._ancestors(os.getpid())
    assert os.path.isabs(gate._exe_of(os.getpid()))
    assert gate._ancestors(2**22 + 12345) == []


def test_the_host_executables_come_from_install_locations_not_the_environment(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    found = gate._host_executables()
    assert os.path.realpath("/Applications/Wisp.app/Contents/MacOS/Wisp") in found
    assert not any(str(tmp_path) in e for e in found)


def _fake_home(monkeypatch, tmp_path):
    monkeypatch.setattr(gate.pwd, "getpwuid", lambda uid: type("P", (), {"pw_dir": str(tmp_path)})())


def test_a_runtime_python_is_allowed_by_its_resolved_and_its_framework_path(monkeypatch, tmp_path):
    runtime = tmp_path / ".local/share/wisp/runtime"
    bin_dir = runtime / "venv/bin"
    real = runtime / "py/bin"
    real.mkdir(parents=True)
    bin_dir.mkdir(parents=True)
    (real / "python3.13").write_text("")
    (bin_dir / "python").symlink_to(real / "python3.13")
    _fake_home(monkeypatch, tmp_path)
    found = gate._host_executables()
    assert os.path.realpath(real / "python3.13") in found
    assert os.path.join(os.path.realpath(runtime), "py", gate.FRAMEWORK_PYTHON) in found


def test_a_venv_python_link_to_a_python_outside_the_runtime_is_refused(monkeypatch, tmp_path):
    bin_dir = tmp_path / ".local/share/wisp/runtime/venv/bin"
    outside = tmp_path / "system/bin"
    outside.mkdir(parents=True)
    bin_dir.mkdir(parents=True)
    (outside / "python3.13").write_text("")
    (bin_dir / "pythonx").symlink_to(outside / "python3.13")
    _fake_home(monkeypatch, tmp_path)
    found = gate._host_executables()
    assert os.path.realpath(outside / "python3.13") not in found
    assert not any(e.startswith(os.path.realpath(tmp_path / "system")) for e in found)
