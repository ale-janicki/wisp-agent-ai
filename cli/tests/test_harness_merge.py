import os

from wisp.harness_merge import BEGIN, END, InstalledManifest, backup, install_tree, merge_claude_md, merge_settings, render, sha256

VALUES = {"PERSONA_NAME": "Ada", "USER_NAME": "Rita"}


def _src(tmp_path, files):
    src = tmp_path / "src"
    for rel, text in files.items():
        (src / rel).parent.mkdir(parents=True, exist_ok=True)
        (src / rel).write_text(text)
    for sub in ("agents", "skills", "commands"):
        (src / sub).mkdir(exist_ok=True)
    return src


def test_render_replaces_known_placeholders_only():
    assert render("{{A}} and {{B}} {{C}}", {"A": "1", "B": "2"}) == "1 and 2 {{C}}"


def test_claude_md_without_user_is_the_block():
    block = f"{BEGIN}\nx\n{END}\n"
    assert merge_claude_md(None, block) == block


def test_claude_md_appends_block_after_user_text():
    block = f"{BEGIN}\nx\n{END}\n"
    merged = merge_claude_md("mine\n", block)
    assert merged == "mine\n\n\n" + block


def test_claude_md_replaces_inside_markers_and_keeps_the_rest():
    block = f"{BEGIN}\nnew\n{END}\n"
    merged = merge_claude_md(f"before\n{BEGIN}\nold\n{END}\nafter\n", block)
    assert merged == f"before\n{BEGIN}\nnew\n{END}\nafter\n"


def test_claude_md_broken_markers_raise():
    for broken in (f"a {BEGIN} b", f"a {END} b", f"{BEGIN} {BEGIN} {END}"):
        try:
            merge_claude_md(broken, f"{BEGIN}\n{END}\n")
        except ValueError:
            continue
        raise AssertionError(broken)


def test_settings_permissions_keep_user_order_and_append_missing():
    user = {"permissions": {"allow": ["B", "A"], "defaultMode": "plan"}}
    ours = {"permissions": {"allow": ["A", "C"], "deny": ["X"], "defaultMode": "ask"}}
    merged, notes = merge_settings(user, ours)
    assert merged["permissions"]["allow"] == ["B", "A", "C"]
    assert merged["permissions"]["deny"] == ["X"]
    assert merged["permissions"]["defaultMode"] == "plan"
    assert notes == ["permissions.defaultMode: mantido o valor do usuário"]
    assert user["permissions"]["allow"] == ["B", "A"]


def test_settings_hook_added_only_when_command_is_absent():
    group = {"hooks": [{"type": "command", "command": "wisp hook boot"}]}
    user = {"hooks": {"SessionStart": [{"matcher": "x", "hooks": [{"type": "command", "command": "wisp hook boot"}]}]}}
    merged, _ = merge_settings(user, {"hooks": {"SessionStart": [group], "Stop": [group]}})
    assert len(merged["hooks"]["SessionStart"]) == 1
    assert merged["hooks"]["Stop"] == [group]


def test_settings_other_keys_never_change_existing():
    merged, notes = merge_settings({"model": "sonnet"}, {"model": "opus", "theme": "dark"})
    assert merged == {"model": "sonnet", "theme": "dark"}
    assert notes == ["model: mantido o valor do usuário"]


def test_install_tree_decision_table(fake_home, tmp_path):
    src = _src(tmp_path, {"agents/a.md": "hi {{USER_NAME}}", "agents/b.md": "b", "agents/c.md": "c2", "agents/d.md": "d"})
    dst = fake_home / ".claude"
    (dst / "agents").mkdir(parents=True)
    (dst / "agents/b.md").write_text("b")
    (dst / "agents/c.md").write_text("c1")
    (dst / "agents/d.md").write_text("mine")
    manifest = InstalledManifest(1, {"agents/c.md": sha256(b"c1")})
    kinds = {c.rel: c.kind for c in install_tree(src, dst, manifest, VALUES)}
    assert kinds == {"agents/a.md": "added", "agents/b.md": "skipped", "agents/c.md": "updated", "agents/d.md": "conflict"}
    assert (dst / "agents/a.md").read_text() == "hi Rita"
    assert (dst / "agents/c.md").read_text() == "c2"
    assert (dst / "agents/d.md").read_text() == "mine"
    assert "agents/d.md" not in manifest.files


def test_install_tree_symlinked_target_is_a_conflict(fake_home, tmp_path):
    src = _src(tmp_path, {"skills/s/SKILL.md": "x"})
    dst = fake_home / ".claude"
    real = fake_home / "elsewhere"
    real.mkdir()
    (dst / "skills").mkdir(parents=True)
    (dst / "skills/s").symlink_to(real)
    assert [c.kind for c in install_tree(src, dst, InstalledManifest(), {})] == ["conflict"]
    assert list(real.iterdir()) == []


def test_install_tree_dry_run_writes_nothing(fake_home, tmp_path):
    src = _src(tmp_path, {"commands/c.md": "x"})
    assert [c.kind for c in install_tree(src, fake_home / ".claude", InstalledManifest(), {}, dry_run=True)] == ["added"]
    assert not (fake_home / ".claude").exists()


def test_backup_copies_known_items_and_never_projects(fake_home):
    claude = fake_home / ".claude"
    (claude / "projects").mkdir(parents=True)
    (claude / "projects/p.jsonl").write_text("secret history")
    (claude / "skills/s").mkdir(parents=True)
    (claude / "skills/s/SKILL.md").write_text("s")
    (claude / "settings.json").write_text("{}")
    dest = backup(claude, fake_home / "bk", "t1")
    assert dest == fake_home / "bk/claude-t1"
    assert (dest / "skills/s/SKILL.md").read_text() == "s"
    assert (dest / "settings.json").read_text() == "{}"
    assert not (dest / "projects").exists()


def test_backup_keeps_symlinks_as_links_and_returns_none_when_empty(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    assert backup(claude, fake_home / "bk", "t1") is None
    (fake_home / "real.md").write_text("r")
    (claude / "CLAUDE.md").symlink_to(fake_home / "real.md")
    dest = backup(claude, fake_home / "bk", "t2")
    assert os.path.islink(dest / "CLAUDE.md")


def test_claude_md_crlf_user_text_stays_byte_identical():
    block = f"{BEGIN}\nx\ny\n{END}\n"
    merged = merge_claude_md("line1\r\nline2\r\n", block)
    assert merged == f"line1\r\nline2\r\n\r\n\r\n{BEGIN}\r\nx\r\ny\r\n{END}\r\n"
    again = merge_claude_md(merged, block)
    assert again == merged


def test_settings_flat_hook_entry_with_our_command_gets_no_duplicate():
    ours = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "wisp hook x"}]}]}}
    user = {"hooks": {"Stop": [{"type": "command", "command": "wisp hook x"}]}}
    merged, _ = merge_settings(user, ours)
    assert merged == user


def test_backup_dir_is_unique_per_call(fake_home):
    claude = fake_home / ".claude"
    claude.mkdir()
    (claude / "settings.json").write_text("first")
    first = backup(claude, fake_home / "bk", "t")
    (claude / "settings.json").write_text("second")
    second = backup(claude, fake_home / "bk", "t")
    assert first != second
    assert (first / "settings.json").read_text() == "first"
    assert (second / "settings.json").read_text() == "second"
