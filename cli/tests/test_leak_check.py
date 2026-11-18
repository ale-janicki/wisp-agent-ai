import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/leak-check.sh"
needs_gitleaks = pytest.mark.skipif(shutil.which("gitleaks") is None, reason="gitleaks not installed")


def _run(*dirs):
    return subprocess.run([str(SCRIPT), *map(str, dirs)], capture_output=True, text=True, cwd=ROOT)


@needs_gitleaks
def test_leak_check_flags_planted_file(tmp_path):
    first = (ROOT / "scripts/leak-patterns.txt").read_text().splitlines()[0]
    (tmp_path / "planted.txt").write_text("see " + first.replace("[a-z]", "a") + "\n")
    result = _run(tmp_path)
    assert result.returncode == 1
    assert "planted.txt" in result.stdout + result.stderr


@needs_gitleaks
def test_leak_check_flags_secret_shape(tmp_path):
    (tmp_path / "s.txt").write_text("k = " + "AKIA" + "B" * 16 + "\n")
    assert _run(tmp_path).returncode == 1


@needs_gitleaks
def test_clean_dir_passes(tmp_path):
    (tmp_path / "ok.txt").write_text("hello\n")
    assert _run(tmp_path).returncode == 0


@needs_gitleaks
def test_shipped_tree_is_clean():
    result = _run("cli", "vault-template")
    assert result.returncode == 0, result.stdout + result.stderr


def test_missing_gitleaks_fails_loudly(tmp_path):
    bare = tmp_path / "bin"
    bare.mkdir()
    for tool in ("bash", "grep", "cat", "dirname", "mktemp", "rm"):
        found = shutil.which(tool)
        if found:
            (bare / tool).symlink_to(found)
    result = subprocess.run(["/bin/bash", str(SCRIPT), str(tmp_path)], capture_output=True, text=True, cwd=ROOT, env={"PATH": str(bare)})
    assert result.returncode == 1
    assert "gitleaks" in result.stderr


@needs_gitleaks
def test_missing_default_dir_is_an_error(tmp_path):
    (tmp_path / "scripts").mkdir()
    shutil.copy(SCRIPT, tmp_path / "scripts/leak-check.sh")
    for name in ("app", "core", "cli", "bot", "docs", "vault-template"):
        (tmp_path / name).mkdir()
    result = subprocess.run([str(tmp_path / "scripts/leak-check.sh")], capture_output=True, text=True)
    assert result.returncode == 1
    assert "harness" in result.stderr


@needs_gitleaks
def test_grep_read_error_is_a_failure(tmp_path):
    (tmp_path / "scripts").mkdir()
    shutil.copy(SCRIPT, tmp_path / "scripts/leak-check.sh")
    (tmp_path / "scripts/leak-patterns.txt").write_text("zzz-never-matches\n")
    (tmp_path / "scripts/gitleaks").write_text("#!/bin/sh\nexit 0\n")
    (tmp_path / "scripts/gitleaks").chmod(0o755)
    (tmp_path / "scripts/uv").write_text("#!/bin/sh\nexit 0\n")
    (tmp_path / "scripts/uv").chmod(0o755)
    locked = tmp_path / "d"
    locked.mkdir()
    (locked / "f.txt").write_text("x")
    locked.chmod(0)
    env = {"PATH": f"{tmp_path / 'scripts'}:/usr/bin:/bin"}
    try:
        result = subprocess.run([str(tmp_path / "scripts/leak-check.sh"), str(locked)], capture_output=True, text=True, env=env)
    finally:
        locked.chmod(0o755)
    assert result.returncode == 1


def _default_scope_tree(tmp_path):
    (tmp_path / "scripts").mkdir()
    shutil.copy(SCRIPT, tmp_path / "scripts/leak-check.sh")
    (tmp_path / "scripts/leak-patterns.txt").write_text("planted-marker\n")
    (tmp_path / "scripts/uv").write_text("#!/bin/sh\nexit 0\n")
    (tmp_path / "scripts/uv").chmod(0o755)
    for name in ("app", "core", "cli", "bot", "harness", "docs", "vault-template"):
        (tmp_path / name).mkdir()
    return {"PATH": f"{tmp_path / 'scripts'}:{shutil.which('gitleaks') and Path(shutil.which('gitleaks')).parent}:/usr/bin:/bin"}


@needs_gitleaks
def test_default_scope_covers_docs_and_core_but_skips_runtime_build_and_patterns(tmp_path):
    env = _default_scope_tree(tmp_path)
    script = str(tmp_path / "scripts/leak-check.sh")
    (tmp_path / "app/Resources/runtime").mkdir(parents=True)
    (tmp_path / "app/Resources/runtime/vendored.txt").write_text("planted-marker\n")
    (tmp_path / "core/build").mkdir()
    (tmp_path / "core/build/out.txt").write_text("planted-marker\n")
    assert subprocess.run([script], capture_output=True, text=True, env=env).returncode == 0
    for folder in ("docs", "core/Tests", "app/Sources", "scripts"):
        planted = tmp_path / folder / "n.md"
        planted.parent.mkdir(parents=True, exist_ok=True)
        planted.write_text("planted-marker\n")
        assert subprocess.run([script], capture_output=True, text=True, env=env).returncode == 1, folder
        planted.unlink()
