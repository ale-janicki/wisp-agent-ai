from __future__ import annotations

import json
import os
import time
import webbrowser
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from wisp.config import load_config
from wisp.paths import WispPaths
from wisp.serve.protocol import ENGINE
from wisp.serve.store import format_time
from wisp.soul_config import profile_path

from .home_usage import UsageIndex

FIVE_HOUR = "five_hour"
SEVEN_DAY = "seven_day"
RECENT = 5


def _profile(paths: WispPaths | None = None) -> dict:
    try:
        raw = json.loads(profile_path(paths).read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    return raw if isinstance(raw, dict) else {}


def _text(value) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def profile_info(paths: WispPaths | None = None) -> dict:
    persona = _profile(paths).get("persona")
    persona = persona if isinstance(persona, dict) else {}
    user = _text(persona.get("user"))
    if user is None:
        try:
            user = _text(load_config().user_name)
        except (OSError, ValueError):
            user = None
    if user is None:
        try:
            import getpass
            user = _text(getpass.getuser())
        except (KeyError, OSError):
            user = None
    return {"user": user, "first_name": user.split()[0] if user else None,
            "persona": _text(persona.get("name")) or "Wisp", "language": _text(persona.get("language")) or "pt-BR"}


def _window(raw, now: float) -> dict | None:
    if not isinstance(raw, dict) or not isinstance(raw.get("used_percentage"), (int, float)):
        return None
    resets = raw.get("resets_at")
    return {"utilization": raw["used_percentage"] / 100, "resets_at": resets if isinstance(resets, (int, float)) else None}


def usage_rows(snapshot: dict, now: float) -> list[dict]:
    rows = []
    for kind, key in (("session", FIVE_HOUR), ("week", SEVEN_DAY)):
        window = _window(snapshot.get(key), now)
        if window is None:
            rows.append({"kind": kind, "state": "used", "percent": 0, "resets_at": None, "severity": "normal"})
        elif window["resets_at"] is not None and window["resets_at"] <= now:
            rows.append({"kind": kind, "state": "renewed"})
        else:
            use = window["utilization"]
            rows.append({"kind": kind, "state": "used", "percent": int(use * 100 + 0.5), "resets_at": window["resets_at"],
                         "severity": "critical" if use >= 0.9 else "warning" if use >= 0.75 else "normal"})
    return rows


def read_limits(paths: WispPaths | None = None, now: float | None = None) -> dict | None:
    blocks = _profile(paths).get("blocks")
    usage = blocks.get("usage") if isinstance(blocks, dict) else None
    path = _text(usage.get("limits")) if isinstance(usage, dict) else None
    if path is None:
        return None
    try:
        data = json.loads(Path(os.path.expanduser(path)).read_text("utf-8"))
    except (OSError, ValueError):
        return None
    captured = data.get("captured_at") if isinstance(data, dict) else None
    if not isinstance(captured, (int, float)) or not any(_window(data.get(k), 0) for k in (FIVE_HOUR, SEVEN_DAY)):
        return None
    return {"captured_at": captured, "rows": usage_rows(data, time.time() if now is None else now)}


async def get_profile(request: Request) -> Response:
    return JSONResponse(profile_info())


async def get_conversations(request: Request) -> Response:
    store = request.app.state.host.store
    items = [{"id": str(r["id"]).lower(), "title": r["title"], "updated_at": format_time(r["updatedAt"]),
              "preview": r.get("lastPreview"), "telegram": r.get("telegramThread") is not None, "engine": ENGINE}
             for r in store.all()]
    return JSONResponse({"items": items[:RECENT], "total": len(items)})


_usage_index: UsageIndex | None = None


def usage_index() -> UsageIndex:
    global _usage_index
    if _usage_index is None:
        _usage_index = UsageIndex()
    return _usage_index


async def get_usage(request: Request) -> Response:
    import asyncio
    return JSONResponse({"limits": read_limits(), "tokens": await asyncio.to_thread(usage_index().summary)})


OPENABLE_SCHEMES = {"http", "https", "zoommtg", "zoomus", "msteams", "webex", "facetime"}


def _open_url(url: str) -> None:
    webbrowser.open(url)


def safe_link(url: object) -> str | None:
    if not isinstance(url, str) or not url or "\\" in url:
        return None
    if any(ch.isspace() or not ch.isprintable() for ch in url):
        return None
    try:
        parts = urlsplit(url)
        host = parts.hostname
    except ValueError:
        return None
    if parts.scheme.lower() not in OPENABLE_SCHEMES or not host:
        return None
    return urlunsplit(parts)


async def post_open(request: Request) -> Response:
    try:
        body = await request.json()
    except ValueError:
        body = {}
    link = safe_link(body.get("url") if isinstance(body, dict) else None)
    if link is None:
        return JSONResponse({"error": "link inválido"}, status_code=400)
    _open_url(link)
    return JSONResponse({"ok": True})


routes = [Route("/profile", get_profile, methods=["GET"]), Route("/conversations", get_conversations, methods=["GET"]),
          Route("/usage", get_usage, methods=["GET"]), Route("/open", post_open, methods=["POST"])]
