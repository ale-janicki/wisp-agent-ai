from __future__ import annotations

import asyncio
import base64
import json
import re
import time
from dataclasses import asdict, dataclass
from datetime import date, datetime, timedelta
from typing import Any, Callable
from urllib.parse import quote, urlsplit

import httpx

from . import oauth
from .dpapi import SecretFile

AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN = "https://oauth2.googleapis.com/token"
REVOKE = "https://oauth2.googleapis.com/revoke"
EVENTS = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
SCOPES = ["https://www.googleapis.com/auth/calendar.events", "openid", "email"]
REDIRECT_PATH = "/callback"
EXPIRY_SKEW = 60.0
REVOKE_TIMEOUT = 5.0
RSVP_CHOICES = ("accepted", "tentative", "declined")


class ClientParseError(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class GoogleClient:
    client_id: str
    client_secret: str

    @staticmethod
    def parse(text: str | bytes) -> "GoogleClient":
        try:
            root = json.loads(text)
        except ValueError:
            raise ClientParseError("notJSON") from None
        if not isinstance(root, dict):
            raise ClientParseError("notJSON")
        installed = root.get("installed")
        if not isinstance(installed, dict):
            raise ClientParseError("webClient" if "web" in root else "missingFields")
        ident, secret = installed.get("client_id"), installed.get("client_secret")
        if not isinstance(ident, str) or not ident.strip() or not isinstance(secret, str) or not secret.strip():
            raise ClientParseError("missingFields")
        return GoogleClient(ident.strip(), secret.strip())

    def serialized(self) -> bytes:
        return json.dumps({"installed": {"client_id": self.client_id, "client_secret": self.client_secret}},
                          sort_keys=True).encode()


CLIENT_MESSAGES = {
    "notJSON": "Esse arquivo não é um JSON. Use o credentials.json baixado do Google Cloud.",
    "webClient": "Esse é um cliente da web. Crie um cliente do tipo \"App para computador\" no Google Cloud.",
    "missingFields": "Não achei client_id e client_secret no arquivo.",
}


@dataclass
class GoogleToken:
    access_token: str
    refresh_token: str
    expires_at: float
    email: str

    def needs_refresh(self, now: float, skew: float = EXPIRY_SKEW) -> bool:
        return now + skew >= self.expires_at


class GoogleAuthError(Exception):
    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


def email_from_id_token(token: str) -> str | None:
    segments = token.split(".")
    if len(segments) != 3:
        return None
    try:
        claims = json.loads(base64.urlsafe_b64decode(segments[1] + "=" * (-len(segments[1]) % 4)))
    except ValueError:
        return None
    email = claims.get("email") if isinstance(claims, dict) else None
    return email if isinstance(email, str) and "@" in email else None


def token_from_response(data: Any, now: float, previous: GoogleToken | None) -> GoogleToken:
    if not isinstance(data, dict):
        raise GoogleAuthError("malformed")
    if isinstance(data.get("error"), str):
        raise GoogleAuthError("rejected", data.get("error_description") or data["error"])
    access, expires = data.get("access_token"), data.get("expires_in")
    if not isinstance(access, str) or not isinstance(expires, (int, float)):
        raise GoogleAuthError("malformed")
    refresh = data.get("refresh_token") or (previous.refresh_token if previous else None)
    if not refresh:
        raise GoogleAuthError("missingRefreshToken")
    email = email_from_id_token(data["id_token"]) if isinstance(data.get("id_token"), str) else None
    email = email or (previous.email if previous else None)
    if not email:
        raise GoogleAuthError("missingEmail")
    return GoogleToken(access, refresh, now + float(expires), email.lower())


def authorization_url(client_id: str, redirect: str, state: str, code_challenge: str) -> str:
    return AUTHORIZE + "?" + oauth.query([
        ("client_id", client_id), ("response_type", "code"), ("redirect_uri", redirect), ("state", state),
        ("scope", " ".join(SCOPES)), ("code_challenge_method", "S256"), ("code_challenge", code_challenge),
        ("access_type", "offline"), ("prompt", "consent"),
    ])


class GoogleError(Exception):
    MESSAGES = {
        "notConnected": "Conecte o Google na aba Agenda para responder.",
        "unauthorized": "O Google recusou o acesso; desconecte e conecte a conta de novo na aba Agenda.",
        "forbidden": "O Google não deixou responder a este convite com esta conta.",
        "notFound": "Não achei este evento na agenda do Google desta conta.",
        "notInvitee": "Esta conta do Google não está entre os convidados do evento.",
        "tooManyAttendees": "Esse convite tem convidados demais para responder pelo Wisp; responda pelo Google Agenda.",
        "changed": "O evento mudou no Google enquanto você respondia; tente de novo.",
        "rateLimited": "O Google pediu uma pausa; tente de novo em instantes.",
        "network": "Sem conexão com o Google; confira a internet.",
        "malformed": "Não entendi a resposta do Google.",
    }
    STATUS = {401: "unauthorized", 403: "forbidden", 404: "notFound", 412: "changed", 429: "rateLimited"}

    def __init__(self, code: str, status: int = 0) -> None:
        super().__init__(code)
        self.code, self.status = code, status

    @property
    def message(self) -> str:
        if self.code == "http":
            return f"O Google respondeu erro {self.status}; tente de novo."
        return self.MESSAGES[self.code]


def patch_body(event: dict, choice: str, account_email: str) -> tuple[dict, str | None]:
    if event.get("attendeesOmitted") is True:
        raise GoogleError("tooManyAttendees")
    attendees = [dict(a) for a in event.get("attendees") or []]
    index = next((i for i, a in enumerate(attendees) if a.get("self") is True), None)
    if index is None:
        wanted = account_email.lower()
        index = next((i for i, a in enumerate(attendees) if str(a.get("email", "")).lower() == wanted), None)
    if index is None:
        raise GoogleError("notInvitee")
    attendees[index]["responseStatus"] = choice
    return {"attendees": attendees}, event.get("etag")


_URL = re.compile(r"""(?:https?|zoommtg|zoomus|msteams|webex|facetime)://[^\s<>"'\]\)]+""", re.IGNORECASE)
PROVIDER_NAMES = {"meet": "Google Meet", "zoom": "Zoom", "teams": "Microsoft Teams", "webex": "Webex", "slack": "Slack",
                  "facetime": "FaceTime"}


def meeting_provider(url: str) -> str | None:
    parts = urlsplit(url)
    scheme, host, path = parts.scheme.lower(), (parts.hostname or "").lower(), parts.path.lower()
    if scheme in ("zoommtg", "zoomus"):
        return "zoom"
    if scheme in ("msteams", "webex", "facetime"):
        return {"msteams": "teams"}.get(scheme, scheme)
    if scheme not in ("http", "https"):
        return None
    if host == "meet.google.com":
        return "meet" if len(path) > 1 or parts.query else None
    if host in ("zoom.us", "zoom.com") or host.endswith((".zoom.us", ".zoom.com")):
        return "zoom" if path.startswith(("/j/", "/my/", "/s/", "/w/", "/wc/", "/join")) else None
    if host in ("teams.microsoft.com", "teams.live.com"):
        return "teams" if path.startswith(("/l/meetup-join", "/meet", "/meeting")) else None
    if host == "webex.com" or host.endswith(".webex.com"):
        return "webex" if len(path) > 1 else None
    if host == "slack.com" or host.endswith(".slack.com"):
        return "slack" if "/huddle/" in path or path.startswith("/huddle") else None
    if host == "facetime.apple.com":
        return "facetime" if path.startswith("/join") else None
    return None


def _links_in(text: str) -> list[tuple[str, str]]:
    found = []
    for match in _URL.finditer(text):
        raw = match.group(0).strip(".,;:!?")
        provider = meeting_provider(raw)
        if provider:
            found.append((provider, raw))
    return found


def detect_meeting(url: str | None, location: str | None, notes: str | None) -> dict | None:
    if url:
        provider = meeting_provider(url)
        if provider:
            return {"provider": PROVIDER_NAMES[provider], "url": url}
        for marker in ("https://", "http://"):
            for part in url.split(marker)[1:]:
                links = _links_in(marker + part)
                if links:
                    return {"provider": PROVIDER_NAMES[links[0][0]], "url": links[0][1]}
    for text in (location, notes):
        links = _links_in(text) if text else []
        if links:
            return {"provider": PROVIDER_NAMES[links[0][0]], "url": links[0][1]}
    return None


def _day_before(day: str) -> str:
    return (date.fromisoformat(day) - timedelta(days=1)).isoformat()


def normalize_event(item: dict, account_email: str = "") -> dict:
    start, end = item.get("start") or {}, item.get("end") or {}
    all_day = "date" in start and "dateTime" not in start
    first = start.get("date") if all_day else start.get("dateTime")
    last = end.get("date") if all_day else end.get("dateTime")
    if all_day and last:
        last = max(first, _day_before(last))
    wanted = account_email.lower()
    attendees = []
    for raw in item.get("attendees") or []:
        email = raw.get("email")
        mine = raw.get("self") is True or (bool(wanted) and str(email or "").lower() == wanted)
        attendees.append({"name": raw.get("displayName") or email or "", "email": email,
                          "status": raw.get("responseStatus") or "needsAction",
                          "organizer": raw.get("organizer") is True, "me": mine})
    me = next((a for a in attendees if a["me"]), None)
    organizer = item.get("organizer") or {}
    conference = next((e.get("uri") for e in (item.get("conferenceData") or {}).get("entryPoints") or []
                       if e.get("entryPointType") == "video" and e.get("uri")), None)
    url = item.get("hangoutLink") or conference
    link = detect_meeting(url, item.get("location"), item.get("description"))
    return {
        "id": item.get("id", ""), "title": item.get("summary") or "", "start": first, "end": last, "all_day": all_day,
        "time_zone": start.get("timeZone"), "location": item.get("location"), "notes": item.get("description"),
        "html_link": item.get("htmlLink"), "meeting": link, "attendees": attendees,
        "my_status": me["status"] if me else None, "declined": bool(me and me["status"] == "declined"),
        "can_respond": bool(me) and not (organizer.get("self") is True) and not (me or {}).get("organizer"),
        "recurring": bool(item.get("recurringEventId")), "busy": item.get("transparency") != "transparent",
        "cancelled": item.get("status") == "cancelled",
    }


Opener = Callable[[str], object]


class GoogleAccount:
    def __init__(self, http: httpx.AsyncClient, client_file: SecretFile, token_file: SecretFile,
                 clock: Callable[[], float] = time.time) -> None:
        self.http, self.client_file, self.token_file, self.clock = http, client_file, token_file, clock
        self._refresh_lock = asyncio.Lock()

    @property
    def storage_available(self) -> bool:
        return self.client_file.available

    def client(self) -> GoogleClient | None:
        raw = self.client_file.read()
        try:
            return GoogleClient.parse(raw) if raw else None
        except ClientParseError:
            return None

    def token(self) -> GoogleToken | None:
        raw = self.token_file.read()
        try:
            return GoogleToken(**json.loads(raw)) if raw else None
        except (ValueError, TypeError):
            return None

    def save_client(self, client: GoogleClient) -> None:
        self.client_file.write(client.serialized())

    def save_token(self, token: GoogleToken) -> None:
        self.token_file.write(json.dumps(asdict(token)).encode())

    async def _token_call(self, fields: list[tuple[str, str]], previous: GoogleToken | None) -> GoogleToken:
        try:
            response = await self.http.post(TOKEN, content=oauth.query(fields),
                                            headers={"Content-Type": "application/x-www-form-urlencoded"})
            body = response.json()
        except httpx.HTTPError:
            raise GoogleError("network") from None
        except ValueError:
            raise GoogleAuthError("malformed") from None
        return token_from_response(body, self.clock(), previous)

    async def sign_in(self, code: str, verifier: str, redirect: str) -> GoogleToken:
        client = self.client()
        if client is None:
            raise GoogleError("notConnected")
        token = await self._token_call([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect),
            ("client_id", client.client_id), ("client_secret", client.client_secret), ("code_verifier", verifier)], None)
        self.save_token(token)
        return token

    async def access_token(self, force_refresh: bool = False) -> str:
        token, client = self.token(), self.client()
        if token is None or client is None:
            raise GoogleError("notConnected")
        if not force_refresh and not token.needs_refresh(self.clock()):
            return token.access_token
        async with self._refresh_lock:
            latest = self.token()
            if latest is None:
                raise GoogleError("notConnected")
            if latest.access_token != token.access_token or (not force_refresh and not latest.needs_refresh(self.clock())):
                return latest.access_token
            try:
                refreshed = await self._token_call([
                    ("grant_type", "refresh_token"), ("refresh_token", latest.refresh_token),
                    ("client_id", client.client_id), ("client_secret", client.client_secret)], latest)
            except GoogleAuthError as error:
                if error.reason == "rejected":
                    current = self.token()
                    if current is None or current.refresh_token == latest.refresh_token:
                        self.token_file.delete()
                    raise GoogleError("unauthorized") from None
                raise GoogleError("malformed") from None
            self.save_token(refreshed)
            return refreshed.access_token

    async def sign_out(self) -> None:
        token = self.token()
        self.token_file.delete()
        if token is None:
            return
        try:
            await self.http.post(REVOKE, content=oauth.query([("token", token.refresh_token)]), timeout=REVOKE_TIMEOUT,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
        except httpx.HTTPError:
            pass

    async def call(self, method: str, url: str, *, params: dict | None = None, body: dict | None = None,
                   etag: str | None = None) -> Any:
        force = False
        while True:
            headers = {"Authorization": f"Bearer {await self.access_token(force)}", "Accept": "application/json"}
            if etag:
                headers["If-Match"] = etag
            try:
                response = await self.http.request(method, url, params=params, json=body, headers=headers)
            except httpx.HTTPError:
                raise GoogleError("network") from None
            status = response.status_code
            if 200 <= status < 300:
                if not response.content:
                    return None
                try:
                    return response.json()
                except ValueError:
                    raise GoogleError("malformed") from None
            if status == 401 and not force:
                force = True
                continue
            raise GoogleError(GoogleError.STATUS.get(status, "http"), status)

    async def list_events(self, start: datetime, end: datetime) -> list[dict]:
        email = (self.token().email if self.token() else "")
        events: list[dict] = []
        params: dict[str, Any] = {"timeMin": _rfc3339(start), "timeMax": _rfc3339(end), "singleEvents": "true",
                                  "orderBy": "startTime", "maxResults": "250", "showDeleted": "false"}
        for _ in range(20):
            page = await self.call("GET", EVENTS, params=params)
            if not isinstance(page, dict):
                raise GoogleError("malformed")
            events += [normalize_event(i, email) for i in page.get("items") or [] if i.get("status") != "cancelled"]
            if not page.get("nextPageToken"):
                break
            params = {**params, "pageToken": page["nextPageToken"]}
        return events

    async def get_event(self, event_id: str) -> dict:
        item = await self.call("GET", f"{EVENTS}/{quote(event_id, safe='')}")
        return normalize_event(item, self.token().email if self.token() else "")

    async def create_event(self, body: dict) -> dict:
        item = await self.call("POST", EVENTS, params={"sendUpdates": "none"}, body=body)
        return normalize_event(item, self.token().email if self.token() else "")

    async def delete_event(self, event_id: str) -> None:
        await self.call("DELETE", f"{EVENTS}/{quote(event_id, safe='')}", params={"sendUpdates": "all"})

    async def respond(self, event_id: str, choice: str) -> dict:
        if choice not in RSVP_CHOICES:
            raise GoogleError("malformed")
        token = self.token()
        if token is None:
            raise GoogleError("notConnected")
        url = f"{EVENTS}/{quote(event_id, safe='')}"
        event = await self.call("GET", url)
        if not isinstance(event, dict):
            raise GoogleError("malformed")
        body, etag = patch_body(event, choice, token.email)
        patched = await self.call("PATCH", url, params={"sendUpdates": "all"}, body=body, etag=etag)
        return normalize_event(patched, token.email)


def _rfc3339(moment: datetime) -> str:
    if moment.tzinfo is None:
        moment = moment.astimezone()
    return moment.isoformat(timespec="seconds")

