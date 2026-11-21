import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from wisp.local.ollama import OllamaClient


def reply(content: str = "", tool_calls: list | None = None, thinking: str = "") -> dict:
    return {"content": content, "tool_calls": tool_calls or [], "thinking": thinking}


def call(name: str, **arguments) -> dict:
    return {"function": {"name": name, "arguments": arguments}}


class FakeOllama:
    def __init__(self, script: list[dict] | None = None, tags: dict[str, int] | None = None, pull: list[dict] | None = None,
                 status: int = 200):
        self.script = list(script or [])
        self.repeat_last = False
        self.tags = tags or {}
        self.pull_chunks = pull or []
        self.status = status
        self.requests: list[dict] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, chunks: list[dict]):
                self.send_response(owner.status)
                self.send_header("Content-Type", "application/x-ndjson")
                self.end_headers()
                for chunk in chunks:
                    self.wfile.write((json.dumps(chunk) + "\n").encode())
                    self.wfile.flush()

            def do_GET(self):
                if self.path == "/api/version":
                    self._send([{"version": "0.0.0-fake"}])
                elif self.path == "/api/tags":
                    self._send([{"models": [{"name": n, "size": s} for n, s in owner.tags.items()]}])
                else:
                    self.send_error(404)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.requests.append({"path": self.path, **body})
                if self.path == "/api/pull":
                    self._send(owner.pull_chunks)
                    return
                if not owner.script:
                    self._send([{"error": "the fake has no more replies"}])
                    return
                step = owner.script[0] if owner.repeat_last and len(owner.script) == 1 else owner.script.pop(0)
                message = {"role": "assistant", "content": step["content"]}
                chunks = []
                half = len(step["content"]) // 2
                if step["thinking"]:
                    chunks.append({"message": {"role": "assistant", "content": "", "thinking": step["thinking"]}, "done": False})
                if step["content"]:
                    chunks.append({"message": {**message, "content": step["content"][:half]}, "done": False})
                    chunks.append({"message": {**message, "content": step["content"][half:]}, "done": False})
                chunks.append({"message": {"role": "assistant", "content": "", "tool_calls": step["tool_calls"]}, "done": True,
                               "prompt_eval_count": 11, "eval_count": 7})
                self._send(chunks)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def client(self, **kwargs) -> OllamaClient:
        return OllamaClient(self.url, **kwargs)

    def chats(self) -> list[dict]:
        return [r for r in self.requests if r["path"] == "/api/chat"]

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()
