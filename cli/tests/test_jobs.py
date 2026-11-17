import plistlib
from pathlib import Path

import pytest

from wisp.jobs import JobSpec, JobState, NotSupportedHere, manager_for
from wisp.jobs.launchd import LaunchdJobs
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult

LABEL = "com.example.job"
UID = 501
DOMAIN = f"gui/{UID}"


def _spec(home):
    return JobSpec(LABEL, ["/bin/echo", "hi"], {"A": "b"}, home / "logs/job.log")


def _result(argv, exit=0, out=""):
    return RunResult(argv, exit, out, "")


def _manager(home, script=None):
    paths = WispPaths.for_os("Darwin", home, {})
    runner = FakeRunner(script)
    return LaunchdJobs(paths, runner, UID), runner, paths.launch_agents / f"{LABEL}.plist"


def test_render_plist_round_trips(fake_home):
    spec = _spec(fake_home)
    data = plistlib.loads(LaunchdJobs.render_plist(spec))
    assert data["Label"] == LABEL
    assert data["ProgramArguments"] == ["/bin/echo", "hi"]
    assert data["EnvironmentVariables"] == {"A": "b"}
    assert data["KeepAlive"] is True
    assert data["RunAtLoad"] is True
    assert data["ThrottleInterval"] == 10
    assert data["StandardOutPath"] == data["StandardErrorPath"] == str(spec.log_path)


def test_install_writes_plist_then_bootstraps(fake_home):
    manager, runner, plist = _manager(fake_home, {("launchctl", "bootstrap"): _result([])})
    details = manager.install(_spec(fake_home))
    assert plist.exists()
    assert runner.calls[-1] == ["launchctl", "bootstrap", DOMAIN, str(plist)]
    assert details[-1].exit == 0


def test_install_reloads_existing(fake_home):
    for code in (0, 3, 113):
        manager, runner, plist = _manager(
            fake_home,
            {("launchctl", "bootout"): _result([], code), ("launchctl", "bootstrap"): _result([])},
        )
        manager.install(_spec(fake_home))
        assert runner.calls == [
            ["launchctl", "bootout", f"{DOMAIN}/{LABEL}"],
            ["launchctl", "bootstrap", DOMAIN, str(plist)],
        ]


def test_install_load_false_never_calls_launchctl(fake_home):
    manager, runner, plist = _manager(fake_home)
    assert manager.install(_spec(fake_home), load=False) == []
    assert plist.exists()
    assert runner.calls == []


def test_remove_boots_out_and_deletes_plist(fake_home):
    manager, runner, plist = _manager(fake_home, {("launchctl", "bootout"): _result([])})
    manager.install(_spec(fake_home), load=False)
    manager.remove(LABEL)
    assert runner.calls == [["launchctl", "bootout", f"{DOMAIN}/{LABEL}"]]
    assert not plist.exists()


PRINT_RUNNING = f"{DOMAIN}/{LABEL} = {{\n\tstate = running\n\tpid = 42\n\tlast exit code = 1\n\tcoalition = {{\n\t\tstate = active\n\t}}\n}}\n"
PRINT_FAILED = f"{DOMAIN}/{LABEL} = {{\n\tstate = not running\n\tlast exit code = 1\n}}\n"
PRINT_IDLE = f"{DOMAIN}/{LABEL} = {{\n\tstate = not running\n\tlast exit code = (never exited)\n}}\n"
PRINT_NESTED_ONLY = f"{DOMAIN}/{LABEL} = {{\n\tstate = not running\n\tcoalition = {{\n\t\tstate = running\n\t}}\n}}\n"


@pytest.mark.parametrize(
    ("out", "expected"),
    [(PRINT_RUNNING, JobState.RUNNING), (PRINT_FAILED, JobState.FAILED), (PRINT_IDLE, JobState.INSTALLED), (PRINT_NESTED_ONLY, JobState.INSTALLED)],
)
def test_state_parses_print(fake_home, out, expected):
    manager, _, _ = _manager(fake_home, {("launchctl", "print"): _result([], 0, out)})
    assert manager.state(LABEL) == expected


def test_state_not_loaded_depends_on_plist(fake_home):
    manager, runner, plist = _manager(fake_home, {("launchctl", "print"): _result([], 113)})
    assert manager.state(LABEL) == JobState.NOT_INSTALLED
    manager.install(_spec(fake_home), load=False)
    assert manager.state(LABEL) == JobState.INSTALLED
    assert runner.calls[0] == ["launchctl", "print", f"{DOMAIN}/{LABEL}"]


@pytest.mark.parametrize("system", ["Linux", "Windows"])
def test_linux_and_windows_raise_not_supported(fake_home, system):
    manager = manager_for(system, WispPaths.for_os(system, fake_home, {"APPDATA": "C:/a", "LOCALAPPDATA": "C:/l"}), FakeRunner(), UID)
    with pytest.raises(NotSupportedHere):
        manager.install(_spec(fake_home))
    with pytest.raises(NotSupportedHere):
        manager.remove(LABEL)
    with pytest.raises(NotSupportedHere):
        manager.state(LABEL)


def test_darwin_gets_launchd(fake_home):
    assert isinstance(manager_for("Darwin", WispPaths.for_os("Darwin", fake_home, {}), FakeRunner(), UID), LaunchdJobs)
