from __future__ import annotations

import webbrowser
from datetime import datetime
from typing import Any, Callable

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from . import google, oauth, quick
from .dpapi import SecretFile, default_protector

FEATURE = "agenda"
HTTP_STATUS = {"notConnected": 409, "unauthorized": 401, "forbidden": 403, "notFound": 404, "notInvitee": 409,
               "tooManyAttendees": 409, "changed": 409, "rateLimited": 429, "network": 502, "malformed": 502,
               "http": 502}


def login_message(error: Exception | None) -> str | None:
    if isinstance(error, oauth.LoginFailure):
        if error.reason == "portBusy":
            return "A porta do login está ocupada; feche o que a usa e clique em Conectar Google de novo."
        if error.reason == "timedOut":
            return "O login do Google expirou; clique em Conectar Google de novo."
        if error.reason == "callback":
            return "A resposta do Google não conferiu; clique em Conectar Google de novo."
    if isinstance(error, google.GoogleAuthError) and error.reason == "rejected":
        return f"O Google recusou o login ({error.detail}); confira o credentials.json."
    if isinstance(error, google.GoogleError) and error.code == "network":
        return google.GoogleError.MESSAGES["network"]
    return "Não consegui conectar ao Google; clique em Conectar Google de novo."


class AgendaService:
    def __init__(self, account: google.GoogleAccount, opener: Callable[[str], object] = webbrowser.open,
                 port: Callable[[], int] | None = None) -> None:
        import random
        self.account = account
        self.opener = opener
        self.port = port or (lambda: random.randint(49152, 65000))
        self.runner = oauth.LoginRunner()
        self.error: str | None = None

    def status(self) -> dict:
        token = self.account.token()
        return {"storage": self.account.storage_available, "has_client": self.account.client() is not None,
                "connected": token is not None, "email": token.email if token else None,
                "connecting": self.runner.running, "error": self.error}

    def connect(self, publish: Callable[..., None]) -> None:
        client = self.account.client()
        if client is None or self.runner.running:
            return
        self.error = None

        def authorize(redirect: str, state: str, code_challenge: str) -> str:
            return google.authorization_url(client.client_id, redirect, state, code_challenge)

        async def exchange(code: str, verifier: str, redirect: str) -> None:
            await self.account.sign_in(code, verifier, redirect)

        def done(outcome: str, error: Exception | None) -> None:
            if outcome == "denied":
                self.error = "O Google não autorizou o Wisp; clique em Conectar Google para tentar de novo."
            elif outcome == "failed":
                self.error = login_message(error)
            publish("auth", state=outcome, message=self.error)

        session = oauth.LoginSession(port=self.port, path=google.REDIRECT_PATH, brand="Google", authorize_url=authorize,
                                     exchange=exchange, opener=self.opener, attempts=5)
        self.runner.start(session, done)


_service: AgendaService | None = None


def service() -> AgendaService:
    global _service
    if _service is None:
        protector = default_protector()
        account = google.GoogleAccount(httpx.AsyncClient(timeout=20.0), SecretFile("google-client.bin", protector),
                                       SecretFile("google-token.bin", protector))
        _service = AgendaService(account)
    return _service


def _error(error: google.GoogleError) -> Response:
    return JSONResponse({"error": error.message, "code": error.code}, status_code=HTTP_STATUS.get(error.code, 502))


def _bad(message: str, status: int = 400) -> Response:
    return JSONResponse({"error": message}, status_code=status)


async def _json(request: Request) -> dict:
    try:
        body = await request.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


def _publisher(request: Request) -> Callable[..., None]:
    host = request.app.state.host
    return lambda type_, **fields: host.publish_feature(FEATURE, type_, **fields)


async def get_status(request: Request) -> Response:
    return JSONResponse(service().status())


async def put_client(request: Request) -> Response:
    svc = service()
    if not svc.account.storage_available:
        return _bad("Guardar o login do Google só funciona no Windows.", 501)
    text = (await _json(request)).get("credentials")
    try:
        client = google.GoogleClient.parse(text if isinstance(text, str) else "")
    except google.ClientParseError as error:
        return _bad(google.CLIENT_MESSAGES[error.reason])
    svc.account.save_client(client)
    svc.error = None
    return JSONResponse(svc.status())


async def delete_client(request: Request) -> Response:
    svc = service()
    svc.runner.cancel()
    await svc.account.sign_out()
    svc.account.client_file.delete()
    return JSONResponse(svc.status())


async def post_connect(request: Request) -> Response:
    svc = service()
    if svc.account.client() is None:
        return _bad("Cole o credentials.json do Google antes de conectar.", 409)
    svc.connect(_publisher(request))
    return JSONResponse(svc.status(), status_code=202)


async def post_cancel(request: Request) -> Response:
    service().runner.cancel()
    return JSONResponse({"ok": True})


async def post_signout(request: Request) -> Response:
    svc = service()
    svc.runner.cancel()
    await svc.account.sign_out()
    svc.error = None
    return JSONResponse(svc.status())


def _moment(value: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


async def list_events(request: Request) -> Response:
    start, end = _moment(request.query_params.get("start")), _moment(request.query_params.get("end"))
    if start is None or end is None or end <= start:
        return _bad("start e end (ISO 8601) são obrigatórios")
    try:
        return JSONResponse({"items": await service().account.list_events(start, end)})
    except google.GoogleError as error:
        return _error(error)


async def get_event(request: Request) -> Response:
    try:
        return JSONResponse(await service().account.get_event(request.path_params["id"]))
    except google.GoogleError as error:
        return _error(error)


def _event_body(body: dict) -> dict | None:
    title, start, end = body.get("title"), body.get("start"), body.get("end")
    if not isinstance(start, str) or not isinstance(end, str):
        return None
    event: dict[str, Any] = {"summary": title if isinstance(title, str) and title.strip() else "Sem título"}
    if body.get("all_day") is True:
        from datetime import date, timedelta
        try:
            event["start"] = {"date": start[:10]}
            event["end"] = {"date": (date.fromisoformat(end[:10]) + timedelta(days=1)).isoformat()}
        except ValueError:
            return None
    else:
        if _moment(start) is None or _moment(end) is None:
            return None
        event["start"], event["end"] = {"dateTime": start}, {"dateTime": end}
    for key, field in (("location", "location"), ("notes", "description")):
        if isinstance(body.get(key), str) and body[key].strip():
            event[field] = body[key].strip()
    return event


async def create_event(request: Request) -> Response:
    event = _event_body(await _json(request))
    if event is None:
        return _bad("título, início e fim são obrigatórios")
    try:
        return JSONResponse(await service().account.create_event(event), status_code=201)
    except google.GoogleError as error:
        return _error(error)


async def delete_event(request: Request) -> Response:
    try:
        await service().account.delete_event(request.path_params["id"])
    except google.GoogleError as error:
        return _error(error)
    return JSONResponse({"ok": True})


async def rsvp(request: Request) -> Response:
    choice = (await _json(request)).get("choice")
    if choice not in google.RSVP_CHOICES:
        return _bad("choice deve ser accepted, tentative ou declined")
    try:
        return JSONResponse(await service().account.respond(request.path_params["id"], choice))
    except google.GoogleError as error:
        return _error(error)


async def parse_quick(request: Request) -> Response:
    body = await _json(request)
    text = body.get("text")
    if not isinstance(text, str):
        return _bad("text é obrigatório")
    parsed = quick.parse(text, _moment(body.get("now")) or datetime.now().astimezone())
    if parsed is None:
        return JSONResponse({"event": None})
    iso = (lambda d: d.date().isoformat()) if parsed.all_day else (lambda d: d.isoformat(timespec="seconds"))
    return JSONResponse({"event": {"title": parsed.title, "start": iso(parsed.start), "end": iso(parsed.end),
                                   "all_day": parsed.all_day, "location": parsed.location,
                                   "calendar_name": parsed.calendar_name, "has_date": parsed.has_date,
                                   "has_time": parsed.has_time}})


routes = [
    Route("/status", get_status, methods=["GET"]),
    Route("/client", put_client, methods=["PUT"]),
    Route("/client", delete_client, methods=["DELETE"]),
    Route("/connect", post_connect, methods=["POST"]),
    Route("/cancel", post_cancel, methods=["POST"]),
    Route("/signout", post_signout, methods=["POST"]),
    Route("/events", list_events, methods=["GET"]),
    Route("/events", create_event, methods=["POST"]),
    Route("/events/{id}", get_event, methods=["GET"]),
    Route("/events/{id}", delete_event, methods=["DELETE"]),
    Route("/events/{id}/rsvp", rsvp, methods=["POST"]),
    Route("/parse", parse_quick, methods=["POST"]),
]
