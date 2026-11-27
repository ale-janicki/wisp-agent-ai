from __future__ import annotations
import asyncio, html, json, logging, tomllib
from pathlib import Path

from . import compat
from . import engine as engines
from .claude_runner import WISP_BIN
from .config import CURRENT as _CFG

log = logging.getLogger("wisp.modelo")

NAMES = {"claude": "Claude", "codex": "Codex", "local": "IA local"}
SET_TIMEOUT_S = 120
ADVICE_TIMEOUT_S = 20


def launch() -> list[str]:
    return [WISP_BIN]


async def _json_line(*argv: str, timeout: float) -> dict | None:
    try:
        proc = await asyncio.create_subprocess_exec(
            *launch(), *argv, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, **compat.new_session_kwargs())
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            try:
                compat.kill_process_tree(proc.pid, compat.SIGKILL)
            except ProcessLookupError:
                pass
            await proc.wait()
            return None
    except OSError:
        return None
    for line in out.decode("utf-8", "replace").splitlines():
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return None


def local_model(wisp_dir: Path) -> str:
    try:
        local = tomllib.loads((wisp_dir / "modelos.toml").read_text("utf-8")).get("local", {})
    except (OSError, ValueError):
        return ""
    value = local.get("ativo") if isinstance(local, dict) else ""
    return value if isinstance(value, str) else ""


def thinking(wisp_dir: Path) -> bool:
    try:
        local = tomllib.loads((wisp_dir / "modelos.toml").read_text("utf-8")).get("local", {})
    except (OSError, ValueError):
        return False
    return isinstance(local, dict) and local.get("pensar") is True


async def set_engine(name: str) -> tuple[bool, str]:
    if name not in engines.ENGINES:
        return False, f"motor desconhecido: {name}. Use claude, codex ou local."
    report = await _json_line("config", "set", "engine", name, "--json", timeout=SET_TIMEOUT_S)
    if report is None or report.get("status") == "failed":
        detail = report.get("summary") if isinstance(report, dict) else None
        return False, f"não consegui trocar o motor: {detail or 'o comando do Wisp não respondeu'}"
    engines._status_cache.pop(name, None)
    return True, f"motor agora: {NAMES[name]}"


def recommendation_lines(advice: dict | None) -> list[str]:
    if advice is None:
        return ["<i>não consegui calcular a recomendação de IA local agora</i>"]
    lines = []
    for label, key in (("Melhor para este Mac", "best"), ("Mais rápido", "fastest")):
        entry = advice.get(key)
        if isinstance(entry, dict):
            lines.append(f"<b>{label}:</b> {html.escape(str(entry.get('name')))}, {html.escape(str(entry.get('reason')))}")
    lines += [f"<i>{html.escape(str(note))}</i>" for note in advice.get("notes") or []]
    return lines


async def summary(wisp_dir: Path | None = None) -> str:
    folder = wisp_dir or _CFG.wisp_dir
    active = engines.active_name(folder)
    model = local_model(folder)
    lines = [f"<b>Motor ativo:</b> {NAMES.get(active, html.escape(active))}",
             f"<b>Modelo da IA local:</b> {html.escape(model) if model else 'nenhum escolhido'}",
             f"<b>Pensar antes de responder:</b> {'sim' if thinking(folder) else 'não'} (muda em Ajustes &gt; Modelo, no app)"]
    lines += recommendation_lines(await _json_line("local", "recomendar", "--json", timeout=ADVICE_TIMEOUT_S))
    lines.append("Trocar: <code>/modelo claude</code>, <code>/modelo codex</code> ou <code>/modelo local</code>. "
                 "Baixar um modelo local: Ajustes &gt; Modelo, no app.")
    return "\n".join(lines)
