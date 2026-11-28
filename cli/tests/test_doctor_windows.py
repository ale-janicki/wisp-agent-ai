from wisp.config import WispConfig
from wisp.doctor import is_windows, locate_claude, locate_git, run_doctor
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult

VER = "\nMicrosoft Windows [Version 10.0.22631.4460]\n"


def _paths(home):
    return WispPaths.for_os("Windows", home, {"APPDATA": str(home / "AppData/Roaming"), "LOCALAPPDATA": str(home / "AppData/Local")})


def _ok(argv, out="", exit=0):
    return RunResult(list(argv), exit, out, "")


def _by_id(checks):
    return {c.id: c for c in checks}


def _runner(**scripted):
    script = {("cmd.exe", "/c", "ver"): _ok(["cmd.exe"], VER)}
    script.update({tuple(k.split("|")): v for k, v in scripted.items()})
    return FakeRunner(script)


def test_windows_paths_are_recognised_and_mac_paths_are_not(fake_home):
    assert is_windows(_paths(fake_home))
    assert not is_windows(WispPaths.for_os("Darwin", fake_home, {}))


def test_windows_check_list_has_no_mac_only_checks(fake_home):
    checks = run_doctor(_runner(), _paths(fake_home), WispConfig())
    assert [c.id for c in checks] == ["os", "git", "claude", "claude_login", "brain", "harness", "telegram", "profile"]
    assert [c.step for c in checks if c.step] == ["system", "system", "login", "brain", "harness", "telegram", "profile"]
    assert _by_id(checks)["os"].ok and _by_id(checks)["os"].summary == "Windows 10.0.22631"


def test_old_windows_is_refused(fake_home):
    runner = _runner(**{"cmd.exe|/c|ver": _ok([], "Microsoft Windows [Version 6.3.9600]")})
    check = _by_id(run_doctor(runner, _paths(fake_home), WispConfig()))["os"]
    assert not check.ok and check.summary == "o Wisp pede Windows 10 ou mais"


def test_git_check_runs_git_version(fake_home):
    runner = _runner(**{"git|--version": _ok([], "git version 2.47.0.windows.1\n")})
    check = _by_id(run_doctor(runner, _paths(fake_home), WispConfig(), {"git"}))["git"]
    assert check.ok and check.data["path"] == "git"
    missing = _by_id(run_doctor(_runner(), _paths(fake_home), WispConfig(), {"git"}))["git"]
    assert not missing.ok and missing.summary == "falta o Git"


def test_locate_git_finds_the_program_files_install_when_path_is_stale(fake_home, monkeypatch):
    monkeypatch.setenv("ProgramFiles", r"C:\Program Files")
    wanted = r"C:\Program Files\Git\cmd\git.exe"
    runner = FakeRunner({(wanted, "--version"): _ok([], "git version 2")})
    assert locate_git(runner) == wanted


def test_native_claude_in_local_bin_wins_over_npm(fake_home):
    paths = _paths(fake_home)
    native = str(paths.home / ".local/bin/claude.exe")
    runner = FakeRunner({(native, "--version"): _ok([], "2.1\n")})
    found = locate_claude(paths, WispConfig(), runner)
    assert str(found) == native


def test_npm_native_binary_is_found_and_flagged_npm(fake_home):
    paths = _paths(fake_home)
    npm_exe = str(paths.config.parent / "npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe")
    runner = FakeRunner({(npm_exe, "--version"): _ok([], "2.1\n")})
    checks = _by_id(run_doctor(runner, paths, WispConfig(), {"claude"}))
    assert checks["claude"].ok and checks["claude"].data == {"path": npm_exe, "kind": "npm"}


def test_cmd_shim_alone_does_not_count_as_installed_agent(fake_home):
    paths = _paths(fake_home)
    shim = str(paths.config.parent / "npm/claude.cmd")
    runner = FakeRunner({(shim, "--version"): _ok([], "2.1\n")})
    check = _by_id(run_doctor(runner, paths, WispConfig(), {"claude"}))["claude"]
    assert not check.ok
    assert check.data == {"kind": "npm-shim", "path": shim}
    assert "nativa" in check.summary


def test_claude_login_uses_the_native_binary(fake_home):
    paths = _paths(fake_home)
    native = str(paths.home / ".local/bin/claude.exe")
    runner = FakeRunner({
        (native, "--version"): _ok([], "2.1\n"),
        (native, "auth", "status", "--json"): _ok([], '{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "pro"}'),
    })
    login = _by_id(run_doctor(runner, paths, WispConfig(), {"claude_login"}))["claude_login"]
    assert login.ok and login.data == {"authMethod": "claude.ai", "subscriptionType": "pro"}


def test_telegram_state_comes_from_the_task_scheduler(fake_home):
    from wisp.config import TelegramConfig
    cfg = WispConfig(telegram=TelegramConfig(1, 2, "tok"))
    row = ",".join(f'"{c}"' for c in ["PC", "\\ai.wisp.bot", "N/A", "Running", "x", "x", "267009", "a", "c", "N/A", "N/A", "Enabled"])
    runner = _runner(**{"schtasks.exe|/Query": _ok([], row)})
    check = _by_id(run_doctor(runner, _paths(fake_home), cfg, {"telegram"}))["telegram"]
    assert check.ok and check.data == {"job": "running"}


def test_codex_is_optional_and_found_in_npm_folder(fake_home):
    paths = _paths(fake_home)
    shim = str(paths.config.parent / "npm/codex.cmd")
    runner = FakeRunner({(shim, "--version"): _ok([], "codex 1\n"), (shim, "login", "status"): _ok([], "ok")})
    checks = _by_id(run_doctor(runner, paths, WispConfig(), {"codex", "codex_login"}))
    assert checks["codex"].ok and checks["codex_login"].ok
