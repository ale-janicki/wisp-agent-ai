import http.client
import json
import os
import shutil
import signal
import subprocess
import time
import urllib.request
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

DEFAULT_URL = "http://127.0.0.1:11434"
DOWNLOAD_URL = "https://ollama.com/download/Ollama-darwin.zip"
CHAT_TIMEOUT = 600.0
PROBE_TIMEOUT = 3.0
SERVE_WAIT = 30.0
INSTALL_CHUNK = 1 << 20
MAX_DOWNLOAD = 1_500_000_000
TEAM_ID = "3MU9H2V9Y9"
REQUIREMENT = (
    'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
    'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
    f'and certificate leaf[subject.OU] = "{TEAM_ID}"'
)
CLI_IN_APP = "Ollama.app/Contents/Resources/ollama"


class OllamaError(Exception):
    pass


@dataclass
class ChatReply:
    content: str = ""
    thinking: str = ""
    tool_calls: list[dict] = field(default_factory=list)
    prompt_tokens: int = 0
    reply_tokens: int = 0


def url_from_env() -> str:
    return os.environ.get("WISP_OLLAMA_URL", DEFAULT_URL)


def install_root() -> Path:
    return Path.home() / ".local/share/wisp/ollama"


def cli_candidates() -> list[Path]:
    home = Path.home()
    found = shutil.which("ollama")
    return [
        install_root() / CLI_IN_APP,
        Path("/Applications") / CLI_IN_APP,
        home / "Applications" / CLI_IN_APP,
        *([Path(found)] if found else []),
        Path("/opt/homebrew/bin/ollama"),
        Path("/usr/local/bin/ollama"),
    ]


def find_cli() -> Path | None:
    return next((p for p in cli_candidates() if p.is_file() and os.access(p, os.X_OK)), None)


class OllamaClient:
    def __init__(self, url: str | None = None, *, chat_timeout: float = CHAT_TIMEOUT):
        parts = urlsplit(url or url_from_env())
        if parts.scheme != "http" or not parts.hostname:
            raise OllamaError(f"endereço do Ollama inválido: {url}")
        self.host = parts.hostname
        self.port = parts.port or 80
        self.chat_timeout = chat_timeout

    def _connection(self, timeout: float) -> http.client.HTTPConnection:
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def _stream(self, path: str, body: dict | None, timeout: float) -> Iterator[dict]:
        connection = self._connection(timeout)
        try:
            payload = None if body is None else json.dumps(body).encode()
            connection.request("GET" if body is None else "POST", path, payload, {"Content-Type": "application/json"})
            response = connection.getresponse()
            if response.status != 200:
                detail = response.read(2000).decode("utf-8", "replace").strip()
                raise OllamaError(f"o Ollama respondeu {response.status}: {detail or response.reason}")
            for raw in response:
                line = raw.strip()
                if not line:
                    continue
                try:
                    chunk = json.loads(line)
                except ValueError:
                    raise OllamaError("o Ollama mandou uma resposta que não consegui ler") from None
                if isinstance(chunk, dict) and chunk.get("error"):
                    raise OllamaError(f"o Ollama falhou: {chunk['error']}")
                yield chunk
        except (OSError, http.client.HTTPException) as e:
            raise OllamaError(f"não consegui falar com o Ollama em {self.host}:{self.port} ({type(e).__name__})") from None
        finally:
            connection.close()

    def running(self) -> bool:
        try:
            return any(True for _ in self._stream("/api/version", None, PROBE_TIMEOUT))
        except OllamaError:
            return False

    def tags(self) -> dict[str, int]:
        for chunk in self._stream("/api/tags", None, PROBE_TIMEOUT * 3):
            return {m["name"]: int(m.get("size", 0)) for m in chunk.get("models", []) if isinstance(m, dict) and "name" in m}
        return {}

    def chat(self, model: str, messages: list[dict], tools: list[dict], options: dict) -> ChatReply:
        body = {"model": model, "messages": messages, "tools": tools, "stream": True, "options": options}
        reply = ChatReply()
        for chunk in self._stream("/api/chat", body, self.chat_timeout):
            message = chunk.get("message") or {}
            reply.content += message.get("content") or ""
            reply.thinking += message.get("thinking") or ""
            reply.tool_calls += [c for c in message.get("tool_calls") or [] if isinstance(c, dict)]
            if chunk.get("done"):
                reply.prompt_tokens = int(chunk.get("prompt_eval_count") or 0)
                reply.reply_tokens = int(chunk.get("eval_count") or 0)
        return reply

    def pull(self, model: str) -> Iterator[dict]:
        return self._stream("/api/pull", {"model": model, "stream": True}, self.chat_timeout)

    def ensure_running(self, cli: Path | None = None, *, wait: float = SERVE_WAIT, sleep: Callable[[float], None] = time.sleep) -> None:
        if self.running():
            return
        binary = cli or find_cli()
        if binary is None:
            raise OllamaError("o Ollama não está instalado; instale pelo Wisp em Ajustes > Modelo")
        proc = subprocess.Popen(
            [str(binary), "serve"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            if self.running():
                return
            code = proc.poll()
            if code is not None:
                raise OllamaError(f"o Ollama encerrou ao iniciar (código {code})")
            sleep(0.2)
        raise OllamaError("o Ollama não respondeu depois de iniciar")


def free_bytes(path: Path) -> int:
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    return shutil.disk_usage(probe).free


def room_problem(need_bytes: int, free: int, margin: int) -> str | None:
    if free >= need_bytes + margin:
        return None
    short = need_bytes + margin - free
    return f"falta espaço em disco: preciso de {_gb(need_bytes)} GB mais {_gb(margin)} GB de folga e há {_gb(free)} GB livres (faltam {_gb(short)} GB)"


def _gb(value: int) -> str:
    return f"{value / 1e9:.1f}"


class _Cancelled(SystemExit):
    pass


def _terminate(signum, frame):
    raise _Cancelled(1)


def verify_app(app: Path, run: Callable[..., subprocess.CompletedProcess]) -> str | None:
    checks = [
        (["/usr/bin/codesign", "--verify", "--deep", "--strict", f"-R={REQUIREMENT}", str(app)], "a assinatura não é da Ollama"),
        (["/usr/bin/xcrun", "stapler", "validate", str(app)], "o Ollama baixado não tem a notarização da Apple"),
        (["/usr/sbin/spctl", "-a", "-t", "exec", "-vv", str(app)], "o macOS não aceitou o Ollama baixado"),
    ]
    for argv, message in checks:
        if run(argv, capture_output=True, text=True, timeout=120).returncode != 0:
            return message
    return None


def install(
    emit: Callable[[dict], None],
    *,
    url: str = DOWNLOAD_URL,
    root: Path | None = None,
    margin: int,
    run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
) -> Path:
    root = root or install_root()
    partial = root / ".download"
    shutil.rmtree(partial, ignore_errors=True)
    partial.mkdir(parents=True, exist_ok=True)
    archive = partial / "Ollama-darwin.zip"
    previous = signal.signal(signal.SIGTERM, _terminate)
    try:
        emit({"status": "downloading", "completed": 0, "total": 0})
        with urllib.request.urlopen(url, timeout=60) as response:
            total = int(response.headers.get("Content-Length") or 0)
            if total <= 0:
                raise OllamaError("o servidor não informou o tamanho do download; não baixei")
            if total > MAX_DOWNLOAD:
                raise OllamaError("o download do Ollama é maior que o esperado; não baixei")
            problem = room_problem(total * 3, free_bytes(root), margin)
            if problem:
                raise OllamaError(problem)
            done, last = 0, -1
            with archive.open("wb") as out:
                while chunk := response.read(INSTALL_CHUNK):
                    done += len(chunk)
                    if done > total:
                        raise OllamaError("o download do Ollama passou do tamanho informado; parei")
                    out.write(chunk)
                    step = done * 100 // total
                    if step != last:
                        last = step
                        emit({"status": "downloading", "completed": done, "total": total})
        if done != total:
            raise OllamaError("o download do Ollama veio incompleto")
        emit({"status": "unpacking"})
        target = root / "Ollama.app"
        shutil.rmtree(target, ignore_errors=True)
        unpacked = run(["/usr/bin/ditto", "-x", "-k", str(archive), str(root)], capture_output=True, text=True, timeout=300)
        if unpacked.returncode != 0 or not target.is_dir():
            raise OllamaError("não consegui abrir o arquivo do Ollama")
        emit({"status": "verifying"})
        problem = verify_app(target, run)
        if problem:
            shutil.rmtree(target, ignore_errors=True)
            raise OllamaError(f"{problem}; não instalei")
        cli = root / CLI_IN_APP
        if not cli.is_file():
            raise OllamaError("o Ollama baixado não tem o comando esperado")
        return cli
    finally:
        signal.signal(signal.SIGTERM, previous)
        shutil.rmtree(partial, ignore_errors=True)
