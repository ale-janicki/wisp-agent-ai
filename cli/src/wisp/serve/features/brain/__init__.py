from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import mimetypes
import os
import sqlite3
import threading
import time
from datetime import datetime
from pathlib import Path

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from wisp.brain_index import BrainError, BrainIndex, fold, index_path
from wisp.config import load_config
from wisp.paths import WispPaths, resources_root

from . import catalog as catalogs
from . import checkbox, daily, document, drawing, merge, refactor, watch
from .refactor import FileResolver
from .vault import Busy, Exists, InvalidName, Missing, Outside, ReadOnly, Vault, VaultError, strict_text

POLL_SECONDS = float(os.environ.get("WISP_BRAIN_POLL", "1.0"))
WATCH_IDLE_SECONDS = float(os.environ.get("WISP_BRAIN_WATCH_IDLE", "300"))
CATALOG_MAX_AGE = 3.0
MAX_ATTACHMENT = 25 * 1024 * 1024
EXCALIDRAW_CSP = ("default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
                  "font-src 'self' data:; connect-src 'self' data: blob:; worker-src 'self' blob:; media-src 'none'; object-src 'none'; "
                  "frame-src 'none'; form-action 'none'; base-uri 'none'")
EXTRA_MIME = {".wasm": "application/wasm", ".woff2": "font/woff2", ".woff": "font/woff", ".js": "text/javascript; charset=utf-8",
              ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".html": "text/html; charset=utf-8"}
IMAGE_EXTENSIONS = frozenset("png jpg jpeg gif svg webp bmp heic".split())


def configured_root() -> Path | None:
    try:
        cfg = load_config()
    except (OSError, ValueError, TypeError):
        cfg = None
    candidates = [cfg.brain] if cfg and cfg.brain else []
    try:
        profile = json.loads((WispPaths.current().config / "profile.json").read_text(encoding="utf-8"))
        candidates.append(profile["blocks"]["memory"]["root"])
    except (OSError, ValueError, KeyError, TypeError):
        pass
    for candidate in candidates:
        if isinstance(candidate, str) and candidate.strip():
            path = Path(candidate.strip()).expanduser()
            if path.is_dir():
                return path
    return None


def bookmarks_file() -> Path:
    try:
        folder = load_config().wisp_dir
    except (OSError, ValueError, TypeError):
        folder = "~/Wisp"
    return Path(folder).expanduser() / "brain-bookmarks.json"


class Runtime:
    def __init__(self, host):
        self.host = host
        self.vault: Vault | None = None
        self.catalog: catalogs.Catalog | None = None
        self.catalog_at = 0.0
        self.dirty = True
        self.index: BrainIndex | None = None
        self.task: asyncio.Task | None = None
        self.lock = threading.Lock()
        self.last_seen = time.monotonic()

    def touch(self) -> None:
        self.last_seen = time.monotonic()

    def current(self) -> Vault | None:
        root = configured_root()
        if root is None:
            self.vault = self.catalog = self.index = None
            return None
        if self.vault is None or self.vault.root != root.resolve():
            self.vault, self.catalog, self.index, self.dirty = Vault(root), None, None, True
        return self.vault

    def fresh_catalog(self, force: bool = False) -> catalogs.Catalog:
        with self.lock:
            assert self.vault is not None
            if force or self.dirty or self.catalog is None or time.monotonic() - self.catalog_at > CATALOG_MAX_AGE:
                self.catalog = catalogs.Catalog.scan(self.vault, self.catalog)
                self.catalog_at, self.dirty = time.monotonic(), False
            return self.catalog

    def search_index(self) -> BrainIndex:
        assert self.vault is not None
        if self.index is None:
            markers = tuple(load_config().brain_log_markers)
            self.index = BrainIndex(self.vault.root, index_path(WispPaths.current().state, self.vault.root), log_markers=markers)
        return self.index


def runtime(request: Request) -> Runtime:
    state = request.app.state
    if getattr(state, "brain", None) is None:
        state.brain = Runtime(state.host)
    return state.brain


def fail(message: str, status: int) -> Response:
    return JSONResponse({"error": message}, status_code=status)


def route(fn):
    async def wrapper(request: Request) -> Response:
        rt = runtime(request)
        vault = rt.current()
        if vault is None:
            return fail("o brain não está configurado ou a pasta não existe", 409)
        rt.touch()
        ensure_watch(rt, vault)
        try:
            return await fn(request, rt, vault)
        except Busy as error:
            return fail(str(error), 423)
        except Missing as error:
            return fail(str(error), 404)
        except Exists as error:
            return fail(str(error), 409)
        except refactor.Stale as error:
            return fail(str(error), 409)
        except InvalidName as error:
            return fail(str(error), 400)
        except (Outside, ReadOnly) as error:
            return fail(str(error), 403)
        except drawing.DrawingError as error:
            return fail(str(error), 422)
        except VaultError as error:
            return fail(str(error), 500)
        except PermissionError as error:
            return fail(f"sem permissão ou arquivo em uso: {error.filename or error}", 423)
        except OSError as error:
            return fail(f"erro no disco: {error}", 500)

    wrapper.__name__ = fn.__name__
    return wrapper


async def body(request: Request) -> dict:
    try:
        data = await request.json()
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def text_arg(data: dict, key: str, required: bool = True) -> str | None:
    value = data.get(key)
    if isinstance(value, str):
        return value
    if required:
        raise InvalidName(f"{key} é obrigatório")
    return None


def kind_of(path: str) -> str:
    lowered = path.lower()
    if drawing.kind_of(path):
        return "drawing"
    if lowered.endswith(".md"):
        return "note"
    return "image" if lowered.rsplit(".", 1)[-1] in IMAGE_EXTENSIONS else "other"


def invalidate(rt: Runtime) -> None:
    rt.dirty = True


async def poll_once(rt: Runtime, vault: Vault, before: watch.Snapshot) -> watch.Snapshot:
    after = await asyncio.to_thread(watch.snapshot, vault)
    changed = watch.diff(before, after)
    if changed:
        rt.dirty = True
        rt.host.publish_feature("brain", "changed", paths=changed[:500])
    return after


async def watch_loop(rt: Runtime, vault: Vault) -> None:
    before = await asyncio.to_thread(watch.snapshot, vault)
    while rt.vault is vault and time.monotonic() - rt.last_seen < WATCH_IDLE_SECONDS:
        await asyncio.sleep(POLL_SECONDS)
        before = await poll_once(rt, vault, before)


def ensure_watch(rt: Runtime, vault: Vault) -> None:
    rt.touch()
    if rt.task is None or rt.task.done() or rt.vault is not vault:
        rt.task = asyncio.get_running_loop().create_task(watch_loop(rt, vault))


@route
async def state(request: Request, rt: Runtime, vault: Vault) -> Response:
    ensure_watch(rt, vault)
    return JSONResponse({"configured": True, "name": vault.root.name})


async def state_open(request: Request) -> Response:
    rt = runtime(request)
    if rt.current() is None:
        return JSONResponse({"configured": False})
    return await state(request)


@route
async def tree(request: Request, rt: Runtime, vault: Vault) -> Response:
    return JSONResponse({"entries": await asyncio.to_thread(vault.tree)})


@route
async def notes(request: Request, rt: Runtime, vault: Vault) -> Response:
    cat = await asyncio.to_thread(rt.fresh_catalog)
    items = [{"path": rel, "title": e.row.title, "aliases": list(e.row.aliases), "modified": e.stamp[0] / 1e9, "link": cat.link_name(rel)}
             for rel, e in cat.entries.items()]
    return JSONResponse({"items": items})


@route
async def get_note(request: Request, rt: Runtime, vault: Vault) -> Response:
    rel = request.query_params.get("path", "")
    kind = kind_of(rel)
    if kind != "note":
        vault.path(rel)
        return JSONResponse({"path": rel, "kind": kind})
    text, reason = vault.inspect(rel)
    return JSONResponse({"path": rel, "kind": kind, "text": text, "read_only": reason, "mtime": vault.path(rel).stat().st_mtime})


@route
async def put_note(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    rel, text = text_arg(data, "path"), text_arg(data, "text")
    force = data.get("force") is True
    base = data.get("base")
    exists = vault.path(rel).exists()
    if not exists and not force and base is not None:
        return fail(f"{rel} não existe mais no disco", 404)
    if exists and isinstance(base, str) and not force:
        disk = vault.read_bytes(rel).decode("utf-8", errors="replace")
        if disk != base:
            return fail(f"{rel} mudou no disco", 409)
    vault.write(rel, text)
    invalidate(rt)
    return JSONResponse({"mtime": vault.path(rel).stat().st_mtime})


@route
async def create_note(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    rel = text_arg(data, "path")
    vault.create(rel, text_arg(data, "text", required=False) or "")
    invalidate(rt)
    return JSONResponse({"path": rel})


@route
async def create_folder(request: Request, rt: Runtime, vault: Vault) -> Response:
    rel = text_arg(await body(request), "path")
    vault.mkdir(rel)
    return JSONResponse({"path": rel})


@route
async def trash(request: Request, rt: Runtime, vault: Vault) -> Response:
    vault.trash(text_arg(await body(request), "path"))
    invalidate(rt)
    return JSONResponse({"ok": True})


def plan_id(move: refactor.MovePlan) -> str:
    return hashlib.sha1(repr(move).encode("utf-8")).hexdigest()


@route
async def rename_preview(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    cat = await asyncio.to_thread(rt.fresh_catalog, True)
    move = await asyncio.to_thread(refactor.plan, vault, cat, text_arg(data, "from"), text_arg(data, "to"))
    return JSONResponse({**move.to_dict(), "id": plan_id(move)})


@route
async def rename_apply(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    cat = await asyncio.to_thread(rt.fresh_catalog, True)
    move = await asyncio.to_thread(refactor.plan, vault, cat, text_arg(data, "from"), text_arg(data, "to"))
    if plan_id(move) != data.get("id"):
        raise refactor.Stale(f"{move.source} mudou no disco; veja a prévia de novo")
    await asyncio.to_thread(refactor.apply, vault, move)
    invalidate(rt)
    return JSONResponse({"ok": True, "path": move.target})


@route
async def search(request: Request, rt: Runtime, vault: Vault) -> Response:
    query = request.query_params.get("q", "").strip()
    limit = max(1, min(50, int(request.query_params.get("limit", "30") or 30)))
    cat = await asyncio.to_thread(rt.fresh_catalog)
    if query.startswith("#"):
        tag = fold(query[1:])
        items = [{"path": rel, "title": cat.notes[rel].title, "snippet": ""} for rel in cat.notes_with_tag(tag)[:limit]]
        return JSONResponse({"items": items})
    if not query:
        return JSONResponse({"items": []})

    def run():
        index = rt.search_index()
        index.sync()
        return index.search(query, limit)

    try:
        hits = await asyncio.to_thread(run)
    except (BrainError, sqlite3.Error, OSError) as error:
        return fail(f"não consegui buscar no brain: {error}", 500)
    return JSONResponse({"items": [{"path": h.rel, "title": h.title, "snippet": h.snippet, "score": h.score} for h in hits]})


@route
async def recent(request: Request, rt: Runtime, vault: Vault) -> Response:
    limit = max(1, min(100, int(request.query_params.get("limit", "30") or 30)))
    cat = await asyncio.to_thread(rt.fresh_catalog)
    ordered = sorted(cat.entries.items(), key=lambda kv: (-kv[1].stamp[0], kv[0]))[:limit]
    return JSONResponse({"items": [{"path": rel, "title": e.row.title, "modified": e.stamp[0] / 1e9} for rel, e in ordered]})


@route
async def backlinks(request: Request, rt: Runtime, vault: Vault) -> Response:
    rel = request.query_params.get("path", "")
    cat = await asyncio.to_thread(rt.fresh_catalog)
    return JSONResponse({"items": await asyncio.to_thread(catalogs.backlinks, vault, cat, rel)})


@route
async def outgoing(request: Request, rt: Runtime, vault: Vault) -> Response:
    rel = request.query_params.get("path", "")
    cat = await asyncio.to_thread(rt.fresh_catalog)
    return JSONResponse({"items": await asyncio.to_thread(catalogs.outgoing, vault, cat, rel)})


@route
async def resolve(request: Request, rt: Runtime, vault: Vault) -> Response:
    cat = await asyncio.to_thread(rt.fresh_catalog)
    target = cat.resolve(request.query_params.get("name", ""), request.query_params.get("from") or None)
    return JSONResponse({"path": target})


@route
async def graph(request: Request, rt: Runtime, vault: Vault) -> Response:
    cat = await asyncio.to_thread(rt.fresh_catalog)
    edges = cat.edges()
    degree: dict[str, int] = {}
    for a, b in edges:
        degree[a] = degree.get(a, 0) + 1
        degree[b] = degree.get(b, 0) + 1
    nodes = [{"id": rel, "title": cat.notes[rel].title, "degree": degree.get(rel, 0)} for rel in sorted(cat.notes)]
    return JSONResponse({"nodes": nodes, "edges": [list(e) for e in edges]})


@route
async def tags(request: Request, rt: Runtime, vault: Vault) -> Response:
    cat = await asyncio.to_thread(rt.fresh_catalog)
    return JSONResponse({"tags": cat.tag_counts()})


@route
async def toggle_task(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    rel, line = text_arg(data, "path"), data.get("line")
    if not isinstance(line, int) or isinstance(line, bool):
        raise InvalidName("line é obrigatório")
    current = vault.read_strict(rel)
    updated = checkbox.toggle(current, line, text_arg(data, "expected", required=False))
    if updated is None:
        return fail("a linha mudou; recarregue a nota", 409)
    vault.write(rel, updated)
    invalidate(rt)
    return JSONResponse({"text": updated, "mtime": vault.path(rel).stat().st_mtime})


@route
async def set_property(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    rel, key = text_arg(data, "path"), text_arg(data, "key")
    doc = document.Document(vault.read_strict(rel))
    if data.get("remove") is True:
        doc.remove(key)
    else:
        value = data.get("value")
        if isinstance(value, list) and all(isinstance(v, str) for v in value):
            doc.set(key, value)
        elif isinstance(value, str):
            doc.set(key, value)
        else:
            raise InvalidName("value deve ser texto ou lista de textos")
    vault.write(rel, doc.text)
    invalidate(rt)
    return JSONResponse({"text": doc.text, "mtime": vault.path(rel).stat().st_mtime})


@route
async def properties(request: Request, rt: Runtime, vault: Vault) -> Response:
    doc = document.Document(vault.read_strict(request.query_params.get("path", "")))
    return JSONResponse({"has_frontmatter": doc.front is not None, "items": doc.properties()})


@route
async def merge_texts(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    kind, text = merge.merge(text_arg(data, "base"), text_arg(data, "mine"), text_arg(data, "theirs"))
    return JSONResponse({"kind": kind, "text": text})


def _daily_context(rt: Runtime, vault: Vault) -> tuple[daily.DailyConfig, str]:
    cat = rt.fresh_catalog()
    config = daily.load_config(vault.root, sorted(cat.notes))
    return config, daily.path_for(config, datetime.now())


@route
async def daily_info(request: Request, rt: Runtime, vault: Vault) -> Response:
    _, rel = await asyncio.to_thread(_daily_context, rt, vault)
    return JSONResponse({"path": rel, "exists": vault.exists(rel)})


@route
async def daily_open(request: Request, rt: Runtime, vault: Vault) -> Response:
    config, rel = await asyncio.to_thread(_daily_context, rt, vault)
    if not vault.exists(rel):
        now = datetime.now()
        text = ""
        if config.template and vault.exists(config.template):
            text = daily.render(vault.read_strict(config.template), Path(rel).stem, now)
        vault.create(rel, text)
        invalidate(rt)
    return JSONResponse({"path": rel})


@route
async def get_bookmarks(request: Request, rt: Runtime, vault: Vault) -> Response:
    return JSONResponse({"paths": _read_bookmarks().get(str(vault.root), [])})


@route
async def put_bookmarks(request: Request, rt: Runtime, vault: Vault) -> Response:
    paths = (await body(request)).get("paths")
    if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
        raise InvalidName("paths deve ser uma lista de textos")
    everything = _read_bookmarks()
    everything[str(vault.root)] = paths
    Vault.write_bytes_atomic(bookmarks_file(), json.dumps(everything, ensure_ascii=False, indent=2).encode("utf-8"))
    return JSONResponse({"paths": paths})


def _read_bookmarks() -> dict[str, list[str]]:
    try:
        data = json.loads(bookmarks_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {k: [p for p in v if isinstance(p, str)] for k, v in data.items() if isinstance(v, list)} if isinstance(data, dict) else {}


def _find_file(vault: Vault, name: str, source: str | None) -> str | None:
    files = [e["path"] for e in vault.tree() if not e["is_folder"]]
    return FileResolver(files).resolve(name, source)


@route
async def attachment(request: Request, rt: Runtime, vault: Vault) -> Response:
    found = await asyncio.to_thread(_find_file, vault, request.query_params.get("name", ""), request.query_params.get("from") or None)
    if found is None:
        return fail("não achei o arquivo", 404)
    if vault.size(found) > MAX_ATTACHMENT:
        return fail("arquivo grande demais para abrir aqui", 413)
    data = vault.read_bytes(found)
    mime = mimetypes.guess_type(found)[0] or "application/octet-stream"
    return JSONResponse({"path": found, "mime": mime, "data": base64.b64encode(data).decode("ascii")})


def _hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@route
async def get_drawing(request: Request, rt: Runtime, vault: Vault) -> Response:
    rel = request.query_params.get("path", "")
    kind = drawing.kind_of(rel)
    if kind is None:
        return fail("não é um desenho", 400)
    raw = vault.read_bytes(rel)
    valid = strict_text(raw)
    text = valid if valid is not None else raw.decode("utf-8", errors="replace")
    reason = vault.write_problem(rel)
    if kind == "canvas":
        return JSONResponse({"kind": kind, "canvas": drawing.parse_canvas(text), "hash": _hash(raw), "read_only": reason})
    file = drawing.parse_excalidraw(text, rel, lossy=valid is None)

    def read_attachment(name: str) -> bytes | None:
        found = _find_file(vault, name, rel)
        return vault.read_bytes(found) if found else None

    files = drawing.files_payload(file, read_attachment)
    return JSONResponse({"kind": kind, "scene": json.dumps(file.scene, ensure_ascii=False), "files": files, "hash": _hash(raw),
                         "read_only": file.read_only or reason})


@route
async def put_drawing(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    rel, scene_text = text_arg(data, "path"), text_arg(data, "scene")
    raw = vault.read_bytes(rel)
    if data.get("hash") != _hash(raw) and data.get("force") is not True:
        return fail(f"{rel} mudou no disco", 409)
    text = strict_text(raw)
    if text is None:
        raise ReadOnly(f"{rel} não é texto UTF-8 válido")
    file = drawing.parse_excalidraw(text, rel)
    try:
        scene = json.loads(scene_text)
    except ValueError as error:
        raise drawing.DrawingError(f"cena inválida: {error}") from error
    if not isinstance(scene, dict):
        raise drawing.DrawingError("cena inválida: a raiz não é um objeto")
    file.set_scene(scene)
    saved = file.serialized()
    vault.write(rel, saved)
    invalidate(rt)
    return JSONResponse({"hash": _hash(saved.encode("utf-8"))})


@route
async def new_drawing(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    kind, folder = data.get("kind"), (text_arg(data, "folder", required=False) or "").strip("/")
    if kind not in ("excalidraw", "canvas"):
        raise InvalidName("kind deve ser excalidraw ou canvas")
    prefix, suffix = ("Desenho", ".excalidraw.md") if kind == "excalidraw" else ("Canvas", ".canvas")
    stem = f"{prefix} {datetime.now():%Y-%m-%d %H.%M}"
    join = (lambda name: f"{folder}/{name}") if folder else (lambda name: name)
    rel, n = join(stem + suffix), 2
    while vault.exists(rel):
        rel, n = join(f"{stem} {n}{suffix}"), n + 1
    vault.create(rel, drawing.blank_excalidraw() if kind == "excalidraw" else drawing.blank_canvas())
    invalidate(rt)
    return JSONResponse({"path": rel})


@route
async def recover(request: Request, rt: Runtime, vault: Vault) -> Response:
    data = await body(request)
    name = Path(text_arg(data, "path")).name or "nota.md"
    target = bookmarks_file().parent / "brain-recuperado" / f"{datetime.now():%Y-%m-%d-%H%M%S}-{name}"
    Vault.write_bytes_atomic(target, text_arg(data, "text").encode("utf-8"))
    return JSONResponse({"saved": target.name})


def excalidraw_root() -> Path:
    override = os.environ.get("WISP_EXCALIDRAW_DIR")
    return Path(override) if override else resources_root() / "app" / "Resources" / "Excalidraw"


BRIDGE_SHIM = """(() => {
  const base = new URL("./", document.currentScript.src).href;
  Object.defineProperty(window, "EXCALIDRAW_ASSET_PATH", { get: () => base, set: () => {}, configurable: true });
  window.webkit = { messageHandlers: { wisp: { postMessage: (message) => window.parent.postMessage({ wisp: message }, "*") } } };
  window.addEventListener("message", (event) => {
    if (event.source !== window.parent || !event.data || typeof event.data.wisp !== "string") return;
    let message;
    try { message = JSON.parse(event.data.wisp); } catch { return; }
    if (window.wispBridge) window.wispBridge.receive(message);
  });
})();
"""
SHIM_TAG = '<script src="./wisp-shim.js"></script>'


async def excalidraw_asset(request: Request) -> Response:
    root = excalidraw_root().resolve()
    asset = request.path_params.get("asset") or "index.html"
    if asset == "wisp-shim.js":
        return Response(BRIDGE_SHIM, media_type=EXTRA_MIME[".js"], headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"})
    parts = asset.split("/")
    if any(p in ("", ".", "..") or "\\" in p for p in parts):
        return fail("not found", 404)
    target = (root / asset).resolve()
    if not target.is_relative_to(root) or not target.is_file():
        return fail("not found", 404)
    mime = EXTRA_MIME.get(target.suffix.lower()) or mimetypes.guess_type(target.name)[0] or "application/octet-stream"
    headers = {"Content-Security-Policy": EXCALIDRAW_CSP, "Cache-Control": "no-store", "Referrer-Policy": "no-referrer"}
    data = target.read_bytes()
    if target == root / "index.html":
        data = data.decode("utf-8").replace("<script", SHIM_TAG + "<script", 1).encode("utf-8")
    return Response(data, media_type=mime, headers=headers)


routes = [
    Route("/state", state_open),
    Route("/tree", tree),
    Route("/notes", notes),
    Route("/note", get_note, methods=["GET"]),
    Route("/note", put_note, methods=["PUT"]),
    Route("/note", create_note, methods=["POST"]),
    Route("/folder", create_folder, methods=["POST"]),
    Route("/trash", trash, methods=["POST"]),
    Route("/rename/preview", rename_preview, methods=["POST"]),
    Route("/rename/apply", rename_apply, methods=["POST"]),
    Route("/search", search),
    Route("/recent", recent),
    Route("/backlinks", backlinks),
    Route("/outgoing", outgoing),
    Route("/resolve", resolve),
    Route("/graph", graph),
    Route("/tags", tags),
    Route("/task", toggle_task, methods=["POST"]),
    Route("/properties", properties, methods=["GET"]),
    Route("/property", set_property, methods=["POST"]),
    Route("/merge", merge_texts, methods=["POST"]),
    Route("/daily", daily_info, methods=["GET"]),
    Route("/daily", daily_open, methods=["POST"]),
    Route("/bookmarks", get_bookmarks, methods=["GET"]),
    Route("/bookmarks", put_bookmarks, methods=["PUT"]),
    Route("/attachment", attachment),
    Route("/drawing", get_drawing, methods=["GET"]),
    Route("/drawing", put_drawing, methods=["PUT"]),
    Route("/drawing/new", new_drawing, methods=["POST"]),
    Route("/recover", recover, methods=["POST"]),
    Route("/excalidraw/t/{token}/{asset:path}", excalidraw_asset),
    Route("/excalidraw/{asset:path}", excalidraw_asset),
]
