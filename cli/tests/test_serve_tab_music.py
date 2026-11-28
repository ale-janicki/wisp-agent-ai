import asyncio
import json
import threading
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlsplit

import pytest

from serve_tab_helpers import XorProtector, client, host_of, json_response, mock_http
from wisp.serve.features import music
from wisp.serve.features.agenda import oauth
from wisp.serve.features.agenda.dpapi import SecretFile
from wisp.serve.features.music import media, spotify


@pytest.fixture(autouse=True)
def isolated_client_id(tmp_path, monkeypatch):
    monkeypatch.delenv("WISP_SPOTIFY_CLIENT_ID", raising=False)


def api(handler, tmp_path, signed_in=True, now=lambda: 1000.0, sleeps=None):
    async def sleep(seconds):
        if sleeps is not None:
            sleeps.append(seconds)

    made = spotify.SpotifyApi(mock_http(handler), lambda: "client-1", SecretFile("s.bin", XorProtector(), tmp_path), clock=now,
                              sleep=sleep)
    if signed_in:
        made._store(spotify.SpotifyToken("acc", "ref", 5000.0, "scope"))
    return made


@pytest.mark.parametrize("status,body,player,kind", [
    (200, {}, False, None), (401, {}, False, "unauthorized"),
    (403, {"error": {"reason": "PREMIUM_REQUIRED"}}, True, "premiumRequired"),
    (403, {"error": {"message": "needs Premium"}}, True, "premiumRequired"),
    (403, {"error": {"message": "x"}}, False, "forbidden"), (404, {}, True, "noActiveDevice"),
    (404, {}, False, "notFound"), (429, {}, False, "rateLimited"), (503, {}, False, "server")])
def test_failure_classification(status, body, player, kind):
    failure = spotify.classify(status, body, "3", player)
    assert (failure.kind if failure else None) == kind


def test_rate_limit_carries_the_wait_and_the_quota_flag():
    limited = spotify.classify(429, {"error": {"reason": "quota_exceeded"}}, " 7 ", False)
    assert (limited.retry_after, limited.quota) == (7.0, True)
    assert spotify.classify(429, {}, None, False).retry_after == 1.0
    assert "em 7 s" in spotify.SpotifyError("rateLimited", retry_after=7.0).message("tocar")


def test_messages_are_the_macs_sentences():
    assert spotify.SpotifyError("noActiveDevice").message("tocar") == "Abra o Spotify em algum dispositivo para tocar."
    assert spotify.SpotifyError("premiumRequired").message("tocar") == "Para tocar pelo Wisp a conta precisa de Spotify Premium."
    assert spotify.SpotifyError("network").message("buscar no Spotify") == "Sem conexão com o Spotify para buscar no Spotify; confira a internet."


def test_authorization_url_is_pkce_with_the_playback_scopes():
    query = parse_qs(urlsplit(spotify.authorization_url("cid", spotify.REDIRECT_URI, "st", "ch")).query)
    assert query["scope"][0].split() == spotify.SCOPES and query["code_challenge_method"] == ["S256"]
    assert query["redirect_uri"] == ["http://127.0.0.1:43821/callback"] and "client_secret" not in query


def test_token_response_keeps_the_old_refresh_token():
    old = spotify.SpotifyToken("a", "keep", 0, "s")
    new = spotify.token_from_response({"access_token": "b", "expires_in": 3600}, 10.0, old)
    assert (new.refresh_token, new.expires_at, new.scope) == ("keep", 3610.0, "s")
    with pytest.raises(spotify.SpotifyError) as rejected:
        spotify.token_from_response({"error": "invalid_grant", "error_description": "Refresh token revoked"}, 0, old)
    assert (rejected.value.kind, rejected.value.detail) == ("rejected", "Refresh token revoked")


def test_best_image_prefers_the_smallest_that_fits():
    images = [{"url": "big", "width": 640}, {"url": "mid", "width": 300}, {"url": "tiny", "width": 64}, {"url": "nosize"}]
    assert spotify.best_image(images, 120) == "mid" and spotify.best_image(images, 1000) == "big"
    assert spotify.best_image([{"url": "only"}], 120) == "only" and spotify.best_image(None) is None


def test_device_choice_prefers_active_then_computer():
    devices = [{"id": "p", "type": "Smartphone"}, {"id": "c", "type": "Computer"}, {"id": "r", "is_restricted": True, "is_active": True},
               {"type": "Computer"}]
    assert spotify.pick_device(devices)["id"] == "c"
    assert spotify.pick_device([{"id": "p", "type": "Smartphone"}, {"id": "a", "is_active": True}])["id"] == "a"
    assert spotify.pick_device([]) is None


def test_playlists_page_until_there_is_no_next_and_skip_malformed_items(tmp_path):
    offsets = []

    def handler(request):
        offsets.append(request.url.params["offset"])
        if request.url.params["offset"] == "0":
            return json_response({"items": [{"id": "1", "name": "A", "uri": "u:1", "owner": {"display_name": "Eu"},
                                             "items": {"total": 3}, "images": [{"url": "i", "width": 300}]}, {"id": 5}],
                                  "limit": 50, "next": "more"})
        return json_response({"items": [{"id": "2", "name": "B", "uri": "u:2", "tracks": {"total": 9}}], "limit": 50})

    found = asyncio.run(api(handler, tmp_path).playlists())
    assert offsets == ["0", "50"]
    assert found == [{"id": "1", "name": "A", "uri": "u:1", "image": "i", "owner": "Eu", "track_count": 3, "collaborative": False},
                     {"id": "2", "name": "B", "uri": "u:2", "image": None, "owner": None, "track_count": 9, "collaborative": False}]


def test_playlist_tracks_read_the_item_or_track_key(tmp_path):
    def handler(request):
        assert b"/playlists/p%2F1/items" in request.url.raw_path
        return json_response({"items": [{"item": {"name": "N", "uri": "t:1", "artists": [{"name": "X"}, {"name": "Y"}], "duration_ms": 61000}},
                                         {"track": {"name": "M", "uri": "t:2"}}, {"track": None}], "limit": 50})

    tracks = asyncio.run(api(handler, tmp_path).playlist_tracks("p/1"))
    assert [(t["uri"], t["artists"]) for t in tracks] == [("t:1", "X, Y"), ("t:2", "")]


def test_search_returns_four_lists(tmp_path):
    def handler(request):
        assert dict(request.url.params) == {"q": "bossa nova", "type": "track,album,playlist,artist", "limit": "8"}
        return json_response({"tracks": {"items": [{"name": "T", "uri": "t"}]}, "albums": {"items": [{"id": "a", "name": "A", "uri": "a:1", "artists": [{"name": "Z"}]}]},
                              "playlists": {"items": [None]}, "artists": {"items": [{"id": "r", "name": "R", "uri": "r:1"}]}})

    found = asyncio.run(api(handler, tmp_path).search("bossa nova"))
    assert [len(found[k]) for k in ("tracks", "albums", "playlists", "artists")] == [1, 1, 0, 1]


def test_play_without_an_active_device_retries_on_the_best_one(tmp_path):
    calls = []

    def handler(request):
        calls.append((request.method, request.url.path, dict(request.url.params), request.content))
        if request.url.path.endswith("/devices"):
            return json_response({"devices": [{"id": "d1", "type": "Computer", "is_active": False}]})
        if "device_id" not in request.url.params:
            return json_response({"error": {"status": 404, "message": "NO_ACTIVE_DEVICE"}}, 404)
        return httpx_empty()

    asyncio.run(api(handler, tmp_path).play(context_uri="spotify:playlist:1", start_at="t:9"))
    assert [c[1].rsplit("/", 1)[1] for c in calls] == ["play", "devices", "play"]
    assert calls[2][2] == {"device_id": "d1"} and json.loads(calls[2][3]) == {"context_uri": "spotify:playlist:1", "offset": {"uri": "t:9"}}


def httpx_empty():
    import httpx
    return httpx.Response(204)


def test_play_with_no_device_at_all_says_to_open_spotify(tmp_path):
    def handler(request):
        if request.url.path.endswith("/devices"):
            return json_response({"devices": []})
        return json_response({}, 404)

    with pytest.raises(spotify.SpotifyError) as caught:
        asyncio.run(api(handler, tmp_path).play(uris=["t:1"]))
    assert caught.value.kind == "noActiveDevice"


def test_queue_uses_post_with_the_uri_as_a_query(tmp_path):
    seen = []

    def handler(request):
        seen.append((request.method, dict(request.url.params)))
        return httpx_empty()

    asyncio.run(api(handler, tmp_path).enqueue("t:7"))
    assert seen == [("POST", {"uri": "t:7"})]


def test_rate_limit_waits_the_asked_time_twice_then_gives_up(tmp_path):
    sleeps, count = [], [0]

    def handler(request):
        count[0] += 1
        return json_response({}, 429, {"Retry-After": "2"})

    with pytest.raises(spotify.SpotifyError) as caught:
        asyncio.run(api(handler, tmp_path, sleeps=sleeps).search("x"))
    assert caught.value.kind == "rateLimited" and sleeps == [2.0, 2.0] and count[0] == 3


def test_a_quota_limit_or_a_long_wait_is_not_retried(tmp_path):
    sleeps = []
    with pytest.raises(spotify.SpotifyError):
        asyncio.run(api(lambda r: json_response({"error": {"reason": "QUOTA_EXCEEDED"}}, 429), tmp_path, sleeps=sleeps).search("x"))
    with pytest.raises(spotify.SpotifyError):
        asyncio.run(api(lambda r: json_response({}, 429, {"Retry-After": "60"}), tmp_path, sleeps=sleeps).search("x"))
    assert sleeps == []


def test_401_refreshes_once_and_a_revoked_refresh_signs_out(tmp_path):
    def handler(request):
        if request.url.host == "accounts.spotify.com":
            fields = parse_qs(request.content.decode())
            assert fields == {"grant_type": ["refresh_token"], "refresh_token": ["ref"], "client_id": ["client-1"]}
            return json_response({"access_token": "fresh", "expires_in": 3600})
        return json_response({"devices": []}, 200 if request.headers["authorization"] == "Bearer fresh" else 401)

    made = api(handler, tmp_path)
    assert asyncio.run(made.devices()) == [] and made.token().access_token == "fresh"

    revoked = api(lambda r: json_response({"error": "invalid_grant", "error_description": "revoked"}, 400)
                  if r.url.host == "accounts.spotify.com" else json_response({}, 401), tmp_path)
    with pytest.raises(spotify.SpotifyError) as caught:
        asyncio.run(revoked.devices())
    assert caught.value.kind == "sessionExpired" and not revoked.is_signed_in()


def test_calls_without_a_session_ask_to_connect(tmp_path):
    with pytest.raises(spotify.SpotifyError) as caught:
        asyncio.run(api(lambda r: json_response({}), tmp_path, signed_in=False).playlists())
    assert caught.value.message("x") == "Sua sessão do Spotify expirou; clique em Conectar Spotify."


def test_player_names_from_app_ids():
    assert media.player_name("Spotify.exe") == "Spotify" and media.player_name("SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify") == "Spotify"
    assert media.player_name("Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic") == "Media Player"
    assert media.player_name("chrome.exe") == "Chrome" and media.player_name("Acme.Tocador.exe") == "Tocador"


def test_a_playing_track_advances_from_the_timeline_snapshot_but_never_past_the_end():
    updated = datetime(2026, 1, 1, tzinfo=timezone.utc)
    now = updated + timedelta(seconds=10)
    assert media.estimate_position(30, 200, True, updated, now) == 40
    assert media.estimate_position(30, 200, False, updated, now) == 30
    assert media.estimate_position(195, 200, True, updated, now) == 200 and media.estimate_position(-5, 0, False, None) == 0


def test_artwork_becomes_a_data_url_only_for_images():
    assert media.artwork_data_url(b"\x89PNG....").startswith("data:image/png;base64,")
    assert media.artwork_data_url(b"\xff\xd8\xff....").startswith("data:image/jpeg;base64,")
    assert media.artwork_data_url(b"<html>") is None and media.artwork_data_url(None) is None


class FakeMedia:
    def __init__(self, track=None):
        self.track, self.pressed, self.art, self.reads = track, [], b"\x89PNG-art", 0

    async def now(self):
        return self.track

    async def control(self, action):
        self.pressed.append(action)
        return True

    async def artwork(self):
        self.reads += 1
        return self.art


TRACK = media.NowPlaying("Spotify", "Garota", "Tom", "Álbum", True, 12.0, 200.0, "k1")


@pytest.fixture
def served(tmp_path, monkeypatch):
    def build(backend, handler=lambda r: json_response({}), signed_in=True):
        service = music.MusicService(api(handler, tmp_path, signed_in), backend, opener=lambda url: None)
        monkeypatch.setattr(music, "_service", service)
        return service

    return build


def test_now_route_reports_the_track_or_the_macs_empty_sentence(served):
    backend = FakeMedia(TRACK)
    served(backend)
    c = client()
    got = c.get("/api/music/now").json()
    assert got["track"]["title"] == "Garota" and got["track"]["player"] == "Spotify" and got["track"]["position"] == 12.0
    backend.track = None
    assert c.get("/api/music/now").json() == {"track": None, "empty": "Abra o Spotify ou o Music para ver o que está tocando"}
    served(None)
    assert client().get("/api/music/now").json()["track"] is None


def test_a_failing_media_session_reads_as_nothing_playing(served):
    class Broken(FakeMedia):
        async def now(self):
            raise OSError("smtc")

    served(Broken())
    assert client().get("/api/music/now").json()["track"] is None


def test_controls_go_to_the_session_and_unknown_actions_are_refused(served):
    backend = FakeMedia(TRACK)
    served(backend)
    c = client()
    for action in ("previous", "playpause", "next"):
        assert c.post("/api/music/control", json={"action": action}).json() == {"ok": True}
    assert backend.pressed == ["previous", "playpause", "next"]
    assert c.post("/api/music/control", json={"action": "format"}).status_code == 400


def test_artwork_is_read_once_per_track(served):
    backend = FakeMedia(TRACK)
    served(backend)
    c = client()
    first = c.get("/api/music/artwork", params={"key": "k1"}).json()["data_url"]
    again = c.get("/api/music/artwork", params={"key": "k1"}).json()["data_url"]
    assert first.startswith("data:image/png") and again == first and backend.reads == 1
    c.get("/api/music/artwork", params={"key": "k2"})
    assert backend.reads == 2


def test_library_routes_return_the_macs_error_sentences(served):
    def handler(request):
        if "/items" in request.url.path:
            return json_response({"error": {"message": "forbidden"}}, 403)
        if "/search" in request.url.path:
            return json_response({}, 429)
        if request.url.path.endswith("/play"):
            return json_response({"error": {"reason": "PREMIUM_REQUIRED"}}, 403)
        return json_response({"items": [], "limit": 50})

    served(None, handler)
    c = client()
    assert c.get("/api/music/playlists").json() == {"items": []}
    assert c.get("/api/music/playlists/p1/tracks").status_code == 403
    assert "só lista as músicas das playlists que você criou" in c.get("/api/music/playlists/p1/tracks").json()["error"]
    assert c.get("/api/music/search", params={"q": " "}).json() == {"tracks": [], "albums": [], "playlists": [], "artists": []}
    assert c.get("/api/music/search", params={"q": "x"}).status_code == 429
    assert c.post("/api/music/play", json={"context_uri": "spotify:playlist:1"}).json()["error"] == \
        "Para tocar pelo Wisp a conta precisa de Spotify Premium."
    assert c.post("/api/music/play", json={}).status_code == 400 and c.post("/api/music/queue", json={}).status_code == 400


def test_library_without_a_session_says_to_connect(served):
    served(None, signed_in=False)
    got = client().get("/api/music/playlists")
    assert got.status_code == 401 and got.json()["error"] == "Sua sessão do Spotify expirou; clique em Conectar Spotify."


def test_client_id_is_saved_in_the_wisp_config_and_env_wins(served, monkeypatch):
    served(None, signed_in=False)
    c = client()
    assert c.get("/api/music/status").json()["has_client_id"] is False
    assert c.post("/api/music/connect").status_code == 409
    assert c.put("/api/music/client", json={"client_id": "  abc123  "}).json()["client_id"] == "abc123"
    assert music.client_id_path().read_text().count("abc123") == 1
    monkeypatch.setenv("WISP_SPOTIFY_CLIENT_ID", "from-env")
    assert c.get("/api/music/status").json()["client_id"] == "from-env"


def test_connect_logs_in_on_the_fixed_loopback_port_with_pkce(served, monkeypatch):
    def handler(request):
        if request.url.host == "accounts.spotify.com":
            handler.fields = parse_qs(request.content.decode())
            return json_response({"access_token": "a", "expires_in": 3600, "refresh_token": "r", "scope": "s"})
        return json_response({})

    handler.fields = None
    opened = []
    service = served(None, handler, signed_in=False)
    service.opener = opened.append
    music.save_client_id("client-1")
    result = {}

    def browser():
        deadline = time.time() + 10
        while not opened and time.time() < deadline:
            time.sleep(0.01)
        result["query"] = parse_qs(urlsplit(opened[0]).query)
        result["status"] = urllib.request.urlopen(
            f"http://127.0.0.1:43821/callback?code=THE-CODE&state={result['query']['state'][0]}", timeout=5).status

    with client() as c:
        queue = host_of(c).hub.subscribe()
        thread = threading.Thread(target=browser)
        thread.start()
        assert c.post("/api/music/connect").status_code == 202
        thread.join(10)
        deadline = time.time() + 10
        while service.runner.running and time.time() < deadline:
            time.sleep(0.02)
    assert result["status"] == 200 and result["query"]["client_id"] == ["client-1"]
    assert handler.fields["code"] == ["THE-CODE"] and "client_secret" not in handler.fields
    assert oauth.challenge(handler.fields["code_verifier"][0]) == result["query"]["code_challenge"][0]
    assert service.api.is_signed_in() and queue.get_nowait() == {"feature": "music", "type": "auth", "state": "connected", "message": None}


def test_signout_forgets_the_session(served):
    service = served(None)
    assert service.api.is_signed_in()
    assert client().post("/api/music/signout").json()["signed_in"] is False
