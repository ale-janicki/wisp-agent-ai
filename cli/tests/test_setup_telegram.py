import http.client
import io
import json
import os
import stat
import threading
import time
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from wisp.cli import main
from wisp.config import TelegramConfig, WispConfig, load_config
from wisp.jobs.launchd import LaunchdJobs
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult
from wisp.setup import telegram as step
from wisp.setup.profile_writer import set_telegram_block
from wisp.telegram_api import TelegramAPI, TelegramError

TOKEN = "424242:test-token-not-real"
ME = {"id": 777, "is_bot": True, "username": "wisp_test_bot"}
FORUM = {"id": -1001, "type": "supergroup", "is_forum": True}
PLAIN = {"id": -1002, "type": "supergroup"}
ADMIN = {"status": "administrator", "can_manage_topics": True}


def update(chat, sender=None, update_id=1, date=None):
    message = {"chat": chat, "from": sender or {"id": 55, "is_bot": False}, "date": int(time.time()) if date is None else date}
    return {"update_id": update_id, "message": message}


class FakeTelegram:
    def __init__(self):
        self.replies: dict[str, object] = {}
        self.backlog: list[dict] = []
        self.later: list[list[dict]] = []
        self.chats: dict[int, dict] = {-1001: FORUM, -1002: PLAIN}
        self.polls = 0
        self.requests: list[tuple[str, dict]] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                method = self.path.rsplit("/", 1)[1]
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
                outer.requests.append((method, body))
                known = self.path.startswith(f"/bot{TOKEN}/")
                reply = outer.replies.get(method, [])
                if method == "getChat" and body["chat_id"] in outer.chats:
                    reply = outer.chats[body["chat_id"]]
                if method == "getUpdates":
                    outer.polls += 1
                    if outer.polls == 1:
                        reply = outer.backlog
                    elif outer.later:
                        reply = outer.later.pop(0)
                    else:
                        reply = [u for u in reply if u["update_id"] >= (body.get("offset") or 0)]
                payload = {"ok": True, "result": reply} if known else {"ok": False, "description": "Unauthorized"}
                self.send_response(200 if known else 401)
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())

            def log_message(self, *args):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def methods(self):
        return [m for m, _ in self.requests]


@pytest.fixture
def tg():
    fake = FakeTelegram()
    yield fake
    fake.server.shutdown()
    fake.server.server_close()


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    monkeypatch.setattr(step, "DISCOVER_S", 1)
    monkeypatch.setattr(step, "UP_WAIT_S", 0)
    monkeypatch.setattr(step, "sleep", lambda s: None)


def paths_of(home):
    return WispPaths.for_os("Darwin", home, {})


def make(home, tg, *, running=False, up=True):
    paths = paths_of(home)
    status_argv = (str(paths.runtime / "venv/bin/wisp"), "topic", "status")
    runner = FakeRunner({
        ("launchctl", "print"): RunResult([], 0 if running else 113, "\tstate = running\n" if running else "", ""),
        ("launchctl",): RunResult([], 0, "", ""),
        status_argv: RunResult([], 0, json.dumps({"up": up}), ""),
    })
    return paths, runner, LaunchdJobs(paths, runner, 501), lambda token: TelegramAPI(token, tg.base)


def run(home, tg, cfg=None, *, running=False, up=True, **flags):
    paths, runner, jobs, factory = make(home, tg, running=running, up=up)
    args = dict(token_stdin=None, discover=False, skip=False, dry_run=False) | flags
    report = step.setup_telegram(runner, paths, cfg or WispConfig(), factory, jobs, **args)
    return report, runner, paths


def store_token(home):
    path = paths_of(home).config / "secrets/telegram-token"
    path.parent.mkdir(parents=True)
    path.write_text(TOKEN + "\n")


def test_token_never_in_argv_or_report(fake_home, tg):
    tg.replies["getMe"] = ME
    report, runner, _ = run(fake_home, tg, token_stdin=TOKEN.encode())
    assert report.status == "needs_user"
    assert "@wisp_test_bot" in report.summary and "Tópicos" in report.summary
    assert TOKEN not in report.to_json()
    assert all(TOKEN not in " ".join(call) for call in runner.calls)
    tg.replies.update({"getUpdates": [update(FORUM)], "getChat": FORUM, "getChatMember": ADMIN})
    report, runner, _ = run(fake_home, tg, discover=True)
    assert report.status == "done"
    assert TOKEN not in report.to_json()
    assert all(TOKEN not in " ".join(call) for call in runner.calls)
    assert TOKEN not in (paths_of(fake_home).launch_agents / "ai.wisp.bot.plist").read_text()


def test_token_file_is_0600(fake_home, tg):
    tg.replies["getMe"] = ME
    run(fake_home, tg, token_stdin=(TOKEN + "\n").encode())
    path = paths_of(fake_home).config / "secrets/telegram-token"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    assert path.read_text().strip() == TOKEN


def test_bad_token_is_failed_one_sentence(fake_home, tg):
    report, _, paths = run(fake_home, tg, token_stdin=b"1:wrong")
    assert report.status == "failed"
    assert "\n" not in report.summary and "wrong" not in report.summary and "127.0.0.1" not in report.summary
    assert not (paths.config / "secrets/telegram-token").exists()


def test_discover_finds_forum_group_and_user(fake_home, tg):
    store_token(fake_home)
    tg.replies.update({"getMe": ME, "getUpdates": [update(FORUM)], "getChat": FORUM, "getChatMember": ADMIN})
    report, runner, paths = run(fake_home, tg, discover=True)
    assert report.status == "done"
    telegram = load_config().telegram
    assert (telegram.chat_id, telegram.user_id) == (-1001, 55)
    assert telegram.token_file == str(paths.config / "secrets/telegram-token")
    plist = (paths.launch_agents / "ai.wisp.bot.plist").read_bytes()
    import plistlib
    job = plistlib.loads(plist)
    assert job["ProgramArguments"] == [str(paths.runtime / "venv/bin/wisp-bot")]
    assert job["EnvironmentVariables"]["WISP_CONFIG"] == str(paths.config / "wisp.json")
    assert job["EnvironmentVariables"]["PATH"] == f"{paths.bin}:/opt/homebrew/bin:/usr/bin:/bin"
    assert job["StandardOutPath"] == str(paths.state / "bot/bot.log")
    assert job["KeepAlive"] is True
    assert any(c[:2] == ["launchctl", "bootstrap"] for c in runner.calls)


def test_discover_ignores_private_chat_and_bots(fake_home, tg):
    store_token(fake_home)
    private = {"id": 9, "type": "private"}
    tg.replies.update({
        "getMe": ME, "getChat": FORUM, "getChatMember": ADMIN,
        "getUpdates": [update(private), update(FORUM, {"id": 3, "is_bot": True}, 2), update(FORUM, {"id": 55}, 3)],
    })
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "done" and load_config().telegram.user_id == 55


def test_discover_non_forum_group_says_enable_topics(fake_home, tg):
    store_token(fake_home)
    tg.replies.update({"getUpdates": [update(PLAIN)], "getChat": PLAIN})
    report, runner, _ = run(fake_home, tg, discover=True)
    assert report.status == "needs_user" and "Tópicos" in report.summary
    assert load_config().telegram is None
    assert not any(c[:2] == ["launchctl", "bootstrap"] for c in runner.calls)


def test_discover_without_message_asks_for_oi(fake_home, tg):
    store_token(fake_home)
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "needs_user" and "'oi'" in report.summary


def test_discover_bot_not_admin_says_so(fake_home, tg):
    store_token(fake_home)
    tg.replies.update({
        "getMe": ME, "getUpdates": [update(FORUM)], "getChat": FORUM,
        "getChatMember": {"status": "administrator", "can_manage_topics": False},
    })
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "needs_user" and "administrador" in report.summary
    assert load_config().telegram is None


def test_discover_refuses_while_job_loaded(fake_home, tg):
    store_token(fake_home)
    report, runner, _ = run(fake_home, tg, discover=True, running=True)
    assert report.status == "failed" and report.summary == "pare o bot antes de procurar o grupo"
    assert "getUpdates" not in tg.methods()
    assert not any(c[:2] == ["launchctl", "bootstrap"] for c in runner.calls)


def test_updates_offset_advances(tg):
    tg.backlog = [{"update_id": 10}, {"update_id": 11}]
    api = TelegramAPI(TOKEN, tg.base)
    api.get_updates(0)
    api.get_updates(0)
    assert "offset" not in tg.requests[0][1] and tg.requests[1][1]["offset"] == 12


def test_profile_block_uses_absolute_wisp_shim(fake_home, tg):
    store_token(fake_home)
    tg.replies.update({"getMe": ME, "getUpdates": [update(FORUM)], "getChat": FORUM, "getChatMember": ADMIN})
    run(fake_home, tg, discover=True)
    block = json.loads((paths_of(fake_home).config / "profile.json").read_text())["blocks"]["telegram"]
    shim = f"{fake_home}/.local/bin/wisp topic"
    for key in ("status", "list", "share", "post", "close"):
        assert block[key].startswith(shim)
    assert block["share"] == f"{shim} compartilhar --session={{session}} --cwd={{cwd}} --nome={{name}} --json"
    assert block["post"] == f"{shim} postar --json"
    assert not {"create", "send", "claim"} & block.keys()
    assert block["attachments"] == str(paths_of(fake_home).state / "bot/anexos")


def test_profile_writer_keeps_other_keys(fake_home):
    profile = fake_home / ".config/wisp/profile.json"
    profile.parent.mkdir(parents=True)
    profile.write_text(json.dumps({"persona": {"name": "Z"}, "blocks": {"tasks": {"file": "x"}}}))
    set_telegram_block(profile, "/h/bin/wisp")
    data = json.loads(profile.read_text())
    assert data["persona"] == {"name": "Z"} and data["blocks"]["tasks"] == {"file": "x"}
    assert "attachments" not in data["blocks"]["telegram"]


def test_symlinked_profile_refused_before_anything_is_written(fake_home, tg):
    store_token(fake_home)
    target = fake_home / "elsewhere.json"
    target.write_text("{}")
    link = paths_of(fake_home).config / "profile.json"
    link.symlink_to(target)
    report, runner, _ = run(fake_home, tg, discover=True)
    assert report.status == "failed" and target.read_text() == "{}"
    assert load_config().telegram is None and "getUpdates" not in tg.methods()


def test_bot_that_never_comes_up_rolls_back(fake_home, tg):
    store_token(fake_home)
    tg.replies.update({"getMe": ME, "getUpdates": [update(FORUM)], "getChat": FORUM, "getChatMember": ADMIN})
    report, runner, paths = run(fake_home, tg, discover=True, up=False)
    assert report.status == "failed" and "não respondeu" in report.summary
    assert load_config().telegram is None
    assert not (paths.config / "profile.json").exists()
    assert not (paths.launch_agents / "ai.wisp.bot.plist").exists()
    assert any(c[:2] == ["launchctl", "bootout"] for c in runner.calls[-1:])


def test_profile_written_only_after_the_bot_answered(fake_home, tg, monkeypatch):
    store_token(fake_home)
    tg.replies.update({"getMe": ME, "getUpdates": [update(FORUM)], "getChat": FORUM, "getChatMember": ADMIN})
    seen = []
    real_wait = step._wait_up

    def wait(runner, paths, details):
        seen.append(((paths.config / "profile.json").exists(), load_config().telegram is not None))
        return real_wait(runner, paths, details)
    monkeypatch.setattr(step, "_wait_up", wait)
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "done" and seen == [(False, True)]
    assert "telegram" in json.loads((paths_of(fake_home).config / "profile.json").read_text())["blocks"]


def test_rerun_configured_verifies_only(fake_home, tg):
    cfg = WispConfig(telegram=TelegramConfig(chat_id=-1, user_id=1, token_file="x"))
    report, runner, _ = run(fake_home, tg, cfg, running=True, discover=True)
    assert report.status == "skipped"
    assert tg.requests == []
    assert not any(c[:2] == ["launchctl", "bootstrap"] for c in runner.calls)


def configured(home):
    store_token(home)
    return WispConfig(telegram=TelegramConfig(chat_id=-1, user_id=1, token_file=str(paths_of(home).config / "secrets/telegram-token")))


def test_rerun_configured_but_stopped_restarts_the_job(fake_home, tg):
    report, runner, paths = run(fake_home, tg, configured(fake_home), running=False, discover=True)
    assert report.status == "done" and tg.requests == []
    assert [c[1] for c in runner.calls if c[0] == "launchctl" and c[1] != "print"] == ["bootout", "bootstrap"]
    assert (paths.launch_agents / "ai.wisp.bot.plist").exists()


def test_rerun_configured_bot_that_stays_down_is_failed(fake_home, tg):
    report, _, _ = run(fake_home, tg, configured(fake_home), running=False, up=False, discover=True)
    assert report.status == "failed" and "não respondeu" in report.summary


def test_rerun_configured_without_token_is_failed(fake_home, tg):
    cfg = WispConfig(telegram=TelegramConfig(chat_id=-1, user_id=1, token_file=str(fake_home / "missing")))
    report, runner, _ = run(fake_home, tg, cfg, running=False, discover=True)
    assert report.status == "failed" and "token" in report.summary
    assert not any(c[:2] == ["launchctl", "bootstrap"] for c in runner.calls)


def connected(home, tg):
    store_token(home)
    tg.replies.update({"getMe": ME, "getUpdates": [update(FORUM)], "getChat": FORUM, "getChatMember": ADMIN})
    report, _, paths = run(home, tg, discover=True)
    assert report.status == "done"
    return paths


def test_skip_on_configured_setup_disconnects(fake_home, tg):
    paths = connected(fake_home, tg)
    profile = paths.config / "profile.json"
    data = json.loads(profile.read_text())
    data["blocks"]["tasks"] = {"file": "x"}
    profile.write_text(json.dumps(data))
    report, runner, _ = run(fake_home, tg, load_config(), skip=True)
    assert report.status == "skipped" and report.summary == "Telegram desconectado"
    after = json.loads(profile.read_text())
    assert "telegram" not in after["blocks"] and after["blocks"]["tasks"] == {"file": "x"}
    assert load_config().telegram is None
    assert any(c[:2] == ["launchctl", "bootout"] and c[2].endswith("/ai.wisp.bot") for c in runner.calls)
    assert not (paths.launch_agents / "ai.wisp.bot.plist").exists()
    assert (paths.config / "secrets/telegram-token").exists()


def test_skip_cleans_a_half_finished_setup(fake_home, tg):
    paths = paths_of(fake_home)
    paths.launch_agents.mkdir(parents=True)
    (paths.launch_agents / "ai.wisp.bot.plist").write_text("x")
    report, runner, _ = run(fake_home, tg, skip=True)
    assert report.status == "skipped" and report.summary == "Telegram desconectado"
    assert not (paths.launch_agents / "ai.wisp.bot.plist").exists()


def test_skip_refuses_a_symlinked_profile_and_changes_nothing(fake_home, tg):
    paths = connected(fake_home, tg)
    profile = paths.config / "profile.json"
    target = fake_home / "elsewhere.json"
    target.write_text(profile.read_text())
    profile.unlink()
    profile.symlink_to(target)
    before = target.read_text()
    report, runner, _ = run(fake_home, tg, load_config(), skip=True)
    assert report.status == "failed"
    assert target.read_text() == before and load_config().telegram is not None
    assert runner.calls == [] and (paths.launch_agents / "ai.wisp.bot.plist").exists()


def test_skip_ignores_a_foreign_symlinked_profile_when_wisp_has_no_telegram(fake_home, tg):
    profile = paths_of(fake_home).config / "profile.json"
    profile.parent.mkdir(parents=True)
    target = fake_home / "elsewhere.json"
    target.write_text(json.dumps({"blocks": {"telegram": {"status": "x"}}}))
    profile.symlink_to(target)
    report, runner, _ = run(fake_home, tg, skip=True)
    assert report.status == "skipped" and report.summary == "Telegram deixado para depois" and runner.calls == []


def test_skip_is_skipped(fake_home, tg):
    report, runner, _ = run(fake_home, tg, skip=True)
    assert report.status == "skipped" and runner.calls == [] and tg.requests == []


def test_dry_run_touches_nothing(fake_home, tg):
    report, runner, _ = run(fake_home, tg, discover=True, dry_run=True)
    assert report.status == "done" and tg.requests == [] and runner.calls == []


def test_cli_skip_prints_one_json(fake_home, capsys):
    assert main(["setup", "telegram", "--skip", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "skipped"


def test_cli_token_stdin_bad_token_never_leaves_the_machine_but_reports(fake_home, capsys, monkeypatch):
    monkeypatch.setattr("wisp.cli.TelegramAPI", lambda token: TelegramAPI(token, "http://127.0.0.1:9"))
    monkeypatch.setattr("sys.stdin", type("S", (), {"buffer": io.BytesIO(b"1:x")})())
    assert main(["setup", "telegram", "--token-stdin", "--json"]) == 1
    out = json.loads(capsys.readouterr().out)
    assert out["status"] == "failed" and "1:x" not in json.dumps(out)


def test_token_with_control_char_never_leaks(fake_home, tg):
    bad = "424242:ab\x01cd"
    report, runner, paths = run(fake_home, tg, token_stdin=bad.encode())
    assert report.status == "failed" and tg.requests == []
    assert "\x01" not in report.to_json() and "424242" not in report.to_json()
    assert not (paths.config / "secrets/telegram-token").exists()
    with pytest.raises(TelegramError) as caught:
        TelegramAPI(bad, tg.base).get_me()
    error = caught.value
    seen = [error, error.__cause__, error.__context__]
    assert all("\x01" not in str(e) and "424242" not in str(e) for e in seen if e)


@pytest.mark.parametrize("raw", [b"abc", b"12:", b":abc", b"12:a b", b"12:a/b"])
def test_token_shape_is_validated(fake_home, tg, raw):
    report, _, _ = run(fake_home, tg, token_stdin=raw)
    assert report.status == "failed" and tg.requests == []


def test_http_exceptions_become_telegram_error(monkeypatch):
    def boom(*a, **k):
        raise http.client.RemoteDisconnected("secret-path")
    monkeypatch.setattr("urllib.request.urlopen", boom)
    with pytest.raises(TelegramError) as caught:
        TelegramAPI(TOKEN, "http://127.0.0.1:9").get_me()
    assert "secret-path" not in str(caught.value) and caught.value.__context__ is None


def test_unreadable_error_body_becomes_telegram_error(monkeypatch):
    class Body(io.RawIOBase):
        def read(self, *a):
            raise OSError("reset")

    def boom(*a, **k):
        raise urllib.error.HTTPError("http://x", 500, "err", {}, Body())
    monkeypatch.setattr("urllib.request.urlopen", boom)
    with pytest.raises(TelegramError):
        TelegramAPI(TOKEN, "http://127.0.0.1:9").get_me()


def test_corrupt_profile_leaves_config_without_telegram(fake_home, tg):
    store_token(fake_home)
    profile = paths_of(fake_home).config / "profile.json"
    profile.write_text("{not json")
    tg.replies.update({"getMe": ME, "getUpdates": [update(FORUM)], "getChat": FORUM, "getChatMember": ADMIN})
    report, runner, _ = run(fake_home, tg, discover=True)
    assert report.status == "failed" and "\n" not in report.summary
    assert load_config().telegram is None
    assert not any(c[:2] == ["launchctl", "bootstrap"] for c in runner.calls)


def test_discover_keeps_polling_past_other_chats(fake_home, tg):
    store_token(fake_home)
    private = {"id": 9, "type": "private"}
    tg.replies.update({"getMe": ME, "getChatMember": ADMIN})
    tg.later = [[update(private, update_id=1)], [update(PLAIN, update_id=2)], [update(FORUM, update_id=3)]]
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "done" and load_config().telegram.chat_id == -1001


def test_plain_group_alone_reports_topics_only_at_deadline(fake_home, tg):
    store_token(fake_home)
    tg.replies.update({"getChat": PLAIN})
    tg.later = [[update(PLAIN, update_id=1)]]
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "needs_user" and "Tópicos" in report.summary
    assert tg.polls > 2


def test_plain_group_then_forum_is_found(fake_home, tg):
    store_token(fake_home)
    tg.replies.update({"getMe": ME, "getChatMember": ADMIN})
    tg.later = [[update(PLAIN, update_id=1), update(FORUM, update_id=2)]]
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "done"


def test_oi_sent_before_procurar_is_found(fake_home, tg):
    tg.replies["getMe"] = ME
    run(fake_home, tg, token_stdin=TOKEN.encode())
    stored_at = load_config().telegram_token_at
    assert isinstance(stored_at, int) and abs(stored_at - time.time()) < 5
    tg.requests.clear()
    tg.polls = 0
    tg.backlog = [update(FORUM, update_id=5, date=stored_at + 30)]
    tg.replies.update({"getChat": FORUM, "getChatMember": ADMIN})
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "done" and load_config().telegram.chat_id == -1001
    assert tg.requests[0][1]["timeout"] > 0


def test_messages_older_than_the_token_are_ignored(fake_home, tg):
    tg.replies["getMe"] = ME
    run(fake_home, tg, token_stdin=TOKEN.encode())
    stored_at = load_config().telegram_token_at
    tg.polls = 0
    tg.backlog = [update(FORUM, update_id=5, date=stored_at - 1)]
    tg.replies.update({"getChat": FORUM, "getChatMember": ADMIN})
    report, runner, _ = run(fake_home, tg, discover=True)
    assert report.status == "needs_user" and "'oi'" in report.summary
    assert load_config().telegram is None
    assert not any(c[:2] == ["launchctl", "bootstrap"] for c in runner.calls)


def test_token_without_timestamp_falls_back_to_the_token_file_time(fake_home, tg):
    store_token(fake_home)
    stored_at = int((paths_of(fake_home).config / "secrets/telegram-token").stat().st_mtime)
    tg.backlog = [update(FORUM, update_id=5, date=stored_at - 60)]
    tg.later = [[update(FORUM, {"id": 66}, update_id=6, date=stored_at)]]
    tg.replies.update({"getMe": ME, "getChat": FORUM, "getChatMember": ADMIN})
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "done" and load_config().telegram.user_id == 66


def test_backlog_then_fresh_message_counts(fake_home, tg):
    store_token(fake_home)
    tg.backlog = [update(PLAIN, update_id=5)]
    tg.later = [[update(FORUM, {"id": 66}, update_id=6)]]
    tg.replies.update({"getMe": ME, "getChat": FORUM, "getChatMember": ADMIN})
    report, _, _ = run(fake_home, tg, discover=True)
    assert report.status == "done" and load_config().telegram.user_id == 66


def test_last_poll_wait_is_bounded_by_time_left(fake_home, tg, monkeypatch):
    monkeypatch.setattr(step, "DISCOVER_S", 2)
    store_token(fake_home)
    run(fake_home, tg, discover=True)
    assert max(body["timeout"] for method, body in tg.requests if method == "getUpdates") <= 2


def test_secrets_dir_is_chmodded_0700_even_if_it_existed(fake_home, tg):
    tg.replies["getMe"] = ME
    secrets = paths_of(fake_home).config / "secrets"
    secrets.mkdir(parents=True)
    os.chmod(secrets, 0o755)
    run(fake_home, tg, token_stdin=TOKEN.encode())
    assert stat.S_IMODE(secrets.stat().st_mode) == 0o700


def test_new_token_on_configured_setup_restarts_the_bot(fake_home, tg):
    tg.replies["getMe"] = ME
    cfg = WispConfig(telegram=TelegramConfig(chat_id=-1, user_id=1, token_file="x"))
    report, runner, _ = run(fake_home, tg, cfg, running=True, token_stdin=TOKEN.encode())
    assert report.status == "done" and "reiniciado" in report.summary
    assert [c[1] for c in runner.calls if c[0] == "launchctl" and c[1] != "print"] == ["bootout", "bootstrap"]


def test_telegram_block_on_a_missing_profile_seeds_persona_and_agent(fake_home):
    profile = fake_home / ".config/wisp/profile.json"
    profile.parent.mkdir(parents=True)
    set_telegram_block(profile, "/h/bin/wisp", name="Ada", language="pt-BR")
    data = json.loads(profile.read_text())
    assert data["persona"] == {"name": "Ada", "language": "pt-BR"} and data["agent"] == {"cwd": "~"}
    profile.write_text(json.dumps({"blocks": {"tasks": {"file": "x"}}}))
    set_telegram_block(profile, "/h/bin/wisp")
    data = json.loads(profile.read_text())
    assert data["persona"] == {"name": "Wisp", "language": "pt-BR"} and data["blocks"]["tasks"] == {"file": "x"}


def test_profile_writer_refuses_symlink(fake_home):
    target = fake_home / "elsewhere.json"
    target.write_text("{}")
    link = fake_home / ".config/wisp/profile.json"
    link.parent.mkdir(parents=True)
    link.symlink_to(target)
    with pytest.raises(ValueError):
        set_telegram_block(link, "/h/bin/wisp")
    assert target.read_text() == "{}"
