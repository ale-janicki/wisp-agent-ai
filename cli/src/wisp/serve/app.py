from __future__ import annotations

import asyncio
import contextlib
import hmac
import os
from typing import Any
from urllib.parse import unquote_to_bytes

from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from wisp import __version__
from wisp.serve import features, protocol
from wisp.serve.claude_session import ClaudeNotFound, ConversationSession, SessionGone, locate_claude
from wisp.serve.store import (ConversationStore, TranscriptStore, claude_history, conversas_dir, data_dir,
                              format_time, locate_claude_session, wisp_history, wisp_root)


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
        self._permissions: dict[str, ConversationSession] = {}

    def publish(self, conversation_id: str, type_: str, **fields: Any) -> None:
        self.hub.publish(protocol.event(conversation_id, type_, **fields))

    def publish_feature(self, feature: str, type_: str, **fields: Any) -> None:
        self.hub.publish(protocol.feature_event(feature, type_, **fields))

    def claude_path(self) -> str:
        return locate_claude(os.environ.get("WISP_CLAUDE_BIN") or None)

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

    def _allowed(self, scope) -> bool:
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
        items = [{"id": public_id(r), "title": r["title"], "updated_at": format_time(r["updatedAt"]),
                  "engine": protocol.ENGINE} for r in host.store.all()]
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
            messages = claude_history(path) if path else None
        if not messages:
            key = public_id(record)
            if not (host.transcripts.folder / f"{key}.jsonl").exists():
                key = host.transcripts.find(record.get("sessionId")) or key
            messages = wisp_history(host.transcripts.messages(key))
        return JSONResponse({"id": public_id(record), "title": record["title"], "messages": messages})

    async def post_message(request: Request) -> Response:
        record = host.store.get(request.path_params["id"])
        if record is None:
            return not_found()
        body = await json_body(request)
        text = body.get("text")
        attachments = body.get("attachments") or []
        if not isinstance(text, str) or not text.strip() or not isinstance(attachments, list) \
                or not all(isinstance(a, str) for a in attachments):
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
        try:
            await owner.answer(request.path_params["request_id"], body["allow"], message)
        except KeyError:
            return not_found()
        except SessionGone as error:
            return JSONResponse({"error": str(error)}, status_code=409)
        return JSONResponse({"ok": True})

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
        yield
        await asyncio.gather(*(s.close() for s in host.sessions.values()), return_exceptions=True)

    app = Starlette(routes=[
        Route("/health", health),
        Route("/conversations", list_conversations, methods=["GET"]),
        Route("/conversations", create_conversation, methods=["POST"]),
        Route("/conversations/{id}", get_conversation, methods=["GET"]),
        Route("/conversations/{id}/messages", post_message, methods=["POST"]),
        Route("/conversations/{id}/stop", stop, methods=["POST"]),
        Route("/permissions/{request_id}", answer_permission, methods=["POST"]),
        Route("/events", events, methods=["GET"]),
        *features.mounts(),
    ], lifespan=lifespan)
    app.state.host = host
    return CORSMiddleware(TokenAuth(app, token), allow_origins=protocol.ALLOWED_ORIGINS,
                          allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"], allow_headers=["Authorization", "Content-Type"])


__all__ = ["ClaudeNotFound", "create_app"]
