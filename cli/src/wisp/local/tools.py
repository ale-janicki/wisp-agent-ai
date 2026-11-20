import os
import signal
import unicodedata
import subprocess
import sys
import tomllib
from collections.abc import AsyncIterator, Callable
from contextlib import AsyncExitStack, asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path

import anyio
import anyio.to_thread
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import get_default_environment, stdio_client

from wisp.secrets_scan import scan_text

CONNECT_TIMEOUT = 30.0
SHELL_TIMEOUT = 60.0
READ_LIMIT = 100_000
WRITE_LIMIT = 200_000
OUTPUT_LIMIT = 8_000
LISTING_LIMIT = 200
PASS_THROUGH_ENV = ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "WISP_CONFIG", "WISP_RESOURCES")
SERVER_KEYS = {"name", "command", "args", "env"}
EMAIL_SERVER = "wisp-email"
EMAIL_TOOLS = frozenset({"email_list", "email_read", "email_search", "email_send"})
BUILTIN_TOOLS = frozenset({"read_file", "list_files", "write_file", "run_shell"})
RESERVED_TOOLS = EMAIL_TOOLS | BUILTIN_TOOLS
CONTROL_FILES = frozenset({"guardrails.toml", "modelos.toml", "agente.md"})
CONTROL_DIRS = frozenset({"ferramentas", "skills", "conversas"})


class ToolFailure(Exception):
    pass


@dataclass(frozen=True)
class ToolSpec:
    name: str
    description: str
    schema: dict

    def for_ollama(self) -> dict:
        return {"type": "function", "function": {"name": self.name, "description": self.description, "parameters": self.schema}}


@dataclass(frozen=True)
class ServerSpec:
    name: str
    command: str
    args: tuple[str, ...] = ()
    env: tuple[tuple[str, str], ...] = ()
    trusted: bool = False


@dataclass
class ToolHost:
    specs: dict[str, ToolSpec] = field(default_factory=dict)
    problems: list[str] = field(default_factory=list)
    _builtin: dict[str, Callable[[dict], str]] = field(default_factory=dict)
    _sessions: dict[str, ClientSession] = field(default_factory=dict)

    async def call(self, name: str, arguments: dict) -> str:
        if name in self._builtin:
            return await anyio.to_thread.run_sync(self._builtin[name], arguments)
        session = self._sessions.get(name)
        if session is None:
            raise ToolFailure(f"a ferramenta {name} não existe")
        result = await session.call_tool(name, arguments)
        text = "\n".join(getattr(block, "text", "") for block in result.content).strip()
        if result.is_error:
            raise ToolFailure(text or f"a ferramenta {name} falhou")
        return text


def _object(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required}


def _text(description: str) -> dict:
    return {"type": "string", "description": description}


def _key(path: Path) -> str:
    return unicodedata.normalize("NFC", str(path)).casefold()


class Files:
    def __init__(self, roots: list[Path]):
        self.roots = [r.resolve() for r in roots]

    def confine(self, raw: object) -> Path:
        if not isinstance(raw, str) or not raw:
            raise ToolFailure("informe o caminho do arquivo")
        path = Path(raw).expanduser()
        if not path.is_absolute():
            path = self.roots[0] / path
        resolved = path.resolve()
        if not any(resolved.is_relative_to(root) for root in self.roots):
            raise ToolFailure(f"só posso mexer em arquivos dentro de {', '.join(str(r) for r in self.roots)}")
        return resolved

    def is_control(self, resolved: Path) -> bool:
        key = _key(resolved)
        root = self.roots[0]
        if not resolved.is_relative_to(root):
            return False
        parts = [unicodedata.normalize("NFC", part).casefold() for part in resolved.relative_to(root).parts]
        return bool(parts) and (parts[0] in CONTROL_DIRS or (len(parts) == 1 and parts[0] in CONTROL_FILES))

    def read(self, args: dict) -> str:
        path = self.confine(args.get("path"))
        try:
            raw = path.read_bytes()[:READ_LIMIT]
        except OSError as e:
            raise ToolFailure(f"não consegui ler {path}: {e.strerror or type(e).__name__}") from None
        text = raw.decode("utf-8", "replace")
        if scan_text(text):
            raise ToolFailure(f"{path.name} parece conter uma senha ou chave; não vou ler")
        return text

    def list(self, args: dict) -> str:
        path = self.confine(args.get("path", "."))
        try:
            names = sorted(f"{p.name}/" if p.is_dir() else p.name for p in path.iterdir())
        except OSError as e:
            raise ToolFailure(f"não consegui listar {path}: {e.strerror or type(e).__name__}") from None
        extra = f"\n(+{len(names) - LISTING_LIMIT} itens)" if len(names) > LISTING_LIMIT else ""
        return "\n".join(names[:LISTING_LIMIT]) + extra

    def write(self, args: dict) -> str:
        path = self.confine(args.get("path"))
        if self.is_control(path):
            raise ToolFailure("esse arquivo faz parte das regras e ferramentas do Wisp; só o usuário pode alterá-lo")
        content = args.get("content")
        if not isinstance(content, str) or len(content) > WRITE_LIMIT:
            raise ToolFailure(f"o conteúdo precisa ser texto de até {WRITE_LIMIT} caracteres")
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, "utf-8")
        except OSError as e:
            raise ToolFailure(f"não consegui gravar {path}: {e.strerror or type(e).__name__}") from None
        return f"gravei {len(content)} caracteres em {path}"


def run_shell(workdir: Path, args: dict, timeout: float = SHELL_TIMEOUT) -> str:
    command = args.get("command")
    if not isinstance(command, str) or not command.strip():
        raise ToolFailure("informe o comando")
    proc = subprocess.Popen(
        ["/bin/sh", "-c", command], cwd=workdir, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, start_new_session=True,
    )
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        raise ToolFailure(f"o comando passou de {int(timeout)} s e foi interrompido") from None
    tail = out[-OUTPUT_LIMIT:]
    if proc.returncode != 0:
        raise ToolFailure(f"saiu com código {proc.returncode}\n{tail}")
    return tail


def builtins(roots: list[Path], workdir: Path) -> tuple[dict[str, ToolSpec], dict[str, Callable[[dict], str]]]:
    files = Files(roots)
    specs = [
        ToolSpec("read_file", "Lê um arquivo de texto da pasta do Wisp ou do brain", _object({"path": _text("caminho do arquivo")}, ["path"])),
        ToolSpec("list_files", "Lista os arquivos de uma pasta do Wisp ou do brain", _object({"path": _text("caminho da pasta")}, [])),
        ToolSpec(
            "write_file", "Grava (substitui) um arquivo de texto na pasta do Wisp ou no brain",
            _object({"path": _text("caminho do arquivo"), "content": _text("conteúdo completo")}, ["path", "content"]),
        ),
        ToolSpec("run_shell", "Roda um comando no terminal do Mac", _object({"command": _text("comando")}, ["command"])),
    ]
    runs: dict[str, Callable[[dict], str]] = {
        "read_file": files.read, "list_files": files.list, "write_file": files.write,
        "run_shell": lambda args: run_shell(workdir, args),
    }
    return {s.name: s for s in specs}, runs


def email_server() -> ServerSpec:
    return ServerSpec(EMAIL_SERVER, sys.executable, ("-m", "wisp", "mcp", "email"), trusted=True)


def load_servers(folder: Path) -> tuple[list[ServerSpec], list[str]]:
    servers, problems = [email_server()], []
    for path in sorted((folder / "ferramentas").glob("*.toml")):
        try:
            raw = tomllib.loads(path.read_text("utf-8"))
            args, env = raw.get("args", []), raw.get("env", {})
            if set(raw) - SERVER_KEYS or not isinstance(raw.get("name"), str) or not isinstance(raw.get("command"), str) \
                    or not isinstance(args, list) or not all(isinstance(a, str) for a in args) \
                    or not isinstance(env, dict) or not all(isinstance(v, str) for v in env.values()):
                raise ValueError("name, command, args e env")
        except (OSError, ValueError, UnicodeDecodeError) as e:
            problems.append(f"ferramentas/{path.name} inválido ({e}); ignorei")
            continue
        if raw["name"] == EMAIL_SERVER:
            problems.append(f"ferramentas/{path.name} usa o nome {EMAIL_SERVER}, que é reservado; ignorei")
            continue
        servers.append(ServerSpec(raw["name"], raw["command"], tuple(args), tuple(env.items())))
    return servers, problems


def server_environment(thread: int | None, extra: tuple[tuple[str, str], ...] = ()) -> dict[str, str]:
    env = get_default_environment()
    env.update(extra)
    env.update({k: os.environ[k] for k in PASS_THROUGH_ENV if k in os.environ})
    if thread is not None:
        env["WISP_TELEGRAM_THREAD"] = str(thread)
    return env


@asynccontextmanager
async def open_host(
    servers: list[ServerSpec], roots: list[Path], workdir: Path, thread: int | None = None, connect_timeout: float = CONNECT_TIMEOUT,
) -> AsyncIterator[ToolHost]:
    specs, runs = builtins(roots, workdir)
    host = ToolHost(specs=dict(specs), _builtin=dict(runs))
    async with AsyncExitStack() as stack:
        for server in servers:
            guard = AsyncExitStack()
            try:
                params = StdioServerParameters(command=server.command, args=list(server.args), env=server_environment(thread, server.env))
                read, write = await guard.enter_async_context(stdio_client(params))
                session = await guard.enter_async_context(ClientSession(read, write))
                with anyio.fail_after(connect_timeout):
                    await session.initialize()
                    listed = await session.list_tools()
            except BaseException as e:
                try:
                    await guard.aclose()
                except BaseException:
                    pass
                if not isinstance(e, Exception):
                    raise
                host.problems.append(f"a ferramenta {server.name} não abriu ({type(e).__name__})")
                continue
            stack.push_async_callback(guard.aclose)
            for tool in listed.tools:
                if tool.name in RESERVED_TOOLS and not (server.trusted and tool.name in EMAIL_TOOLS):
                    host.problems.append(f"{server.name}: o nome {tool.name} é reservado do Wisp; ignorei")
                    continue
                if tool.name in host.specs:
                    host.problems.append(f"{server.name}: a ferramenta {tool.name} repete um nome já usado; ignorei")
                    continue
                host.specs[tool.name] = ToolSpec(tool.name, tool.description or "", dict(tool.input_schema))
                host._sessions[tool.name] = session
        yield host
