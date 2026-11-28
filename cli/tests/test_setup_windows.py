from dataclasses import replace

from wisp.config import WispConfig, load_config
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult
from wisp.setup.brain import setup_brain
from wisp.setup.system import setup_system
from wisp.setup.windows import CLAUDE_INSTALL_URL, GIT_ID, WINGET_CLAUDE_ID

OK = RunResult([], 0, "", "")
BAD = RunResult([], 1, "", "boom")


def _paths(home):
    windows = WispPaths.for_os("Windows", home, {"APPDATA": str(home / "AppData/Roaming"), "LOCALAPPDATA": str(home / "AppData/Local")})
    return replace(windows, state=home / "AppData/Local/wisp/state")


class Machine(FakeRunner):

    def __init__(self, home, *, git=True, claude=False, installs=None, script=None):
        super().__init__(script or {})
        self.native = str(home / ".local/bin/claude.exe")
        self.present = {"git": git, "claude": claude}
        self.installs = installs or {}

    def run(self, argv, **kw):
        args = list(argv)
        self.calls.append(args)
        if args[:2] == ["git", "--version"]:
            return RunResult(args, 0 if self.present["git"] else 127, "git version 2.47\n", "")
        if args[:2] == [self.native, "--version"]:
            return RunResult(args, 0 if self.present["claude"] else 127, "2.1.0 (Claude Code)\n", "")
        for prefix, (result, effect) in self.installs.items():
            if tuple(args[: len(prefix)]) == prefix:
                if result.exit == 0 and effect:
                    self.present[effect] = True
                return result
        return RunResult(args, 127, "", "no scripted result")


def test_everything_present_is_skipped_and_saves_the_native_path(fake_home):
    machine = Machine(fake_home, claude=True)
    report = setup_system(machine, _paths(fake_home), WispConfig(), with_homebrew=False, dry_run=False)
    assert report.status == "skipped" and report.summary == "tudo pronto"
    assert report.data == {"claude": machine.native, "claude_version": "2.1.0 (Claude Code)", "claude_kind": "native"}
    assert load_config().claude_bin == machine.native
    assert not any(call[0] in ("winget.exe", "powershell.exe") for call in machine.calls)


def test_dry_run_lists_what_is_missing_and_runs_nothing_that_installs(fake_home):
    machine = Machine(fake_home, git=False)
    report = setup_system(machine, _paths(fake_home), WispConfig(), with_homebrew=False, dry_run=True)
    assert report.status == "done" and report.data["missing"] == "git,claude"
    assert all(call[-1] == "--version" for call in machine.calls)


def test_missing_claude_runs_the_official_installer_through_a_downloaded_script(fake_home):
    machine = Machine(fake_home, installs={
        ("curl.exe", "--fail"): (OK, None),
        ("powershell.exe",): (RunResult([], 0, "installed", ""), "claude"),
    })
    report = setup_system(machine, _paths(fake_home), WispConfig(), with_homebrew=False, dry_run=False)
    assert report.status == "done" and report.summary == "o Claude foi instalado"
    curl = next(c for c in machine.calls if c[0] == "curl.exe")
    assert curl[-1] == CLAUDE_INSTALL_URL and "--proto" in curl
    ps = next(c for c in machine.calls if c[0] == "powershell.exe")
    assert ps[:5] == ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass"] and ps[5] == "-File"
    assert [d.command.split()[0] for d in report.details][:2] == ["curl.exe", "powershell.exe"]
    assert not (fake_home / "AppData/Local/wisp/state/downloads/claude-install.ps1").exists()


def test_failed_official_installer_falls_back_to_winget(fake_home):
    machine = Machine(fake_home, installs={
        ("curl.exe", "--fail"): (BAD, None),
        ("winget.exe", "install", "--id", WINGET_CLAUDE_ID): (OK, "claude"),
    })
    report = setup_system(machine, _paths(fake_home), WispConfig(), with_homebrew=False, dry_run=False)
    assert report.status == "done"
    winget = next(c for c in machine.calls if c[0] == "winget.exe")
    assert "--accept-package-agreements" in winget and "--accept-source-agreements" in winget and "-e" in winget


def test_both_installers_failing_reports_failed_with_the_commands_that_ran(fake_home):
    machine = Machine(fake_home, installs={("curl.exe",): (BAD, None), ("winget.exe",): (BAD, None)})
    report = setup_system(machine, _paths(fake_home), WispConfig(), with_homebrew=False, dry_run=False)
    assert report.status == "failed" and report.summary == "não consegui instalar o Claude"
    assert [d.command.split()[0] for d in report.details] == ["curl.exe", "winget.exe"]
    assert report.details[0].exit == 1 and "boom" in report.details[0].output


def test_missing_git_goes_through_winget_then_continues(fake_home):
    machine = Machine(fake_home, git=False, claude=True, installs={("winget.exe", "install", "--id", GIT_ID): (OK, "git")})
    report = setup_system(machine, _paths(fake_home), WispConfig(), with_homebrew=False, dry_run=False)
    assert report.status == "done" and report.summary == "o Git foi instalado"
    assert report.data["claude_kind"] == "native"


def test_git_that_winget_cannot_finish_waits_for_the_user(fake_home):
    machine = Machine(fake_home, git=False, installs={("winget.exe", "install", "--id", GIT_ID): (OK, None)})
    report = setup_system(machine, _paths(fake_home), WispConfig(), with_homebrew=False, dry_run=False)
    assert report.status == "needs_user" and report.data == {"waiting": "git"}


def test_git_install_failure_is_reported(fake_home):
    machine = Machine(fake_home, git=False, installs={("winget.exe",): (BAD, None)})
    report = setup_system(machine, _paths(fake_home), WispConfig(), with_homebrew=False, dry_run=False)
    assert report.status == "failed" and report.summary == "não consegui instalar o Git"


def test_brain_on_windows_needs_git_not_xcode(fake_home):
    machine = Machine(fake_home, git=False)
    report = setup_brain(machine, _paths(fake_home), WispConfig(), path=None, dry_run=False)
    assert report.status == "failed" and report.summary == "falta o Git" and report.data == {"step": "system"}
    assert not any(call[0] == "xcode-select" for call in machine.calls)


def test_brain_on_windows_uses_the_located_git_and_skips_the_mac_folder_warning(fake_home, monkeypatch):
    monkeypatch.setenv("ProgramFiles", r"C:\Program Files")
    full = r"C:\Program Files\Git\cmd\git.exe"
    brain = fake_home / "Documents/brain"

    class StaleGit(FakeRunner):
        def run(self, argv, **kw):
            args = list(argv)
            self.calls.append(args)
            if args[0] == "git":
                return RunResult(args, 127, "", "")
            if args[0] == full and args[-1] == "--version":
                return RunResult(args, 0, "git version 2", "")
            if "rev-parse" in args:
                return RunResult(args, 128, "", "")
            if "init" in args:
                (brain / ".git").mkdir(parents=True, exist_ok=True)
            return RunResult(args, 0, "x\n", "")

    runner = StaleGit()
    report = setup_brain(runner, _paths(fake_home), WispConfig(), path=brain, dry_run=False)
    assert report.status == "done", report
    assert "warning" not in report.data
    assert [c for c in runner.calls if "init" in c][0][:3] == [full, "-C", str(brain)]
    assert not any(c[0] == "git" and "-C" in c for c in runner.calls)


def test_telegram_status_probe_runs_the_scripts_wisp_exe_on_windows(fake_home, monkeypatch):
    import sys

    from wisp.setup.telegram import _status_up

    monkeypatch.setattr(sys, "platform", "win32")
    runner = FakeRunner()
    _status_up(runner, _paths(fake_home))
    assert runner.calls[0][0].replace("/", "\\").endswith("venv\\Scripts\\wisp.exe")
    assert runner.calls[0][1:] == ["topic", "status", "--json"]
