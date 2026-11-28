from __future__ import annotations

import asyncio
import json
import time
from dataclasses import asdict, dataclass
from typing import Any, Awaitable, Callable
from urllib.parse import quote

import httpx

from ..agenda import oauth
from ..agenda.dpapi import SecretFile

AUTHORIZE = "https://accounts.spotify.com/authorize"
TOKEN = "https://accounts.spotify.com/api/token"
API = "https://api.spotify.com/v1"
REDIRECT_PORT = 43821
REDIRECT_PATH = "/callback"
REDIRECT_URI = f"http://127.0.0.1:{REDIRECT_PORT}{REDIRECT_PATH}"
SCOPES = ["playlist-read-private", "playlist-read-collaborative", "user-read-playback-state",
          "user-modify-playback-state"]
EXPIRY_SKEW = 60.0
PAGE_MAX = 50
SEARCH_LIMIT = 8
SEARCH_TYPES = "track,album,playlist,artist"
PLAYLIST_CAP = 500
TRACK_CAP = 500
MAX_RATE_LIMIT_RETRIES = 2
MAX_RETRY_AFTER = 10.0


@dataclass
class SpotifyToken:
    access_token: str
    refresh_token: str
    expires_at: float
    scope: str

    def needs_refresh(self, now: float, skew: float = EXPIRY_SKEW) -> bool:
        return now + skew >= self.expires_at


class SpotifyError(Exception):
    def __init__(self, kind: str, detail: str = "", status: int = 0, retry_after: float = 1.0, quota: bool = False) -> None:
        super().__init__(kind)
        self.kind, self.detail, self.status, self.retry_after, self.quota = kind, detail, status, retry_after, quota

    def message(self, action: str) -> str:
        kind = self.kind
        if kind in ("notSignedIn", "sessionExpired"):
            return "Sua sessão do Spotify expirou; clique em Conectar Spotify."
        if kind == "unauthorized":
            return f"O Spotify recusou o acesso para {action}; saia e conecte de novo."
        if kind == "premiumRequired":
            return f"Para {action} pelo Wisp a conta precisa de Spotify Premium."
        if kind == "noActiveDevice":
            return f"Abra o Spotify em algum dispositivo para {action}."
        if kind == "forbidden":
            return f"O Spotify negou {action}; confira se sua conta está em Users Management do app."
        if kind == "notFound":
            return f"O Spotify não encontrou o item para {action}."
        if kind == "rateLimited":
            if self.quota:
                return f"A cota do app no Spotify acabou por agora; tente {action} mais tarde."
            return f"O Spotify pediu uma pausa; tente {action} em {int(-(-self.retry_after // 1))} s."
        if kind == "server":
            return f"O Spotify respondeu erro {self.status} ao {action}; tente de novo."
        if kind == "network":
            return f"Sem conexão com o Spotify para {action}; confira a internet."
        if kind == "rejected":
            return f"O Spotify recusou o pedido para {action}: {self.detail}."
        if kind == "decoding":
            return f"Não entendi a resposta do Spotify ao {action}."
        if kind == "storage":
            return "Não consegui guardar a sessão do Spotify neste PC."
        return f"Não consegui {action} no Spotify."

    def login_message(self) -> str | None:
        if self.kind == "rejected":
            return f"O Spotify recusou o login ({self.detail}); confira o Client ID e o Redirect URI do app."
        if self.kind == "network":
            return "Sem conexão com o Spotify; confira a internet e conecte de novo."
        if self.kind == "storage":
            return self.message("conectar")
        return "Não consegui conectar ao Spotify; clique em Conectar Spotify de novo."


def classify(status: int, body: Any, retry_after: str | None, player: bool) -> SpotifyError | None:
    if 200 <= status < 300:
        return None
    error = body.get("error") if isinstance(body, dict) else None
    error = error if isinstance(error, dict) else {}
    message = str(error.get("message") or "")
    reason = str(error.get("reason") or "").upper()
    if status == 401:
        return SpotifyError("unauthorized", status=status)
    if status == 403 and player and (reason == "PREMIUM_REQUIRED" or "premium" in message.lower()):
        return SpotifyError("premiumRequired", status=status)
    if status == 403:
        return SpotifyError("forbidden", message, status)
    if status == 404 and player:
        return SpotifyError("noActiveDevice", status=status)
    if status == 404:
        return SpotifyError("notFound", message, status)
    if status == 429:
        try:
            seconds = max(1.0, float((retry_after or "").strip()))
        except ValueError:
            seconds = 1.0
        return SpotifyError("rateLimited", status=status, retry_after=seconds, quota=reason == "QUOTA_EXCEEDED")
    return SpotifyError("server", message, status)


def authorization_url(client_id: str, redirect: str, state: str, code_challenge: str) -> str:
    return AUTHORIZE + "?" + oauth.query([
        ("client_id", client_id), ("response_type", "code"), ("redirect_uri", redirect), ("state", state),
        ("scope", " ".join(SCOPES)), ("code_challenge_method", "S256"), ("code_challenge", code_challenge)])


def token_from_response(data: Any, now: float, previous: SpotifyToken | None) -> SpotifyToken:
    if not isinstance(data, dict):
        raise SpotifyError("decoding")
    if isinstance(data.get("error"), str):
        raise SpotifyError("rejected", data.get("error_description") or data["error"])
    access, expires = data.get("access_token"), data.get("expires_in")
    if not isinstance(access, str) or not isinstance(expires, (int, float)):
        raise SpotifyError("decoding")
    refresh = data.get("refresh_token") or (previous.refresh_token if previous else None)
    if not refresh:
        raise SpotifyError("decoding")
    return SpotifyToken(access, refresh, now + float(expires), data.get("scope") or (previous.scope if previous else ""))


def best_image(images: Any, pixels: int = 120) -> str | None:
    sized = sorted((i for i in images or [] if isinstance(i, dict) and i.get("width") and i.get("url")),
                   key=lambda i: i["width"])
    fit = next((i for i in sized if i["width"] >= pixels), None)
    if fit:
        return fit["url"]
    if sized:
        return sized[-1]["url"]
    first = next((i for i in images or [] if isinstance(i, dict) and i.get("url")), None)
    return first["url"] if first else None


def _artists(raw: Any) -> str:
    return ", ".join(a["name"] for a in raw or [] if isinstance(a, dict) and a.get("name"))


def playlist_shape(item: Any) -> dict | None:
    if not isinstance(item, dict) or not all(isinstance(item.get(k), str) for k in ("id", "name", "uri")):
        return None
    owner = item.get("owner") if isinstance(item.get("owner"), dict) else {}
    count = next((item[k].get("total") for k in ("items", "tracks") if isinstance(item.get(k), dict)
                  and item[k].get("total") is not None), None)
    return {"id": item["id"], "name": item["name"], "uri": item["uri"], "image": best_image(item.get("images")),
            "owner": owner.get("display_name"), "track_count": count, "collaborative": bool(item.get("collaborative"))}


def album_shape(item: Any) -> dict | None:
    if not isinstance(item, dict) or not all(isinstance(item.get(k), str) for k in ("id", "name", "uri")):
        return None
    return {"id": item["id"], "name": item["name"], "uri": item["uri"], "image": best_image(item.get("images")),
            "artists": _artists(item.get("artists")), "total_tracks": item.get("total_tracks")}


def track_shape(item: Any) -> dict | None:
    if not isinstance(item, dict) or not all(isinstance(item.get(k), str) for k in ("name", "uri")):
        return None
    album = item.get("album") if isinstance(item.get("album"), dict) else {}
    return {"uri": item["uri"], "name": item["name"], "artists": _artists(item.get("artists")),
            "duration_ms": item.get("duration_ms") or 0, "image": best_image(album.get("images") or item.get("images"))}


def artist_shape(item: Any) -> dict | None:
    if not isinstance(item, dict) or not all(isinstance(item.get(k), str) for k in ("id", "name", "uri")):
        return None
    return {"id": item["id"], "name": item["name"], "uri": item["uri"], "image": best_image(item.get("images"))}


def _page(raw: Any, shape: Callable[[Any], dict | None]) -> list[dict]:
    items = raw.get("items") if isinstance(raw, dict) else None
    return [s for s in (shape(i) for i in items or []) if s]


def entry_track(item: Any) -> dict | None:
    if not isinstance(item, dict):
        return None
    return track_shape(item.get("item")) or track_shape(item.get("track"))


def pick_device(devices: list[dict]) -> dict | None:
    usable = [d for d in devices if d.get("id") and not d.get("is_restricted")]
    return (next((d for d in usable if d.get("is_active")), None)
            or next((d for d in usable if str(d.get("type", "")).lower() == "computer"), None)
            or (usable[0] if usable else None))


class SpotifyApi:
    def __init__(self, http: httpx.AsyncClient, client_id: Callable[[], str], token_file: SecretFile,
                 clock: Callable[[], float] = time.time,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep) -> None:
        self.http, self.client_id, self.token_file, self.clock, self.sleep = http, client_id, token_file, clock, sleep
        self._refresh_lock = asyncio.Lock()

    @property
    def storage_available(self) -> bool:
        return self.token_file.available

    def token(self) -> SpotifyToken | None:
        raw = self.token_file.read()
        try:
            return SpotifyToken(**json.loads(raw)) if raw else None
        except (ValueError, TypeError):
            return None

    def is_signed_in(self) -> bool:
        return self.token() is not None

    def _store(self, token: SpotifyToken) -> None:
        try:
            self.token_file.write(json.dumps(asdict(token)).encode())
        except OSError:
            raise SpotifyError("storage") from None

    async def _token_call(self, fields: list[tuple[str, str]], previous: SpotifyToken | None) -> SpotifyToken:
        try:
            response = await self.http.post(TOKEN, content=oauth.query(fields),
                                            headers={"Content-Type": "application/x-www-form-urlencoded"})
            body = response.json()
        except httpx.HTTPError as error:
            raise SpotifyError("network", str(error)) from None
        except ValueError:
            raise SpotifyError("decoding") from None
        return token_from_response(body, self.clock(), previous)

    async def sign_in(self, code: str, verifier: str, redirect: str = REDIRECT_URI) -> None:
        token = await self._token_call([("grant_type", "authorization_code"), ("code", code),
                                        ("redirect_uri", redirect), ("client_id", self.client_id()),
                                        ("code_verifier", verifier)], None)
        self._store(token)

    def sign_out(self) -> None:
        self.token_file.delete()

    async def access_token(self, force_refresh: bool = False) -> str:
        current = self.token()
        if current is None:
            raise SpotifyError("notSignedIn")
        if not force_refresh and not current.needs_refresh(self.clock()):
            return current.access_token
        async with self._refresh_lock:
            latest = self.token() or current
            if not force_refresh and not latest.needs_refresh(self.clock()):
                return latest.access_token
            try:
                refreshed = await self._token_call([("grant_type", "refresh_token"),
                                                    ("refresh_token", latest.refresh_token),
                                                    ("client_id", self.client_id())], latest)
            except SpotifyError as error:
                if error.kind == "rejected":
                    self.sign_out()
                    raise SpotifyError("sessionExpired") from None
                raise
            self._store(refreshed)
            return refreshed.access_token

    async def send(self, method: str, path: str, params: dict | None = None, body: dict | None = None,
                   player: bool = False) -> Any:
        refreshed, limited = False, 0
        while True:
            token = await self.access_token()
            try:
                response = await self.http.request(method, f"{API}/{path}", params=params, json=body,
                                                   headers={"Authorization": f"Bearer {token}"})
            except httpx.HTTPError as error:
                raise SpotifyError("network", str(error)) from None
            try:
                data = response.json() if response.content else None
            except ValueError:
                data = None
            failure = classify(response.status_code, data, response.headers.get("Retry-After"), player)
            if failure is None:
                return data
            if failure.kind == "unauthorized" and not refreshed:
                refreshed = True
                await self.access_token(force_refresh=True)
            elif (failure.kind == "rateLimited" and not failure.quota and limited < MAX_RATE_LIMIT_RETRIES
                  and failure.retry_after <= MAX_RETRY_AFTER):
                limited += 1
                await self.sleep(failure.retry_after)
            else:
                raise failure

    async def playlists(self) -> list[dict]:
        found: list[dict] = []
        offset = 0
        while len(found) < PLAYLIST_CAP:
            page = await self.send("GET", "me/playlists", {"limit": PAGE_MAX, "offset": offset})
            found += _page(page, playlist_shape)
            limit = page.get("limit", 0) if isinstance(page, dict) else 0
            offset += limit
            if not (isinstance(page, dict) and page.get("next")) or limit == 0:
                break
        return found

    async def playlist_tracks(self, playlist_id: str) -> list[dict]:
        found: list[dict] = []
        offset = 0
        while len(found) < TRACK_CAP:
            page = await self.send("GET", f"playlists/{quote(playlist_id, safe='')}/items",
                                   {"limit": PAGE_MAX, "offset": offset})
            items = page.get("items") if isinstance(page, dict) else None
            found += [t for t in (entry_track(i) for i in items or []) if t]
            limit = page.get("limit", 0) if isinstance(page, dict) else 0
            offset += limit
            if not (isinstance(page, dict) and page.get("next")) or limit == 0:
                break
        return found

    async def search(self, query: str) -> dict:
        raw = await self.send("GET", "search", {"q": query, "type": SEARCH_TYPES, "limit": SEARCH_LIMIT})
        raw = raw if isinstance(raw, dict) else {}
        return {"tracks": _page(raw.get("tracks"), track_shape), "albums": _page(raw.get("albums"), album_shape),
                "playlists": _page(raw.get("playlists"), playlist_shape),
                "artists": _page(raw.get("artists"), artist_shape)}

    async def devices(self) -> list[dict]:
        raw = await self.send("GET", "me/player/devices")
        return [d for d in (raw or {}).get("devices", []) if isinstance(d, dict)]

    async def _player(self, method: str, path: str, params: dict, body: dict | None) -> None:
        try:
            await self.send(method, path, params, body, player=True)
        except SpotifyError as error:
            if error.kind != "noActiveDevice":
                raise
            device = pick_device(await self.devices())
            if device is None:
                raise
            await self.send(method, path, {**params, "device_id": device["id"]}, body, player=True)

    async def play(self, context_uri: str | None = None, uris: list[str] | None = None,
                   start_at: str | None = None) -> None:
        if context_uri:
            body: dict[str, Any] = {"context_uri": context_uri}
            if start_at:
                body["offset"] = {"uri": start_at}
        else:
            body = {"uris": uris or []}
        await self._player("PUT", "me/player/play", {}, body)

    async def enqueue(self, uri: str) -> None:
        await self._player("POST", "me/player/queue", {"uri": uri}, None)
