import shlex
import stat

from wisp.cli import main
from wisp.paths import WispPaths
from wisp.setup.shim import MARKER, setup_shim

import json


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def test_shim_written_executable(fake_home):
    paths = _paths(fake_home)
    report = setup_shim(paths)
    shim = paths.bin / "wisp"
    assert report.status == "done"
    assert shim.read_text() == f'#!/bin/sh\n{MARKER}\nexec {shlex.quote(str(paths.runtime / "venv/bin/wisp"))} "$@"\n'
    assert stat.S_IMODE(shim.stat().st_mode) == 0o755


def test_shim_refuses_foreign_file(fake_home):
    paths = _paths(fake_home)
    paths.bin.mkdir(parents=True)
    (paths.bin / "wisp").write_text("#!/bin/sh\necho mine\n")
    report = setup_shim(paths)
    assert report.status == "failed"
    assert (paths.bin / "wisp").read_text() == "#!/bin/sh\necho mine\n"


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
    (paths.bin / "wisp").write_text(f'#!/bin/sh\n{MARKER}\nexec "/old/venv/bin/wisp" "$@"\n')
    assert setup_shim(paths).status == "done"
    assert str(paths.runtime) in (paths.bin / "wisp").read_text()


def test_cli_shim_json(fake_home, capsys):
    assert main(["setup", "shim", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["step"] == "shim"
    assert (fake_home / ".local/bin/wisp").is_file()


def test_shim_quotes_runtime_path(fake_home):
    paths = WispPaths.for_os("Darwin", fake_home, {"XDG_DATA_HOME": str(fake_home / "my data")})
    setup_shim(paths)
    assert "'" in (paths.bin / "wisp").read_text() and "my data" in (paths.bin / "wisp").read_text()
