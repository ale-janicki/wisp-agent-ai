import json
import subprocess
from pathlib import Path

import pytest

from wisp.cli import main
from wisp.config import WispConfig, load_config
from wisp.paths import WispPaths, resources_root
from wisp.runner import FakeRunner, RunResult, SubprocessRunner
from wisp.setup.brain import setup_brain

CLT_OK = subprocess.run(["xcode-select", "-p"], capture_output=True).returncode == 0
needs_git = pytest.mark.skipif(not CLT_OK, reason="no Command Line Tools")


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _git(path, *args):
    return subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True, check=True).stdout.strip()


def test_resources_root_env_override(monkeypatch, tmp_path):
    assert (resources_root() / "vault-template/index.md").is_file()
    monkeypatch.setenv("WISP_RESOURCES", str(tmp_path))
    assert resources_root() == tmp_path


@needs_git
def test_creates_vault_from_template_and_git_inits(fake_home):
    report = setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    brain = fake_home / "Wisp/brain"
    assert report.status == "done"
    assert report.data == {"path": str(brain)}
    for name in ("index.md", "pendencias.md", "convencoes.md", "notas/.gitkeep", ".gitignore"):
        assert (brain / name).is_file()
    assert len(_git(brain, "log", "--oneline").splitlines()) == 1
    assert load_config().brain == str(brain)
    assert "[[pendencias]]" in (brain / "index.md").read_text()


@needs_git
def test_rerun_is_skipped_without_new_commit(fake_home):
    setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    report = setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    assert report.status == "skipped"
    assert len(_git(fake_home / "Wisp/brain", "log", "--oneline").splitlines()) == 1


@needs_git
def test_existing_dir_keeps_user_files(fake_home):
    brain = fake_home / "mine"
    brain.mkdir()
    (brain / "index.md").write_bytes("meu\n".encode())
    report = setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=brain, dry_run=False)
    assert report.status == "done"
    assert (brain / "index.md").read_bytes() == "meu\n".encode()
    assert (brain / "pendencias.md").is_file()
    assert (brain / "convencoes.md").is_file()


@needs_git
def test_commit_works_without_global_git_identity(fake_home):
    assert not (fake_home / ".gitconfig").exists()
    cfg = WispConfig(user_name="Rafa")
    setup_brain(SubprocessRunner(), _paths(fake_home), cfg, path=None, dry_run=False)
    brain = fake_home / "Wisp/brain"
    assert _git(brain, "config", "--local", "user.name") == "Rafa"
    assert _git(brain, "config", "--local", "user.email") == "wisp@localhost"
    assert _git(brain, "log", "-1", "--format=%an") == "Rafa"


@needs_git
def test_identity_defaults_to_wisp(fake_home):
    setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    assert _git(fake_home / "Wisp/brain", "config", "--local", "user.name") == "Wisp"


@needs_git
@pytest.mark.parametrize("folder", ["Documents", "Desktop", "Downloads", "Library/Mobile Documents"])
def test_warns_for_tcc_protected_location(fake_home, folder):
    report = setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=fake_home / folder / "brain", dry_run=False)
    assert report.status == "done"
    assert "warning" in report.data


@needs_git
def test_no_warning_for_default_location(fake_home):
    report = setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    assert "warning" not in report.data


def test_git_missing_reports_needs_system(fake_home):
    runner = FakeRunner({("xcode-select", "-p"): RunResult(["xcode-select", "-p"], 2, "", "")})
    report = setup_brain(runner, _paths(fake_home), WispConfig(), path=None, dry_run=False)
    assert report.status == "failed"
    assert report.data["step"] == "system"
    assert [c for c in runner.calls if c[0] in ("git", "/usr/bin/git")] == []
    assert not (fake_home / "Wisp").exists()


def test_dry_run_writes_nothing(fake_home):
    runner = FakeRunner({("xcode-select", "-p"): RunResult(["xcode-select", "-p"], 0, "", "")})
    report = setup_brain(runner, _paths(fake_home), WispConfig(), path=None, dry_run=True)
    assert report.status == "done"
    assert not (fake_home / "Wisp").exists()
    assert not (fake_home / ".config/wisp/wisp.json").exists()
    assert [c for c in runner.calls if c[0] == "git"] == []


@needs_git
def test_cli_prints_one_json_object(fake_home, capsys):
    assert main(["setup", "brain", "--path", str(fake_home / "b"), "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["step"] == "brain"
    assert out["status"] == "done"


def _failing_hook_home(fake_home):
    hooks = fake_home / "hooks"
    hooks.mkdir()
    hook = hooks / "pre-commit"
    hook.write_text("#!/bin/sh\nexit 1\n")
    hook.chmod(0o755)
    (fake_home / ".gitconfig").write_text(f"[core]\n\thooksPath = {hooks}\n")
    return hook


@needs_git
def test_rerun_after_failed_commit_commits_instead_of_skipping(fake_home):
    hook = _failing_hook_home(fake_home)
    brain = fake_home / "Wisp/brain"
    first = setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    assert first.status == "failed"
    hook.unlink()
    second = setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    assert second.status == "done"
    assert len(_git(brain, "log", "--oneline").splitlines()) == 1
    assert "index.md" in _git(brain, "ls-tree", "-r", "--name-only", "HEAD")


@needs_git
def test_existing_repo_with_missing_files_adds_a_commit(fake_home):
    brain = fake_home / "Wisp/brain"
    setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    (brain / "convencoes.md").unlink()
    _git(brain, "commit", "-am", "drop convencoes")
    report = setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    assert report.status == "done"
    assert _git(brain, "log", "-1", "--format=%s") == "chore: add missing template files"
    assert len(_git(brain, "log", "--oneline").splitlines()) == 3


@needs_git
def test_commit_leaves_user_staged_files_out(fake_home):
    brain = fake_home / "Wisp/brain"
    setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    (brain / "convencoes.md").unlink()
    _git(brain, "commit", "-am", "drop convencoes")
    (brain / "mine.md").write_text("x\n")
    _git(brain, "add", "mine.md")
    setup_brain(SubprocessRunner(), _paths(fake_home), WispConfig(), path=None, dry_run=False)
    assert _git(brain, "show", "--name-only", "--format=", "HEAD") == "convencoes.md"
    assert _git(brain, "diff", "--cached", "--name-only") == "mine.md"


@needs_git
def test_cli_outside_home_prints_failed_json(fake_home, capsys):
    assert main(["setup", "brain", "--path", "/tmp/wisp-outside-home-test", "--json"]) == 1
    out = json.loads(capsys.readouterr().out)
    assert out["status"] == "failed"
    assert not Path("/tmp/wisp-outside-home-test").exists()


@needs_git
def test_cli_path_is_a_file_prints_failed_json(fake_home, capsys):
    target = fake_home / "afile"
    target.write_text("x")
    assert main(["setup", "brain", "--path", str(target), "--json"]) == 1
    assert json.loads(capsys.readouterr().out)["status"] == "failed"


@needs_git
def test_cli_corrupt_config_falls_back_with_warning(fake_home, capsys):
    config = fake_home / ".config/wisp/wisp.json"
    config.parent.mkdir(parents=True)
    config.write_text("{not json")
    assert main(["setup", "brain", "--path", str(fake_home / "b"), "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["status"] == "done"
    assert out["data"]["warning"] == "não consegui ler o wisp.json; o Wisp usou os valores padrão"
