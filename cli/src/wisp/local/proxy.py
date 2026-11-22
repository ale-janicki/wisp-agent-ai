import hashlib
import hmac
import http.client
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOOPBACK = "127.0.0.1"
MAX_BODY = 16_000_000
IDLE_POLL = 2.0
CHILD_WAIT = 180.0
CHAT_PATHS = ("/v1/chat/completions", "/chat/completions")
DROPPED_FIELDS = ("draft_model", "adapters", "adapter_path")
DEFAULT_CHILD = [sys.executable, "-m", "wisp", "local", "mlx-child", "--model-dir", "{model}", "--socket", "{socket}"]


def proof(key: str, nonce: str) -> str:
    return hmac.new(key.encode(), nonce.encode(), hashlib.sha256).hexdigest()


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float):
        super().__init__("localhost", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


class Gate:
    def __init__(self, model: str, key: str, child_path: str, idle_seconds: float, clock: Callable[[], float] = time.monotonic):
        self.model, self.key, self.child_path, self.idle_seconds = model, key, child_path, idle_seconds
        self.clock = clock
        self.lock = threading.Lock()
        self.active = 0
        self.ready = False
        self.last = self.clock()

    def touch(self, delta: int) -> None:
        with self.lock:
            self.active += delta
            self.last = self.clock()

    def idle(self) -> bool:
        with self.lock:
            return self.active == 0 and self.clock() - self.last > self.idle_seconds


def handler_for(gate: Gate):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _reply(self, status: int, body: bytes, kind: str = "application/json") -> None:
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self._sign()
            self.end_headers()
            self.wfile.write(body)

        def _sign(self) -> None:
            nonce = self.headers.get("X-Wisp-Nonce")
            if nonce:
                self.send_header("X-Wisp-Proof", proof(gate.key, nonce))

        def _authorized(self) -> bool:
            header = self.headers.get("Authorization") or ""
            return hmac.compare_digest(header.encode(), f"Bearer {gate.key}".encode())

        def do_GET(self):
            if self.path == "/wisp/identity":
                self._reply(200, json.dumps({"wisp": "mlx-proxy", "model": gate.model, "ready": gate.ready}).encode())
            elif not self._authorized():
                self._reply(401, b'{"error": "unauthorized"}')
            elif self.path == "/v1/models":
                gate.touch(0)
                self._reply(200, json.dumps({"object": "list", "data": [{"id": gate.model, "object": "model"}]}).encode())
            else:
                self._reply(404, b'{"error": "not found"}')

        def do_POST(self):
            if self.path not in CHAT_PATHS:
                self._reply(404, b'{"error": "not found"}')
                return
            if not self._authorized():
                self._reply(401, b'{"error": "unauthorized"}')
                return
            try:
                length = int(self.headers.get("Content-Length") or "")
                if not 0 < length <= MAX_BODY:
                    raise ValueError
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict):
                    raise ValueError
            except ValueError:
                self._reply(400, b'{"error": "bad request"}')
                return
            if body.get("model") != gate.model:
                self._reply(403, json.dumps({"error": f"this server only serves {gate.model}"}).encode())
                return
            body["model"] = "default_model"
            for name in DROPPED_FIELDS:
                body.pop(name, None)
            gate.touch(1)
            try:
                self._forward(body)
            finally:
                gate.touch(-1)

        def _forward(self, body: dict) -> None:
            upstream = UnixConnection(gate.child_path, 600)
            try:
                upstream.request("POST", "/v1/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
                response = upstream.getresponse()
                self.send_response(response.status)
                self.send_header("Content-Type", response.getheader("Content-Type") or "application/json")
                self._sign()
                self.end_headers()
                while chunk := response.read1(65536):
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (OSError, http.client.HTTPException):
                try:
                    self._reply(502, b'{"error": "the model server did not answer"}')
                except OSError:
                    pass
            finally:
                upstream.close()

    return Handler


def child_ready(path: str) -> bool:
    try:
        connection = UnixConnection(path, 2)
        connection.request("GET", "/v1/models")
        ok = connection.getresponse().status == 200
        connection.close()
        return ok
    except (OSError, http.client.HTTPException):
        return False


def write_info(path: Path, info: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump(info, out)


def remove_own_files(info_path: Path, key: str) -> None:
    try:
        owner = json.loads(info_path.read_text("utf-8")).get("pid")
    except (OSError, ValueError, AttributeError):
        return
    if owner != os.getpid():
        return
    key_path = info_path.parent / "server.key"
    try:
        same_key = key_path.read_text("utf-8").strip() == key
    except (OSError, UnicodeDecodeError):
        same_key = False
    info_path.unlink(missing_ok=True)
    if same_key:
        key_path.unlink(missing_ok=True)


def serve(*, model: str, port: int, key: str, idle_minutes: float, info_path: Path, child_argv: list[str] | None = None,
          marker: str = "") -> int:
    sockets = tempfile.mkdtemp(prefix="wisp-mlx-", dir="/tmp")
    child_path = os.path.join(sockets, "child.sock")
    argv = [a.format(socket=child_path, model=model) for a in (child_argv or DEFAULT_CHILD)]
    env = {**os.environ, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"}
    child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    gate = Gate(model, key, child_path, idle_minutes * 60)
    try:
        server = ThreadingHTTPServer((LOOPBACK, port), handler_for(gate))
    except OSError:
        child.terminate()
        shutil.rmtree(sockets, ignore_errors=True)
        return 3
    stop = threading.Event()

    def shut(*_):
        stop.set()

    signal.signal(signal.SIGTERM, shut)
    signal.signal(signal.SIGINT, shut)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    write_info(info_path, {"pid": os.getpid(), "child": child.pid, "port": port, "model": model,
                           "marker": marker, "socket_dir": sockets, "started": time.time()})
    deadline = time.monotonic() + CHILD_WAIT
    while not stop.is_set():
        if child.poll() is not None:
            break
        if not gate.ready and child_ready(child_path):
            gate.ready = True
            gate.touch(0)
        if not gate.ready and time.monotonic() > deadline:
            break
        if gate.ready and gate.idle():
            break
        stop.wait(IDLE_POLL if gate.ready else 0.3)
    server.shutdown()
    server.server_close()
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(8)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    remove_own_files(info_path, key)
    shutil.rmtree(sockets, ignore_errors=True)
    return 0
