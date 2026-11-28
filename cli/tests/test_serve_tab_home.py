import json
import time

import pytest

from serve_tab_helpers import client
from wisp.paths import WispPaths
from wisp.serve.features import home


@pytest.fixture(autouse=True)
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("WISP_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setattr(home, "_usage_index", None)


def write_profile(fake_home, body):
    path = WispPaths.current().config / "profile.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body))


def test_profile_names_the_user_from_the_wisp_profile(fake_home):
    write_profile(fake_home, {"persona": {"name": "Pip", "user": "Maria da Silva", "language": "pt-BR"}})
    got = client().get("/api/home/profile").json()
    assert got == {"user": "Maria da Silva", "first_name": "Maria", "persona": "Pip", "language": "pt-BR"}


def test_profile_falls_back_to_the_config_name_then_the_account(fake_home, monkeypatch):
    config = fake_home / ".config/wisp/wisp.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"user_name": "Joana Prado"}))
    assert home.profile_info()["first_name"] == "Joana"
    config.write_text("{}")
    monkeypatch.setattr("getpass.getuser", lambda: "conta")
    info = home.profile_info()
    assert info["first_name"] == "conta" and info["persona"] == "Wisp"


def test_profile_needs_the_token():
    from starlette.testclient import TestClient
    from wisp.serve.app import create_app
    assert TestClient(create_app("x")).get("/api/home/profile").status_code == 401


def test_usage_rows_follow_the_mac_rules():
    now = 1_000_000.0
    rows = home.usage_rows({"five_hour": {"used_percentage": 80.4, "resets_at": now + 600},
                            "seven_day": {"used_percentage": 95, "resets_at": now - 1}}, now)
    assert rows == [{"kind": "session", "state": "used", "percent": 80, "resets_at": now + 600, "severity": "warning"},
                    {"kind": "week", "state": "renewed"}]
    assert home.usage_rows({"seven_day": {"used_percentage": 10}}, now)[0] == {
        "kind": "session", "state": "used", "percent": 0, "resets_at": None, "severity": "normal"}


def test_usage_reads_the_file_the_profile_names(fake_home, tmp_path):
    limits = tmp_path / "limits.json"
    limits.write_text(json.dumps({"captured_at": time.time(), "five_hour": {"used_percentage": 92, "resets_at": time.time() + 99}}))
    write_profile(fake_home, {"blocks": {"usage": {"limits": str(limits)}}})
    got = client().get("/api/home/usage").json()["limits"]
    assert got["rows"][0]["severity"] == "critical" and got["rows"][0]["percent"] == 92


def test_usage_is_null_without_a_readable_file(fake_home):
    assert client().get("/api/home/usage").json()["limits"] is None
    write_profile(fake_home, {"blocks": {"usage": {"limits": "/nope/limits.json"}}})
    assert client().get("/api/home/usage").json()["limits"] is None


def test_usage_carries_the_token_totals_from_claude_transcripts(fake_home, monkeypatch):
    monkeypatch.setattr(home, "_usage_index", None)
    assert client().get("/api/home/usage").json()["tokens"] == {"today": 0, "week": 0}


def test_conversations_are_the_newest_five_with_their_count():
    c = client()
    for n in range(7):
        c.post("/conversations", json={"title": f"Conversa {n}"})
    got = c.get("/api/home/conversations").json()
    assert got["total"] == 7 and len(got["items"]) == 5
    assert {"id", "title", "updated_at", "preview", "telegram"} <= set(got["items"][0])


@pytest.mark.parametrize("url", [
    "https://meet.google.com/abc", "http://exemplo.com", "zoommtg://zoom.us/join?confno=1",
    "msteams://teams.microsoft.com/l/meetup-join/x", "HTTPS://Exemplo.com/a?b=1#c"])
def test_open_hands_the_normalized_link_to_the_system_browser(monkeypatch, url):
    from urllib.parse import urlsplit, urlunsplit
    opened = []
    monkeypatch.setattr(home, "_open_url", opened.append)
    assert client().post("/api/home/open", json={"url": url}).status_code == 200
    assert opened == [urlunsplit(urlsplit(url))]


@pytest.mark.parametrize("url", [
    "http:calc.exe", "http:///c:/windows/system32/calc.exe", "http:/calc.exe", "https:calc.exe", "http:\\\\evil.com",
    "zoommtg:calc", "msteams:foo", "file:///C:/Windows/System32/calc.exe", "javascript:alert(1)", "calc.exe", "https://", "",
    "ht\ttp://a.com", " https://a.com", "https://a.com ", "https://a.com/\n", "https://a .com", "https://a.com/\x00",
    "https://a.com/\u2028x", "https://a.com\\x", "\x1bhttps://a.com", "https://\ta.com", "http://\x7fa.com"])
def test_open_refuses_every_link_the_parser_and_the_shell_could_read_differently(monkeypatch, url):
    opened = []
    monkeypatch.setattr(home, "_open_url", opened.append)
    assert client().post("/api/home/open", json={"url": url}).status_code == 400
    assert opened == []


def test_links_the_parser_rejects_are_refused_not_a_crash():
    from wisp.serve.features.home import safe_link
    for bad in ("http://[::1", "http://＃h/", "http://a℀b/"):
        assert safe_link(bad) is None
