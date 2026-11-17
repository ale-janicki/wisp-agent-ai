import stat
from pathlib import Path

import pytest

from wisp.fsops import OutsideHome, atomic_write, copy_file


def test_atomic_write_inside_home(fake_home):
    target = fake_home / "a/b.txt"
    atomic_write(target, "oi")
    assert target.read_text() == "oi"


def test_write_outside_home_raises(fake_home):
    with pytest.raises(OutsideHome):
        atomic_write(Path("/tmp/x"), "no")


def test_mode_0600_respected(fake_home):
    target = fake_home / "secret"
    atomic_write(target, b"t", mode=0o600)
    assert stat.S_IMODE(target.stat().st_mode) == 0o600


def test_copy_file_inside_home(fake_home):
    src = fake_home / "s"
    src.write_text("x")
    copy_file(src, fake_home / "d/s")
    assert (fake_home / "d/s").read_text() == "x"


def test_dotdot_escape_raises(fake_home):
    with pytest.raises(OutsideHome):
        atomic_write(fake_home / ".." / "escaped.txt", "no")


def test_symlink_escape_raises(fake_home, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (fake_home / "link").symlink_to(outside)
    with pytest.raises(OutsideHome):
        atomic_write(fake_home / "link/file.txt", "no")
    assert not (outside / "file.txt").exists()
