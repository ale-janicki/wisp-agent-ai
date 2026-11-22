import re
from pathlib import Path

from wisp.config import WispConfig, is_unreadable, save_config
from wisp.fsops import atomic_write, copy_file, ensure_dir
from wisp.migrate_folder import migrate_folder
from wisp.paths import WispPaths, resources_root
from wisp.report import StepReport
from wisp.runner import Runner

DIRS = ("skills", "ferramentas", "conversas", "reunioes", "anexos", "logs")
UNREADABLE = "não consegui ler o wisp.json; nada foi alterado"
RELATIVE = "use um caminho completo (começando com / ou ~)"
BLOCK = re.compile(r"<!-- wisp:begin -->\n(.*?)<!-- wisp:end -->", re.DOTALL)


def wisp_root(cfg: WispConfig) -> Path:
    return Path(cfg.wisp_dir).expanduser()


def _agente_seed() -> str:
    text = (resources_root() / "harness/claude-md-block.md").read_text()
    match = BLOCK.search(text)
    if not match:
        raise ValueError("harness/claude-md-block.md has no wisp markers")
    return match.group(1)


def _layout() -> tuple[dict[str, Path | None], Path, list[Path]]:
    """What a Wisp folder holds: top files (None = the agente.md seed), the packaged skills root and its files."""
    defaults = Path(__file__).resolve().parents[1] / "wisp_folder"
    wanted: dict[str, Path | None] = {
        "agente.md": None,
        "guardrails.toml": defaults / "guardrails.toml",
        "modelos.toml": defaults / "modelos.toml",
    }
    skills = resources_root() / "harness/skills"
    return wanted, skills, sorted(p.relative_to(skills) for p in skills.rglob("*") if p.is_file())


def missing_items(target: Path) -> list[str]:
    wanted, _, skill_files = _layout()
    missing = [name for name in wanted if not (target / name).exists()]
    missing += [f"{d}/" for d in DIRS if not (target / d).is_dir()]
    missing += [f"skills/{rel}" for rel in skill_files if not (target / "skills" / rel).exists()]
    return missing


def seed_folder(target: Path) -> list[str]:
    """Creates whatever of the layout is missing, never overwriting; returns what was created."""
    missing = missing_items(target)
    wanted, skills, skill_files = _layout()
    ensure_dir(target)
    for d in DIRS:
        ensure_dir(target / d)
    for name, src in wanted.items():
        if (target / name).exists():
            continue
        if src is None:
            atomic_write(target / name, _agente_seed())
        else:
            copy_file(src, target / name)
    for rel in skill_files:
        if not (target / "skills" / rel).exists():
            copy_file(skills / rel, target / "skills" / rel)
    return missing


def setup_folder(runner: Runner, paths: WispPaths, cfg: WispConfig, *, path: Path | None, dry_run: bool) -> StepReport:
    if path is not None and not str(path).startswith(("/", "~")):
        return StepReport("folder", "failed", RELATIVE)
    if is_unreadable():
        return StepReport("folder", "failed", UNREADABLE)
    target = path.expanduser() if path else wisp_root(cfg)
    data = {"path": str(target)}
    if dry_run:
        return StepReport("folder", "done", "dry run: nada foi escrito", data=data)
    missing = seed_folder(target)
    cfg.wisp_dir = str(path) if path else cfg.wisp_dir
    save_config(cfg)
    data["created"] = ", ".join(missing)
    moved = migrate_folder(paths, cfg)
    if moved.status != "skipped":
        data["migrated"] = moved.summary
    if not missing:
        return StepReport("folder", "skipped", "a pasta do Wisp já existe", data=data)
    return StepReport("folder", "done", "pasta do Wisp criada", data=data)
