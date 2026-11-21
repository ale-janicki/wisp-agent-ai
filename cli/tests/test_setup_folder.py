from wisp.config import WispConfig, load_config
from wisp.paths import WispPaths, resources_root
from wisp.runner import FakeRunner
from wisp.setup.folder import setup_folder, wisp_root


def _run(home, cfg, path):
    return setup_folder(FakeRunner(), WispPaths.for_os("Darwin", home, {}), cfg, path=path, dry_run=False)


def test_creates_layout_and_seeds_agente(fake_home):
    root = fake_home / "Wisp"
    report = _run(fake_home, WispConfig(), root)
    assert report.status == "done"
    for name in ("agente.md", "guardrails.toml", "modelos.toml", "skills", "ferramentas", "conversas"):
        assert (root / name).exists()
    block = (resources_root() / "harness/claude-md-block.md").read_text()
    body = block.split("<!-- wisp:begin -->\n", 1)[1].split("<!-- wisp:end -->", 1)[0]
    assert (root / "agente.md").read_text() == body
    assert "{{PERSONA_NAME}}" in body
    assert (root / "skills/brain-boot/SKILL.md").is_file()
    assert (root / "skills/save-to-brain/SKILL.md").is_file()


def test_never_overwrites_user_files(fake_home):
    root = fake_home / "Wisp"
    root.mkdir()
    (root / "agente.md").write_text("minhas regras")
    first = _run(fake_home, WispConfig(), root)
    second = _run(fake_home, WispConfig(), root)
    assert (root / "agente.md").read_text() == "minhas regras"
    assert "agente.md" not in first.data["created"]
    assert "guardrails.toml" in first.data["created"]
    assert second.status == "skipped"
    assert second.data["created"] == ""


def test_path_with_spaces_and_accents(fake_home):
    root = fake_home / "Minha Pasta/Wisp ç"
    cfg = WispConfig()
    report = _run(fake_home, cfg, root)
    assert report.status == "done"
    assert (root / "agente.md").is_file()
    assert load_config().wisp_dir == str(root)
    assert wisp_root(load_config()) == root


def test_brain_elsewhere_is_left_alone(fake_home):
    vault = fake_home / "vault"
    cfg = WispConfig(brain=str(vault))
    root = fake_home / "Wisp"
    _run(fake_home, cfg, root)
    assert not (root / "brain").exists()
    assert not vault.exists()
    assert load_config().brain == str(vault)
