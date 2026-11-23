from __future__ import annotations
import asyncio, json, logging, os, shutil, signal, tomllib
from pathlib import Path
from typing import Awaitable, Callable

from .claude_runner import (LIMITE_LINHA, TELEGRAM_STYLE, WISP_BIN, falha_de_auth, permission_mode, rotulo,
                            strip_status)
from . import soul
from .broker import SOCKET_ENV, Broker, PedirPermissao
from .config import CURRENT as _CFG
from .engine import Result, Status, run_process_status

log = logging.getLogger("wisp.codex")

CODEX_BIN = _CFG.codex_bin
CODEX_FILES_NOTE = ("You are running under Codex, whose sandbox has no network: you cannot send files to Telegram. "
                    "If the user asks for a file, say so plainly instead of trying.")
SANDBOX_ARGS = {
    "auto": ["--sandbox", "workspace-write"],
    "bypassPermissions": ["--sandbox", "workspace-write"],
}
SANDBOX_STRICTEST = ["--sandbox", "read-only"]
NO_WORKSPACE = "não há uma pasta de trabalho segura para o Codex (nem a pasta do Wisp serve: é a pasta pessoal ou uma pasta acima dela)"


def codex_bin() -> str:
    if CODEX_BIN and os.path.isfile(os.path.expanduser(CODEX_BIN)):
        return os.path.expanduser(CODEX_BIN)
    found = shutil.which("codex")
    if found:
        return found
    for candidate in ("~/.local/bin/codex", "~/.npm-global/bin/codex", "~/.bun/bin/codex",
                      "/opt/homebrew/bin/codex", "/usr/local/bin/codex"):
        if os.path.isfile(os.path.expanduser(candidate)):
            return os.path.expanduser(candidate)
    return "codex"


def codex_home() -> Path:
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser()


def configured_model() -> str | None:
    try:
        value = tomllib.loads((codex_home() / "config.toml").read_text("utf-8")).get("model")
    except (OSError, ValueError):
        return None
    return value if isinstance(value, str) and value else None


def toml_string(text: str) -> str:
    return json.dumps(text, ensure_ascii=False).replace("\x7f", "\\u007f")


def permission_args(mode: str) -> list[str]:
    return list(SANDBOX_ARGS.get(mode, SANDBOX_STRICTEST))


def unsafe_root(path: Path) -> bool:
    home = Path.home().resolve()
    return path == home or path in home.parents or path == Path(path.anchor)


def safe_dir(raw: str | Path) -> Path | None:
    text = str(raw).strip()
    if not text:
        return None
    path = Path(os.path.expanduser(text)).resolve()
    return path if path.is_dir() and not unsafe_root(path) else None


def workspace(cwd: str, wisp_dir: Path) -> Path | None:
    return safe_dir(cwd) or safe_dir(wisp_dir)


PROJECT_DEFINES = ("o arquivo {file} define o servidor {name} do Codex; o Wisp não usa o Codex nesta pasta "
                   "enquanto ele existir (apague essa parte do arquivo ou use outra pasta)")
PROJECT_UNREADABLE = ("não consegui ler {file} como TOML; o Wisp não usa o Codex nesta pasta enquanto ele estiver assim "
                      "(corrija o arquivo ou use outra pasta)")


def project_conflict(root: Path | None, home: Path | None = None) -> str | None:
    if root is None:
        return None
    stop = (home or Path.home()).resolve()
    folder = root.resolve()
    while folder != stop and folder != folder.parent:
        file = folder / ".codex" / "config.toml"
        if file.is_file():
            try:
                servers = tomllib.loads(file.read_bytes().decode()).get("mcp_servers")
            except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
                return PROJECT_UNREADABLE.format(file=file)
            taken = next((name for name in ("wisp-email", "wisp-mac") if isinstance(servers, dict) and name in servers), None)
            if taken:
                return PROJECT_DEFINES.format(file=file, name=taken)
        folder = folder.parent
    return None


def extra_dirs(root: Path, brain: Path, wisp_dir: Path) -> list[str]:
    out: list[str] = []
    for folder in (wisp_dir, brain):
        path = safe_dir(folder)
        if path and path != root and root not in path.parents and str(path) not in out:
            out.append(str(path))
    return out


MAC_READ_ONLY = ("mac_apps", "mac_battery", "mac_dnd_status", "mac_screenshot", "mac_shortcuts_list", "mac_ui_tree", "mac_wifi", "mac_windows")
MAC_ALL = ("mac_app", "mac_apps", "mac_battery", "mac_brightness", "mac_dark_mode", "mac_dnd_status", "mac_media", "mac_notify",
           "mac_open", "mac_open_url", "mac_screenshot", "mac_script", "mac_send", "mac_settings_pane", "mac_shortcut",
           "mac_shortcuts_list", "mac_ui_click", "mac_ui_key", "mac_ui_menu", "mac_ui_scroll", "mac_ui_tree", "mac_ui_type",
           "mac_volume", "mac_wifi", "mac_windows")
CHANGING_MODES = ("auto", "bypassPermissions")
OWNABLE = ("wisp-email", "wisp-brain", "wisp-mac")


def mcp_overrides(wisp_bin: str, owned: frozenset[str] = frozenset(), allow_changes: bool = True) -> list[str]:
    mac_tools = "[" + ", ".join(json.dumps(t) for t in (MAC_ALL if allow_changes else MAC_READ_ONLY)) + "]"
    servers = {
        "wisp-email": [
            ("command", toml_string(wisp_bin)),
            ("args", '["mcp", "email"]'),
            ("env_vars", f'["WISP_TELEGRAM_THREAD", "{SOCKET_ENV}"]'),
            ("default_tools_approval_mode", '"approve"'),
            ("startup_timeout_sec", "30"),
            ("tool_timeout_sec", "660"),
            ("enabled", "true"),
        ],
        "wisp-brain": [
            ("command", toml_string(wisp_bin)),
            ("args", '["mcp", "brain"]'),
            ("env_vars", '["WISP_CONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME"]'),
            ("default_tools_approval_mode", '"approve"'),
            ("startup_timeout_sec", "30"),
            ("tool_timeout_sec", "60"),
            ("enabled", "true"),
        ],
        "wisp-mac": [
            ("command", toml_string(wisp_bin)),
            ("args", '["mcp", "mac"]'),
            ("env_vars", f'["WISP_TELEGRAM_THREAD", "{SOCKET_ENV}"]'),
            ("default_tools_approval_mode", '"approve"'),
            ("startup_timeout_sec", "30"),
            ("tool_timeout_sec", "660"),
            ("enabled_tools", mac_tools),
            ("enabled", "true"),
        ],
    }
    return [f"mcp_servers.{name}.{key}={value}" for name, fields in servers.items() if name == "wisp-email" or name not in owned for key, value in fields]


def user_owned_servers() -> frozenset[str]:
    try:
        text = (codex_home() / "config.toml").read_text("utf-8")
        begin, end = text.find("# wisp:begin"), text.find("# wisp:end")
        outside = text[:begin] + text[end + len("# wisp:end"):] if 0 <= begin < end else text
        servers = tomllib.loads(outside).get("mcp_servers")
    except (OSError, ValueError):
        return frozenset()
    return frozenset(name for name in OWNABLE if isinstance(servers, dict) and name in servers)


def command(*, root: Path, mode: str, extra_prompt: str, session: str | None, wisp_bin: str | None = None) -> list[str]:
    cmd = [codex_bin(), "exec", "--json", "--skip-git-repo-check", "-C", str(root), *permission_args(mode)]
    for folder in extra_dirs(root, _CFG.brain, _CFG.wisp_dir):
        cmd += ["--add-dir", folder]
    instructions = "\n\n".join(x for x in (TELEGRAM_STYLE, CODEX_FILES_NOTE, extra_prompt) if x)
    cmd += ["-c", f"developer_instructions={toml_string(instructions)}"]
    for override in mcp_overrides(wisp_bin or WISP_BIN, user_owned_servers(), mode in CHANGING_MODES):
        cmd += ["-c", override]
    if session:
        cmd += ["resume", session]
    return cmd + ["-"]


def item_label(item: dict) -> str | None:
    kind = item.get("type")
    if kind == "command_execution":
        return rotulo({"name": "Bash", "input": {"command": item.get("command") or ""}})
    if kind == "mcp_tool_call":
        return f"usando {item.get('server') or 'uma ferramenta'}"
    if kind == "file_change":
        changes = item.get("changes") or []
        first = changes[0].get("path") if changes and isinstance(changes[0], dict) else ""
        return rotulo({"name": "Edit", "input": {"file_path": first}})
    if kind == "web_search":
        return "pesquisando na web"
    return None


class Stream:
    def __init__(self) -> None:
        self.thread_id: str | None = None
        self.turn_started = False
        self.message: str | None = None
        self.failure: str | None = None
        self.last_error: str | None = None
        self.completed = False

    def feed(self, event: dict) -> list[tuple[str, str]]:
        kind = event.get("type")
        item = event.get("item") if isinstance(event.get("item"), dict) else {}
        if kind == "thread.started" and isinstance(event.get("thread_id"), str):
            self.thread_id = event["thread_id"]
        elif kind == "turn.started":
            self.turn_started = True
        elif kind == "turn.completed":
            self.completed = True
        elif kind == "turn.failed":
            self.failure = str((event.get("error") or {}).get("message") or "o turno falhou")
        elif kind == "error":
            self.last_error = str(event.get("message") or "erro do Codex")
        elif kind == "item.started":
            label = item_label(item) if item.get("type") != "file_change" else None
            return [("label", label)] if label else []
        elif kind == "item.completed":
            if item.get("type") == "agent_message" and item.get("text"):
                self.message = str(item["text"])
                return [("text", self.message)]
            label = item_label(item) if item.get("type") == "file_change" else None
            return [("label", label)] if label else []
        return []


def failure_text(returncode: int, stream: Stream, stderr: str) -> str:
    detail = stream.failure or stream.last_error or stderr.strip()[-600:]
    if falha_de_auth(detail, stderr) or "401" in detail:
        detail = f"{detail}\nConserto: rodar `codex login` nesta máquina.".strip()
    return "\n".join(x for x in (f"codex saiu com {returncode}", detail) if x)


async def run(prompt: str, *, session_id: str, cwd: str, started: bool, model: str | None = None,
              timeout: int = 900, extra_prompt: str = "", disallowed: str = "", env: dict | None = None,
              no_tools: bool = False, on_event: Callable[[str], None] | None = None,
              on_text: Callable[[str], Awaitable[None] | None] | None = None,
              on_permission: PedirPermissao | None = None) -> Result:
    extra_prompt = soul.append(extra_prompt, await soul.text("codex", WISP_BIN))
    broker = None
    if on_permission:
        try:
            broker = await Broker(on_permission).start()
        except OSError as e:
            log.warning("sem canal de aprovacao neste turno do codex (o envio de e-mail fica negado): %s", e)
    try:
        return await _turn(prompt, session_id=session_id, cwd=cwd, started=started, model=model, timeout=timeout,
                           extra_prompt=extra_prompt, env=env, no_tools=no_tools, on_event=on_event, on_text=on_text,
                           socket=broker.path if broker else None)
    finally:
        if broker:
            await broker.close()


async def _turn(prompt: str, *, session_id: str, cwd: str, started: bool, model: str | None, timeout: int,
                extra_prompt: str, env: dict | None, no_tools: bool, on_event: Callable[[str], None] | None,
                on_text: Callable[[str], Awaitable[None] | None] | None, socket: str | None) -> Result:
    mode = "default" if no_tools else permission_mode()
    root = workspace(cwd, _CFG.wisp_dir)
    if root is None:
        return Result(False, NO_WORKSPACE, engine="codex")
    conflict = project_conflict(root)
    if conflict:
        return Result(False, conflict, engine="codex")
    cmd = command(root=root, mode=mode, extra_prompt=extra_prompt, session=session_id if started else None)
    log.info("permissao do turno no codex: %s; pasta %s", mode, root)
    child_env = {**os.environ, "WISP_SKIP_PULL": "1", **(env or {}), "WISP_BIN": WISP_BIN}
    child_env.pop(SOCKET_ENV, None)
    if socket:
        child_env[SOCKET_ENV] = socket
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, cwd=str(root), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, limit=LIMITE_LINHA, start_new_session=True, env=child_env)
    except FileNotFoundError:
        return Result(False, f"binario do codex nao encontrado: {codex_bin()}", engine="codex")

    stream = Stream()
    tasks: list[asyncio.Task] = []

    def emit(kind: str, value: str) -> None:
        try:
            if kind == "label" and on_event:
                on_event(value)
            elif kind == "text" and on_text:
                r = on_text(value)
                if asyncio.iscoroutine(r) or isinstance(r, asyncio.Future):
                    tasks.append(asyncio.ensure_future(r))
        except Exception:
            pass

    async def read_stdout() -> None:
        async for raw in proc.stdout:
            try:
                event = json.loads(raw.decode("utf-8", "replace"))
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                for kind, value in stream.feed(event):
                    emit(kind, value)

    async def everything() -> bytes:
        proc.stdin.write(prompt.encode("utf-8"))
        try:
            await proc.stdin.drain()
            proc.stdin.close()
        except (BrokenPipeError, ConnectionResetError):
            pass
        _, err, _ = await asyncio.gather(read_stdout(), proc.stderr.read(), proc.wait())
        return err

    async def kill() -> None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            await asyncio.wait_for(proc.wait(), 5)
        except Exception:
            pass

    try:
        err = (await asyncio.wait_for(everything(), timeout=timeout)).decode("utf-8", "replace")
    except asyncio.TimeoutError:
        await kill()
        return Result(False, f"estourou {timeout}s e foi morto", engine="codex")
    except Exception as e:
        await kill()
        return Result(False, f"leitura do codex falhou: {type(e).__name__}: {e}", engine="codex")
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)

    if proc.returncode == 0 and not stream.completed and not stream.failure:
        return Result(False, "o Codex terminou sem concluir o turno", engine="codex")
    if proc.returncode != 0 or stream.failure:
        if started and not stream.turn_started and not falha_de_auth(err, stream.failure or ""):
            return Result(False, "a sessão do codex não existe mais aqui", resume_failed=True, engine="codex")
        return Result(False, failure_text(proc.returncode or 1, stream, err), engine="codex")
    return Result(True, strip_status(stream.message or "") or "(resposta vazia)",
                  session_id=stream.thread_id, model=model_name(), engine="codex")


def model_name() -> str:
    return configured_model() or ""


GATE_STALE = "está com o envio de e-mail sem a trava de aprovação; rode `wisp harness sync`"


async def gate_stale(timeout: float = 15) -> str | None:
    try:
        proc = await asyncio.create_subprocess_exec(
            WISP_BIN, "codex", "check", stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, start_new_session=True)
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await proc.wait()
            log.warning("wisp codex check estourou %ss", timeout)
            return GATE_STALE
        verdict = json.loads(out.decode("utf-8", "replace"))
    except (OSError, ValueError):
        log.warning("nao consegui rodar `wisp codex check`")
        return GATE_STALE
    if isinstance(verdict, dict) and verdict.get("ready") is True and proc.returncode == 0:
        return None
    log.warning("a trava de e-mail do Codex nao esta em dia: %s", verdict.get("problem") if isinstance(verdict, dict) else verdict)
    return GATE_STALE


class CodexEngine:
    name = "codex"

    async def run(self, prompt: str, **kwargs) -> Result:
        return await run(prompt, **kwargs)

    async def status(self) -> Status:
        binary = codex_bin()
        installed = os.path.isfile(binary) and await run_process_status(binary, "--version") == 0
        logged_in = installed and await run_process_status(binary, "login", "status") == 0
        problem = None if safe_dir(_CFG.wisp_dir) else "não tem uma pasta de trabalho segura (a pasta do Wisp é a pasta pessoal ou fica acima dela)"
        if problem is None and installed and logged_in:
            problem = await gate_stale()
        return Status(installed=installed, logged_in=logged_in, problem=problem)


CODEX = CodexEngine()
