import hashlib
import json

from wisp.cli import main
from wisp.config import WispConfig
from wisp.paths import WispPaths, resources_root
from wisp.runner import FakeRunner
from wisp.setup.harness import setup_harness


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _cfg(home, **kw):
    brain = home / "Wisp/brain"
    brain.mkdir(parents=True, exist_ok=True)
    return WispConfig(user_name=kw.pop("user_name", "Rita"), persona=kw.pop("persona", "Ada"), brain=str(brain), **kw)


def _run(home, cfg=None, **kw):
    return setup_harness(FakeRunner(), _paths(home), cfg or _cfg(home), dry_run=kw.pop("dry_run", False), **kw)


def _digests(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*")) if p.is_file()}


def _skill():
    return next((resources_root() / "harness/skills").rglob("SKILL.md"))


def test_fresh_home_installs_everything(fake_home):
    report = _run(fake_home)
    claude = fake_home / ".claude"
    text = (claude / "CLAUDE.md").read_text()
    assert report.status == "done"
    assert "# Ada" in text and "Rita" in text and str(fake_home / "Wisp/brain") in text
    assert "{{" not in text
    assert (claude / "agents/operator.md").is_file() and (claude / "commands/diagnose.md").is_file()
    assert "{{" not in (claude / "skills/brain-boot/SKILL.md").read_text()
    assert report.data["conflicts"] == "0"
    assert json.loads((fake_home / ".config/wisp/harness-installed.json").read_text())["files"]


def test_existing_settings_keeps_user_values(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "settings.json").write_text(json.dumps({"model": "sonnet", "permissions": {"allow": ["Mine", "Bash(ls:*)"]}}))
    _run(fake_home)
    merged = json.loads((claude / "settings.json").read_text())
    ours = json.loads((resources_root() / "harness/settings.json").read_text())["permissions"]["allow"]
    assert merged["model"] == "sonnet"
    assert merged["permissions"]["allow"][:2] == ["Mine", "Bash(ls:*)"]
    assert merged["permissions"]["allow"][2:] == [a for a in ours if a != "Bash(ls:*)"]
    assert len(set(merged["permissions"]["allow"])) == len(merged["permissions"]["allow"])


def test_hooks_added_once(fake_home):
    _run(fake_home)
    _run(fake_home)
    hooks = json.loads((fake_home / ".claude/settings.json").read_text())["hooks"]
    assert len(hooks["SessionStart"]) == 1 and len(hooks["Stop"]) == 1


def test_second_run_is_byte_identical(fake_home):
    _run(fake_home)
    before = _digests(fake_home / ".claude")
    second = _run(fake_home)
    assert second.status == "skipped"
    assert _digests(fake_home / ".claude") == before
    assert not (fake_home / ".local/state/wisp/backups").exists()


def test_claude_md_user_text_untouched_and_block_once(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "CLAUDE.md").write_text("# My rules\nkeep me\n")
    _run(fake_home)
    _run(fake_home)
    text = (claude / "CLAUDE.md").read_text()
    assert text.startswith("# My rules\nkeep me\n")
    assert text.count("<!-- wisp:begin -->") == 1 and text.count("<!-- wisp:end -->") == 1


def test_claude_md_block_replaced_on_persona_change(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "CLAUDE.md").write_text("mine\n")
    _run(fake_home)
    _run(fake_home, _cfg(fake_home, persona="Bia"))
    text = (claude / "CLAUDE.md").read_text()
    assert "# Bia" in text and "# Ada" not in text
    assert text.startswith("mine\n") and text.count("<!-- wisp:begin -->") == 1


def test_user_modified_skill_is_kept_and_reported(fake_home):
    _run(fake_home)
    rel = _skill().relative_to(resources_root() / "harness").as_posix()
    target = fake_home / ".claude" / rel
    target.write_text("my own version")
    report = _run(fake_home, _cfg(fake_home, persona="Bia"))
    assert report.data["conflicts"] == "1"
    assert target.read_text() == "my own version"
    assert any(rel in d.output for d in report.details)


def test_unmodified_installed_file_is_updated(fake_home):
    _run(fake_home)
    _run(fake_home, _cfg(fake_home, user_name="Sol"))
    assert "Sol" in (fake_home / ".claude/agents/operator.md").read_text()
    assert "Rita" not in (fake_home / ".claude/agents/operator.md").read_text()


def test_backup_created_before_any_write(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    original = b'{"model": "sonnet"}'
    (claude / "settings.json").write_bytes(original)
    report = _run(fake_home)
    backups = list((fake_home / ".local/state/wisp/backups").glob("claude-*"))
    assert [str(b) for b in backups] == [report.data["backup"]]
    assert (backups[0] / "settings.json").read_bytes() == original
    assert (claude / "settings.json").read_bytes() != original


def test_symlinked_claude_files_refused(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    real = fake_home / "vault/settings.json"
    real.parent.mkdir(parents=True)
    real.write_text("{}")
    (claude / "settings.json").symlink_to(real)
    report = _run(fake_home)
    assert report.status == "failed"
    assert report.summary == "harness gerenciado fora do Wisp"
    assert real.read_text() == "{}"
    assert sorted(p.name for p in claude.iterdir()) == ["settings.json"]
    assert not (fake_home / ".local/state/wisp/backups").exists()
    assert not (fake_home / ".config/wisp/harness-installed.json").exists()


def test_symlinked_claude_md_and_skills_dir_refused(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (fake_home / "notes.md").write_text("n")
    (claude / "CLAUDE.md").symlink_to(fake_home / "notes.md")
    assert _run(fake_home).summary == "harness gerenciado fora do Wisp"
    (claude / "CLAUDE.md").unlink()
    (fake_home / "sk").mkdir()
    (claude / "skills").symlink_to(fake_home / "sk")
    assert _run(fake_home).summary == "harness gerenciado fora do Wisp"
    assert list((fake_home / "sk").iterdir()) == []


def test_invalid_user_settings_json_not_touched(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "settings.json").write_text("{not json")
    report = _run(fake_home)
    assert report.status == "failed"
    assert (claude / "settings.json").read_text() == "{not json"
    assert sorted(p.name for p in claude.iterdir()) == ["settings.json"]
    assert not (fake_home / ".local/state/wisp/backups").exists()


def test_dry_run_writes_nothing(fake_home):
    report = _run(fake_home, dry_run=True)
    assert report.status == "done"
    assert not (fake_home / ".claude").exists()
    assert not (fake_home / ".config/wisp").exists()
    assert not (fake_home / ".local/state/wisp").exists()


def test_brain_missing_needs_brain_step(fake_home):
    report = _run(fake_home, WispConfig())
    assert report.status == "failed"
    assert report.data == {"step": "brain"}
    assert not (fake_home / ".claude").exists()


def test_cli_setup_harness_prints_one_json_object(fake_home, capsys):
    _cfg(fake_home)
    from wisp.config import save_config

    save_config(_cfg(fake_home))
    assert main(["setup", "harness", "--dry-run", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["step"] == "harness"


def test_rerun_over_existing_home_makes_one_backup_and_no_changes(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "settings.json").write_text('{"model": "sonnet"}')
    _run(fake_home)
    before = _digests(claude)
    assert _run(fake_home).status == "skipped"
    assert _digests(claude) == before
    assert len(list((fake_home / ".local/state/wisp/backups").iterdir())) == 1


def test_crlf_claude_md_keeps_user_bytes_and_is_stable(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "CLAUDE.md").write_bytes(b"line1\r\nline2\r\n")
    _run(fake_home)
    data = (claude / "CLAUDE.md").read_bytes()
    assert data.startswith(b"line1\r\nline2\r\n")
    assert b"\n" not in data.replace(b"\r\n", b"")
    before = _digests(claude)
    assert _run(fake_home).status == "skipped"
    assert _digests(claude) == before


def test_user_edit_inside_block_is_kept_and_reported(fake_home):
    claude = fake_home / ".claude"
    _run(fake_home)
    edited = (claude / "CLAUDE.md").read_text().replace("# Ada", "# Ada\nMY EDIT")
    (claude / "CLAUDE.md").write_text(edited)
    report = _run(fake_home, _cfg(fake_home, persona="Bia"))
    assert (claude / "CLAUDE.md").read_text() == edited
    assert report.data["conflicts"] == "1"
    assert any("CLAUDE.md" in d.output for d in report.details)


def test_block_without_manifest_sha_is_a_conflict(fake_home):
    claude = fake_home / ".claude"
    _run(fake_home)
    (fake_home / ".config/wisp/harness-installed.json").unlink()
    before = (claude / "CLAUDE.md").read_bytes()
    report = _run(fake_home, _cfg(fake_home, persona="Bia"))
    assert (claude / "CLAUDE.md").read_bytes() == before
    assert any(d.output.startswith("CLAUDE.md") for d in report.details)


def test_two_writing_runs_in_one_second_keep_both_backups(fake_home, monkeypatch):
    import wisp.setup.harness as h

    class Frozen:
        @staticmethod
        def now():
            import datetime

            return datetime.datetime(2026, 1, 1, 12, 0, 0)

    monkeypatch.setattr(h, "datetime", Frozen)
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "settings.json").write_text('{"model": "sonnet"}')
    _run(fake_home)
    _run(fake_home, _cfg(fake_home, persona="Bia"))
    assert len(list((fake_home / ".local/state/wisp/backups").iterdir())) == 2


def test_existing_agent_file_is_kept_and_reported(fake_home):
    agents = fake_home / ".claude/agents"
    agents.mkdir(parents=True)
    (agents / "operator.md").write_text("my own operator")
    report = _run(fake_home)
    _run(fake_home, _cfg(fake_home, user_name="Sol"))
    assert (agents / "operator.md").read_text() == "my own operator"
    assert report.data["conflicts"] != "0"
    files = json.loads((fake_home / ".config/wisp/harness-installed.json").read_text())["files"]
    assert "agents/operator.md" not in files
