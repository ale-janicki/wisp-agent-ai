from __future__ import annotations
import asyncio, json, logging, os, sys, time
from pathlib import Path

from . import compat
from .config import CURRENT as _CFG, config_path

log = logging.getLogger("wisp.soul")

TIMEOUT_S = 5
FAILURE_TTL_S = 60
TERMINAL_TREE = ("agents", "skills", "commands")
_cache: dict[tuple[str, str], tuple[tuple, str]] = {}
_failures: dict[tuple[str, str], tuple[tuple, float]] = {}


def _now() -> float:
    return time.monotonic()


def _home() -> Path:
    return Path(os.environ.get("HOME") or Path.home())


def _template() -> Path:
    env = os.environ.get("WISP_RESOURCES")
    root = Path(env) if env else Path(sys.executable).parent.parent.parent / "src"
    return root / "harness" / "claude-md-block.md"


def _managed_elsewhere() -> bool:
    claude = _home() / ".claude"
    return any(p.is_symlink() for p in (claude, claude / "CLAUDE.md", claude / "settings.json", *(claude / t for t in TERMINAL_TREE)))


def _files() -> list[Path]:
    codex = Path(os.environ.get("CODEX_HOME") or _home() / ".codex")
    return [config_path().parent / "profile.json", config_path(), Path(_CFG.wisp_dir) / "agente.md", _template(),
            _home() / ".claude" / "CLAUDE.md", codex / "AGENTS.md"]


def _stamp() -> tuple:
    out: list = [_managed_elsewhere()]
    for f in _files():
        try:
            out.append(f.stat().st_mtime_ns)
        except OSError:
            out.append(None)
    return tuple(out)


def decode(saida: bytes) -> str | None:
    try:
        text = json.loads(saida.decode("utf-8", "replace"))["text"]
    except (ValueError, KeyError, TypeError):
        return None
    return text if isinstance(text, str) else None


async def _render(wisp_bin: str, engine: str) -> str | None:
    proc = await asyncio.create_subprocess_exec(
        wisp_bin, "soul", "render", "--engine", engine, "--json", stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, **compat.new_session_kwargs())
    try:
        saida, _ = await asyncio.wait_for(proc.communicate(), TIMEOUT_S)
    except BaseException:
        try:
            compat.kill_process_tree(proc.pid, compat.SIGKILL)
        except ProcessLookupError:
            pass
        await proc.wait()
        raise
    return decode(saida) if proc.returncode == 0 else None


async def text(engine: str, wisp_bin: str) -> str:
    stamp = _stamp()
    key = (wisp_bin, engine)
    hit = _cache.get(key)
    if hit and hit[0] == stamp:
        return hit[1]
    failed = _failures.get(key)
    if failed and failed[0] == stamp and _now() - failed[1] < FAILURE_TTL_S:
        return ""
    try:
        rendered = await _render(wisp_bin, engine)
    except (OSError, asyncio.TimeoutError):
        rendered = None
    if rendered is None:
        log.warning("wisp soul render falhou; o turno segue sem a personalidade")
        _failures[key] = (stamp, _now())
        return ""
    _failures.pop(key, None)
    _cache[key] = (stamp, rendered)
    return rendered


def append(extra_prompt: str, soul: str) -> str:
    return "\n\n".join(x for x in (extra_prompt, soul) if x)
