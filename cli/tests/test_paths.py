from pathlib import Path, PureWindowsPath

from wisp.paths import WispPaths


def test_darwin_layout(fake_home):
    p = WispPaths.for_os("Darwin", fake_home, {})
    assert p.home == fake_home
    assert p.config == fake_home / ".config/wisp"
    assert p.runtime == fake_home / ".local/share/wisp/runtime"
    assert p.state == fake_home / ".local/state/wisp"
    assert p.bin == fake_home / ".local/bin"
    assert p.launch_agents == fake_home / "Library/LaunchAgents"


def test_linux_honors_xdg(fake_home):
    env = {"XDG_CONFIG_HOME": "/x/c", "XDG_STATE_HOME": "/x/s", "XDG_DATA_HOME": "/x/d"}
    p = WispPaths.for_os("Linux", fake_home, env)
    assert p.config == Path("/x/c/wisp")
    assert p.state == Path("/x/s/wisp")
    assert p.runtime == Path("/x/d/wisp/runtime")
    assert p.bin == fake_home / ".local/bin"
    assert p.launch_agents is None


def test_windows_uses_appdata(fake_home):
    env = {"APPDATA": "C:\\U\\a", "LOCALAPPDATA": "C:\\U\\l"}
    p = WispPaths.for_os("Windows", fake_home, env)
    assert p.config == PureWindowsPath("C:/U/a/wisp")
    assert p.runtime == PureWindowsPath("C:/U/l/wisp/runtime")
    assert p.state == PureWindowsPath("C:/U/l/wisp/state")
    assert p.bin == PureWindowsPath("C:/U/l/wisp/bin")
    assert p.launch_agents is None


def test_windows_falls_back_without_appdata(fake_home):
    p = WispPaths.for_os("Windows", fake_home, {})
    assert p.config == PureWindowsPath(fake_home / "AppData/Roaming" / "wisp")
    assert p.runtime == PureWindowsPath(fake_home / "AppData/Local" / "wisp" / "runtime")
    assert p.state == PureWindowsPath(fake_home / "AppData/Local" / "wisp" / "state")


def test_venv_bin_and_exe_per_platform(monkeypatch):
    from wisp import paths as wp

    monkeypatch.setattr(wp.sys, "platform", "win32")
    assert wp.venv_bin(Path("v")) == Path("v") / "Scripts"
    assert wp.exe("wisp") == "wisp.exe"
    monkeypatch.setattr(wp.sys, "platform", "darwin")
    assert wp.venv_bin(Path("v")) == Path("v") / "bin"
    assert wp.exe("wisp") == "wisp"
