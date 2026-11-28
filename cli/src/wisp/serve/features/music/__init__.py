from __future__ import annotations

import os
import json
import webbrowser
from pathlib import Path
from typing import Callable

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from wisp.paths import WispPaths

from ..agenda import oauth
from ..agenda.dpapi import SecretFile, default_protector
from . import media, spotify

FEATURE = "music"
EMPTY_SENTENCE = "Abra o Spotify ou o Music para ver o que está tocando"
CONNECT_SENTENCE = "Cole o Client ID do seu app do Spotify antes de conectar."


def client_id_path() -> Path:
    return WispPaths.current().config / "spotify.json"


def load_client_id() -> str:
    env = os.environ.get("WISP_SPOTIFY_CLIENT_ID", "").strip()
    if env:
        return env
    try:
        value = json.loads(client_id_path().read_text("utf-8")).get("client_id", "")
    except (OSError, ValueError, AttributeError):
        return ""
    return value.strip() if isinstance(value, str) else ""


def save_client_id(value: str) -> None:
    path = client_id_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"client_id": value.strip()}), "utf-8")


class MusicService:
    def __init__(self, api: spotify.SpotifyApi, backend: media.MediaBackend | None,
                 opener: Callable[[str], object] = webbrowser.open) -> None:
        self.api, self.backend, self.opener = api, backend, opener
        self.runner = oauth.LoginRunner()
        self.error: str | None = None
        self._artwork_key: str | None = None
        self._artwork: str | None = None

    def status(self) -> dict:
        return {"storage": self.api.storage_available, "has_client_id": bool(load_client_id()),
                "client_id": load_client_id(), "signed_in": self.api.is_signed_in(),
                "signing_in": self.runner.running, "error": self.error, "media": self.backend is not None}

    def connect(self, publish: Callable[..., None]) -> None:
        client_id = load_client_id()
        if not client_id or self.runner.running:
            return
        self.error = None

        def authorize(redirect: str, state: str, code_challenge: str) -> str:
            return spotify.authorization_url(client_id, redirect, state, code_challenge)

        async def exchange(code: str, verifier: str, redirect: str) -> None:
            await self.api.sign_in(code, verifier, redirect)

        def done(outcome: str, error: Exception | None) -> None:
            if outcome == "denied":
                self.error = "O Spotify não autorizou o Wisp; clique em Conectar Spotify para tentar de novo."
            elif outcome == "failed":
                self.error = _login_message(error)
            publish("auth", state=outcome, message=self.error)

        session = oauth.LoginSession(port=lambda: spotify.REDIRECT_PORT, path=spotify.REDIRECT_PATH, brand="Spotify",
                                     authorize_url=authorize, exchange=exchange, opener=self.opener)
        self.runner.start(session, done)


def _login_message(error: Exception | None) -> str | None:
    if isinstance(error, oauth.LoginFailure):
        if error.reason == "portBusy":
            return (f"A porta {spotify.REDIRECT_PORT} está ocupada; feche o que a usa e clique em "
                    "Conectar Spotify de novo.")
        if error.reason == "timedOut":
            return "O login do Spotify expirou; clique em Conectar Spotify de novo."
        if error.reason == "callback":
            return "A resposta do Spotify não conferiu; clique em Conectar Spotify de novo."
    if isinstance(error, spotify.SpotifyError):
        return error.login_message()
    return "Não consegui conectar ao Spotify; clique em Conectar Spotify de novo."


_service: MusicService | None = None


def service() -> MusicService:
    global _service
    if _service is None:
        api = spotify.SpotifyApi(httpx.AsyncClient(timeout=20.0), load_client_id,
                                 SecretFile("spotify-token.bin", default_protector()))
        _service = MusicService(api, media.default_backend())
    return _service


def _fail(error: spotify.SpotifyError, action: str) -> Response:
    status = {"notSignedIn": 401, "sessionExpired": 401, "unauthorized": 401, "premiumRequired": 403,
              "forbidden": 403, "noActiveDevice": 409, "notFound": 404, "rateLimited": 429}.get(error.kind, 502)
    return JSONResponse({"error": error.message(action), "kind": error.kind}, status_code=status)


async def _json(request: Request) -> dict:
    try:
        body = await request.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


async def get_status(request: Request) -> Response:
    return JSONResponse(service().status())


async def put_client(request: Request) -> Response:
    value = (await _json(request)).get("client_id")
    save_client_id(value if isinstance(value, str) else "")
    return JSONResponse(service().status())


async def post_connect(request: Request) -> Response:
    svc = service()
    if not load_client_id():
        return JSONResponse({"error": CONNECT_SENTENCE}, status_code=409)
    host = request.app.state.host
    svc.connect(lambda type_, **fields: host.publish_feature(FEATURE, type_, **fields))
    return JSONResponse(svc.status(), status_code=202)


async def post_cancel(request: Request) -> Response:
    service().runner.cancel()
    return JSONResponse({"ok": True})


async def post_signout(request: Request) -> Response:
    svc = service()
    svc.runner.cancel()
    svc.api.sign_out()
    svc.error = None
    return JSONResponse(svc.status())


async def get_now(request: Request) -> Response:
    backend = service().backend
    if backend is None:
        return JSONResponse({"track": None, "empty": EMPTY_SENTENCE})
    try:
        track = await backend.now()
    except Exception:  # noqa: BLE001
        track = None
    return JSONResponse({"track": track.as_json() if track else None, "empty": EMPTY_SENTENCE})


async def get_artwork(request: Request) -> Response:
    svc = service()
    key = request.query_params.get("key", "")
    if svc.backend is None:
        return JSONResponse({"data_url": None})
    if key and key == svc._artwork_key:
        return JSONResponse({"data_url": svc._artwork})
    try:
        url = media.artwork_data_url(await svc.backend.artwork())
    except Exception:  # noqa: BLE001
        url = None
    svc._artwork_key, svc._artwork = key, url
    return JSONResponse({"data_url": url})


async def post_control(request: Request) -> Response:
    action = (await _json(request)).get("action")
    backend = service().backend
    if action not in media.ACTIONS or backend is None:
        return JSONResponse({"error": "ação inválida"}, status_code=400)
    return JSONResponse({"ok": await backend.control(action)})


async def get_playlists(request: Request) -> Response:
    try:
        return JSONResponse({"items": await service().api.playlists()})
    except spotify.SpotifyError as error:
        return _fail(error, "carregar suas playlists")


async def get_playlist_tracks(request: Request) -> Response:
    try:
        return JSONResponse({"items": await service().api.playlist_tracks(request.path_params["id"])})
    except spotify.SpotifyError as error:
        if error.kind == "forbidden":
            return JSONResponse({"error": "O Spotify só lista as músicas das playlists que você criou ou edita; "
                                          "use Tocar para ouvir esta.", "kind": "forbidden"}, status_code=403)
        return _fail(error, "abrir esta playlist")


async def get_search(request: Request) -> Response:
    query = request.query_params.get("q", "").strip()
    if not query:
        return JSONResponse({"tracks": [], "albums": [], "playlists": [], "artists": []})
    try:
        return JSONResponse(await service().api.search(query))
    except spotify.SpotifyError as error:
        return _fail(error, "buscar no Spotify")


async def post_play(request: Request) -> Response:
    body = await _json(request)
    context, uris = body.get("context_uri"), body.get("uris")
    if not isinstance(context, str) and not (isinstance(uris, list) and all(isinstance(u, str) for u in uris)):
        return JSONResponse({"error": "context_uri ou uris são obrigatórios"}, status_code=400)
    start = body.get("start_at")
    try:
        await service().api.play(context if isinstance(context, str) else None, uris if isinstance(uris, list) else None,
                                 start if isinstance(start, str) else None)
    except spotify.SpotifyError as error:
        return _fail(error, "tocar")
    return JSONResponse({"ok": True})


async def post_queue(request: Request) -> Response:
    uri = (await _json(request)).get("uri")
    if not isinstance(uri, str):
        return JSONResponse({"error": "uri é obrigatória"}, status_code=400)
    try:
        await service().api.enqueue(uri)
    except spotify.SpotifyError as error:
        return _fail(error, "adicionar à fila")
    return JSONResponse({"ok": True})


routes = [
    Route("/status", get_status, methods=["GET"]),
    Route("/client", put_client, methods=["PUT"]),
    Route("/connect", post_connect, methods=["POST"]),
    Route("/cancel", post_cancel, methods=["POST"]),
    Route("/signout", post_signout, methods=["POST"]),
    Route("/now", get_now, methods=["GET"]),
    Route("/artwork", get_artwork, methods=["GET"]),
    Route("/control", post_control, methods=["POST"]),
    Route("/playlists", get_playlists, methods=["GET"]),
    Route("/playlists/{id}/tracks", get_playlist_tracks, methods=["GET"]),
    Route("/search", get_search, methods=["GET"]),
    Route("/play", post_play, methods=["POST"]),
    Route("/queue", post_queue, methods=["POST"]),
]
