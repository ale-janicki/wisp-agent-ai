from pathlib import Path

from wisp.config import WispConfig
from wisp.doctor import run_doctor
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult

FIXTURES = Path(__file__).parent / "fixtures"
CLAUDE = "/opt/homebrew/bin/claude"


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _by_id(checks):
    return {c.id: c for c in checks}


def _runner(clt=True, auth=None, auth_exit=0):
    script = {("xcode-select", "-p"): RunResult(["xcode-select", "-p"], 0 if clt else 2, "/Library/Developer/CommandLineTools\n", "")}
    if auth is not None:
        script[(CLAUDE, "--version")] = RunResult([CLAUDE, "--version"], 0, "2.0\n", "")
        script[(CLAUDE, "auth", "status", "--json")] = RunResult([CLAUDE, "auth", "status", "--json"], auth_exit, auth, "")
    return FakeRunner(script)


def test_all_missing_on_fresh_home(fake_home):
    checks = run_doctor(_runner(clt=False), _paths(fake_home), WispConfig())
    assert [c.id for c in checks] == ["os", "clt", "claude", "claude_login", "homebrew", "brain", "harness", "telegram", "profile"]
    assert [c.step for c in checks if c.step] == ["system", "system", "login", "brain", "harness", "telegram", "profile"]
    for c in checks:
        assert c.ok == (c.id == "telegram")
    assert _by_id(checks)["claude"].summary == "o Claude não está instalado"
    assert _by_id(checks)["telegram"].summary == "opcional, não configurado"


def test_doctor_never_calls_git_without_clt(fake_home):
    runner = _runner(clt=False)
    run_doctor(runner, _paths(fake_home), WispConfig(brain=str(fake_home / "brain")))
    assert not [a for a in runner.calls if a[0] in ("git", "/usr/bin/git")]


def test_login_parsed_from_auth_status(fake_home):
    runner = _runner(auth=(FIXTURES / "claude-auth-status-in.json").read_text())
    checks = _by_id(run_doctor(runner, _paths(fake_home), WispConfig()))
    assert checks["claude"].ok and checks["claude"].summary == "o Claude está instalado"
    assert checks["claude_login"].ok
    assert checks["claude_login"].data == {"authMethod": "claude.ai", "subscriptionType": "max"}


def test_logged_out_shape(fake_home):
    runner = _runner(auth=(FIXTURES / "claude-auth-status-out.json").read_text(), auth_exit=1)
    login = _by_id(run_doctor(runner, _paths(fake_home), WispConfig()))["claude_login"]
    assert not login.ok
    assert login.step == "login"


def test_auth_status_garbage_is_not_logged_in(fake_home):
    runner = _runner(auth="not json at all")
    assert not _by_id(run_doctor(runner, _paths(fake_home), WispConfig()))["claude_login"].ok


def test_profile_symlink_reported_external(fake_home):
    config = fake_home / ".config/wisp"
    config.mkdir(parents=True)
    target = fake_home / "elsewhere.json"
    target.write_text("{}")
    (config / "profile.json").symlink_to(target)
    profile = _by_id(run_doctor(_runner(), _paths(fake_home), WispConfig()))["profile"]
    assert profile.ok
    assert "gerenciado fora do Wisp" in profile.summary


def test_only_filter(fake_home):
    checks = run_doctor(_runner(), _paths(fake_home), WispConfig(), only={"clt", "profile"})
    assert [c.id for c in checks] == ["clt", "profile"]


def _telegram_cfg():
    from wisp.config import TelegramConfig

    return WispConfig(telegram=TelegramConfig(chat_id=1, user_id=2, token_file="t"))


def _telegram_check(fake_home, monkeypatch, print_exit, print_out):
    monkeypatch.setattr("wisp.doctor.platform.system", lambda: "Darwin")
    runner = _runner()
    runner.script[("launchctl", "print")] = RunResult([], print_exit, print_out, "")
    check = _by_id(run_doctor(runner, _paths(fake_home), _telegram_cfg(), only={"telegram"}))["telegram"]
    return check, runner


def test_telegram_configured_ok_only_when_running(fake_home, monkeypatch):
    check, runner = _telegram_check(fake_home, monkeypatch, 0, "x = {\n\tstate = running\n}\n")
    assert check.ok
    assert check.data == {"job": "running"}
    assert runner.calls[0][:2] == ["launchctl", "print"]
    assert runner.calls[0][2].endswith("/ai.wisp.bot")


def test_telegram_configured_not_ok_when_stopped(fake_home, monkeypatch):
    check, _ = _telegram_check(fake_home, monkeypatch, 0, "x = {\n\tstate = not running\n\tlast exit code = (never exited)\n}\n")
    assert not check.ok
    assert check.data == {"job": "installed"}
    check, _ = _telegram_check(fake_home, monkeypatch, 113, "")
    assert not check.ok
    assert check.data == {"job": "not_installed"}


def test_telegram_configured_not_supported_on_linux(fake_home, monkeypatch):
    monkeypatch.setattr("wisp.doctor.platform.system", lambda: "Linux")
    check = _by_id(run_doctor(_runner(), _paths(fake_home), _telegram_cfg(), only={"telegram"}))["telegram"]
    assert not check.ok


def _profile_check(fake_home, data):
    config = fake_home / ".config/wisp"
    config.mkdir(parents=True, exist_ok=True)
    (config / "profile.json").write_text(data if isinstance(data, str) else __import__("json").dumps(data))
    return _by_id(run_doctor(_runner(), _paths(fake_home), WispConfig(), only={"profile"}))["profile"]


def test_profile_with_only_blocks_is_not_present(fake_home):
    check = _profile_check(fake_home, {"blocks": {"telegram": {"status": "x"}}})
    assert not check.ok and check.summary == "o perfil ainda não está completo"


def test_profile_seeded_by_telegram_is_not_the_users_yet(fake_home):
    seeded = {"persona": {"name": "Wisp", "language": "pt-BR"}, "agent": {"cwd": "~"}, "blocks": {}}
    assert not _profile_check(fake_home, seeded).ok


def test_profile_written_by_the_profile_step_is_ready(fake_home):
    full = {"persona": {"name": "Ada", "user": "Rita", "language": "pt-BR"}, "agent": {"cwd": "~"}}
    assert _profile_check(fake_home, full).ok
    assert not _profile_check(fake_home, "{not json").ok
    assert not _profile_check(fake_home, {"persona": {"name": "Ada", "user": "Rita", "language": "pt-BR"}}).ok
