import hashlib
import json

from wisp.cli import main
from wisp.config import WispConfig, save_config
from wisp.harness_merge import render_agente
from wisp.paths import WispPaths, resources_root
from wisp.runner import FakeRunner
from wisp.setup.harness import MCP_ALLOW, setup_harness


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
    setup_harness(_mcp_runner(1), _paths(fake_home), _cfg(fake_home), dry_run=False)
    merged = json.loads((claude / "settings.json").read_text())
    ours = json.loads((resources_root() / "harness/settings.json").read_text())["permissions"]["allow"]
    assert merged["model"] == "sonnet"
    assert merged["permissions"]["allow"][:2] == ["Mine", "Bash(ls:*)"]
    assert merged["permissions"]["allow"][2:] == [a for a in ours if a != "Bash(ls:*)"] + MCP_ALLOW
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


def _wisp(home):
    root = home / "Wisp"
    root.mkdir(parents=True, exist_ok=True)
    return root


def test_block_comes_from_agente_md(fake_home):
    (_wisp(fake_home) / "agente.md").write_text(_template_body() + "\nregra X\n")
    _run(fake_home)
    text = (fake_home / ".claude/CLAUDE.md").read_text()
    assert "# Ada" in text and "regra X" in text
    assert text.count("<!-- wisp:begin -->") == 1 and text.count("<!-- wisp:end -->") == 1


def test_unknown_braces_kept_verbatim():
    assert render_agente("a {{NAO_EXISTE}} b {{USER_NAME}}", {"USER_NAME": "Rafa"}) == "a {{NAO_EXISTE}} b Rafa"


def test_markers_inside_agente_md_cannot_corrupt_claude_md(fake_home):
    (_wisp(fake_home) / "agente.md").write_text(_template_body() + "\n<!-- wisp:end -->\nregra Y\n<!-- wisp:begin -->\n")
    _run(fake_home)
    first = (fake_home / ".claude/CLAUDE.md").read_text()
    assert first.count("<!-- wisp:begin -->") == 1 and first.count("<!-- wisp:end -->") == 1
    assert "regra Y" in first
    _run(fake_home)
    assert (fake_home / ".claude/CLAUDE.md").read_text() == first


def test_render_agente_strips_block_markers():
    assert render_agente("a <!-- wisp:begin --> b <!-- wisp:end --> {{USER_NAME}}", {"USER_NAME": "Rafa"}) == "a  b  Rafa"


def test_user_text_outside_block_untouched(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "CLAUDE.md").write_text("# Mine\nkeep\n")
    (_wisp(fake_home) / "agente.md").write_text(_template_body() + "\nregra X\n")
    _run(fake_home)
    text = (claude / "CLAUDE.md").read_text()
    assert text.startswith("# Mine\nkeep\n") and "regra X" in text


def test_skills_from_wisp_folder(fake_home):
    skill = _wisp(fake_home) / "skills/minha"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("---\nname: minha\n---\nPara {{USER_NAME}}\n")
    _run(fake_home)
    assert "Para Rita" in (fake_home / ".claude/skills/minha/SKILL.md").read_text()


def test_brain_dir_outside_wisp_rendered_in_place(fake_home):
    brain = fake_home / "Documents/cerebro"
    brain.mkdir(parents=True)
    (_wisp(fake_home) / "agente.md").write_text(_template_body() + "\ncerebro: {{BRAIN_DIR}}\n")
    _run(fake_home, WispConfig(user_name="Rita", persona="Ada", brain=str(brain)))
    assert f"cerebro: {brain}" in (fake_home / ".claude/CLAUDE.md").read_text()


def test_block_mentions_wisp_dir(fake_home):
    _run(fake_home)
    assert f"live in `{fake_home / 'Wisp'}`" in (fake_home / ".claude/CLAUDE.md").read_text()


def test_cli_harness_sync_prints_one_json_object(fake_home, capsys):
    save_config(_cfg(fake_home))
    assert main(["harness", "sync", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["step"] == "harness"
    assert (fake_home / ".claude/CLAUDE.md").is_file()


def test_harness_registers_server_once(fake_home):
    from wisp.runner import RunResult

    wisp_bin = str(_paths(fake_home).runtime / "venv/bin/wisp")
    add = ("claude", "mcp", "add")

    class Runner(FakeRunner):
        added = False

        def run(self, argv, **kw):
            args = list(argv)
            if args[:3] == ["claude", "mcp", "get"]:
                self.calls.append(args)
                return RunResult(args, 0, f"wisp-email:\n  Command: {wisp_bin}\n  Args: mcp email\n", "") if self.added else RunResult(args, 1, "", "not found")
            if tuple(args[:3]) == add:
                self.added = True
            return super().run(args, **kw)

    runner = Runner({add: RunResult([], 0, "", "")})
    cfg = _cfg(fake_home)
    setup_harness(runner, _paths(fake_home), cfg, dry_run=False)
    setup_harness(runner, _paths(fake_home), cfg, dry_run=False)
    adds = [c for c in runner.calls if tuple(c[:3]) == add]
    assert adds == [["claude", "mcp", "add", "--scope", "user", "wisp-email", "--", wisp_bin, "mcp", "email"]]
    allow = json.loads((fake_home / ".claude/settings.json").read_text())["permissions"]["allow"]
    assert [a for a in allow if a.startswith("mcp__wisp-email")] == MCP_ALLOW


def test_harness_dry_run_does_not_register(fake_home):
    runner = FakeRunner()
    setup_harness(runner, _paths(fake_home), _cfg(fake_home), dry_run=True)
    assert runner.calls == []


def _mcp_runner(get_exit, get_out="", add_exit=0):
    from wisp.runner import RunResult

    return FakeRunner({
        ("claude", "mcp", "get"): RunResult([], get_exit, get_out, ""),
        ("claude", "mcp", "add"): RunResult([], add_exit, "", "boom"),
    })


def _allow(home):
    path = home / ".claude/settings.json"
    return json.loads(path.read_text())["permissions"]["allow"] if path.exists() else []


def _adds(runner):
    return [c for c in runner.calls if c[:3] == ["claude", "mcp", "add"]]


FOREIGN = "já existe outro servidor chamado wisp-email no Claude; o Wisp não mexeu nele"


def test_foreign_server_untouched_no_allow(fake_home):
    runner = _mcp_runner(0, "wisp-email:\n  Command: /usr/bin/other\n  Args: serve\n")
    report = setup_harness(runner, _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert _adds(runner) == []
    assert not any(a.startswith("mcp__wisp-email") for a in _allow(fake_home))
    assert FOREIGN in report.to_json()


def test_lookalike_path_is_not_ours(fake_home):
    other = str(_paths(fake_home).runtime / "venv/bin/wisp-other")
    runner = _mcp_runner(0, f"wisp-email:\n  Command: {other}\n  Args: mcp email\n")
    setup_harness(runner, _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert _adds(runner) == [] and not any(a.startswith("mcp__wisp-email") for a in _allow(fake_home))
    runner = _mcp_runner(0, f"wisp-email: {other} mcp email")
    setup_harness(runner, _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert not any(a.startswith("mcp__wisp-email") for a in _allow(fake_home))


def test_add_failure_no_allow(fake_home):
    runner = _mcp_runner(1, add_exit=1)
    setup_harness(runner, _paths(fake_home), _cfg(fake_home), dry_run=False)
    assert len(_adds(runner)) == 1
    assert not any(a.startswith("mcp__wisp-email") for a in _allow(fake_home))


def test_dry_run_no_allow_rule(fake_home):
    runner = _mcp_runner(1)
    setup_harness(runner, _paths(fake_home), _cfg(fake_home), dry_run=True)
    assert runner.calls == [] and not (fake_home / ".claude/settings.json").exists()


def test_merged_settings_ask_before_sending_and_never_allow_it(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "settings.json").write_text(json.dumps({"permissions": {"ask": ["Mine"]}}))
    _run(fake_home)
    permissions = json.loads((claude / "settings.json").read_text())["permissions"]
    assert permissions["ask"][0] == "Mine" and "mcp__wisp-email__email_send" in permissions["ask"]
    assert "mcp__wisp-email__email_send" not in permissions["allow"] and "mcp__wisp-email" not in permissions["allow"]


def _template_body():
    text = (resources_root() / "harness/claude-md-block.md").read_text()
    return text.split("<!-- wisp:begin -->\n", 1)[1].split("<!-- wisp:end -->", 1)[0]


def test_new_user_gets_seeded_agente_with_full_template(fake_home):
    report = _run(fake_home)
    root = fake_home / "Wisp"
    assert (root / "agente.md").read_text() == _template_body()
    assert (root / "guardrails.toml").is_file() and (root / "skills/brain-boot/SKILL.md").is_file()
    assert "You are **Ada**" in (fake_home / ".claude/CLAUDE.md").read_text()
    assert not [d for d in report.details if d.command == "agente"]


def test_seeding_never_overwrites_and_dry_run_seeds_nothing(fake_home):
    _run(fake_home, dry_run=True)
    assert sorted(p.name for p in (fake_home / "Wisp").iterdir()) == ["brain"]
    mine = _template_body() + "\nminhas regras\n"
    (_wisp(fake_home) / "agente.md").write_text(mine)
    _run(fake_home)
    assert (fake_home / "Wisp/agente.md").read_text() == mine
    assert (fake_home / "Wisp/modelos.toml").is_file()


def test_incomplete_agente_falls_back_to_the_template(fake_home):
    (_wisp(fake_home) / "agente.md").write_text("regra X\n")
    report = _run(fake_home)
    text = (fake_home / ".claude/CLAUDE.md").read_text()
    assert "You are **Ada**" in text and "regra X" not in text
    assert [d.output for d in report.details if d.command == "agente"] == ["o agente.md parece incompleto; usei as regras padrão"]
    assert (fake_home / "Wisp/agente.md").read_text() == "regra X\n"


_INCOMPLETE_DETAIL = ["o agente.md parece incompleto; usei as regras padrão"]


def _falls_back(fake_home):
    report = _run(fake_home)
    text = (fake_home / ".claude/CLAUDE.md").read_text()
    assert "You are **Ada**" in text
    assert [d.output for d in report.details if d.command == "agente"] == _INCOMPLETE_DETAIL


def test_unreadable_agente_falls_back_to_the_template(fake_home):
    path = _wisp(fake_home) / "agente.md"
    path.write_text(_template_body() + "\nregra X\n")
    path.chmod(0)
    try:
        _falls_back(fake_home)
    finally:
        path.chmod(0o644)


def test_non_utf8_agente_falls_back_to_the_template(fake_home):
    (_wisp(fake_home) / "agente.md").write_bytes(b"# {{PERSONA_NAME}}\n\xff\xfe regra\n")
    _falls_back(fake_home)


def test_truncated_agente_with_heading_falls_back_to_the_template(fake_home):
    body = _template_body()
    (_wisp(fake_home) / "agente.md").write_text(body[: body.index("## Hard rules")])
    _falls_back(fake_home)


def test_complete_user_edited_agente_is_kept(fake_home):
    (_wisp(fake_home) / "agente.md").write_text(_template_body() + "\nminha regra Z\n")
    report = _run(fake_home)
    assert "minha regra Z" in (fake_home / ".claude/CLAUDE.md").read_text()
    assert not [d for d in report.details if d.command == "agente"]


def test_rendered_persona_heading_counts_as_complete(fake_home):
    (_wisp(fake_home) / "agente.md").write_text(_template_body().replace("{{PERSONA_NAME}}", "Ada") + "\nregra X\n")
    report = _run(fake_home)
    assert "regra X" in (fake_home / ".claude/CLAUDE.md").read_text()
    assert not [d for d in report.details if d.command == "agente"]


def test_symlinks_in_wisp_skills_are_not_followed(fake_home):
    outside = fake_home / "segredos"
    outside.mkdir()
    (outside / "SKILL.md").write_text("segredo\n")
    skills = _wisp(fake_home) / "skills"
    (skills / "real").mkdir(parents=True)
    (skills / "real/SKILL.md").write_text("ok {{USER_NAME}}\n")
    (skills / "linkado").symlink_to(outside)
    (skills / "real/atalho.md").symlink_to(outside / "SKILL.md")
    _run(fake_home)
    installed = fake_home / ".claude/skills"
    assert (installed / "real/SKILL.md").read_text() == "ok Rita\n"
    assert not (installed / "linkado").exists() and not (installed / "real/atalho.md").exists()
