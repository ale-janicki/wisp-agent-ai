import copy
import json
import os
from datetime import datetime
from pathlib import Path

from wisp.config import WispConfig
from wisp.fsops import atomic_write
from wisp.harness_merge import (
    Change,
    InstalledManifest,
    BLOCK_KEY,
    TREE_DIRS,
    backup,
    block_digest,
    current_block,
    has_symlink,
    install_tree,
    merge_claude_md,
    merge_settings,
    render,
)
from wisp.paths import WispPaths, resources_root
from wisp.report import Detail, StepReport
from wisp.runner import Runner

MANIFEST_NAME = "harness-installed.json"
FALLBACK_USER = "the user"


def _load_manifest(path: Path) -> InstalledManifest:
    try:
        raw = json.loads(path.read_text())
        return InstalledManifest(int(raw["version"]), {str(k): str(v) for k, v in raw["files"].items()})
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return InstalledManifest()


def _values(cfg: WispConfig) -> dict[str, str]:
    return {
        "PERSONA_NAME": cfg.persona,
        "USER_NAME": cfg.user_name or FALLBACK_USER,
        "BRAIN_DIR": cfg.brain or "",
        "LANGUAGE": cfg.language,
    }


def _managed_elsewhere(claude_dir: Path) -> bool:
    guarded = [claude_dir, claude_dir / "CLAUDE.md", claude_dir / "settings.json", *(claude_dir / sub for sub in TREE_DIRS)]
    return any(has_symlink(p, claude_dir) for p in guarded)


def _file_mode(path: Path) -> int:
    return os.stat(path).st_mode & 0o777 if path.exists() else 0o644


def _failed(summary: str, **data: str) -> StepReport:
    return StepReport("harness", "failed", summary, data=dict(data))


def setup_harness(runner: Runner, paths: WispPaths, cfg: WispConfig, *, dry_run: bool, force_merge: bool = False) -> StepReport:
    if not cfg.brain or not Path(cfg.brain).is_dir():
        return _failed("falta criar o cérebro antes", step="brain")
    claude_dir = paths.home / ".claude"
    if _managed_elsewhere(claude_dir):
        return _failed("harness gerenciado fora do Wisp")

    source = resources_root() / "harness"
    values = _values(cfg)
    claude_md_path = claude_dir / "CLAUDE.md"
    settings_path = claude_dir / "settings.json"
    block = render((source / "claude-md-block.md").read_text(), values)
    manifest_path = paths.config / MANIFEST_NAME
    manifest = _load_manifest(manifest_path)
    plan = copy.deepcopy(manifest)
    try:
        user_md = claude_md_path.read_bytes().decode() if claude_md_path.exists() else None
        existing = current_block(user_md) if user_md is not None else None
        new_md = merge_claude_md(user_md, block)
    except (UnicodeDecodeError, ValueError):
        return _failed("o CLAUDE.md tem marcadores do Wisp quebrados ou não é texto; nada foi alterado")
    block_conflict = existing is not None and new_md != user_md and block_digest(existing) != plan.files.get(BLOCK_KEY)
    if block_conflict:
        new_md = user_md
    elif existing is None or new_md != user_md or block_digest(existing) == block_digest(block):
        plan.files[BLOCK_KEY] = block_digest(block)
    try:
        user_settings = json.loads(settings_path.read_text()) if settings_path.exists() else None
        if user_settings is not None and not isinstance(user_settings, dict):
            raise ValueError
    except (UnicodeDecodeError, ValueError):
        return _failed("o settings.json não é um JSON válido; nada foi alterado")
    ours = json.loads((source / "settings.json").read_text())
    new_settings, notes = merge_settings(user_settings or {}, ours)

    changes = install_tree(source, claude_dir, plan, values, dry_run=True)
    claude_md_kind = "conflict" if block_conflict else "added" if user_md is None else "merged" if new_md != user_md else "skipped"
    changes.append(Change("CLAUDE.md", claude_md_kind))
    changes.append(Change("settings.json", "added" if user_settings is None else "merged" if new_settings != user_settings else "skipped"))

    pending = [c for c in changes if c.kind in ("added", "updated", "merged")]
    conflicts = [c for c in changes if c.kind == "conflict"]
    data = {"backup": "", "added": str(sum(c.kind == "added" for c in changes)), "conflicts": str(len(conflicts))}
    details = [Detail("conflito", 0, f"{c.rel}: editado por você, mantido" if c.rel != "CLAUDE.md" else "CLAUDE.md: o bloco do Wisp foi editado por você, mantido") for c in conflicts]
    details += [Detail("settings", 0, note) for note in notes]
    if dry_run:
        return StepReport("harness", "done", "dry run: nada foi escrito", details, data)

    if pending:
        saved = backup(claude_dir, paths.state / "backups", datetime.now().strftime("%Y%m%d-%H%M%S"))
        data["backup"] = str(saved) if saved else ""
        install_tree(source, claude_dir, manifest, values)
        if new_md != user_md:
            atomic_write(claude_md_path, new_md.encode(), mode=_file_mode(claude_md_path))
        if new_settings != user_settings:
            atomic_write(settings_path, json.dumps(new_settings, indent=2, ensure_ascii=False) + "\n", mode=_file_mode(settings_path))
    if BLOCK_KEY in plan.files:
        manifest.files[BLOCK_KEY] = plan.files[BLOCK_KEY]
    if manifest != _load_manifest(manifest_path):
        atomic_write(manifest_path, json.dumps({"version": manifest.version, "files": manifest.files}, indent=2, sort_keys=True) + "\n")

    if not pending:
        return StepReport("harness", "skipped", "o harness já está instalado", details, data)
    summary = "harness instalado"
    if conflicts:
        summary += f"; {len(conflicts)} arquivo(s) editado(s) por você foram mantidos"
    return StepReport("harness", "done", summary, details, data)
