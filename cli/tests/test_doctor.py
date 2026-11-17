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
    assert _by_id(checks)["telegram"].summary == "opcional, não configurado"


def test_doctor_never_calls_git_without_clt(fake_home):
    runner = _runner(clt=False)
    run_doctor(runner, _paths(fake_home), WispConfig(brain=str(fake_home / "brain")))
    assert not [a for a in runner.calls if a[0] in ("git", "/usr/bin/git")]


def test_login_parsed_from_auth_status(fake_home):
    runner = _runner(auth=(FIXTURES / "claude-auth-status-in.json").read_text())
    checks = _by_id(run_doctor(runner, _paths(fake_home), WispConfig()))
    assert checks["claude"].ok
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
