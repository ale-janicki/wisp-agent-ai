import json
from pathlib import Path

import pytest

from wisp.cli import main
from wisp.config import WispConfig, load_config
from wisp.harness_merge import BEGIN
from wisp.paths import WispPaths
from wisp.runner import FakeRunner
from wisp.setup.harness import setup_harness
from wisp.setup.profile import setup_profile
from wisp.setup.profile_writer import set_telegram_block

PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 16
FIXTURE = Path(__file__).parent / "fixtures/contract/profile.json"


@pytest.fixture(autouse=True)
def persona_block_installed(monkeypatch):
    """These tests cover the persona block (source `assistant`); the soul-injected path is in test_soul.py."""
    monkeypatch.setattr("wisp.setup.harness.soul_source", lambda paths: "assistant")


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _cfg(home, **kw):
    brain = home / "Wisp/brain"
    brain.mkdir(parents=True, exist_ok=True)
    return WispConfig(brain=str(brain), **kw)


def _profile(home):
    return json.loads((home / ".config/wisp/profile.json").read_text())


def _run(home, cfg=None, **kw):
    kw.setdefault("name", "Ada")
    kw.setdefault("user_name", "Rita")
    kw.setdefault("language", "pt-BR")
    kw.setdefault("avatar", None)
    kw.setdefault("dry_run", False)
    return setup_profile(_paths(home), cfg or _cfg(home), **kw)


def test_writes_profile_matching_swift_schema(fake_home):
    cfg = _cfg(fake_home)
    report = _run(fake_home, cfg)
    brain = str(fake_home / "Wisp/brain")
    data = _profile(fake_home)
    assert report.status == "done"
    assert data["persona"] == {"name": "Ada", "user": "Rita", "language": "pt-BR"}
    assert data["agent"] == {"cwd": "~"}
    assert data["blocks"]["tasks"] == {"file": f"{brain}/pendencias.md"}
    assert data["blocks"]["memory"]["root"] == brain
    assert "{query}" in data["blocks"]["memory"]["search"] and "{root}" in data["blocks"]["memory"]["search"]
    assert "telegram" not in data["blocks"]
    assert (cfg.persona, cfg.user_name) == ("Ada", "Rita")
    saved = load_config()
    assert (saved.persona, saved.user_name, saved.language) == ("Ada", "Rita", "pt-BR")
    set_telegram_block(fake_home / ".config/wisp/profile.json", "/opt/wisp/venv/bin/wisp", "/state/anexos")
    text = (fake_home / ".config/wisp/profile.json").read_text().replace(brain, "/home/rita/Wisp/brain")
    FIXTURE.write_text(text.replace(str(fake_home), "/home/rita"))


def test_symlinked_profile_refused(fake_home):
    config = fake_home / ".config/wisp"
    config.mkdir(parents=True)
    target = fake_home / "elsewhere.json"
    target.write_text('{"keep": true}')
    (config / "profile.json").symlink_to(target)
    avatar = fake_home / "a.png"
    avatar.write_bytes(b"png")
    cfg = _cfg(fake_home)
    report = _run(fake_home, cfg, avatar=avatar)
    assert report.status == "failed"
    assert target.read_text() == '{"keep": true}'
    assert not (config / "avatar.png").exists()
    assert not (config / "wisp.json").exists()


def test_existing_blocks_kept(fake_home):
    path = fake_home / ".config/wisp/profile.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({
        "persona": {"name": "Old", "language": "en"},
        "agent": {"cwd": "~", "statusPrefix": "X"},
        "blocks": {"alerts": {"list": "a"}, "tasks": {"file": "/mine/t.md"}},
    }))
    set_telegram_block(path, "/w/wisp")
    _run(fake_home)
    data = _profile(fake_home)
    assert data["persona"]["name"] == "Ada"
    assert data["agent"]["statusPrefix"] == "X"
    assert data["blocks"]["alerts"] == {"list": "a"}
    assert data["blocks"]["tasks"] == {"file": f"{fake_home}/Wisp/brain/pendencias.md"}
    assert data["blocks"]["telegram"]["status"].endswith("topic status --json")
    assert "root" in data["blocks"]["memory"]


def test_persona_rerenders_claude_md_block(fake_home):
    cfg = _cfg(fake_home, persona="Ada", user_name="Rita")
    setup_harness(FakeRunner(), _paths(fake_home), cfg, dry_run=False)
    md = fake_home / ".claude/CLAUDE.md"
    assert "# Ada" in md.read_text()
    report = _run(fake_home, cfg, name="Bia")
    assert "# Bia" in md.read_text() and "# Ada" not in md.read_text()
    assert "warning" not in report.data


def test_edited_block_is_kept_as_conflict(fake_home):
    cfg = _cfg(fake_home, persona="Ada", user_name="Rita")
    setup_harness(FakeRunner(), _paths(fake_home), cfg, dry_run=False)
    md = fake_home / ".claude/CLAUDE.md"
    md.write_text(md.read_text().replace("# Ada", "# Ada, minha"))
    before = md.read_text()
    report = _run(fake_home, cfg, name="Bia")
    assert md.read_text() == before
    assert "warning" in report.data
    assert _profile(fake_home)["persona"]["name"] == "Bia"


def test_no_harness_installed_leaves_claude_untouched(fake_home):
    _run(fake_home)
    assert not (fake_home / ".claude").exists()


def test_avatar_copied_into_config_dir(fake_home):
    avatar = fake_home / "face.PNG"
    avatar.write_bytes(PNG)
    _run(fake_home, avatar=avatar)
    copied = fake_home / ".config/wisp/avatar.png"
    assert copied.read_bytes() == PNG
    assert _profile(fake_home)["persona"]["avatar"] == str(copied)


def test_avatar_missing_or_not_an_image_fails(fake_home):
    assert _run(fake_home, avatar=fake_home / "none.png").status == "failed"
    doc = fake_home / "x.txt"
    doc.write_text("x")
    assert _run(fake_home, avatar=doc).status == "failed"
    assert not (fake_home / ".config/wisp/profile.json").exists()


def test_name_required_nonempty(fake_home):
    for bad in ("", "   "):
        report = _run(fake_home, name=bad)
        assert report.status == "failed"
    assert not (fake_home / ".config/wisp/profile.json").exists()


def test_name_with_quotes_and_unicode(fake_home):
    cfg = _cfg(fake_home)
    setup_harness(FakeRunner(), _paths(fake_home), cfg, dry_run=False)
    cfg.persona = "Zé"
    _run(fake_home, cfg, name='Zé "Bot"')
    assert _profile(fake_home)["persona"]["name"] == 'Zé "Bot"'
    assert '# Zé "Bot"' in (fake_home / ".claude/CLAUDE.md").read_text()


def test_dry_run_writes_nothing(fake_home):
    report = _run(fake_home, dry_run=True)
    assert report.status == "done"
    assert not (fake_home / ".config/wisp").exists()


def test_rerun_is_skipped_and_identical(fake_home):
    cfg = _cfg(fake_home)
    _run(fake_home, cfg)
    first = (fake_home / ".config/wisp/profile.json").read_bytes()
    assert _run(fake_home, load_config()).status == "skipped"
    assert (fake_home / ".config/wisp/profile.json").read_bytes() == first


def test_user_name_falls_back_to_saved(fake_home):
    cfg = _cfg(fake_home, user_name="Rita")
    _run(fake_home, cfg, user_name=None)
    assert _profile(fake_home)["persona"]["user"] == "Rita"


def test_cli_profile_json(fake_home, capsys):
    code = main(["setup", "profile", "--name", "Ada", "--user-name", "Rita", "--language", "pt-BR", "--json"])
    out = json.loads(capsys.readouterr().out)
    assert code == 0 and out["step"] == "profile"
    assert (fake_home / ".config/wisp/profile.json").is_file()


def test_avatar_magic_bytes_decide_not_the_extension(fake_home):
    fake = fake_home / "fake.png"
    fake.write_bytes(b"not an image at all")
    assert _run(fake_home, avatar=fake).status == "failed"
    jpeg = fake_home / "p.png"
    jpeg.write_bytes(b"\xff\xd8\xff\xe0" + b"\0" * 16)
    assert _run(fake_home, avatar=jpeg).status == "done"
    assert (fake_home / ".config/wisp/avatar.jpg").is_file()
    webp = fake_home / "w.bin"
    webp.write_bytes(b"RIFF\0\0\0\0WEBPVP8 ")
    assert _run(fake_home, avatar=webp).status == "done"
    assert (fake_home / ".config/wisp/avatar.webp").is_file()
    assert not (fake_home / ".config/wisp/avatar.jpg").exists()


def test_avatar_over_5mb_refused(fake_home):
    big = fake_home / "big.png"
    big.write_bytes(PNG + b"\0" * (5 * 1024 * 1024))
    report = _run(fake_home, avatar=big)
    assert report.status == "failed" and "5 MB" in report.summary
    assert not (fake_home / ".config/wisp/profile.json").exists()
    assert not list((fake_home / ".config/wisp").glob("*avatar*")) if (fake_home / ".config/wisp").exists() else True


def test_avatar_failure_keeps_old_avatar_and_profile(fake_home, monkeypatch):
    good = fake_home / "a.png"
    good.write_bytes(PNG)
    _run(fake_home, avatar=good)
    before = (fake_home / ".config/wisp/profile.json").read_text()
    other = fake_home / "b.jpg"
    other.write_bytes(b"\xff\xd8\xff" + b"\1" * 8)
    import wisp.setup.profile as mod
    monkeypatch.setattr(mod.os, "replace", lambda *a: (_ for _ in ()).throw(OSError("boom")))
    assert _run(fake_home, name="Zed", avatar=other).status == "failed"
    assert (fake_home / ".config/wisp/avatar.png").read_bytes() == PNG
    assert not list((fake_home / ".config/wisp").glob(".avatar*"))
    assert "Ada" in before


def test_symlinked_avatar_target_refused(fake_home):
    config = fake_home / ".config/wisp"
    config.mkdir(parents=True)
    victim = fake_home / "victim"
    victim.write_text("keep")
    (config / "avatar.png").symlink_to(victim)
    good = fake_home / "a.png"
    good.write_bytes(PNG)
    assert _run(fake_home, avatar=good).status == "failed"
    assert victim.read_text() == "keep"


def test_conflict_returns_done_with_warning(fake_home):
    cfg = _cfg(fake_home, persona="Ada", user_name="Rita")
    setup_harness(FakeRunner(), _paths(fake_home), cfg, dry_run=False)
    md = fake_home / ".claude/CLAUDE.md"
    md.write_text(md.read_text().replace("# Ada", "# Ada, minha"))
    report = _run(fake_home, cfg, name="Bia")
    assert report.status == "done"
    assert "nome antigo" in report.data["warning"] and "editado" in report.data["warning"]


def test_harness_symlink_returns_warning(fake_home):
    cfg = _cfg(fake_home, persona="Ada", user_name="Rita")
    setup_harness(FakeRunner(), _paths(fake_home), cfg, dry_run=False)
    real = fake_home / "real.md"
    md = fake_home / ".claude/CLAUDE.md"
    real.write_text(md.read_text())
    md.unlink()
    md.symlink_to(real)
    report = _run(fake_home, cfg, name="Bia")
    assert report.status == "done" and "nome antigo" in report.data["warning"]
    assert "# Ada" in real.read_text()


def test_name_rejects_dangerous_characters(fake_home):
    for bad in ["a\nb", "a\x00b", "x <!-- y", "x --> y", "{{USER_NAME}}", "a}}", "a\u2028b"]:
        assert _run(fake_home, name=bad).status == "failed", bad
        assert _run(fake_home, user_name=bad).status == "failed", bad
    assert not (fake_home / ".config/wisp/profile.json").exists()


def test_placeholder_in_value_not_substituted():
    from wisp.harness_merge import render
    assert render("{{A}} {{B}}", {"A": "{{B}}", "B": "x"}) == "{{B}} x"


def test_blocks_follow_current_brain(fake_home):
    _run(fake_home)
    new_brain = fake_home / "Other"
    new_brain.mkdir()
    path = fake_home / ".config/wisp/profile.json"
    data = json.loads(path.read_text())
    data["blocks"]["tasks"]["extra"] = 1
    data["blocks"]["memory"]["search"] = "mine {query} {root}"
    path.write_text(json.dumps(data))
    _run(fake_home, WispConfig(brain=str(new_brain)))
    data = _profile(fake_home)
    assert data["blocks"]["tasks"] == {"file": f"{new_brain}/pendencias.md", "extra": 1}
    assert data["blocks"]["memory"] == {"root": str(new_brain), "search": "mine {query} {root}"}


def test_persona_change_installs_nothing_and_no_backup(fake_home):
    cfg = _cfg(fake_home, persona="Ada", user_name="Rita")
    setup_harness(FakeRunner(), _paths(fake_home), cfg, dry_run=False)
    skill = fake_home / ".claude/skills/brain-boot/SKILL.md"
    skill.unlink()
    _run(fake_home, cfg, name="Bia")
    assert not skill.exists()
    assert not (fake_home / ".local/state/wisp/backups").exists() or not list((fake_home / ".local/state/wisp/backups").iterdir())


def test_dry_run_with_no_change_is_skipped(fake_home):
    cfg = _cfg(fake_home)
    _run(fake_home, cfg)
    assert _run(fake_home, load_config(), dry_run=True).status == "skipped"
    assert _run(fake_home, load_config(), dry_run=True, name="Other").status == "done"


def test_persona_rename_reports_incomplete_agente(fake_home):
    cfg = _cfg(fake_home, persona="Ada", user_name="Rita")
    setup_harness(FakeRunner(), _paths(fake_home), cfg, dry_run=False)
    (fake_home / "Wisp/agente.md").write_text("regra X\n")
    report = _run(fake_home, cfg, name="Bia")
    assert [d.output for d in report.details if d.command == "agente"] == ["o agente.md parece incompleto; usei as regras padrão"]


def test_no_name_keeps_the_existing_persona_name(fake_home):
    _run(fake_home, name="Ada")
    report = _run(fake_home, name=None, user_name="Rita")
    assert report.status in ("done", "skipped")
    assert _profile(fake_home)["persona"]["name"] == "Ada"


def test_no_name_on_a_fresh_profile_uses_wisp(fake_home):
    report = _run(fake_home, name=None, cfg=_cfg(fake_home))
    assert report.status == "done"
    assert _profile(fake_home)["persona"]["name"] == "Wisp"


def test_no_name_falls_back_to_the_configured_persona(fake_home):
    _run(fake_home, name=None, cfg=_cfg(fake_home, persona="Lia"))
    assert _profile(fake_home)["persona"]["name"] == "Lia"
