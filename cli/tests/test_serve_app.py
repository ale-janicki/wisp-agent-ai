import json
import os
import queue
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

import httpx
import pytest
import uvicorn
from starlette.testclient import TestClient

from wisp.compat import kill_process_tree, new_session_kwargs
from wisp.serve.app import create_app

TOKEN = "t0ken-for-tests"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
FIXTURES = Path(__file__).parent / "fixtures" / "serve"


CMD_SHIM_NODE = (
    "@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\r\n"
    'IF EXIST "%dp0%\\node.exe" (\r\n  SET "_prog=%dp0%\\node.exe"\r\n) ELSE (\r\n  SET "_prog=node"\r\n'
    "  SET PATHEXT=%PATHEXT:;.JS;=;%\r\n)\r\n\r\n"
    "endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "
    '"%_prog%"  "%dp0%\\node_modules\\@anthropic-ai\\claude-code\\cli.js" %*\r\n'
)


@pytest.fixture
def data(tmp_path, monkeypatch):
    path = tmp_path / "data"
    path.mkdir()
    monkeypatch.setenv("WISP_DATA_DIR", str(path))
    return path


@pytest.fixture
def guards(tmp_path, monkeypatch):
    binary = tmp_path / "bin dir" / "wisp"
    binary.parent.mkdir()
    binary.write_text("#!/bin/sh\n", encoding="utf-8")
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    state = tmp_path / "state"
    monkeypatch.setattr("wisp.serve.guards.wisp_binary", lambda *a, **k: str(binary))
    monkeypatch.setenv("XDG_STATE_HOME", str(state))
    monkeypatch.setenv("LOCALAPPDATA", str(state))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("APPDATA", str(tmp_path / "config"))
    monkeypatch.setattr("wisp.serve.guards.soul_text", lambda: "SOUL-TEXT")
    return binary


@pytest.fixture
def fake_claude(tmp_path, monkeypatch, guards):
    source = (FIXTURES / "fake_claude.py").read_text(encoding="utf-8")
    if sys.platform == "win32":
        script = tmp_path / "fake_claude.js"
        script.write_text(source, encoding="utf-8")
        launcher = tmp_path / "fake_claude.cmd"
        shim = CMD_SHIM_NODE.replace("node_modules\\@anthropic-ai\\claude-code\\cli.js", "fake_claude.js")
        launcher.write_bytes(shim.encode("utf-8"))
        monkeypatch.setattr("wisp.serve.claude_session.shutil.which", lambda name: sys.executable)
    else:
        launcher = tmp_path / "fake-claude"
        launcher.write_text(source.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1), encoding="utf-8")
        launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR)
    log = tmp_path / "fake.log"
    monkeypatch.setenv("WISP_CLAUDE_BIN", str(launcher))
    monkeypatch.setenv("FAKE_CLAUDE_LOG", str(log))
    return log


def fake_log(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


class LiveServer:
    def __init__(self, app):
        self.server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=0, log_level="warning",
                                                   timeout_graceful_shutdown=1))
        self.thread = threading.Thread(target=self.server.run, daemon=True)

    def __enter__(self):
        self.thread.start()
        deadline = time.time() + 10
        while not self.server.started and time.time() < deadline:
            time.sleep(0.02)
        assert self.server.started
        self.port = self.server.servers[0].sockets[0].getsockname()[1]
        self.base = f"http://127.0.0.1:{self.port}"
        self.http = httpx.Client(base_url=self.base, headers=AUTH, timeout=15)
        return self

    def __exit__(self, *exc):
        self.http.close()
        self.server.should_exit = True
        self.thread.join(10)


class Sse:
    def __init__(self, live):
        self.events = queue.Queue()
        self.seen = []
        self.comments = []
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._read, args=(live,), daemon=True)
        self.thread.start()
        assert self.ready.wait(10)

    def _read(self, live):
        try:
            self._stream(live)
        except httpx.TransportError:
            pass

    def _stream(self, live):
        with httpx.Client(base_url=live.base, timeout=30) as client:
            with client.stream("GET", "/events", params={"token": TOKEN}) as response:
                assert response.status_code == 200
                assert response.headers["content-type"].startswith("text/event-stream")
                self.ready.set()
                for line in response.iter_lines():
                    if line.startswith("data: "):
                        self.events.put(json.loads(line[6:]))
                    elif line.startswith(":"):
                        self.comments.append(line)

    def until(self, kind, timeout=15, **match):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                event = self.events.get(timeout=0.2)
            except queue.Empty:
                continue
            self.seen.append(event)
            if event["type"] == kind and all(event.get(k) == v for k, v in match.items()):
                return event
        raise AssertionError(f"no {kind} {match} in {self.seen}")

    def drain(self, settle=0.5):
        time.sleep(settle)
        while True:
            try:
                self.seen.append(self.events.get_nowait())
            except queue.Empty:
                return self.seen


def test_requests_without_or_with_wrong_token_are_401(data):
    client = TestClient(create_app(TOKEN))
    for path in ["/health", "/conversations", "/events"]:
        assert client.get(path).status_code == 401
        assert client.get(path, headers={"Authorization": "Bearer nope"}).status_code == 401
        assert client.get(path, headers={"Authorization": TOKEN}).status_code == 401
    assert client.get("/events", params={"token": "nope"}).status_code == 401
    assert client.post("/conversations", json={}).status_code == 401
    assert client.post("/permissions/x", json={"allow": True}).status_code == 401
    assert client.get("/health", params={"token": TOKEN}).status_code == 401


def test_cors_preflight_only_for_the_tauri_origins(data):
    client = TestClient(create_app(TOKEN))
    ask = {"Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "authorization,content-type"}
    for origin in ["http://tauri.localhost", "https://tauri.localhost", "tauri://localhost"]:
        ok = client.options("/conversations", headers={"Origin": origin, **ask})
        assert ok.status_code == 200 and ok.headers["access-control-allow-origin"] == origin
        assert "authorization" in ok.headers["access-control-allow-headers"].lower()
    evil = client.options("/conversations", headers={"Origin": "http://evil.example", **ask})
    assert "access-control-allow-origin" not in evil.headers
    plain = client.get("/conversations", headers={"Origin": "http://tauri.localhost"})
    assert plain.status_code == 401 and plain.headers["access-control-allow-origin"] == "http://tauri.localhost"


def test_health_and_conversation_crud(data):
    client = TestClient(create_app(TOKEN), headers=AUTH)
    assert client.get("/health").json() == {"ok": True, "version": "0.1.0"}
    assert client.get("/conversations").json() == {"items": []}
    made = client.post("/conversations", json={"title": "Primeira"})
    assert made.status_code == 200
    cid = made.json()["id"]
    items = client.get("/conversations").json()["items"]
    assert [(i["id"], i["title"], i["engine"]) for i in items] == [(cid, "Primeira", "claude")]
    assert items[0]["updated_at"].endswith("Z")
    assert client.get(f"/conversations/{cid}").json() == {"id": cid, "title": "Primeira", "messages": []}
    assert client.get("/conversations/does-not-exist").status_code == 404
    assert client.post(f"/conversations/{cid}/messages", json={"text": ""}).status_code == 400
    assert client.post("/conversations/does-not-exist/messages", json={"text": "x"}).status_code == 404
    assert client.post("/permissions/unknown", json={"allow": True}).status_code == 404
    assert client.post("/conversations").status_code == 200


def send(live, cid, text, attachments=()):
    response = live.http.post(f"/conversations/{cid}/messages", json={"text": text, "attachments": list(attachments)})
    assert response.status_code == 202 and response.json() == {"accepted": True}


def test_message_permission_allow_result_idle(data, fake_claude):
    with LiveServer(create_app(TOKEN, heartbeat=0.3)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        assert sse.until("status", conversation_id=cid, state="thinking")
        tool = sse.until("tool_use", conversation_id=cid)
        assert (tool["id"], tool["name"], tool["input"]) == ("toolu_1", "Bash", {"command": "touch probe"})
        ask = sse.until("permission_request", conversation_id=cid)
        assert ask["request_id"] == "req-1" and ask["tool_name"] == "Bash" and ask["input"] == {"command": "touch probe"}
        assert live.http.post("/permissions/req-1", json={"allow": True}).status_code == 200
        done = sse.until("tool_result", conversation_id=cid)
        assert (done["tool_use_id"], done["content"], done["is_error"]) == ("toolu_1", "done", False)
        reply = sse.until("assistant_message", conversation_id=cid)
        assert reply["message"]["role"] == "assistant"
        assert reply["message"]["blocks"] == [{"type": "text", "text": "ok: oi"}]
        result = sse.until("result", conversation_id=cid)
        assert result["usage"] == {"input_tokens": 1, "output_tokens": 2}
        assert sse.until("status", conversation_id=cid, state="idle")
        assert sse.comments, "no heartbeat comment"

        log = fake_log(fake_claude)
        assert "--resume" not in log[0]["argv"] and "--permission-prompt-tool" in log[0]["argv"]
        assert {"user": "oi"} in log
        answer = next(e["control_response"] for e in log if "control_response" in e)
        assert answer["response"]["request_id"] == "req-1"
        assert answer["response"]["response"] == {"behavior": "allow", "updatedInput": {"command": "touch probe"}}

        history = live.http.get(f"/conversations/{cid}").json()
        assert [(m["role"], m["blocks"]) for m in history["messages"]] == [
            ("user", [{"type": "text", "text": "oi"}]), ("assistant", [{"type": "text", "text": "ok: oi"}])]
        assert history["title"] == "oi"
        records = json.loads((data / "conversations.json").read_text(encoding="utf-8"))
        assert records[0]["sessionId"] == "fake-session-1" and records[0]["lastFrom"] == "agent"
        assert (data / "conversas" / f"{cid}.jsonl").exists()

        send(live, cid, "de novo")
        sse.until("permission_request", conversation_id=cid)
        live.http.post("/permissions/req-1", json={"allow": True})
        sse.until("result", conversation_id=cid)
        sse.until("status", conversation_id=cid, state="idle")
        argvs = [e["argv"] for e in fake_log(fake_claude) if "argv" in e]
        assert len(argvs) == 1, "the same process serves the next turn"


def argv_of(path):
    return [e["argv"] for e in fake_log(path) if "argv" in e]


def option(argv, flag):
    return argv[argv.index(flag) + 1]


def test_claude_starts_with_the_guards_the_mac_passes(data, fake_claude, guards, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE_NO_PERMISSION", "1")
    (data / "settings.json").write_text(json.dumps({"permissionMode": "auto"}), encoding="utf-8")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        sse.until("status", conversation_id=cid, state="idle")
    argv = argv_of(fake_claude)[0]
    assert option(argv, "--permission-mode") == "auto"
    prompt = option(argv, "--append-system-prompt")
    assert prompt.startswith("The user is reading the Wisp app") and prompt.endswith("\n\nSOUL-TEXT")
    assert "--disallowedTools" not in argv
    settings = json.loads(Path(option(argv, "--settings")).read_text(encoding="utf-8"))
    pre = settings["hooks"]["PreToolUse"][0]
    assert pre["matcher"] == "Bash|Read|Edit|MultiEdit|Write|NotebookEdit|Grep|Glob"
    quoted = "'" + str(guards) + "'" if sys.platform != "win32" else '"' + str(guards).replace("\\", "/") + '"'
    assert [h["command"] for h in pre["hooks"]] == [
        f"{quoted} hook {n}" for n in ("guard-secrets", "guard-telegram", "guard-destructive", "guard-lessons",
                                       "guard-agenda", "guard-outbound")]
    assert settings["hooks"]["UserPromptSubmit"][0]["hooks"] == [
        {"type": "command", "command": f"{quoted} hook recall", "timeout": 5}]
    assert settings["permissions"]["ask"][-2:] == ["mcp__wisp-email__email_send", "mcp__wisp-mac__mac_send"]
    assert "Write(~/.config/wisp/**)" in settings["permissions"]["deny"]


def test_without_the_wisp_cli_the_turn_is_refused_and_claude_never_starts(data, fake_claude, monkeypatch, tmp_path):
    monkeypatch.setattr("wisp.serve.guards.wisp_binary", lambda *a, **k: None)
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        err = sse.until("error", conversation_id=cid)
        assert err["message"] == "não consegui ativar as travas do Wisp: não achei o CLI do Wisp"
        assert sse.until("status", conversation_id=cid, state="error")
    assert fake_log(fake_claude) == [], "claude was started without the guards"


def test_unwritable_guards_file_refuses_the_turn_too(data, fake_claude, monkeypatch, tmp_path):
    blocker = tmp_path / "state"
    blocker.write_text("a file where the folder should be", encoding="utf-8")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        assert sse.until("error", conversation_id=cid)["message"].startswith("não consegui ativar as travas do Wisp: ")
    assert fake_log(fake_claude) == []


def test_deny_sends_a_deny_control_response(data, fake_claude):
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        sse.until("permission_request", conversation_id=cid)
        assert live.http.post("/permissions/req-1", json={"allow": False, "message": "nao"}).status_code == 200
        assert sse.until("tool_result", conversation_id=cid)["is_error"] is True
        sse.until("status", conversation_id=cid, state="idle")
        answer = next(e["control_response"] for e in fake_log(fake_claude) if "control_response" in e)
        assert answer["response"]["response"] == {"behavior": "deny", "message": "nao"}
        assert live.http.post("/permissions/req-1", json={"allow": True}).status_code == 404


def test_messages_sent_while_a_turn_runs_are_queued_and_idle_comes_once(data, fake_claude):
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "um")
        sse.until("permission_request", conversation_id=cid)
        send(live, cid, "dois")
        live.http.post("/permissions/req-1", json={"allow": True})
        assert sse.until("result", conversation_id=cid)
        sse.until("permission_request", conversation_id=cid)
        live.http.post("/permissions/req-1", json={"allow": True})
        sse.until("result", conversation_id=cid)
        sse.until("status", conversation_id=cid, state="idle")
        seen = sse.drain()
        states = [e["state"] for e in seen if e["type"] == "status"]
        assert states.count("idle") == 1 and states[-1] == "idle", states
        assert [e["user"] for e in fake_log(fake_claude) if "user" in e] == ["um", "dois"]
        replies = [m["blocks"][0]["text"] for m in live.http.get(f"/conversations/{cid}").json()["messages"]
                   if m["role"] == "assistant"]
        assert replies == ["ok: um", "ok: dois"]


def test_attachments_go_into_the_prompt_like_the_mac(data, fake_claude, tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE_NO_PERMISSION", "1")
    photo = tmp_path / "foto.png"
    photo.write_bytes(b"12345")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "olha isso", [str(photo)])
        sse.until("status", conversation_id=cid, state="idle")
        sent = next(e["user"] for e in fake_log(fake_claude) if "user" in e)
        assert sent == f"[o usuario enviou 1 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n- {photo} (foto.png, 5 bytes)]\n\nolha isso"


@pytest.mark.parametrize("attachment", ["relativo.png", "~/foto.png", "{missing}", "{folder}"])
def test_attachments_must_be_absolute_existing_files(data, fake_claude, tmp_path, attachment):
    attachment = attachment.format(missing=tmp_path / "nao-existe.png", folder=tmp_path)
    with LiveServer(create_app(TOKEN)) as live:
        cid = live.http.post("/conversations", json={}).json()["id"]
        response = live.http.post(f"/conversations/{cid}/messages", json={"text": "oi", "attachments": [attachment]})
        assert response.status_code == 400
    assert fake_log(fake_claude) == []


def test_stop_ends_the_turn_and_a_new_message_starts_again(data, fake_claude):
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        sse.until("permission_request", conversation_id=cid)
        assert live.http.post(f"/conversations/{cid}/stop").status_code == 200
        sse.until("status", conversation_id=cid, state="idle")
        send(live, cid, "outra")
        sse.until("permission_request", conversation_id=cid)
        argvs = [e["argv"] for e in fake_log(fake_claude) if "argv" in e]
        assert len(argvs) == 2 and "--resume" not in argvs[0]
        assert argvs[1][argvs[1].index("--resume") + 1] == "fake-session-1"
        assert live.http.post(f"/conversations/{cid}/stop").status_code == 200


def test_missing_claude_reports_an_error_event(data, monkeypatch, guards):
    monkeypatch.setenv("WISP_CLAUDE_BIN", str(data / "nope"))
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        err = sse.until("error", conversation_id=cid)
        assert "claude" in err["message"].lower()
        assert sse.until("status", conversation_id=cid, state="error")


def run_serve(env, *args):
    return subprocess.Popen([sys.executable, "-m", "wisp.serve", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, text=True, **new_session_kwargs())


def stop_group(proc):
    try:
        kill_process_tree(proc.pid)
    except (ProcessLookupError, PermissionError):
        pass
    proc.wait(10)


def test_refuses_to_start_without_a_token(data):
    env = {k: v for k, v in os.environ.items() if k != "WISP_SERVE_TOKEN"}
    proc = run_serve(env, "--port", "0")
    try:
        out, err = proc.communicate(timeout=20)
    finally:
        stop_group(proc)
    assert proc.returncode != 0 and out == "" and "WISP_SERVE_TOKEN" in err


def test_prints_one_ready_line_and_serves_on_loopback(data):
    env = {**os.environ, "WISP_SERVE_TOKEN": TOKEN}
    proc = run_serve(env, "--port", "0")
    try:
        line = proc.stdout.readline()
        ready = json.loads(line)
        assert ready["ready"] is True and isinstance(ready["port"], int) and ready["port"] > 0
        assert line == json.dumps(ready) + "\n"
        reply = httpx.get(f"http://127.0.0.1:{ready['port']}/health", headers=AUTH, timeout=10)
        assert reply.json()["ok"] is True
        assert httpx.get(f"http://127.0.0.1:{ready['port']}/health", timeout=10).status_code == 401
        assert proc.poll() is None
    finally:
        stop_group(proc)
