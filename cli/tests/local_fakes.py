import hashlib
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from wisp.local.backend import Backend, OpenAIClient


def reply(content: str = "", tool_calls: list | None = None, thinking: str = "") -> dict:
    return {"content": content, "tool_calls": tool_calls or [], "thinking": thinking}


def call(name: str, **arguments) -> dict:
    return {"function": {"name": name, "arguments": arguments}}


class FakeLLM:
    def __init__(self, script: list[dict] | None = None, tags: dict[str, int] | None = None, status: int = 200):
        self.script = list(script or [])
        self.repeat_last = False
        self.tags = tags or {}
        self.status = status
        self.requests: list[dict] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _sse(self, chunks: list[dict]):
                self.send_response(owner.status)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for chunk in chunks:
                    self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                    self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()

            def do_GET(self):
                if self.path == "/v1/models":
                    body = json.dumps({"object": "list", "data": [{"id": n, "object": "model"} for n in owner.tags]}).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_error(404)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.requests.append({"path": self.path, "authorization": self.headers.get("Authorization"), **body})
                if not owner.script:
                    self._sse([{"error": {"message": "the fake has no more replies"}}])
                    return
                step = owner.script[0] if owner.repeat_last and len(owner.script) == 1 else owner.script.pop(0)
                chunks = []
                if step["thinking"]:
                    chunks.append({"choices": [{"delta": {"reasoning_content": step["thinking"]}}]})
                half = len(step["content"]) // 2
                for part in (step["content"][:half], step["content"][half:]):
                    if part:
                        chunks.append({"choices": [{"delta": {"content": part}}]})
                for index, c in enumerate(step["tool_calls"]):
                    function = c["function"]
                    arguments = json.dumps(function["arguments"])
                    chunks.append({"choices": [{"delta": {"tool_calls": [{"index": index, "id": f"call_{index}", "function": {"name": function["name"], "arguments": ""}}]}}]})
                    chunks.append({"choices": [{"delta": {"tool_calls": [{"index": index, "function": {"arguments": arguments}}]}}]})
                chunks.append({"choices": [{"delta": {}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 11, "completion_tokens": 7}})
                self._sse(chunks)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def client(self, **kwargs) -> Backend:
        return Backend(OpenAIClient(self.url, **kwargs))

    def chats(self) -> list[dict]:
        return [r for r in self.requests if r["path"] == "/v1/chat/completions"]

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()


class FakeHub:
    """Serves the files of a model the way huggingface.co/<repo>/resolve/<revision>/<path> does."""

    def __init__(self, repo: str, revision: str, files: dict[str, bytes], tamper: set[str] | None = None, chunk_delay: float = 0.0):
        self.prefix = f"/{repo}/resolve/{revision}/"
        self.files, self.tamper, self.chunk_delay = files, tamper or set(), chunk_delay
        self.hits: list[str] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                if not self.path.startswith(owner.prefix) or self.path[len(owner.prefix):] not in owner.files:
                    self.send_error(404)
                    return
                name = self.path[len(owner.prefix):]
                owner.hits.append(name)
                data = owner.files[name]
                if name in owner.tamper:
                    data = bytes(b ^ 1 for b in data[:1]) + data[1:]
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def manifest(self) -> list[dict]:
        out = []
        for path, data in self.files.items():
            if path.endswith(".safetensors"):
                out.append({"path": path, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
            else:
                out.append({"path": path, "size": len(data), "git_sha1": hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()})
        return out

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()
