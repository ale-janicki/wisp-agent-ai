import hmac
import http.client
import importlib.util
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

from wisp.local import arch, fetch, proxy

DEFAULT_MLX_URL = "http://127.0.0.1:8421"
CHAT_TIMEOUT = 600.0
PROBE_TIMEOUT = 3.0
SERVE_WAIT = 120.0
API_KEY_ENV = "WISP_LLM_API_KEY"
THINK = re.compile(r"<think>(.*?)</think>", re.DOTALL)
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")
MLX_NOT_LOCAL = "o MLX só aceita um endereço local (127.0.0.1); para outro servidor use `wisp local backend openai`"
NOT_OURS = "o que respondeu no endereço do MLX não é o servidor do Wisp; não enviei nada"
MLX_MISSING = "o componente de IA local ainda está sendo instalado (a instalação foi interrompida); ele termina sozinho"


class BackendError(Exception):
    pass


@dataclass
class ChatReply:
    content: str = ""
    thinking: str = ""
    tool_calls: list[dict] = field(default_factory=list)
    prompt_tokens: int = 0
    reply_tokens: int = 0


def to_openai_messages(messages: list[dict]) -> list[dict]:
    out = []
    for m in messages:
        if m.get("role") == "assistant" and m.get("tool_calls"):
            calls = [
                {"id": c.get("id") or f"call_{i}", "type": "function",
                 "function": {"name": c["function"]["name"], "arguments": json.dumps(c["function"].get("arguments") or {}, ensure_ascii=False)}}
                for i, c in enumerate(m["tool_calls"])
            ]
            out.append({"role": "assistant", "content": m.get("content") or "", "tool_calls": calls})
        elif m.get("role") == "tool":
            out.append({"role": "tool", "tool_call_id": m.get("tool_call_id") or "", "content": m.get("content", "")})
        else:
            out.append({"role": m["role"], "content": m.get("content", "")})
    return out


def _arguments(raw: object) -> dict:
    if isinstance(raw, dict):
        return raw
    try:
        value = json.loads(raw) if isinstance(raw, str) and raw.strip() else {}
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


class OpenAIClient:
    def __init__(self, url: str, *, chat_timeout: float = CHAT_TIMEOUT, api_key: str | None = None, think: bool | None = None):
        self.think = think
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise BackendError(f"endereço do servidor inválido: {url}")
        self.url = url.rstrip("/")
        self.scheme, self.host = parts.scheme, parts.hostname
        self.port = parts.port or (443 if parts.scheme == "https" else 80)
        self.base = parts.path.rstrip("/")
        self.chat_timeout = chat_timeout
        self.api_key = api_key if api_key is not None else os.environ.get(API_KEY_ENV, "")

    def _connection(self, timeout: float) -> http.client.HTTPConnection:
        factory = http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        return factory(self.host, self.port, timeout=timeout)

    def _lines(self, path: str, body: dict | None, timeout: float) -> Iterator[str]:
        connection = self._connection(timeout)
        try:
            headers = {"Content-Type": "application/json", **({"Authorization": f"Bearer {self.api_key}"} if self.api_key else {})}
            connection.request("GET" if body is None else "POST", self.base + path, None if body is None else json.dumps(body).encode(), headers)
            response = connection.getresponse()
            if response.status != 200:
                detail = response.read(2000).decode("utf-8", "replace").strip()
                raise BackendError(f"o servidor respondeu {response.status}: {detail or response.reason}")
            for raw in response:
                line = raw.decode("utf-8", "replace").strip()
                if line:
                    yield line
        except (OSError, http.client.HTTPException) as e:
            raise BackendError(f"não consegui falar com o servidor em {self.host}:{self.port} ({type(e).__name__})") from None
        finally:
            connection.close()

    def running(self) -> bool:
        try:
            return any(True for _ in self._lines("/v1/models", None, PROBE_TIMEOUT))
        except BackendError:
            return False

    def models(self) -> list[str]:
        try:
            raw = "".join(self._lines("/v1/models", None, PROBE_TIMEOUT * 3))
            data = json.loads(raw).get("data", [])
        except (ValueError, AttributeError):
            raise BackendError("o servidor mandou uma lista de modelos que não consegui ler") from None
        return [m["id"] for m in data if isinstance(m, dict) and isinstance(m.get("id"), str)]

    def chat(self, model: str, messages: list[dict], tools: list[dict], options: dict) -> ChatReply:
        body = {"model": model, "messages": to_openai_messages(messages), "stream": True, "stream_options": {"include_usage": True}}
        body["tools"] = tools
        if self.think is not None:
            body["chat_template_kwargs"] = {"enable_thinking": self.think}
        reply = ChatReply()
        partial: dict[int, dict] = {}
        for line in self._lines("/v1/chat/completions", body, self.chat_timeout):
            if not line.startswith("data:"):
                if line.startswith("{"):
                    self._raise_error(line)
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except ValueError:
                raise BackendError("o servidor mandou uma resposta que não consegui ler") from None
            if not isinstance(chunk, dict):
                continue
            if chunk.get("error"):
                raise BackendError(f"o servidor falhou: {chunk['error'].get('message') if isinstance(chunk['error'], dict) else chunk['error']}")
            usage = chunk.get("usage") or {}
            reply.prompt_tokens = int(usage.get("prompt_tokens") or reply.prompt_tokens)
            reply.reply_tokens = int(usage.get("completion_tokens") or reply.reply_tokens)
            for choice in chunk.get("choices") or []:
                delta = choice.get("delta") or {}
                reply.content += delta.get("content") or ""
                reply.thinking += delta.get("reasoning_content") or delta.get("reasoning") or ""
                for call in delta.get("tool_calls") or []:
                    slot = partial.setdefault(int(call.get("index") or 0), {"id": "", "name": "", "arguments": ""})
                    slot["id"] = call.get("id") or slot["id"]
                    function = call.get("function") or {}
                    slot["name"] += function.get("name") or ""
                    slot["arguments"] += function.get("arguments") if isinstance(function.get("arguments"), str) else ""
        found = THINK.findall(reply.content)
        if found:
            reply.thinking += "".join(found)
            reply.content = THINK.sub("", reply.content)
        reply.tool_calls = [
            {"id": slot["id"], "function": {"name": slot["name"], "arguments": _arguments(slot["arguments"])}}
            for _, slot in sorted(partial.items()) if slot["name"]
        ]
        return reply

    @staticmethod
    def _raise_error(line: str) -> None:
        try:
            error = json.loads(line).get("error")
        except ValueError:
            return
        if error:
            raise BackendError(f"o servidor falhou: {error.get('message') if isinstance(error, dict) else error}")


class Backend:
    kind = "openai"

    def __init__(self, client: OpenAIClient, folder: Path | None = None):
        self.client = client
        self.folder = folder

    def running(self) -> bool:
        return self.client.running()

    def ensure_running(self, tag: str | None = None) -> None:
        if not self.client.running():
            raise BackendError(f"o servidor {self.client.url} não respondeu")

    def model_id(self, tag: str) -> str:
        return tag

    def available(self) -> list[str]:
        return self.client.models()

    def chat(self, tag: str, messages: list[dict], tools: list[dict], options: dict) -> ChatReply:
        return self.client.chat(self.model_id(tag), messages, tools, options)

    def runtime_missing(self) -> str | None:
        return None

    def readiness(self, active: str) -> str | None:
        if not self.client.running():
            return f"o servidor {self.client.url} não respondeu"
        if not active:
            return "nenhum modelo local está ativo"
        try:
            offered = self.client.models()
        except BackendError as e:
            return str(e)
        if offered and active not in offered:
            return f"o servidor não oferece o modelo {active}"
        return None


def server_state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state")
    return Path(base) / "wisp" / "mlx"


def _ps(pid: int) -> str | None:
    try:
        done = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat=,command="], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    line = done.stdout.strip()
    if done.returncode != 0 or not line or line.startswith("Z"):
        return None
    return line


def _terminate(pid: int, needle: str, wait: float = 8.0) -> None:
    line = _ps(pid)
    if line is None or needle not in line:
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline and _ps(pid) is not None:
        time.sleep(0.1)
    if _ps(pid) is not None:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def read_server_info(state_dir: Path) -> dict | None:
    try:
        info = json.loads((state_dir / "server.json").read_text("utf-8"))
    except (OSError, ValueError):
        return None
    return info if isinstance(info, dict) else None


def stop_server(state_dir: Path | None = None) -> bool:
    state_dir = state_dir or server_state_dir()
    info = read_server_info(state_dir)
    had = info is not None
    if info:
        if isinstance(info.get("pid"), int) and info.get("marker"):
            _terminate(info["pid"], info["marker"])
        if isinstance(info.get("child"), int) and info.get("model"):
            _terminate(info["child"], info["model"], wait=3.0)
        leftover = info.get("socket_dir")
        if isinstance(leftover, str) and Path(leftover).parent == Path("/tmp") and Path(leftover).name.startswith("wisp-mlx-"):
            shutil.rmtree(leftover, ignore_errors=True)
    for name in ("server.json", "server.key"):
        (state_dir / name).unlink(missing_ok=True)
    return had


class MlxBackend(Backend):
    kind = "mlx"

    def __init__(self, client: OpenAIClient, folder: Path, catalog, *, runtime_ok: Callable[[], bool] | None = None,
                 launcher: list[str] | None = None, child: list[str] | None = None, wait: float = SERVE_WAIT,
                 state_dir: Path | None = None, idle_minutes: int = 15):
        super().__init__(client, folder)
        self.catalog = catalog
        self.runtime_ok = runtime_ok or (lambda: importlib.util.find_spec("mlx_lm") is not None)
        self.launcher = launcher
        self.child = child
        self.wait = wait
        self.state_dir = state_dir or server_state_dir()
        self.idle_minutes = idle_minutes

    def runtime_missing(self) -> str | None:
        return None if self.runtime_ok() else MLX_MISSING

    def model_id(self, tag: str) -> str:
        return str(fetch.model_dir(self.folder, tag))

    def available(self) -> list[str]:
        return [m.tag for m in self.catalog.models if fetch.state_of(self.folder, m.tag) == "downloaded"]

    def _key(self) -> str | None:
        try:
            return (self.state_dir / "server.key").read_text("utf-8").strip() or None
        except OSError:
            return None

    def _probe(self, nonce: str) -> tuple[dict, str] | None:
        connection = self.client._connection(PROBE_TIMEOUT)
        try:
            connection.request("GET", "/wisp/identity", headers={"X-Wisp-Nonce": nonce})
            response = connection.getresponse()
            if response.status != 200:
                return None
            return json.loads(response.read(4000)), response.getheader("X-Wisp-Proof") or ""
        except (OSError, http.client.HTTPException, ValueError):
            return None
        finally:
            connection.close()

    def _verified(self, model: str | None) -> bool:
        key = self._key()
        if key is None:
            return False
        nonce = secrets.token_hex(16)
        answer = self._probe(nonce)
        if answer is None:
            return False
        identity, given = answer
        if not isinstance(identity, dict) or identity.get("wisp") != "mlx-proxy":
            return False
        if not hmac.compare_digest(given.encode(), proxy.proof(key, nonce).encode()):
            return False
        if identity.get("ready") is not True or (model is not None and identity.get("model") != model):
            return False
        self.client.api_key = key
        return True

    def running(self) -> bool:
        return self._verified(None)

    def stop(self) -> bool:
        return stop_server(self.state_dir)

    def _launch(self, model: str, key: str) -> subprocess.Popen:
        self.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        key_path = self.state_dir / "server.key"
        key_path.unlink(missing_ok=True)
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as out:
            out.write(key)
        marker = f"wisp-mlx-{secrets.token_hex(8)}"
        argv = [*(self.launcher or [sys.executable, "-m", "wisp", "local", "serve"]), "--model-dir", model, "--port", str(self.client.port),
                "--key-file", str(key_path), "--idle-minutes", str(self.idle_minutes), "--state-dir", str(self.state_dir), "--marker", marker]
        if self.child:
            argv += ["--child-json", json.dumps(self.child)]
        return subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    def ensure_running(self, tag: str | None = None) -> None:
        if not arch.host_is_apple_silicon():
            raise BackendError(arch.NEEDS_APPLE_SILICON)
        model = self.model_id(tag) if tag else None
        if self._verified(model):
            return
        if tag is None:
            raise BackendError("o servidor do MLX não está rodando")
        if self.runtime_missing():
            raise BackendError(MLX_MISSING)
        self.stop()
        proc = self._launch(model, secrets.token_hex(32))
        deadline = time.monotonic() + self.wait
        while time.monotonic() < deadline:
            if self._verified(model):
                return
            code = proc.poll()
            if code is not None:
                self.stop()
                raise BackendError(f"o servidor do MLX encerrou ao iniciar (código {code})")
            time.sleep(0.2)
        self.stop()
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        proc.wait()
        raise BackendError("o servidor do MLX não respondeu depois de iniciar; parei o processo")

    def chat(self, tag: str, messages: list[dict], tools: list[dict], options: dict) -> ChatReply:
        self.ensure_running(tag)
        return super().chat(tag, messages, tools, options)

    def readiness(self, active: str) -> str | None:
        if not arch.host_is_apple_silicon():
            return arch.NEEDS_APPLE_SILICON
        if self.runtime_missing():
            return MLX_MISSING
        if not active:
            return "nenhum modelo local está ativo"
        if active not in self.available():
            return f"o modelo {active} não está baixado"
        try:
            self.ensure_running(active)
        except BackendError as e:
            return str(e)
        return None


def make_backend(folder: Path, state, catalog, **mlx) -> Backend:
    if state.backend == "openai":
        if not state.url:
            raise BackendError("falta o endereço do servidor: rode `wisp local backend openai --url ENDEREÇO`")
        return Backend(OpenAIClient(state.url), folder)
    url = os.environ.get("WISP_MLX_URL") or state.url or DEFAULT_MLX_URL
    client = OpenAIClient(url)
    if client.host not in LOOPBACK_HOSTS:
        raise BackendError(MLX_NOT_LOCAL)
    client.think = state.pensar
    return MlxBackend(client, folder, catalog, idle_minutes=state.idle_minutes, **mlx)
