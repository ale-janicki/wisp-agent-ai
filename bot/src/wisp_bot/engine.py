from __future__ import annotations
import asyncio, html, logging, time, tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable, Protocol

log = logging.getLogger("wisp.engine")

ENGINES = ("claude", "codex", "local")
DEFAULT = "claude"
STATUS_TTL_S = 30


@dataclass
class Result:
    ok: bool
    text: str
    session_id: str | None = None
    cost_usd: float | None = None
    model: str | None = None
    resume_failed: bool = False
    engine: str = DEFAULT


@dataclass(frozen=True)
class Status:
    installed: bool
    logged_in: bool
    problem: str | None = None

    @property
    def ready(self) -> bool:
        return self.installed and self.logged_in and self.problem is None


class Engine(Protocol):
    name: str

    async def run(self, prompt: str, *, session_id: str, cwd: str, started: bool,
                  model: str | None = None, timeout: int = 900, extra_prompt: str = "",
                  disallowed: str = "", env: dict | None = None, no_tools: bool = False,
                  on_event: Callable[[str], None] | None = None,
                  on_text: Callable[[str], Awaitable[None] | None] | None = None,
                  on_permission: Callable[[dict], Awaitable[str | None]] | None = None) -> Result: ...

    async def status(self) -> Status: ...


def active_name(wisp_dir: Path) -> str:
    try:
        value = tomllib.loads((wisp_dir / "modelos.toml").read_text("utf-8")).get("ativo")
    except (OSError, ValueError):
        return DEFAULT
    return value if isinstance(value, str) and value else DEFAULT


def get(name: str) -> Engine:
    if name == "local":
        from .local_runner import LOCAL
        return LOCAL
    if name == "codex":
        from .codex_runner import CODEX
        return CODEX
    from .claude_runner import CLAUDE
    return CLAUDE


_status_cache: dict[str, tuple[float, Status]] = {}


async def cached_status(engine: Engine) -> Status:
    hit = _status_cache.get(engine.name)
    if hit and time.monotonic() - hit[0] < STATUS_TTL_S:
        return hit[1]
    status = await engine.status()
    _status_cache[engine.name] = (time.monotonic(), status)
    return status


def fallback_note(name: str, status: Status) -> str:
    if name == "local":
        return (f"<i>a IA local não está pronta neste Mac ({html.escape(status.problem or 'sem detalhe')}); "
                "esta resposta veio do Claude. Ajustes &gt; Modelo, no app, resolve.</i>")
    why = ("não está instalado" if not status.installed else "não está com o login feito" if not status.logged_in
           else status.problem)
    return f"<i>o {name.capitalize()} {why} neste Mac; esta resposta veio do Claude.</i>"


async def resolve(wisp_dir: Path) -> tuple[Engine, str | None]:
    name = active_name(wisp_dir)
    if name == DEFAULT or name not in ENGINES:
        return get(DEFAULT), None
    engine = get(name)
    status = await cached_status(engine)
    if status.ready:
        return engine, None
    log.warning("o motor ativo %s nao esta pronto aqui (%s); o turno roda no Claude", name, status)
    return get(DEFAULT), fallback_note(name, status)


async def run_process_status(*argv: str, timeout: float = 10) -> int | None:
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL)
        return await asyncio.wait_for(proc.wait(), timeout)
    except (OSError, asyncio.TimeoutError):
        return None
