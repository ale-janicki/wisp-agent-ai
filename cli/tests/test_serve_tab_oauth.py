import asyncio
import sys
import urllib.request

import pytest

from serve_tab_helpers import XorProtector
from wisp.serve.features.agenda import oauth
from wisp.serve.features.agenda.dpapi import DpapiProtector, SecretFile


def test_pkce_challenge_matches_the_rfc_7636_vector():
    assert oauth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    verifier = oauth.make_verifier()
    assert len(verifier) == 64 and "=" not in verifier and oauth.make_state() != oauth.make_state()


def test_query_encoding_keeps_plus_and_spaces_apart():
    assert oauth.query([("scope", "a b+c"), ("x", "é")]) == "scope=a%20b%2Bc&x=%C3%A9"


def test_callback_parsing():
    assert oauth.request_target("GET /callback?code=1&state=s HTTP/1.1\r\nHost: x\r\n\r\n") == "/callback?code=1&state=s"
    assert oauth.request_target("POST / HTTP/1.1") is None and oauth.request_target("garbage") is None
    assert oauth.parse_callback("/callback?code=abc&state=s", "/callback", "s") == ("code", "abc")
    assert oauth.parse_callback("/callback?error=access_denied&state=s", "/callback", "s") == ("denied", "access_denied")
    for target, reason in (("/other?code=1&state=s", "notCallback"), ("/callback?code=1&state=x", "stateMismatch"),
                           ("/callback?state=s", "missingCode"), ("/callback?code=1", "stateMismatch")):
        with pytest.raises(oauth.CallbackError) as caught:
            oauth.parse_callback(target, "/callback", "s")
        assert caught.value.reason == reason


async def hit(port, target):
    return await asyncio.to_thread(lambda: _get(f"http://127.0.0.1:{port}{target}"))


def _get(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def test_loopback_delivers_the_code_and_answers_the_browser():
    async def scenario():
        loopback = oauth.Loopback(0, "/callback", "st", "Spotify")
        port = await loopback.start()
        assert (await hit(port, "/favicon.ico"))[0] == 404
        waiting = asyncio.create_task(loopback.result(5))
        status, page = await hit(port, "/callback?code=XYZ&state=st")
        return status, page, await waiting

    status, page, callback = asyncio.run(scenario())
    assert status == 200 and "Spotify conectado" in page and callback == ("code", "XYZ")


def test_a_wrong_state_aborts_the_login():
    async def scenario():
        loopback = oauth.Loopback(0, "/callback", "st", "Google")
        port = await loopback.start()
        waiting = asyncio.create_task(loopback.result(5))
        status, page = await hit(port, "/callback?code=XYZ&state=forged")
        with pytest.raises(oauth.LoginFailure) as caught:
            await waiting
        return status, page, caught.value

    status, page, failure = asyncio.run(scenario())
    assert status == 400 and "não confere" in page and (failure.reason, failure.detail) == ("callback", "stateMismatch")


def test_timeout_cancel_and_a_busy_port():
    async def scenario():
        slow = oauth.Loopback(0, "/callback", "s", "X")
        await slow.start()
        with pytest.raises(oauth.LoginFailure) as timed_out:
            await slow.result(0.05)
        stopped = oauth.Loopback(0, "/callback", "s", "X")
        await stopped.start()
        waiting = asyncio.create_task(stopped.result(5))
        await asyncio.sleep(0.01)
        stopped.cancel()
        with pytest.raises(oauth.LoginFailure) as cancelled:
            await waiting
        holder = oauth.Loopback(0, "/callback", "s", "X")
        port = await holder.start()
        with pytest.raises(oauth.LoginFailure) as busy:
            await oauth.Loopback(port, "/callback", "s", "X").start()
        await holder.close()
        return timed_out.value.reason, cancelled.value.reason, busy.value.reason

    assert asyncio.run(scenario()) == ("timedOut", "cancelled", "portBusy")


def test_login_session_sends_the_verifier_whose_challenge_it_published():
    seen = {}

    async def scenario():
        async def exchange(code, verifier, redirect):
            seen.update(code=code, verifier=verifier, redirect=redirect)

        def authorize(redirect, state, challenge):
            seen.update(url_redirect=redirect, state=state, challenge=challenge)
            return "https://idp.example/auth"

        def opener(url):
            seen["opened"] = url
            asyncio.get_running_loop().call_later(0.01, lambda: asyncio.get_running_loop().create_task(
                hit(int(seen["url_redirect"].split(":")[2].split("/")[0]), f"/cb?code=C1&state={seen['state']}")))

        session = oauth.LoginSession(port=lambda: 0, path="/cb", brand="X", authorize_url=authorize, exchange=exchange,
                                     opener=opener, timeout=5)
        return await session.run()

    assert asyncio.run(scenario()) == "connected"
    assert seen["opened"] == "https://idp.example/auth" and seen["code"] == "C1"
    assert oauth.challenge(seen["verifier"]) == seen["challenge"] and seen["redirect"] == seen["url_redirect"]


def test_login_runner_reports_cancel_exactly_once():
    done = []

    async def scenario():
        async def exchange(*args):
            raise AssertionError("never reached")

        session = oauth.LoginSession(port=lambda: 0, path="/cb", brand="X", authorize_url=lambda *a: "u",
                                     exchange=exchange, opener=lambda url: None, timeout=5)
        runner = oauth.LoginRunner()
        runner.start(session, lambda outcome, error: done.append(outcome))
        await asyncio.sleep(0.05)
        assert runner.running
        runner.cancel()
        await runner.task

    asyncio.run(scenario())
    assert done == ["cancelled"]


def test_secret_file_round_trips_and_never_stores_plain_text(tmp_path):
    secret = SecretFile("t.bin", XorProtector(), tmp_path)
    assert secret.read() is None
    secret.write(b'{"refresh":"abc"}')
    assert b"abc" not in (tmp_path / "t.bin").read_bytes() and secret.read() == b'{"refresh":"abc"}'
    secret.delete()
    assert secret.read() is None


def test_without_dpapi_nothing_is_stored(tmp_path):
    secret = SecretFile("t.bin", None, tmp_path)
    assert not secret.available and secret.read() is None
    with pytest.raises(OSError):
        secret.write(b"x")


@pytest.mark.skipif(sys.platform != "win32", reason="DPAPI exists only on Windows")
def test_dpapi_round_trip_on_windows(tmp_path):
    protector = DpapiProtector()
    blob = protector.protect(b"segredo")
    assert blob != b"segredo" and protector.unprotect(blob) == b"segredo"


def test_dpapi_refuses_to_exist_off_windows():
    if sys.platform != "win32":
        with pytest.raises(OSError):
            DpapiProtector()
