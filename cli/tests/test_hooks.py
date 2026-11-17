import subprocess
from datetime import date

import pytest

from wisp.cli import main
from wisp.config import WispConfig
from wisp.hooks import hook_boot, hook_brain_commit
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, SubprocessRunner

CLT_OK = subprocess.run(["xcode-select", "-p"], capture_output=True).returncode == 0
needs_git = pytest.mark.skipif(not CLT_OK, reason="no Command Line Tools")


def _git(path, *args):
    return subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True, check=True).stdout.strip()


def _brain(home):
    brain = home / "Wisp/brain"
    brain.mkdir(parents=True)
    _git(brain, "init", "-b", "main")
    _git(brain, "config", "user.name", "Test")
    _git(brain, "config", "user.email", "test@localhost")
    (brain / "pendencias.md").write_text("# Pendências\n")
    _git(brain, "add", "pendencias.md")
    _git(brain, "commit", "-m", "start")
    return brain


def test_boot_prints_pendencias(fake_home):
    brain = fake_home / "Wisp/brain"
    brain.mkdir(parents=True)
    (brain / "pendencias.md").write_text("\n".join(f"linha {i}" for i in range(100)))
    out = hook_boot(WispConfig(brain=str(brain)), WispPaths.current())
    assert date.today().isoformat() in out
    assert str(brain) in out
    assert "linha 0" in out and "linha 59" in out
    assert "linha 60" not in out


def test_boot_without_brain_is_silent_exit0(fake_home, capsys):
    assert hook_boot(WispConfig(), WispPaths.current()) == ""
    assert hook_boot(WispConfig(brain=str(fake_home / "missing")), WispPaths.current()) == ""
    assert main(["hook", "boot"]) == 0
    assert capsys.readouterr().out == ""


def test_boot_without_pendencias_file_still_names_the_brain(fake_home):
    brain = fake_home / "Wisp/brain"
    brain.mkdir(parents=True)
    out = hook_boot(WispConfig(brain=str(brain)), WispPaths.current())
    assert str(brain) in out


@needs_git
def test_brain_commit_commits_changes(fake_home):
    brain = _brain(fake_home)
    (brain / "nota.md").write_text("oi\n")
    (brain / "pendencias.md").write_text("# Pendências\n- algo\n")
    assert hook_brain_commit(WispConfig(brain=str(brain)), SubprocessRunner()) == 0
    assert _git(brain, "status", "--porcelain") == ""
    assert len(_git(brain, "log", "--oneline").splitlines()) == 2
    assert "nota.md" in _git(brain, "show", "--stat", "--format=", "HEAD")


@needs_git
def test_brain_commit_commits_a_deletion(fake_home):
    brain = _brain(fake_home)
    (brain / "pendencias.md").unlink()
    assert hook_brain_commit(WispConfig(brain=str(brain)), SubprocessRunner()) == 0
    assert _git(brain, "status", "--porcelain") == ""


@needs_git
def test_brain_commit_works_without_any_git_identity(fake_home):
    brain = _brain(fake_home)
    _git(brain, "config", "--unset", "user.name")
    _git(brain, "config", "--unset", "user.email")
    (brain / "nota.md").write_text("oi\n")
    assert hook_brain_commit(WispConfig(brain=str(brain)), SubprocessRunner()) == 0
    assert _git(brain, "status", "--porcelain") == ""


@needs_git
def test_brain_commit_holds_back_secret_file(fake_home, capsys):
    brain = _brain(fake_home)
    token = "sk-" + "a1b2c3d4" * 4
    (brain / "chaves.md").write_text(f"minha chave {token}\n")
    (brain / "nota.md").write_text("oi\n")
    assert hook_brain_commit(WispConfig(brain=str(brain)), SubprocessRunner()) == 0
    err = capsys.readouterr().err
    assert "chaves.md" in err
    assert token not in err
    assert _git(brain, "status", "--porcelain") == "?? chaves.md"
    assert "nota.md" in _git(brain, "show", "--stat", "--format=", "HEAD")


@needs_git
def test_brain_commit_noop_when_clean(fake_home):
    brain = _brain(fake_home)
    assert hook_brain_commit(WispConfig(brain=str(brain)), SubprocessRunner()) == 0
    assert len(_git(brain, "log", "--oneline").splitlines()) == 1


def test_brain_commit_never_pushes(fake_home):
    brain = fake_home / "Wisp/brain"
    (brain / ".git").mkdir(parents=True)
    (brain / "a.md").write_text("x")
    runner = FakeRunner()
    assert hook_brain_commit(WispConfig(brain=str(brain)), runner) == 0
    assert not [c for c in runner.calls if "push" in c]


def test_brain_commit_without_brain_is_exit0(fake_home):
    assert hook_brain_commit(WispConfig(), FakeRunner()) == 0


def test_hooks_never_fail_the_turn(fake_home):
    config = fake_home / ".config/wisp/wisp.json"
    config.parent.mkdir(parents=True)
    config.write_text("{not json")
    assert main(["hook", "boot"]) == 0
    assert main(["hook", "brain-commit"]) == 0

    class Exploding:
        def run(self, *a, **k):
            raise RuntimeError("boom")

    brain = fake_home / "Wisp/brain"
    (brain / ".git").mkdir(parents=True)
    assert hook_brain_commit(WispConfig(brain=str(brain)), Exploding()) == 0


def test_boot_labels_follow_language(fake_home):
    brain = fake_home / "Wisp/brain"
    brain.mkdir(parents=True)
    (brain / "pendencias.md").write_text("x\n")
    pt = hook_boot(WispConfig(brain=str(brain), language="pt-BR"), WispPaths.current())
    en = hook_boot(WispConfig(brain=str(brain), language="en"), WispPaths.current())
    assert pt.startswith("Hoje:") and "Cérebro:" in pt
    assert en.startswith("Today:") and "Brain:" in en


@needs_git
def test_held_file_is_noted_once_in_pendencias(fake_home):
    brain = _brain(fake_home)
    (brain / "chaves.md").write_text("k " + "sk-" + "a1b2c3d4" * 4 + "\n")
    for _ in range(2):
        assert hook_brain_commit(WispConfig(brain=str(brain)), SubprocessRunner()) == 0
    text = (brain / "pendencias.md").read_text()
    assert text.count("Arquivo chaves.md ficou fora do commit por parecer conter um segredo") == 1
    assert "sk-" not in text
    assert _git(brain, "status", "--porcelain") == "?? chaves.md"
