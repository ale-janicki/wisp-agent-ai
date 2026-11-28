from __future__ import annotations

import asyncio
import base64
import os
import sys
import threading

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from .service import Clipboard
from .store import ClipboardStore

FEATURE = "clipboard"
EMPTY = "Nada copiado ainda"
NOT_FOUND = "Nada encontrado"

_clipboard: Clipboard | None = None
_guard = threading.Lock()


def _source():
    if sys.platform != "win32":
        return None
    from .winclip import WindowsClipboard
    return WindowsClipboard()


def clipboard() -> Clipboard:
    global _clipboard
    with _guard:
        if _clipboard is None:
            _clipboard = Clipboard(ClipboardStore(), _source())
        return _clipboard


def _start_thread(board: Clipboard, stop: threading.Event) -> None:
    threading.Thread(target=board.run, args=(stop,), name="wisp-clipboard", daemon=True).start()


def startup(host):
    if os.environ.get("WISP_CLIPBOARD_POLL") == "0":
        return None
    board = clipboard()
    if board.source is None:
        return None
    stop = threading.Event()
    _start_thread(board, stop)
    return stop.set


def notifier(host, loop: asyncio.AbstractEventLoop):
    owner = threading.get_ident()

    def notify() -> None:
        if threading.get_ident() == owner:
            host.publish_feature(FEATURE, "changed")
            return
        try:
            loop.call_soon_threadsafe(host.publish_feature, FEATURE, "changed")
        except RuntimeError:
            pass

    return notify


def _hook(request: Request) -> Clipboard:
    service = clipboard()
    service.notify = notifier(request.app.state.host, asyncio.get_running_loop())
    return service


async def get_items(request: Request) -> Response:
    service = _hook(request)
    query = request.query_params.get("q", "")
    items = service.items(query)
    return JSONResponse({
        "items": [i.as_json() for i in items], "capture": service.capture_enabled, "notice": service.notice,
        "empty": (EMPTY if service.total() == 0 else NOT_FOUND) if not items else None,
        "available": service.source is not None,
    })


async def _body(request: Request) -> dict:
    try:
        body = await request.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


async def put_capture(request: Request) -> Response:
    service = _hook(request)
    enabled = (await _body(request)).get("enabled")
    if not isinstance(enabled, bool):
        return JSONResponse({"error": "enabled (bool) é obrigatório"}, status_code=400)
    service.set_capture(enabled)
    return JSONResponse({"capture": service.capture_enabled})


async def post_copy(request: Request) -> Response:
    service = _hook(request)
    item = service.find(request.path_params["id"])
    if item is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return JSONResponse({"ok": service.copy(item)})


async def post_pin(request: Request) -> Response:
    service = _hook(request)
    if service.find(request.path_params["id"]) is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    service.toggle_pin(request.path_params["id"])
    return JSONResponse({"ok": True})


async def delete_item(request: Request) -> Response:
    if not _hook(request).remove(request.path_params["id"]):
        return JSONResponse({"error": "not found"}, status_code=404)
    return JSONResponse({"ok": True})


async def post_clear(request: Request) -> Response:
    _hook(request).clear_unpinned()
    return JSONResponse({"ok": True})


async def get_thumbnail(request: Request) -> Response:
    from .store import thumbnail_name
    service = _hook(request)
    item = service.find(request.path_params["id"])
    path = service.store.path_of(thumbnail_name(item.image)) if item and item.image else None
    if path is None or not path.exists():
        return JSONResponse({"error": "not found"}, status_code=404)
    return JSONResponse({"data_url": "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode()})


routes = [
    Route("/items", get_items, methods=["GET"]),
    Route("/capture", put_capture, methods=["PUT"]),
    Route("/clear", post_clear, methods=["POST"]),
    Route("/items/{id}/copy", post_copy, methods=["POST"]),
    Route("/items/{id}/pin", post_pin, methods=["POST"]),
    Route("/items/{id}/thumbnail", get_thumbnail, methods=["GET"]),
    Route("/items/{id}", delete_item, methods=["DELETE"]),
]

