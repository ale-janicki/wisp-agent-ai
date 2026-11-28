import asyncio
import base64
import json
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from serve_tab_helpers import XorProtector, client, host_of, json_response, mock_http
from wisp.serve.features import agenda
from wisp.serve.features.agenda import google, oauth
from wisp.serve.features.agenda.dpapi import SecretFile

CREDENTIALS = json.dumps({"installed": {"client_id": "id-123.apps", "client_secret": "sek"}})


def id_token(email):
    body = base64.urlsafe_b64encode(json.dumps({"email": email}).encode()).decode().rstrip("=")
    return f"h.{body}.s"


def account(handler, tmp_path, now=lambda: 1000.0):
    protector = XorProtector()
    made = google.GoogleAccount(mock_http(handler), SecretFile("c.bin", protector, tmp_path),
                                SecretFile("t.bin", protector, tmp_path), clock=now)
    made.save_client(google.GoogleClient.parse(CREDENTIALS))
    return made


def sign_in_token(made, expires=5000.0):
    made.save_token(google.GoogleToken("acc", "ref", expires, "eu@exemplo.com"))


def test_client_file_must_be_a_desktop_client():
    assert google.GoogleClient.parse(CREDENTIALS) == google.GoogleClient("id-123.apps", "sek")
    for text, reason in (("nope", "notJSON"), ("[]", "notJSON"), (json.dumps({"web": {}}), "webClient"),
                         (json.dumps({"installed": {"client_id": " "}}), "missingFields")):
        with pytest.raises(google.ClientParseError) as caught:
            google.GoogleClient.parse(text)
        assert caught.value.reason == reason


def test_token_reads_the_email_from_the_id_token_and_keeps_it_on_refresh():
    first = google.token_from_response({"access_token": "a", "expires_in": 3600, "refresh_token": "r",
                                        "id_token": id_token("Eu@Exemplo.com")}, 100.0, None)
    assert (first.email, first.refresh_token, first.expires_at) == ("eu@exemplo.com", "r", 3700.0)
    again = google.token_from_response({"access_token": "b", "expires_in": 60}, 200.0, first)
    assert (again.email, again.refresh_token) == ("eu@exemplo.com", "r") and again.needs_refresh(200.0)
    with pytest.raises(google.GoogleAuthError) as rejected:
        google.token_from_response({"error": "invalid_grant", "error_description": "Bad"}, 0, None)
    assert (rejected.value.reason, rejected.value.detail) == ("rejected", "Bad")
    with pytest.raises(google.GoogleAuthError) as missing:
        google.token_from_response({"access_token": "a", "expires_in": 1}, 0, None)
    assert missing.value.reason == "missingRefreshToken"


def test_authorization_url_carries_pkce_offline_access_and_the_scopes():
    url = google.authorization_url("cid", "http://127.0.0.1:50000/callback", "st", "chal")
    query = parse_qs(urlsplit(url).query)
    assert urlsplit(url).netloc == "accounts.google.com"
    assert query["code_challenge_method"] == ["S256"] and query["code_challenge"] == ["chal"]
    assert query["access_type"] == ["offline"] and query["prompt"] == ["consent"] and query["state"] == ["st"]
    assert query["scope"][0].split() == google.SCOPES and query["redirect_uri"] == ["http://127.0.0.1:50000/callback"]


def test_event_shape_all_day_end_is_the_last_day_and_meeting_link_is_found():
    event = google.normalize_event({
        "id": "e1", "summary": "Retiro", "start": {"date": "2026-12-01"}, "end": {"date": "2026-12-04"},
        "description": "Link https://meet.google.com/abc-defg-hij.", "attendees": [
            {"email": "eu@exemplo.com", "self": True, "responseStatus": "needsAction"},
            {"email": "chefe@exemplo.com", "organizer": True, "displayName": "Chefe", "responseStatus": "accepted"}]})
    assert (event["all_day"], event["start"], event["end"]) == (True, "2026-12-01", "2026-12-03")
    assert event["meeting"] == {"provider": "Google Meet", "url": "https://meet.google.com/abc-defg-hij"}
    assert event["my_status"] == "needsAction" and event["can_respond"] and not event["declined"]
    assert event["attendees"][1]["name"] == "Chefe"


def test_the_organizer_cannot_rsvp_and_a_declined_event_is_marked():
    organizer = google.normalize_event({"id": "1", "start": {"dateTime": "2026-12-01T10:00:00-03:00"},
                                        "end": {"dateTime": "2026-12-01T11:00:00-03:00"}, "organizer": {"self": True},
                                        "attendees": [{"email": "eu@x.com", "self": True, "responseStatus": "accepted"}]})
    assert organizer["can_respond"] is False and organizer["all_day"] is False and organizer["title"] == ""
    declined = google.normalize_event({"id": "2", "start": {"date": "2026-12-01"}, "end": {"date": "2026-12-02"},
                                       "attendees": [{"email": "eu@x.com", "self": True, "responseStatus": "declined"}]})
    assert declined["declined"] is True


@pytest.mark.parametrize("url,provider", [
    ("https://meet.google.com/abc", "meet"), ("https://us02web.zoom.us/j/123", "zoom"), ("https://zoom.us/pricing", None),
    ("https://teams.microsoft.com/l/meetup-join/x", "teams"), ("https://acme.webex.com/acme/j.php", "webex"),
    ("https://acme.slack.com/huddle/T1/C1", "slack"), ("zoommtg://zoom.us/join?confno=1", "zoom"),
    ("https://meet.google.com/", None), ("https://exemplo.com", None)])
def test_meeting_providers(url, provider):
    assert google.meeting_provider(url) == provider


def test_a_meeting_url_wrapped_in_another_url_and_location_before_notes():
    wrapped = "https://www.google.com/url?q=https://zoom.us/j/55&sa=D"
    assert google.detect_meeting(wrapped, None, None) == {"provider": "Zoom", "url": "https://zoom.us/j/55&sa=D"}
    both = google.detect_meeting(None, "Sala https://zoom.us/j/1", "https://meet.google.com/abc")
    assert both["provider"] == "Zoom"


def test_list_events_pages_and_asks_for_expanded_instances(tmp_path):
    calls = []

    def handler(request):
        calls.append(dict(request.url.params))
        assert request.headers["authorization"] == "Bearer acc"
        if "pageToken" not in request.url.params:
            return json_response({"items": [{"id": "a", "summary": "A", "start": {"date": "2026-12-01"},
                                             "end": {"date": "2026-12-02"}}], "nextPageToken": "p2"})
        return json_response({"items": [{"id": "b", "status": "cancelled"}, {"id": "c", "summary": "C",
                              "start": {"dateTime": "2026-12-01T10:00:00Z"}, "end": {"dateTime": "2026-12-01T11:00:00Z"}}]})

    made = account(handler, tmp_path)
    sign_in_token(made)
    from datetime import datetime, timezone
    events = asyncio.run(made.list_events(datetime(2026, 12, 1, tzinfo=timezone.utc), datetime(2026, 12, 8, tzinfo=timezone.utc)))
    assert [e["id"] for e in events] == ["a", "c"]
    assert calls[0]["singleEvents"] == "true" and calls[0]["orderBy"] == "startTime"
    assert calls[0]["timeMin"] == "2026-12-01T00:00:00+00:00" and calls[1]["pageToken"] == "p2"


def test_a_401_refreshes_once_and_retries_then_gives_up(tmp_path):
    seen = []

    def handler(request):
        if request.url.host == "oauth2.googleapis.com":
            fields = parse_qs(request.content.decode())
            assert fields["grant_type"] == ["refresh_token"] and fields["refresh_token"] == ["ref"]
            assert fields["client_secret"] == ["sek"]
            return json_response({"access_token": "fresh", "expires_in": 3600})
        seen.append(request.headers["authorization"])
        return json_response({}, 200 if request.headers["authorization"] == "Bearer fresh" else 401)

    made = account(handler, tmp_path)
    sign_in_token(made)
    assert asyncio.run(made.call("GET", google.EVENTS)) == {}
    assert seen == ["Bearer acc", "Bearer fresh"] and made.token().access_token == "fresh"

    always = account(lambda r: json_response({"access_token": "x", "expires_in": 3600}) if r.url.host == "oauth2.googleapis.com"
                     else json_response({}, 401), tmp_path)
    sign_in_token(always)
    with pytest.raises(google.GoogleError) as caught:
        asyncio.run(always.call("GET", google.EVENTS))
    assert caught.value.code == "unauthorized"


def test_a_revoked_refresh_token_signs_out_instead_of_crashing(tmp_path):
    def handler(request):
        return json_response({"error": "invalid_grant", "error_description": "Token has been expired or revoked."}, 400)

    made = account(handler, tmp_path, now=lambda: 4990.0)
    sign_in_token(made, expires=5000.0)
    with pytest.raises(google.GoogleError) as caught:
        asyncio.run(made.call("GET", google.EVENTS))
    assert caught.value.code == "unauthorized" and made.token() is None


def test_a_failed_refresh_does_not_delete_a_token_another_call_just_saved(tmp_path):
    def handler(request):
        made.save_token(google.GoogleToken("newer", "newer-refresh", 9000.0, "eu@exemplo.com"))
        return json_response({"error": "invalid_grant"}, 400)

    made = account(handler, tmp_path, now=lambda: 4990.0)
    sign_in_token(made, expires=5000.0)
    with pytest.raises(google.GoogleError):
        asyncio.run(made.call("GET", google.EVENTS))
    assert made.token() is not None and made.token().refresh_token == "newer-refresh"


def test_concurrent_calls_share_one_refresh(tmp_path):
    refreshes = []

    def handler(request):
        if request.url.host == "oauth2.googleapis.com":
            refreshes.append(1)
            return json_response({"access_token": "fresh", "expires_in": 3600})
        return json_response({"id": "e"})

    made = account(handler, tmp_path, now=lambda: 4990.0)
    sign_in_token(made, expires=5000.0)

    async def both():
        await asyncio.gather(made.call("GET", google.EVENTS), made.call("GET", google.EVENTS), made.call("GET", google.EVENTS))

    asyncio.run(both())
    assert len(refreshes) == 1


def test_an_expiring_token_is_refreshed_before_the_call(tmp_path):
    hosts = []

    def handler(request):
        hosts.append(request.url.host)
        if request.url.host == "oauth2.googleapis.com":
            return json_response({"access_token": "fresh", "expires_in": 3600})
        return json_response({"id": "e"})

    made = account(handler, tmp_path, now=lambda: 990.0)
    sign_in_token(made, expires=1000.0)
    asyncio.run(made.call("GET", google.EVENTS))
    assert hosts == ["oauth2.googleapis.com", "www.googleapis.com"]


@pytest.mark.parametrize("status,code", [(403, "forbidden"), (404, "notFound"), (412, "changed"), (429, "rateLimited"),
                                         (500, "http")])
def test_http_failures_map_to_the_macs_messages(tmp_path, status, code):
    made = account(lambda r: json_response({}, status), tmp_path)
    sign_in_token(made)
    with pytest.raises(google.GoogleError) as caught:
        asyncio.run(made.call("GET", google.EVENTS))
    assert caught.value.code == code and caught.value.message


def test_no_connection_is_a_network_error(tmp_path):
    def handler(request):
        raise httpx.ConnectError("down")

    made = account(handler, tmp_path)
    sign_in_token(made)
    with pytest.raises(google.GoogleError) as caught:
        asyncio.run(made.call("GET", google.EVENTS))
    assert caught.value.message == "Sem conexão com o Google; confira a internet."


EVENT = {"id": "ev1", "etag": '"e7"', "summary": "Alinhamento", "start": {"dateTime": "2026-12-01T10:00:00-03:00"},
         "end": {"dateTime": "2026-12-01T11:00:00-03:00"}, "attendees": [
             {"email": "chefe@exemplo.com", "organizer": True, "responseStatus": "accepted"},
             {"email": "EU@exemplo.com", "responseStatus": "needsAction"},
             {"email": "outro@exemplo.com", "responseStatus": "tentative", "comment": "talvez"}]}


def test_rsvp_patches_only_the_users_row_and_sends_the_etag(tmp_path):
    sent = {}

    def handler(request):
        if request.method == "GET":
            return json_response(EVENT)
        sent.update(body=json.loads(request.content), match=request.headers["if-match"], params=dict(request.url.params))
        return json_response({**EVENT, "attendees": sent["body"]["attendees"]})

    made = account(handler, tmp_path)
    sign_in_token(made)
    result = asyncio.run(made.respond("ev1", "accepted"))
    assert [a["responseStatus"] for a in sent["body"]["attendees"]] == ["accepted", "accepted", "tentative"]
    assert sent["body"]["attendees"][2]["comment"] == "talvez"
    assert sent["match"] == '"e7"' and sent["params"] == {"sendUpdates": "all"} and result["my_status"] == "accepted"


def test_rsvp_refuses_what_would_damage_the_guest_list():
    with pytest.raises(google.GoogleError) as many:
        google.patch_body({**EVENT, "attendeesOmitted": True}, "declined", "eu@exemplo.com")
    assert many.value.code == "tooManyAttendees"
    with pytest.raises(google.GoogleError) as stranger:
        google.patch_body(EVENT, "declined", "outra-conta@exemplo.com")
    assert stranger.value.code == "notInvitee"
    body, _ = google.patch_body({"attendees": [{"email": "x@y.com", "self": True}]}, "tentative", "other@y.com")
    assert body["attendees"][0]["responseStatus"] == "tentative"


def test_sign_out_removes_the_local_token_first_even_when_revoke_fails(tmp_path):
    def handler(request):
        raise httpx.ConnectError("down")

    made = account(handler, tmp_path)
    sign_in_token(made)
    asyncio.run(made.sign_out())
    assert made.token() is None


@pytest.fixture
def served(tmp_path, monkeypatch):
    def build(handler=lambda r: json_response({})):
        made = account(handler, tmp_path)
        opened = []
        service = agenda.AgendaService(made, opener=opened.append, port=lambda: 0)
        monkeypatch.setattr(agenda, "_service", service)
        return service, opened

    return build


def test_status_walks_from_no_client_to_connected(tmp_path, monkeypatch):
    protector = XorProtector()
    made = google.GoogleAccount(mock_http(lambda r: json_response({})), SecretFile("c.bin", protector, tmp_path),
                                SecretFile("t.bin", protector, tmp_path))
    monkeypatch.setattr(agenda, "_service", agenda.AgendaService(made, opener=lambda u: None))
    c = client()
    assert c.get("/api/agenda/status").json() == {"storage": True, "has_client": False, "connected": False, "email": None,
                                                  "connecting": False, "error": None}
    assert c.post("/api/agenda/connect").status_code == 409
    assert c.put("/api/agenda/client", json={"credentials": "{}"}).json()["error"] == google.CLIENT_MESSAGES["missingFields"]
    assert c.put("/api/agenda/client", json={"credentials": json.dumps({"web": {}})}).status_code == 400
    assert c.put("/api/agenda/client", json={"credentials": CREDENTIALS}).json()["has_client"] is True
    assert b"sek" not in (tmp_path / "c.bin").read_bytes()
    made.save_token(google.GoogleToken("a", "r", 9e9, "eu@exemplo.com"))
    assert c.get("/api/agenda/status").json()["email"] == "eu@exemplo.com"
    assert c.post("/api/agenda/signout").json()["connected"] is False
    assert c.delete("/api/agenda/client").json()["has_client"] is False


def test_without_dpapi_the_client_cannot_be_saved(monkeypatch):
    made = google.GoogleAccount(mock_http(lambda r: json_response({})), SecretFile("c", None), SecretFile("t", None))
    monkeypatch.setattr(agenda, "_service", agenda.AgendaService(made))
    assert client().put("/api/agenda/client", json={"credentials": CREDENTIALS}).status_code == 501


def test_event_routes_talk_to_google_and_report_errors_in_portuguese(served):
    seen = []

    def handler(request):
        seen.append((request.method, request.url.path, request.content))
        if request.method == "GET" and request.url.path.endswith("/events"):
            return json_response({"items": [{"id": "z", "summary": "Z", "start": {"date": "2026-12-01"}, "end": {"date": "2026-12-02"}}]})
        if request.method == "POST":
            return json_response({"id": "new", **json.loads(request.content)})
        return json_response({}, 404 if request.method == "GET" else 200)

    service, _ = served(handler)
    sign_in_token(service.account)
    c = client()
    got = c.get("/api/agenda/events", params={"start": "2026-12-01T00:00:00Z", "end": "2026-12-08T00:00:00Z"}).json()
    assert [e["id"] for e in got["items"]] == ["z"]
    assert c.get("/api/agenda/events", params={"start": "x"}).status_code == 400
    created = c.post("/api/agenda/events", json={"title": "Festa", "start": "2026-12-05", "end": "2026-12-06", "all_day": True})
    assert created.status_code == 201
    posted = json.loads(seen[-1][2])
    assert posted["start"] == {"date": "2026-12-05"} and posted["end"] == {"date": "2026-12-07"}
    timed = c.post("/api/agenda/events", json={"title": "", "start": "2026-12-05T10:00:00-03:00", "end": "2026-12-05T11:00:00-03:00"})
    assert json.loads(seen[-1][2])["summary"] == "Sem título" and timed.status_code == 201
    assert c.post("/api/agenda/events", json={"title": "x"}).status_code == 400
    missing = c.get("/api/agenda/events/nope")
    assert missing.status_code == 404 and missing.json()["error"] == "Não achei este evento na agenda do Google desta conta."
    assert c.delete("/api/agenda/events/z").json() == {"ok": True}
    assert c.post("/api/agenda/events/z/rsvp", json={"choice": "maybe"}).status_code == 400


def test_events_without_a_connection_ask_to_connect(served):
    served()
    got = client().get("/api/agenda/events", params={"start": "2026-12-01T00:00:00Z", "end": "2026-12-08T00:00:00Z"})
    assert got.status_code == 409 and got.json()["error"].startswith("Conecte o Google")


def test_parse_route_returns_the_quick_event():
    c = client()
    got = c.post("/api/agenda/parse", json={"text": "dentista amanhã 14h", "now": "2026-11-28T10:00:00-03:00"}).json()["event"]
    assert got["title"] == "dentista" and got["start"].startswith("2026-11-29T14:00:00") and got["all_day"] is False
    day = c.post("/api/agenda/parse", json={"text": "festa 20/12", "now": "2026-11-28T10:00:00-03:00"}).json()["event"]
    assert (day["all_day"], day["start"], day["end"]) == (True, "2026-12-20", "2026-12-20")
    assert c.post("/api/agenda/parse", json={"text": "  "}).json() == {"event": None}


def test_connect_runs_the_whole_pkce_login_and_announces_the_result(served):
    def handler(request):
        if request.url.host == "oauth2.googleapis.com":
            fields = parse_qs(request.content.decode())
            handler.exchanged = fields
            return json_response({"access_token": "a", "expires_in": 3600, "refresh_token": "r",
                                  "id_token": id_token("eu@exemplo.com")})
        return json_response({})

    handler.exchanged = None
    service, opened = served(handler)
    import threading
    import time
    import urllib.request
    result = {}

    def browser():
        deadline = time.time() + 10
        while not opened and time.time() < deadline:
            time.sleep(0.01)
        query = parse_qs(urlsplit(opened[0]).query)
        result["query"] = query
        result["status"] = urllib.request.urlopen(
            f"http://127.0.0.1:{urlsplit(query['redirect_uri'][0]).port}/callback?code=THE-CODE&state={query['state'][0]}",
            timeout=5).status

    with client() as c:
        queue = host_of(c).hub.subscribe()
        thread = threading.Thread(target=browser)
        thread.start()
        assert c.post("/api/agenda/connect").status_code == 202
        thread.join(10)
        deadline = time.time() + 10
        while service.runner.running and time.time() < deadline:
            time.sleep(0.02)
    assert result["status"] == 200 and service.account.token().email == "eu@exemplo.com"
    assert handler.exchanged["code"] == ["THE-CODE"] and handler.exchanged["client_secret"] == ["sek"]
    assert oauth.challenge(handler.exchanged["code_verifier"][0]) == result["query"]["code_challenge"][0]
    assert queue.get_nowait() == {"feature": "agenda", "type": "auth", "state": "connected", "message": None}
