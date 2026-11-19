from __future__ import annotations
import json, re, time
from datetime import datetime
from pathlib import Path

from . import sessao

RECAP_N = 6
RECAP_CHARS = 500
PUXAR_N = 10
_WRAPPERS = ("<command-name>", "<local-command", "<system-reminder>", "<task-notification>")


def jsonl_path(session_id: str, cwd: str, projetos: Path | None = None) -> Path:
    base = projetos or Path.home() / ".claude" / "projects"
    return base / re.sub(r"[^A-Za-z0-9]", "-", cwd) / f"{session_id}.jsonl"


def _texto(content) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    return "\n".join(b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text").strip()


def recap(session_id: str, cwd: str, projetos: Path | None = None) -> list[tuple[str, str]]:
    try:
        linhas = jsonl_path(session_id, cwd, projetos).read_text("utf-8", errors="replace").splitlines()
    except OSError:
        return []
    msgs: list[tuple[str, str]] = []
    for linha in linhas:
        try:
            o = json.loads(linha)
        except ValueError:
            continue
        msg = o.get("message") if isinstance(o, dict) else None
        if not isinstance(msg, dict) or o.get("isMeta") or o.get("isSidechain"):
            continue
        papel = o.get("type")
        t = _texto(msg.get("content"))
        if papel not in ("user", "assistant") or not t or t.startswith(_WRAPPERS):
            continue
        msgs.append((papel, t if len(t) <= RECAP_CHARS else t[:RECAP_CHARS].rstrip() + "…"))
    return msgs[-RECAP_N:]


def _data(valor) -> float:
    if isinstance(valor, (int, float)):
        return valor / 1000 if valor > 1e11 else float(valor)
    if isinstance(valor, str):
        try:
            return datetime.fromisoformat(valor.replace("Z", "+00:00")).timestamp()
        except ValueError:
            try:
                return float(valor)
            except ValueError:
                return 0.0
    return 0.0


def recentes(arquivo: Path, ja_compartilhadas: set[str], n: int = PUXAR_N) -> list[dict]:
    try:
        brutos = json.loads(arquivo.read_text("utf-8"))
    except FileNotFoundError:
        raise ValueError("não achei a lista de conversas do app (abra o app uma vez)") from None
    except (OSError, ValueError):
        raise ValueError("a lista de conversas do app está ilegível") from None
    if not isinstance(brutos, list):
        raise ValueError("a lista de conversas do app está ilegível")
    out = []
    for r in brutos:
        if not isinstance(r, dict):
            continue
        sid = str(r.get("sessionId") or "")
        if not sessao.valido(sid) or sid in ja_compartilhadas:
            continue
        out.append({"session_id": sid, "title": str(r.get("title") or "").strip() or "sem título",
                    "cwd": str(r.get("cwd") or ""), "updated": _data(r.get("updatedAt"))})
    out.sort(key=lambda d: d["updated"], reverse=True)
    return out[:n]


def relativa(epoch: float, agora: float | None = None) -> str:
    s = max(0, (time.time() if agora is None else agora) - epoch)
    if not epoch:
        return "?"
    if s < 3600:
        return f"há {int(s // 60)} min"
    if s < 86400:
        return f"há {int(s // 3600)} h"
    return f"há {int(s // 86400)} d"
