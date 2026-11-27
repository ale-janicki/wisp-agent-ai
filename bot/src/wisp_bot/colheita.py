from __future__ import annotations
import asyncio, json, logging

from . import compat
from .claude_runner import WISP_BIN

log = logging.getLogger("wisp.colheita")

INTERVALO_S = 600
PRIMEIRA_S = 120
TIMEOUT_S = 1800
ARGS = ("brain", "colher", "--if-due", "--json")


def contagens(saida: bytes) -> tuple[int, int] | None:
    try:
        rel = json.loads(saida.decode("utf-8", "replace"))
        return len(rel["colhidas"]), len(rel["puladas"])
    except (ValueError, KeyError, TypeError):
        return None


async def rodar_uma_vez(wisp_bin: str = WISP_BIN, timeout: float = TIMEOUT_S) -> tuple[int, int] | None:
    proc = await asyncio.create_subprocess_exec(
        wisp_bin, *ARGS, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL, **compat.new_session_kwargs())
    try:
        saida, _ = await asyncio.wait_for(proc.communicate(), timeout)
    except BaseException:
        try:
            compat.kill_process_tree(proc.pid, compat.SIGKILL)
        except ProcessLookupError:
            pass
        await proc.wait()
        raise
    return contagens(saida) if proc.returncode == 0 else None


async def vigiar(parar: asyncio.Event, wisp_bin: str = WISP_BIN, intervalo: float = INTERVALO_S,
                 primeira: float = PRIMEIRA_S) -> None:
    await asyncio.sleep(primeira)
    while not parar.is_set():
        try:
            c = await rodar_uma_vez(wisp_bin)
            if c is None:
                log.warning("colheita: saida ilegivel ou erro")
            else:
                log.info("colheita: colhidas=%s puladas=%s", c[0], c[1])
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("colheita quebrou: %r", e)
        await asyncio.sleep(intervalo)
