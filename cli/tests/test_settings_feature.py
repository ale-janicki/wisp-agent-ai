import json
import stat
import subprocess
import sys

import pytest
from starlette.testclient import TestClient

from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult
from wisp.serve.app import create_app
from wisp.serve.features.settings import wisp_cli

TOKEN = "t0ken-for-tests"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
WISP = [sys.executable, "-m", "wisp"]


class Recorder(FakeRunner):
    def __init__(self, script=None):
        super().__init__(script)
        self.stdins: list[bytes | None] = []

    def run(self, argv, *, stdin=None, timeout=60, env=None, cwd=None):
        self.stdins.append(stdin)
        return super().run(argv, stdin=stdin, timeout=timeout, env=env, cwd=cwd)


def ok(argv=(), out="", exit=0):
    return RunResult(list(argv), exit, out, "")


def report(name, status="done", summary="feito", **data):
    return json.dumps({"step": name, "status": status, "summary": summary, "details": [], "data": data})


@pytest.fixture
def env(fake_home, monkeypatch):
    monkeypatch.setenv("WISP_DATA_DIR", str(fake_home / "data"))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(fake_home / "claude-config"))
    config = WispPaths.current().config
    config.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("WISP_CONFIG", str(config / "wisp.json"))

    def use(script=None):
        runner = Recorder(script)
        monkeypatch.setattr(wisp_cli, "runner_factory", lambda: runner)
        return runner

    return fake_home, config, use


@pytest.fixture
def client(env):
    return TestClient(create_app(TOKEN))


def get(client, path, **params):
    return client.get(f"/api/settings{path}", headers=AUTH, params=params)


def post(client, path, **body):
    return client.post(f"/api/settings{path}", headers=AUTH, json=body)


def test_every_route_needs_the_token(client):
    assert client.get("/api/settings/state").status_code == 401
    assert client.post("/api/settings/engine", json={"engine": "codex"}).status_code == 401


def test_state_reads_config_profile_and_defaults(client, env):
    home, config, _ = env
    (config / "wisp.json").write_text(json.dumps({"wisp_dir": str(home / "Wisp"), "brain": str(home / "nope"), "brain_learn": False}))
    (config / "profile.json").write_text(json.dumps({"persona": {"name": "Lia", "user": "Bia", "language": "pt-BR"}, "blocks": {"hooks": {"list": "x"}}}))
    state = get(client, "/state").json()
    assert state["engine"] == "claude"
    assert state["paths"] == {"wisp_dir": str(home / "Wisp"), "has_wisp_dir": True, "brain": str(home / "nope"),
                              "brain_default": str(home / "Wisp") + "/brain", "brain_missing": True, "brain_learn": False}
    assert state["profile"] == {"name": "Lia", "user": "Bia", "avatar": None}
    assert state["blocks"] == {"routines": False, "hooks": True, "commands": False}
    assert state["permission"]["source"] == "standard" and state["permission"]["choice"] == "default"
    assert state["notices"]["reply"] is True and state["notices"]["doNotDisturb"] is False


def test_engine_runs_config_set_exactly_like_the_mac(client, env):
    _, _, use = env
    runner = use({(*WISP, "config", "set", "engine", "codex", "--json"): ok(out=report("config", summary="motor salvo"))})
    answer = post(client, "/engine", engine="codex").json()
    assert answer["status"] == "done" and answer["summary"] == "motor salvo"
    assert runner.calls == [[*WISP, "config", "set", "engine", "codex", "--json"]]


def test_engine_rejects_unknown_engine_without_running_anything(client, env):
    runner = env[2]()
    assert post(client, "/engine", engine="gpt").status_code == 400
    assert runner.calls == []


def test_a_cli_that_prints_nothing_is_reported_in_the_macs_words(client, env):
    env[2]({(*WISP, "config"): ok(out="")})
    answer = post(client, "/engine", engine="codex").json()
    assert answer["status"] == "failed" and answer["summary"] == "O wisp não respondeu."


def test_a_cli_that_times_out_says_so(client, env):
    env[2]({(*WISP, "config"): RunResult([], -9, "", "", timed_out=True)})
    assert post(client, "/engine", engine="codex").json()["summary"] == "O wisp demorou demais."


def test_a_cli_that_does_not_start_says_it_could_not_run(client, env):
    env[2]({(*WISP, "config"): RunResult([], 127, "", "no such file")})
    assert post(client, "/engine", engine="codex").json()["summary"] == "Não consegui rodar o wisp."


def test_path_change_goes_through_config_set_and_only_for_the_two_keys(client, env):
    _, _, use = env
    runner = use({(*WISP, "config", "set", "brain"): ok(out=report("config", summary="caminho salvo"))})
    assert post(client, "/path", key="brain", value="C:/Users/x/brain").json()["summary"] == "caminho salvo"
    assert runner.calls[-1] == [*WISP, "config", "set", "brain", "C:/Users/x/brain", "--json"]
    assert post(client, "/path", key="engine", value="x").status_code == 400
    assert post(client, "/path", key="brain", value=" ").status_code == 400


def test_permission_is_written_to_the_profile_keeping_other_keys(client, env):
    _, config, _ = env
    (config / "profile.json").write_text(json.dumps({"persona": {"name": "A", "language": "pt-BR"}, "agent": {"cwd": "~/w"}, "x": 1}))
    answer = post(client, "/permission", choice="auto").json()
    assert answer["ok"] and answer["permission"] == {"choice": "auto", "source": "profile", "claude_mode": None, "profile_is_link": False}
    saved = json.loads((config / "profile.json").read_text())
    assert saved["agent"] == {"cwd": "~/w", "permissionMode": "auto"} and saved["x"] == 1
    if sys.platform != "win32":
        assert stat.S_IMODE((config / "profile.json").stat().st_mode) == 0o600


def test_permission_with_no_profile_creates_the_minimum_the_app_needs(client, env):
    _, config, _ = env
    post(client, "/permission", choice="bypassPermissions")
    saved = json.loads((config / "profile.json").read_text())
    assert saved == {"persona": {"name": "Wisp", "language": "pt-BR"}, "agent": {"cwd": "~", "permissionMode": "bypassPermissions"}}


@pytest.mark.skipif(sys.platform == "win32", reason="creating a symlink needs developer mode on Windows")
def test_permission_on_a_linked_profile_lives_in_wisp_settings_not_the_target(client, env):
    home, config, _ = env
    target = home / "managed.json"
    target.write_text(json.dumps({"persona": {"name": "A", "language": "pt"}}))
    (config / "profile.json").symlink_to(target)
    answer = post(client, "/permission", choice="auto").json()
    assert answer["permission"] == {"choice": "auto", "source": "wisp", "claude_mode": None, "profile_is_link": True}
    assert "permissionMode" not in json.loads(target.read_text()).get("agent", {})
    assert json.loads((home / "data/settings.json").read_text())["permissionMode"] == "auto"


def test_claude_default_mode_is_shown_but_never_written(client, env):
    home, _, _ = env
    (home / "claude-config").mkdir()
    (home / "claude-config/settings.json").write_text(json.dumps({"permissions": {"defaultMode": "acceptEdits"}}))
    assert get(client, "/state").json()["permission"] == {"choice": None, "source": "claude", "claude_mode": "acceptEdits", "profile_is_link": False}


def test_permission_rejects_unknown_choice(client, env):
    assert post(client, "/permission", choice="yolo").json()["ok"] is False


def test_learn_flag_is_saved_in_wisp_json(client, env):
    _, config, _ = env
    (config / "wisp.json").write_text(json.dumps({"version": 1}))
    assert post(client, "/learn", on=False).json() == {"ok": True}
    assert json.loads((config / "wisp.json").read_text())["brain_learn"] is False
    assert post(client, "/learn", on="no").status_code == 400


def test_create_brain_runs_brain_then_profile_and_stops_on_failure(client, env):
    _, _, use = env
    runner = use({(*WISP, "setup", "brain"): ok(out=report("brain", "failed", "falta o Git", step="system"))})
    answer = post(client, "/brain/create").json()
    assert answer["ok"] is False and answer["error"] == "Falta o Git"
    assert runner.calls == [[*WISP, "setup", "brain", "--json"]]
    runner = use({(*WISP, "setup", "brain"): ok(out=report("brain")), (*WISP, "setup", "profile"): ok(out=report("profile"))})
    assert post(client, "/brain/create").json() == {"ok": True}
    assert [c[3:5] for c in runner.calls] == [["setup", "brain"], ["setup", "profile"]]


def test_lessons_list_confirm_discard_forget(client, env):
    home, config, _ = env
    brain = home / "brain"
    (brain / "wisp").mkdir(parents=True)
    (brain / "wisp/aprendizados.md").write_text("# h\n\n- responda curto · 2025-01-02 · conversa\n- sempre em pt · 2025-01-03 · colheita\n", encoding="utf-8")
    (brain / "wisp/aprendizados-pendentes.md").write_text("# p\n\n- use tabelas · 2025-02-01 · colheita\n- evite emojis · 2025-02-02 · conversa\n", encoding="utf-8")
    (config / "wisp.json").write_text(json.dumps({"brain": str(brain)}))
    listing = get(client, "/lessons").json()
    assert [(item["rule"], item["learned_alone"]) for item in listing["lessons"]] == [("responda curto", False), ("sempre em pt", True)]
    assert listing["pending"][0] == {"number": 1, "rule": "use tabelas", "date": "2025-02-01", "origin": "colheita", "learned_alone": True}
    assert post(client, "/lessons/confirm", number=1).json()["ok"]
    assert post(client, "/lessons/discard", number=1).json()["ok"]
    assert post(client, "/lessons/forget", number=1).json()["ok"]
    after = get(client, "/lessons").json()
    assert [item["rule"] for item in after["lessons"]] == ["sempre em pt", "use tabelas"] and after["pending"] == []
    assert post(client, "/lessons/forget", number=9).json()["ok"] is False
    assert post(client, "/lessons/explode", number=1).status_code == 400


def test_profile_save_passes_name_user_and_avatar(client, env):
    runner = env[2]({(*WISP, "setup", "profile"): ok(out=report("profile", summary="perfil pronto"))})
    answer = post(client, "/profile", name="Lia", user_name="Bia", avatar="C:/a.png").json()
    assert answer["summary"] == "Perfil pronto"
    assert runner.calls[0][3:] == ["setup", "profile", "--name", "Lia", "--user-name", "Bia", "--avatar", "C:/a.png", "--json"]
    assert post(client, "/profile", name="", user_name="Bia").status_code == 400


def test_telegram_connect_sends_the_token_on_stdin_never_on_the_command_line(client, env):
    checks = {"checks": [{"id": "telegram", "ok": False, "summary": "", "step": "telegram", "data": {"job": "installed"}}]}
    runner = env[2]({
        (*WISP, "setup", "telegram"): ok(out=report("telegram", "needs_user", "mande oi no grupo")),
        (*WISP, "doctor"): ok(out=json.dumps(checks)),
    })
    answer = post(client, "/telegram", action="connect", token=" 123:abc ").json()
    assert answer == {"ok": True, "message": "Mande oi no grupo", "token_stored": True, "configured": True}
    assert runner.calls[0] == [*WISP, "setup", "telegram", "--token-stdin", "--json"]
    assert runner.stdins[0] == b"123:abc"
    assert not any("123:abc" in part for call in runner.calls for part in call)
    assert runner.calls[1] == [*WISP, "doctor", "--json", "--only", "telegram"]


def test_telegram_failure_message_and_validation(client, env):
    env[2]()
    answer = post(client, "/telegram", action="discover").json()
    assert answer["ok"] is False and answer["message"] == "Não consegui falar com o Telegram. Tente de novo."
    assert post(client, "/telegram", action="connect", token=" ").status_code == 400
    assert post(client, "/telegram", action="drop").status_code == 400


def test_setup_steps_are_whitelisted_and_return_the_cli_report(client, env):
    runner = env[2]({(*WISP, "setup", "system"): ok(out=report("system", "needs_user", "termine o Git", waiting="git"))})
    answer = post(client, "/setup/system").json()
    assert answer["status"] == "needs_user" and answer["data"] == {"waiting": "git"}
    assert runner.calls == [[*WISP, "setup", "system", "--json"]]
    assert post(client, "/setup/telegram").status_code == 404
    assert post(client, "/setup/rm").status_code == 404


def test_doctor_passes_through_and_502s_when_the_cli_is_silent(client, env):
    runner = env[2]({(*WISP, "doctor"): ok(out=json.dumps({"version": 1, "checks": [{"id": "git", "ok": True}]}))})
    assert get(client, "/doctor", only="git").json()["checks"][0]["id"] == "git"
    assert runner.calls == [[*WISP, "doctor", "--json", "--only", "git"]]
    env[2]()
    assert get(client, "/doctor").status_code == 502


def test_login_opens_a_new_console_with_the_located_claude(client, env, monkeypatch):
    launched = []
    env[2]({(*WISP, "doctor"): ok(out=json.dumps({"checks": [{"id": "claude", "ok": True, "data": {"path": "C:/c/claude.exe"}}]}))})
    monkeypatch.setattr(subprocess, "Popen", lambda argv, **kw: launched.append((argv, kw)))
    assert post(client, "/setup/login").json()["ok"]
    argv, kw = launched[0]
    assert argv == ["C:/c/claude.exe", "auth", "login"]
    assert kw["creationflags"] == getattr(subprocess, "CREATE_NEW_CONSOLE", 0)


def test_login_without_the_agent_installed_says_so(client, env):
    env[2]({(*WISP, "doctor"): ok(out=json.dumps({"checks": [{"id": "claude", "ok": False, "data": {}}]}))})
    assert post(client, "/setup/login").json() == {"ok": False, "error": "O Claude não está instalado."}


def test_notices_merge_and_persist_known_keys_only(client, env):
    answer = post(client, "/notices", doNotDisturb=True, reply=False, bogus=True, update="no").json()
    assert answer["doNotDisturb"] is True and answer["reply"] is False and answer["update"] is True and "bogus" not in answer
    assert get(client, "/state").json()["notices"] == answer


def test_setup_finish_is_remembered(client, env):
    assert get(client, "/state").json()["setup_finished"] is False
    post(client, "/setup/finish")
    assert get(client, "/state").json()["setup_finished"] is True


def test_update_install_ignores_whatever_the_client_sends(client, env, monkeypatch):
    from wisp.serve.features.settings import updates

    asked, ran = [], []
    release = {"tag_name": "windows-v0.2.0", "prerelease": True, "draft": False, "assets": [
        {"name": "Wisp-Setup.exe", "browser_download_url": f"https://github.com/{updates.REPOSITORY}/releases/download/windows-v0.2.0/Wisp-Setup.exe"}]}

    def fetch(url):
        asked.append(url)
        return json.dumps([release]).encode() if "/releases?" in url else b"bits"

    monkeypatch.setattr(updates, "fetch", fetch)
    monkeypatch.setattr(updates, "fetch_page", lambda url: (fetch(url), ""))
    monkeypatch.setattr(updates, "start_installer", ran.append)
    monkeypatch.setattr(updates, "reveal_folder", lambda path: None)
    answer = post(client, "/updates/install", url="https://evil.example/a.exe", asset="calc.exe", sha256="0" * 64).json()
    assert answer["ok"] and answer["run"] is False
    assert not any("evil" in url for url in asked) and ran == []


def test_update_check_route(client, env, monkeypatch):
    from wisp.serve.features.settings import updates

    monkeypatch.setattr(updates, "fetch_page", lambda url: (b"[]", ""))
    assert get(client, "/updates/check", current="0.1.0").json() == {"ok": True, "available": None}


def test_open_only_the_projects_own_github_pages(client, env, monkeypatch):
    import webbrowser

    from wisp.serve.features.settings import updates

    opened = []
    monkeypatch.setattr(webbrowser, "open", lambda url: opened.append(url) or True)
    assert post(client, "/open", url=f"https://github.com/{updates.REPOSITORY}/releases/tag/windows-v0.1.0").json() == {"ok": True}
    assert post(client, "/open", url="https://example.com").status_code == 400
    assert post(client, "/open", url=f"https://github.com/{updates.REPOSITORY}-evil/x").status_code == 400
    assert post(client, "/open", url="file:///C:/Windows/System32/calc.exe").status_code == 400
    assert opened == [f"https://github.com/{updates.REPOSITORY}/releases/tag/windows-v0.1.0"]
