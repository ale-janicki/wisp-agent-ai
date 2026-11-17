from pathlib import Path

from wisp.config import WispConfig, save_config
from wisp.fsops import copy_file, ensure_dir
from wisp.paths import WispPaths, resources_root
from wisp.report import Detail, StepReport
from wisp.runner import Runner

PROTECTED = ("Documents", "Desktop", "Downloads", "Library/Mobile Documents")
DEFAULT_REL = "Wisp/brain"
GIT_EMAIL = "wisp@localhost"


def _template_files() -> list[Path]:
    root = resources_root() / "vault-template"
    return sorted(p.relative_to(root) for p in root.rglob("*") if p.is_file())


def _protected_warning(home: Path, target: Path) -> str | None:
    resolved = target.resolve()
    for rel in PROTECTED:
        if resolved.is_relative_to((home / rel).resolve()):
            return "essa pasta é protegida pelo macOS; o Wisp pode pedir permissão para lê-la"
    return None


def _git(runner: Runner, target: Path, details: list[Detail], *args: str) -> str | None:
    result = runner.run(["git", "-C", str(target), *args], timeout=60)
    details.append(Detail.capture("git " + " ".join(args), result.exit, result.stdout, result.stderr))
    return result.stdout.strip() if result.exit == 0 else None


def setup_brain(runner: Runner, paths: WispPaths, cfg: WispConfig, *, path: Path | None, dry_run: bool) -> StepReport:
    target = (path or paths.home / DEFAULT_REL).expanduser()
    if runner.run(["xcode-select", "-p"], timeout=10).exit != 0:
        return StepReport("brain", "failed", "faltam as Ferramentas de linha de comando", data={"step": "system"})
    data = {"path": str(target)}
    warning = _protected_warning(paths.home, target)
    if warning:
        data["warning"] = warning
    template = _template_files()
    missing = [rel for rel in template if not (target / rel).exists()]
    has_repo = (target / ".git").exists()
    if dry_run:
        return StepReport("brain", "done", "dry run: nada foi escrito", data=data)
    probe: list[Detail] = []
    has_head = has_repo and _git(runner, target, probe, "rev-parse", "--verify", "HEAD") is not None
    if not missing and has_head:
        cfg.brain = str(target)
        save_config(cfg)
        return StepReport("brain", "skipped", "o cérebro já existe", data=data)

    details: list[Detail] = []
    ensure_dir(target)
    source = resources_root() / "vault-template"
    for rel in missing:
        copy_file(source / rel, target / rel)
    if not has_repo and _git(runner, target, details, "init", "-b", "main") is None:
        return StepReport("brain", "failed", "não consegui criar o repositório do cérebro", details, data)
    if not _git(runner, target, details, "config", "user.name"):
        name = cfg.user_name or "Wisp"
        if _git(runner, target, details, "config", "--local", "user.name", name) is None:
            return StepReport("brain", "failed", "não consegui configurar o git do cérebro", details, data)
    if not _git(runner, target, details, "config", "user.email"):
        if _git(runner, target, details, "config", "--local", "user.email", GIT_EMAIL) is None:
            return StepReport("brain", "failed", "não consegui configurar o git do cérebro", details, data)
    to_commit = [str(rel) for rel in (missing if has_head else template) if (target / rel).exists()]
    if to_commit:
        message = "chore: add missing template files" if has_head else "chore: start the brain from the template"
        staged = _git(runner, target, details, "add", "--", *to_commit)
        if staged is None or _git(runner, target, details, "commit", "-m", message, "--", *to_commit) is None:
            return StepReport("brain", "failed", "não consegui salvar o primeiro commit do cérebro", details, data)
    cfg.brain = str(target)
    save_config(cfg)
    return StepReport("brain", "done", "cérebro criado", details, data)
