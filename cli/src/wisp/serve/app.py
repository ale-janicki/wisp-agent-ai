from __future__ import annotations

import asyncio
import contextlib
import hmac
import json
import mimetypes
import os
import time
from pathlib import Path
from typing import Any
from urllib.parse import unquote_to_bytes

from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from wisp import __version__
from wisp import engines as engine_settings
from wisp.paths import WispPaths
from wisp.serve import engines, features, guards, protocol
from wisp.serve.claude_session import ClaudeNotFound, ConversationSession, SessionGone, locate_claude
from wisp.serve.engines import choose, title
from wisp.serve.store import (ATTACHMENT_LIMIT, ConversationStore, TranscriptStore, attachments_root, claude_history,
                              conversas_dir, data_dir, format_time, is_image, locate_claude_session, refusal,
                              is_inside, remove_staged, save_upload, stage_files, too_big_notice, wisp_history, wisp_root)

PREFIX_TTL = 5.0
USER_PREFIX = "Você: "
TITLE_RENAME_LIMIT = 120


class Hub:
    def __init__(self) -> None:
        self._subscribers: set[asyncio.Queue] = set()

    def subscribe(self) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue()
        self._subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue) -> None:
        self._subscribers.discard(queue)

    def publish(self, payload: dict[str, Any]) -> None:
        for queue in list(self._subscribers):
            queue.put_nowait(payload)


class Host:
    def __init__(self) -> None:
        self.hub = Hub()
        self.store = ConversationStore(data_dir())
        self.transcripts = TranscriptStore(conversas_dir())
        self.workspace = wisp_root()
        self.sessions: dict[str, ConversationSession] = {}
        self.rate_limit: dict[str, Any] | None = None
        self._permissions: dict[str, ConversationSession] = {}
        self._prefix: tuple[float, str | None] = (0.0, None)

    def publish(self, conversation_id: str, type_: str, **fields: Any) -> None:
        self.hub.publish(protocol.event(conversation_id, type_, **fields))

    def publish_feature(self, feature: str, type_: str, **fields: Any) -> None:
        self.hub.publish(protocol.feature_event(feature, type_, **fields))

    def claude_path(self) -> str:
        return locate_claude(os.environ.get("WISP_CLAUDE_BIN") or guards.profile_text("claudePath"))

    def status_prefix(self) -> str | None:
        stamp, value = self._prefix
        if time.monotonic() - stamp > PREFIX_TTL:
            value = guards.profile_text("statusPrefix")
            self._prefix = (time.monotonic(), value)
        return value

    def attachments_root(self):
        try:
            profile = json.loads((Path(WispPaths.current().config) / "profile.json").read_text("utf-8"))
            folder = profile["blocks"]["telegram"]["attachments"]
        except (OSError, ValueError, KeyError, TypeError):
            folder = None
        return attachments_root(folder if isinstance(folder, str) else None)

    def active_engine(self) -> str:
        return engine_settings.read_active(self.workspace)

    def engine_environment(self) -> tuple[str | None, dict[str, str]]:
        binary = guards.wisp_binary()
        env = dict(os.environ)
        if binary:
            env["WISP_BIN"] = binary
        return binary, env

    async def engine_choice(self, session: ConversationSession) -> tuple[str, str | None]:
        active = await asyncio.to_thread(self.active_engine)
        if active not in ("codex", "local"):
            return "claude", None
        binary, env = await asyncio.to_thread(self.engine_environment)
        record = self.store.get(session.id) or {}
        return await asyncio.to_thread(choose.desired, active, binary, env, record.get("cwd"), str(self.workspace))

    async def generate_title(self, user: str, reply: str) -> str | None:
        try:
            executable = await asyncio.to_thread(self.claude_path)
        except ClaudeNotFound:
            return None
        return await asyncio.to_thread(title.generate, executable, user, reply)

    def register_permission(self, request_id: str, session: ConversationSession) -> None:
        self._permissions[request_id] = session

    def forget_permission(self, request_id: str) -> None:
        self._permissions.pop(request_id, None)

    def permission_owner(self, request_id: str) -> ConversationSession | None:
        return self._permissions.get(request_id)

    def session(self, conversation_id: str) -> ConversationSession:
        key = conversation_id.lower()
        if key not in self.sessions:
            self.sessions[key] = ConversationSession(key, self)
        return self.sessions[key]


class TokenAuth:
    def __init__(self, app, token: str):
        self.app = app
        self.token = token.encode()

    EXCALIDRAW_PREFIX = "/api/brain/excalidraw/t/"

    def _path_token_allowed(self, scope) -> bool:
        if not scope["path"].startswith(self.EXCALIDRAW_PREFIX):
            return False
        raw = scope.get("raw_path") or scope["path"].encode()
        raw = raw.split(b"?", 1)[0]
        prefix = self.EXCALIDRAW_PREFIX.encode()
        if not raw.startswith(prefix):
            return False
        segment = unquote_to_bytes(raw[len(prefix) :].split(b"/", 1)[0])
        return bool(segment) and hmac.compare_digest(segment, self.token)

    def _allowed(self, scope) -> bool:
        if self._path_token_allowed(scope):
            return True
        headers = dict(scope.get("headers") or [])
        header = headers.get(b"authorization", b"")
        if header[:7].lower() == b"bearer " and hmac.compare_digest(header[7:].strip(), self.token):
            return True
        if scope["path"] == "/events":
            for pair in scope.get("query_string", b"").split(b"&"):
                name, _, value = pair.partition(b"=")
                if name == b"token":
                    return hmac.compare_digest(unquote_to_bytes(value.replace(b"+", b"%20")), self.token)
        return False

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and not self._allowed(scope):
            await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
            return
        await self.app(scope, receive, send)


def create_app(token: str, heartbeat: float = protocol.HEARTBEAT_SECONDS) -> CORSMiddleware:
    host = Host()

    def public_id(record: dict) -> str:
        return str(record["id"]).lower()

    def not_found() -> Response:
        return JSONResponse({"error": "not found"}, status_code=404)

    async def json_body(request: Request) -> dict:
        try:
            body = await request.json()
        except ValueError:
            return {}
        return body if isinstance(body, dict) else {}

    async def health(request: Request) -> Response:
        return JSONResponse({"ok": True, "version": __version__})

    async def list_conversations(request: Request) -> Response:
        def preview(record: dict) -> str | None:
            text = record.get("lastPreview")
            if not text:
                return None
            return USER_PREFIX + text if record.get("lastFrom") == "user" else text

        items = [{"id": public_id(r), "title": r["title"], "updated_at": format_time(r["updatedAt"]),
                  "engine": protocol.ENGINE, "preview": preview(r), "closed": "closedAt" in r}
                 for r in host.store.all()]
        return JSONResponse({"items": items})

    async def create_conversation(request: Request) -> Response:
        title = (await json_body(request)).get("title")
        record = host.store.create(title if isinstance(title, str) and title.strip() else None,
                                   protocol.DEFAULT_TITLE)
        return JSONResponse({"id": public_id(record)})

    async def get_conversation(request: Request) -> Response:
        record = host.store.get(request.path_params["id"])
        if record is None:
            return not_found()
        messages = None
        if record.get("sessionId"):
            path = locate_claude_session(record["sessionId"], record.get("cwd"))
            messages = claude_history(path, host.status_prefix()) if path else None
        if not messages:
            key = public_id(record)
            if not (host.transcripts.folder / f"{key}.jsonl").exists():
                key = host.transcripts.find(record.get("sessionId")) or key
            messages = wisp_history(host.transcripts.messages(key))
        return JSONResponse({"id": public_id(record), "title": record["title"], "messages": messages,
                             "closed": "closedAt" in record})

    async def rename_conversation(request: Request) -> Response:
        record = host.store.get(request.path_params["id"])
        if record is None:
            return not_found()
        raw = (await json_body(request)).get("title")
        name = " ".join(raw.split())[:TITLE_RENAME_LIMIT] if isinstance(raw, str) else ""
        if not name:
            return JSONResponse({"error": "title is required"}, status_code=400)
        host.store.update(public_id(record), lambda r: r.update(title=name, titleGenerated=True))
        host.publish(public_id(record), "title", title=name)
        return JSONResponse({"id": public_id(record), "title": name})

    async def delete_conversation(request: Request) -> Response:
        record = host.store.get(request.path_params["id"])
        if record is None:
            return not_found()
        key = public_id(record)
        session = host.sessions.pop(key, None)
        host.store.delete(key)
        if session is not None:
            await session.close()
        return JSONResponse({"ok": True})

    async def reopen_conversation(request: Request) -> Response:
        record = host.store.get(request.path_params["id"])
        if record is None:
            return not_found()
        host.store.update(public_id(record), lambda r: (r.pop("closedAt", None), r.pop("closedFrom", None)))
        return JSONResponse({"ok": True})

    async def post_message(request: Request) -> Response:
        record = host.store.get(request.path_params["id"])
        if record is None:
            return not_found()
        body = await json_body(request)
        text = body.get("text")
        attachments = body.get("attachments") or []
        if not isinstance(attachments, list) or not all(isinstance(a, str) for a in attachments) \
                or not isinstance(text, str) or not (text.strip() or attachments):
            return JSONResponse({"error": "text is required"}, status_code=400)
        if not all(os.path.isabs(a) and os.path.isfile(a) for a in attachments):
            return JSONResponse({"error": "attachments must be absolute paths of existing files"}, status_code=400)
        host.session(public_id(record)).submit(text, attachments)
        return JSONResponse({"accepted": True}, status_code=202)

    async def stop(request: Request) -> Response:
        record = host.store.get(request.path_params["id"])
        if record is None:
            return not_found()
        host.session(public_id(record)).stop()
        return JSONResponse({"ok": True})

    async def answer_permission(request: Request) -> Response:
        owner = host.permission_owner(request.path_params["request_id"])
        if owner is None:
            return not_found()
        body = await json_body(request)
        if not isinstance(body.get("allow"), bool):
            return JSONResponse({"error": "allow (bool) is required"}, status_code=400)
        message = body.get("message") if isinstance(body.get("message"), str) else None
        always = body.get("always") is True
        try:
            await owner.answer(request.path_params["request_id"], body["allow"], message, always)
        except KeyError:
            return not_found()
        except ValueError:
            return JSONResponse({"error": "nothing to persist for this request"}, status_code=400)
        except SessionGone as error:
            return JSONResponse({"error": str(error)}, status_code=409)
        return JSONResponse({"ok": True})

    async def stage_attachments(request: Request) -> Response:
        paths = (await json_body(request)).get("paths")
        if not isinstance(paths, list) or not paths or not all(isinstance(p, str) for p in paths) \
                or len(paths) > ATTACHMENT_LIMIT:
            return JSONResponse({"error": f"paths must be 1 to {ATTACHMENT_LIMIT} absolute file paths"},
                                status_code=400)
        root = host.attachments_root()
        try:
            staged, refused, too_big = await asyncio.to_thread(stage_files, paths, root, None,
                                                               protocol.MAX_UPLOAD_BYTES)
        except OSError as error:
            return JSONResponse({"error": f"Não consegui preparar o anexo: {error}"}, status_code=500)
        notice = " ".join(n for n in (refusal(refused) if refused else "",
                                      too_big_notice(too_big, protocol.MAX_UPLOAD_BYTES) if too_big else "") if n)
        return JSONResponse({"files": staged, "refused": refused + too_big, "notice": notice or None})

    async def upload_attachment(request: Request) -> Response:
        name = request.query_params.get("name", "")
        if not name.strip():
            return JSONResponse({"error": "name is required"}, status_code=400)
        data = bytearray()
        async for chunk in request.stream():
            data += chunk
            if len(data) > protocol.MAX_UPLOAD_BYTES:
                return JSONResponse({"error": "file too large"}, status_code=413)
        if not data:
            return JSONResponse({"error": "empty file"}, status_code=400)
        try:
            saved = await asyncio.to_thread(save_upload, name, bytes(data), host.attachments_root())
        except OSError as error:
            return JSONResponse({"error": f"Não consegui preparar o anexo: {error}"}, status_code=500)
        return JSONResponse({"files": [saved], "refused": [], "notice": None})

    async def discard_attachment(request: Request) -> Response:
        path = request.query_params.get("path", "")
        removed = await asyncio.to_thread(remove_staged, path, host.attachments_root()) if path else False
        return JSONResponse({"ok": True}) if removed else not_found()

    async def attachment_file(request: Request) -> Response:
        path = request.query_params.get("path", "")
        root = host.attachments_root()
        if not path or not os.path.isabs(path) or not is_image(path) or not is_inside(path, root) \
                or not os.path.isfile(path):
            return not_found()
        kind = mimetypes.guess_type(path)[0] or "application/octet-stream"
        return FileResponse(path, media_type=kind, headers={"X-Content-Type-Options": "nosniff",
                                                            "Cache-Control": "private, max-age=3600"})

    async def engine_overview(request: Request) -> Response:
        def gather() -> dict:
            binary, env = host.engine_environment()
            try:
                host.claude_path()
                found = True
            except ClaudeNotFound:
                found = False
            return choose.overview(host.active_engine(), binary, env, found)

        return JSONResponse(await asyncio.to_thread(gather))

    async def set_engine(request: Request) -> Response:
        engine = (await json_body(request)).get("engine")
        if engine not in engines.KINDS:
            return JSONResponse({"error": f"engine must be one of {', '.join(engines.KINDS)}"}, status_code=400)
        await asyncio.to_thread(engine_settings.write_active, host.workspace, engine)
        return JSONResponse({"active": engine})

    async def usage(request: Request) -> Response:
        return JSONResponse(host.rate_limit or {"five_hour": None, "seven_day": None})

    async def events(request: Request) -> Response:
        queue = host.hub.subscribe()

        async def stream():
            try:
                yield ": connected\n\n"
                while True:
                    try:
                        payload = await asyncio.wait_for(queue.get(), heartbeat)
                    except asyncio.TimeoutError:
                        yield ": ping\n\n"
                        continue
                    yield protocol.sse_data(payload)
            finally:
                host.hub.unsubscribe(queue)

        return StreamingResponse(stream(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    @contextlib.asynccontextmanager
    async def lifespan(app):
        stops = features.start(host)
        yield
        for stop in stops:
            with contextlib.suppress(Exception):
                stop()
        await asyncio.gather(*(s.close() for s in host.sessions.values()), return_exceptions=True)

    app = Starlette(routes=[
        Route("/health", health),
        Route("/conversations", list_conversations, methods=["GET"]),
        Route("/conversations", create_conversation, methods=["POST"]),
        Route("/conversations/{id}", get_conversation, methods=["GET"]),
        Route("/conversations/{id}", rename_conversation, methods=["PATCH"]),
        Route("/conversations/{id}", delete_conversation, methods=["DELETE"]),
        Route("/conversations/{id}/reopen", reopen_conversation, methods=["POST"]),
        Route("/conversations/{id}/messages", post_message, methods=["POST"]),
        Route("/conversations/{id}/stop", stop, methods=["POST"]),
        Route("/permissions/{request_id}", answer_permission, methods=["POST"]),
        Route("/attachments", stage_attachments, methods=["POST"]),
        Route("/attachments", upload_attachment, methods=["PUT"]),
        Route("/attachments", discard_attachment, methods=["DELETE"]),
        Route("/attachments/file", attachment_file, methods=["GET"]),
        Route("/engines", engine_overview, methods=["GET"]),
        Route("/engines/active", set_engine, methods=["PUT"]),
        Route("/usage", usage, methods=["GET"]),
        Route("/events", events, methods=["GET"]),
        *features.mounts(),
    ], lifespan=lifespan)
    app.state.host = host
    return CORSMiddleware(TokenAuth(app, token), allow_origins=protocol.ALLOWED_ORIGINS,
                          allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"], allow_headers=["Authorization", "Content-Type"])


__all__ = ["ClaudeNotFound", "create_app"]
