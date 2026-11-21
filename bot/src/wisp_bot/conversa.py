from __future__ import annotations
import asyncio, html, json, logging
from datetime import datetime, timezone
from pathlib import Path

from .store import CURSOR
from .transcript import Transcripts, clip, stamp

log = logging.getLogger("wisp.conversa")

RESUMO_CHARS = 1200
USER_CHARS = 600
ULTIMAS_TROCAS = 5
ATRASO_S = 90
CABECALHO = "<i>↻ do app, enquanto o Telegram estava fora</i>"
_locks: dict[str, asyncio.Lock] = {}


def legado(session_id: str, transcripts: Transcripts, indice: Path | None = None) -> str:
    if indice is not None:
        try:
            registros = json.loads(indice.read_text("utf-8"))
        except (OSError, ValueError):
            registros = []
        for r in registros if isinstance(registros, list) else []:
            if isinstance(r, dict) and r.get("sessionId") == session_id and r.get("id"):
                return str(r["id"]).lower()
    return transcripts.find(session_id) or session_id.lower()


def indice_do_app() -> Path:
    from .config import CURRENT
    return CURRENT.conversations_file


def garantir(store, transcripts: Transcripts, key: str, reason: str = "new", indice: Path | None = None) -> str:
    topic = store.get(key)
    if topic is None:
        raise KeyError(key)
    conversation = topic.conversation
    if not conversation:
        conversation = legado(topic.session_id, transcripts, indice if indice is not None else indice_do_app())
        store.set_conversation(key, conversation)
    if transcripts.find(topic.session_id) != conversation:
        transcripts.link(conversation, topic.session_id, reason)
    return conversation


def pendentes(entries: list[dict], cursor: str) -> list[dict]:
    return [e for e in entries
            if e.get("kind") in ("user", "assistant") and e.get("surface") == "app"
            and isinstance(e.get("text"), str) and e["text"].strip() and str(e.get("at") or "") > cursor]


def trocas(pend: list[dict]) -> list[dict]:
    out: list[dict] = []
    for entry in pend:
        if entry["kind"] == "user":
            out.append({"user": entry["text"], "user_at": entry["at"], "reply": None, "reply_at": None})
            continue
        if not out or out[-1]["reply"] is not None:
            out.append({"user": None, "user_at": None, "reply": entry["text"], "reply_at": entry["at"]})
        else:
            out[-1]["reply"] = entry["text"]
            out[-1]["reply_at"] = entry["at"]
    return out


def _fim(troca: dict) -> str:
    return troca["reply_at"] or troca["user_at"]


def _epoch(at: str) -> float:
    try:
        return datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def atrasado(troca: dict, agora: float) -> bool:
    return agora - _epoch(str(troca["user_at"] or troca["reply_at"] or "")) > ATRASO_S


def coberto(entries: list[dict], cursor: str, reply: str, turn_at: str) -> bool:
    if not turn_at or turn_at > cursor:
        return False
    alvo = reply.strip()
    return any(e.get("kind") == "assistant" and e.get("surface") == "app" and e.get("at") == turn_at
               and str(e.get("text") or "").strip() == alvo for e in entries)


async def alcancar(store, transcripts: Transcripts, key: str, enviar, agora: float | None = None) -> int:
    topic = store.get(key)
    if topic is None or topic.meta.get("espelho"):
        return 0
    conversation = topic.conversation or transcripts.find(topic.session_id)
    if not conversation:
        return 0
    lock = _locks.setdefault(conversation, asyncio.Lock())
    async with lock:
        topic = store.get(key)
        if topic is None:
            return 0
        cursor = str(topic.meta.get(CURSOR) or "")
        if not cursor:
            store.set_meta(key, **{CURSOR: stamp()})
            return 0
        lista = trocas(pendentes(transcripts.conversation_entries(conversation), cursor))
        if lista and lista[-1]["user"] is not None and lista[-1]["reply"] is None:
            lista.pop()
        postaveis = [t for t in lista if t["reply"] is not None]
        agora = datetime.now(timezone.utc).timestamp() if agora is None else agora
        resumir = len(postaveis) > 1 or (bool(postaveis) and atrasado(postaveis[0], agora))
        omitidas = postaveis[:-ULTIMAS_TROCAS] if resumir else []
        if postaveis and resumir:
            await enviar(CABECALHO)
        if omitidas:
            await enviar(f"<i>(+{len(omitidas)} trocas mais antigas ficaram só no app)</i>")
            store.set_meta(key, **{CURSOR: _fim(omitidas[-1])})
        enviadas = 0
        for troca in lista:
            if troca["reply"] is None:
                store.set_meta(key, **{CURSOR: _fim(troca)})
                continue
            if troca in omitidas:
                continue
            if troca["user"]:
                await enviar("💻 " + html.escape(clip(troca["user"], USER_CHARS) if resumir else troca["user"]))
                store.set_meta(key, **{CURSOR: troca["user_at"]})
            await enviar(clip(troca["reply"], RESUMO_CHARS) if resumir else troca["reply"])
            store.set_meta(key, **{CURSOR: troca["reply_at"]})
            enviadas += 1
        return enviadas
