import shlex
import stat
import sys

import pytest

from wisp.cli import main
from wisp.paths import WispPaths
from wisp.setup.shim import MARKER, setup_shim

import json


WINDOWS = sys.platform == "win32"
posix_only = pytest.mark.skipif(WINDOWS, reason="POSIX shim: a /bin/sh script with mode bits")


def _paths(home):
    return WispPaths.for_os("Windows" if WINDOWS else "Darwin", home, {})


def _shim(paths):
    return paths.bin / ("wisp.cmd" if WINDOWS else "wisp")


def _foreign():
    return "@echo off\r\necho mine\r\n" if WINDOWS else "#!/bin/sh\necho mine\n"


def _stale():
    return f"@echo off\r\nrem {MARKER}\r\n\"C:\\old\\wisp.exe\" %*\r\n" if WINDOWS else f'#!/bin/sh\n{MARKER}\nexec "/old/venv/bin/wisp" "$@"\n'


@posix_only
def test_shim_written_executable(fake_home):
    paths = _paths(fake_home)
    report = setup_shim(paths)
    shim = paths.bin / "wisp"
    assert report.status == "done"
    assert shim.read_text() == f'#!/bin/sh\n{MARKER}\nexec {shlex.quote(str(paths.runtime / "venv/bin/wisp"))} "$@"\n'
    assert stat.S_IMODE(shim.stat().st_mode) == 0o755


@pytest.mark.skipif(not WINDOWS, reason="Windows shim: a .cmd launcher")
def test_shim_written_as_cmd_on_windows(fake_home):
    paths = _paths(fake_home)
    assert setup_shim(paths).status == "done"
    raw = (paths.bin / "wisp.cmd").read_bytes()
    assert raw == f'@echo off\r\nrem {MARKER}\r\n"{paths.runtime / "venv" / "Scripts" / "wisp.exe"}" %*\r\n'.encode()


def test_shim_refuses_foreign_file(fake_home):
    paths = _paths(fake_home)
    paths.bin.mkdir(parents=True)
    _shim(paths).write_bytes(_foreign().encode())
    report = setup_shim(paths)
    assert report.status == "failed"
    assert _shim(paths).read_bytes() == _foreign().encode()


@posix_only
def test_shim_refuses_symlink(fake_home):
    paths = _paths(fake_home)
    paths.bin.mkdir(parents=True)
    target = fake_home / "real"
    target.write_text("x")
    (paths.bin / "wisp").symlink_to(target)
    assert setup_shim(paths).status == "failed"
    assert target.read_text() == "x"


def test_shim_rerun_skipped(fake_home):
    paths = _paths(fake_home)
    setup_shim(paths)
    assert setup_shim(paths).status == "skipped"


def test_shim_ours_but_stale_is_updated(fake_home):
    paths = _paths(fake_home)
    paths.bin.mkdir(parents=True)
    _shim(paths).write_bytes(_stale().encode())
    assert setup_shim(paths).status == "done"
    assert str(paths.runtime) in _shim(paths).read_text()


def test_cli_shim_json(fake_home, capsys):
    assert main(["setup", "shim", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["step"] == "shim"
    assert (WispPaths.current().bin / ("wisp.cmd" if WINDOWS else "wisp")).is_file()


@posix_only
def test_shim_quotes_runtime_path(fake_home):
    paths = WispPaths.for_os("Darwin", fake_home, {"XDG_DATA_HOME": str(fake_home / "my data")})
    setup_shim(paths)
    assert "'" in (paths.bin / "wisp").read_text() and "my data" in (paths.bin / "wisp").read_text()


def test_shim_windows_writes_cmd(fake_home, monkeypatch):
    from wisp import paths as wp

    monkeypatch.setattr(wp.sys, "platform", "win32")
    paths = WispPaths.for_os("Windows", fake_home, {})
    from wisp.setup import shim as sh

    assert sh._content(paths) == f'@echo off\r\nrem {MARKER}\r\n"{paths.runtime / "venv" / "Scripts" / "wisp.exe"}" %*\r\n'
    assert sh._target(paths).name == "wisp.cmd"
