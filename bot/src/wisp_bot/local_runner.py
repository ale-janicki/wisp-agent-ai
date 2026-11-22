from __future__ import annotations
import asyncio, json, logging, os, signal
from pathlib import Path
from typing import Awaitable, Callable

from .claude_runner import LIMITE_LINHA, SEM_CANAL, WISP_BIN, permission_mode, strip_status
from .config import CURRENT as _CFG
from .engine import Result, Status
from .broker import SOCKET_ENV, PedirPermissao

log = logging.getLogger("wisp.local")

NEGADO = "Não consegui perguntar ao usuário, então a ação foi negada. Siga sem ela."
READY_TIMEOUT_S = 45


def launch() -> list[str]:
    return [WISP_BIN]


def command(*, prompt: str, conversation: str, mode: str, thread: str | None) -> list[str]:
    cmd = [*launch(), "local", "chat", f"--message={prompt}", "--approvals", "stdio", "--no-record", "--recorded",
           "--surface", "telegram", "--mode", mode]
    if conversation:
        cmd += ["--conversation", conversation]
    if thread:
        cmd += ["--thread", thread]
    return cmd


def tool_label(item: dict) -> str:
    name = item.get("name") or ""
    given = item.get("input") if isinstance(item.get("input"), dict) else {}
    base = os.path.basename(str(given.get("path") or "").rstrip("/"))
    if name == "read_file":
        return f"lendo {base}"[:80]
    if name == "write_file":
        return f"editando {base}"[:80]
    if name == "list_files":
        return "listando arquivos"
    if name == "run_shell":
        return "rodando um comando"
    if name.startswith("email_"):
        return "usando o e-mail"
    return "trabalhando"


async def run(prompt: str, *, session_id: str, cwd: str, started: bool, model: str | None = None,
              timeout: int = 900, extra_prompt: str = "", disallowed: str = "", env: dict | None = None,
              no_tools: bool = False, on_event: Callable[[str], None] | None = None,
              on_text: Callable[[str], Awaitable[None] | None] | None = None,
              on_permission: PedirPermissao | None = None) -> Result:
    mode = "default" if no_tools else permission_mode()
    child_env = {**os.environ, "WISP_SKIP_PULL": "1", **(env or {}), "WISP_BIN": WISP_BIN}
    child_env.pop(SOCKET_ENV, None)
    root = str(_CFG.wisp_dir) if Path(_CFG.wisp_dir).is_dir() else str(Path.home())
    cmd = command(prompt=prompt, conversation=session_id, mode=mode, thread=child_env.get("WISP_TELEGRAM_THREAD"))
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, cwd=root, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, limit=LIMITE_LINHA, start_new_session=True, env=child_env)
    except OSError as e:
        return Result(False, f"não consegui iniciar a IA local ({type(e).__name__})", engine="local")

    final: dict | None = None
    failure: str | None = None
    tasks: list[asyncio.Task] = []
    pending: dict[str, asyncio.Future] = {}

    async def write(line: dict) -> None:
        try:
            proc.stdin.write((json.dumps(line, ensure_ascii=False) + "\n").encode("utf-8"))
            await proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass

    async def answer(request_id: str, request: dict) -> None:
        denial: str | None = SEM_CANAL
        if on_permission:
            try:
                denial = await on_permission({**request, "engine": "local"})
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("pedido de permissao %s falhou: %s", request_id, e)
                denial = NEGADO
        body = ({"behavior": "allow", "updatedInput": request.get("input") if isinstance(request.get("input"), dict) else {}}
                if denial is None else {"behavior": "deny", "message": denial})
        await write({"type": "control_response", "response": {"subtype": "success", "request_id": request_id, "response": body}})

    def emit_text(text: str) -> None:
        if not on_text:
            return
        try:
            result = on_text(text)
            if asyncio.iscoroutine(result) or isinstance(result, asyncio.Future):
                tasks.append(asyncio.ensure_future(result))
        except Exception:
            pass

    async def read_stdout() -> None:
        nonlocal final, failure
        async for raw in proc.stdout:
            try:
                event = json.loads(raw.decode("utf-8", "replace"))
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            kind = event.get("type")
            if kind == "result":
                final = event
            elif kind == "error":
                failure = str(event.get("message") or "a IA local falhou")
            elif kind == "control_request":
                request, request_id = event.get("request"), event.get("request_id")
                if isinstance(request, dict) and request.get("subtype") == "can_use_tool" and isinstance(request_id, str) and request_id:
                    pending[request_id] = asyncio.ensure_future(answer(request_id, request))
            elif kind == "assistant":
                content = (event.get("message") or {}).get("content")
                for item in content if isinstance(content, list) else []:
                    if not isinstance(item, dict):
                        continue
                    if item.get("type") == "text" and item.get("text"):
                        emit_text(str(item["text"]))
                    elif item.get("type") == "tool_use" and on_event:
                        try:
                            on_event(tool_label(item))
                        except Exception:
                            pass

    async def cancel_pending() -> None:
        open_ones = list(pending.values())
        for task in open_ones:
            task.cancel()
        await asyncio.gather(*open_ones, return_exceptions=True)
        pending.clear()

    async def everything() -> bytes:
        _, err, _ = await asyncio.gather(read_stdout(), proc.stderr.read(), proc.wait())
        await cancel_pending()
        return err

    async def kill() -> None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await cancel_pending()
        try:
            await asyncio.wait_for(proc.wait(), 5)
        except Exception:
            pass

    try:
        err = (await asyncio.wait_for(everything(), timeout=timeout)).decode("utf-8", "replace")
    except asyncio.TimeoutError:
        await kill()
        return Result(False, f"estourou {timeout}s e foi morto", engine="local")
    except Exception as e:
        await kill()
        return Result(False, f"leitura da IA local falhou: {type(e).__name__}: {e}", engine="local")
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
    try:
        proc.stdin.close()
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass

    model_name = final.get("model") if isinstance(final, dict) and isinstance(final.get("model"), str) else None
    if final is None:
        detail = failure or err.strip()[-600:] or "a IA local terminou sem concluir o turno"
        return Result(False, detail, engine="local")
    text = strip_status(final.get("result") or "") or "(resposta vazia)"
    return Result(ok=not final.get("is_error", False) and proc.returncode == 0, text=text,
                  session_id=session_id or None, model=model_name, engine="local")


async def readiness(timeout: float = READY_TIMEOUT_S) -> tuple[bool, str | None]:
    try:
        proc = await asyncio.create_subprocess_exec(
            *launch(), "local", "ready", stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, start_new_session=True)
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await proc.wait()
            return False, "o servidor local não respondeu a tempo"
    except OSError:
        return False, "não achei o comando do Wisp"
    for line in out.decode("utf-8", "replace").splitlines():
        try:
            verdict = json.loads(line)
        except ValueError:
            continue
        if isinstance(verdict, dict) and verdict.get("type") == "ready":
            return verdict.get("ready") is True, verdict.get("missing") if isinstance(verdict.get("missing"), str) else None
        if isinstance(verdict, dict) and verdict.get("type") == "error":
            return False, str(verdict.get("message") or "a IA local falhou")
    return False, "não consegui conferir a IA local"


class LocalEngine:
    name = "local"

    async def run(self, prompt: str, **kwargs) -> Result:
        return await run(prompt, **kwargs)

    async def status(self) -> Status:
        ready, missing = await readiness()
        installed = not (missing or "").startswith("o componente de IA local ainda está sendo instalado")
        return Status(installed=installed, logged_in=True, problem=None if ready else (missing or "não está pronta"))


LOCAL = LocalEngine()
