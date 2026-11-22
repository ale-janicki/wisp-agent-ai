import copy
import json
import os
from datetime import datetime
from pathlib import Path

from wisp.config import WispConfig
from wisp.fsops import atomic_write
from wisp.mac_control import READ_ONLY as MAC_READ_ONLY
from wisp.harness_merge import (
    Change,
    InstalledManifest,
    BLOCK_KEY,
    TREE_DIRS,
    render_agente,
    wrap_block,
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
from wisp.setup.folder import seed_folder, wisp_root

MANIFEST_NAME = "harness-installed.json"
FALLBACK_USER = "the user"
MCP_NAME = "wisp-email"
BRAIN_MCP_NAME = "wisp-brain"
MCP_ALLOW = [f"mcp__{MCP_NAME}__email_{name}" for name in ("list", "read", "search")]   # never email_send: it has an ask rule
BRAIN_MCP_ALLOW = [f"mcp__{BRAIN_MCP_NAME}__brain_{name}" for name in ("search", "read", "links")]
MAC_MCP_NAME = "wisp-mac"
MAC_ALLOW = [f"mcp__{MAC_MCP_NAME}__{name}" for name in sorted(MAC_READ_ONLY)]
INCOMPLETE = "o agente.md parece incompleto; usei as regras padrão"
FOREIGN = "já existe outro servidor chamado wisp-email no Claude; o Wisp não mexeu nele"
BRAIN_FOREIGN = "já existe outro servidor chamado wisp-brain no Claude; o Wisp não mexeu nele"
MAC_FOREIGN = "já existe outro servidor chamado wisp-mac no Claude; o Wisp não mexeu nele"


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
        "BRAIN_DIR": str(Path(cfg.brain).expanduser()) if cfg.brain else "",
        "LANGUAGE": cfg.language,
        "WISP_DIR": str(wisp_root(cfg)),
    }


def _sections(text: str) -> list[str]:
    return [line.rstrip() for line in text.splitlines() if line.startswith("## ")]


def _looks_incomplete(text: str, template: str, persona: str) -> bool:
    """Incomplete when a top-level `## ` heading of the template is missing, or when there is no persona
    heading (placeholder or rendered) and the text is shorter than the template's opening section:
    likely a stub or a half-saved file, not the user's rules."""
    if not set(_sections(template)) <= set(_sections(text)):
        return True
    opening = template.split("<!-- wisp:begin -->", 1)[-1].split("\n## ", 1)[0]
    headed = "{{PERSONA_NAME}}" in text or any(line.strip() == f"# {persona}" for line in text.splitlines())
    return not headed and len(text.strip()) < len(opening.strip())


def _block(source: Path, cfg: WispConfig, values: dict[str, str]) -> tuple[str, str | None]:
    """The rendered block and, when agente.md was set aside, the reason to show the user."""
    template = (source / "claude-md-block.md").read_text()
    agente = wisp_root(cfg) / "agente.md"
    if not agente.is_file():
        return render(template, values), None
    try:
        text = agente.read_text()
    except (OSError, UnicodeDecodeError):
        return render(template, values), INCOMPLETE
    if _looks_incomplete(text, template, cfg.persona):
        return render(template, values), INCOMPLETE
    return wrap_block(render_agente(text, values)), None


def _roots(cfg: WispConfig) -> dict[str, Path]:
    skills = wisp_root(cfg) / "skills"
    return {"skills": skills} if skills.is_dir() and not skills.is_symlink() else {}


def _managed_elsewhere(claude_dir: Path) -> bool:
    guarded = [claude_dir, claude_dir / "CLAUDE.md", claude_dir / "settings.json", *(claude_dir / sub for sub in TREE_DIRS)]
    return any(has_symlink(p, claude_dir) for p in guarded)


def _file_mode(path: Path) -> int:
    return os.stat(path).st_mode & 0o777 if path.exists() else 0o644


def _is_ours(output: str, wisp_bin: str, server: str = "email") -> bool:
    """Exact match of our command in `claude mcp get` output; the real format is confirmed in the live check."""
    lines = [line.strip() for line in output.splitlines()]
    command = next((line.split(":", 1)[1].strip() for line in lines if line.startswith("Command:")), None)
    args = next((line.split(":", 1)[1].split() for line in lines if line.startswith("Args:")), None)
    if command is not None:
        return command == wisp_bin and (args is None or args == ["mcp", server])
    tokens = [t for t in output.split() if t not in ("Command:", "Args:")]
    return any(t == wisp_bin and tokens[i + 1 : i + 3] == ["mcp", server] for i, t in enumerate(tokens))


def _register(runner: Runner, paths: WispPaths, cfg: WispConfig, name: str, server: str, foreign: str, failure: str) -> tuple[str, str | None]:
    """Registers a Wisp MCP server in Claude Code. Returns (state, detail); state is
    present | added | foreign | failed, and only present/added allow the permission rule."""
    claude = cfg.claude_bin or "claude"
    wisp_bin = str(paths.runtime / "venv/bin/wisp")
    current = runner.run([claude, "mcp", "get", name])
    if current.exit == 0:
        if _is_ours(current.stdout, wisp_bin, server):
            return "present", None
        return "foreign", foreign
    added = runner.run([claude, "mcp", "add", "--scope", "user", name, "--", wisp_bin, "mcp", server])
    if added.exit != 0:
        return "failed", failure
    return "added", None


def _register_mac(runner: Runner, paths: WispPaths, cfg: WispConfig) -> tuple[str, str | None]:
    return _register(runner, paths, cfg, MAC_MCP_NAME, "mac", MAC_FOREIGN, "não consegui registrar o controle do Mac no Claude; rode wisp setup harness de novo")


def _register_email(runner: Runner, paths: WispPaths, cfg: WispConfig) -> tuple[str, str | None]:
    return _register(runner, paths, cfg, MCP_NAME, "email", FOREIGN, "não consegui registrar o e-mail no Claude; rode wisp setup harness de novo")


def _register_brain(runner: Runner, paths: WispPaths, cfg: WispConfig) -> tuple[str, str | None]:
    return _register(runner, paths, cfg, BRAIN_MCP_NAME, "brain", BRAIN_FOREIGN, "não consegui registrar a busca no brain no Claude; rode wisp setup harness de novo")


def _failed(summary: str, **data: str) -> StepReport:
    return StepReport("harness", "failed", summary, data=dict(data))


def setup_harness(runner: Runner, paths: WispPaths, cfg: WispConfig, *, dry_run: bool, force_merge: bool = False) -> StepReport:
    if not cfg.brain or not Path(cfg.brain).expanduser().is_dir():
        return _failed("falta criar o cérebro antes", step="brain")
    claude_dir = paths.home / ".claude"
    if _managed_elsewhere(claude_dir):
        return _failed("harness gerenciado fora do Wisp")

    source = resources_root() / "harness"
    values = _values(cfg)
    claude_md_path = claude_dir / "CLAUDE.md"
    settings_path = claude_dir / "settings.json"
    if not dry_run:
        seed_folder(wisp_root(cfg))          # the wizard has no folder step: a new user starts from the full template
    block, agente_problem = _block(source, cfg, values)
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
    email_state, email_problem = ("skipped", None) if dry_run else _register_email(runner, paths, cfg)
    brain_state, brain_problem = ("skipped", None) if dry_run else _register_brain(runner, paths, cfg)
    if email_state in ("present", "added"):
        ours["permissions"]["allow"].extend(MCP_ALLOW)
    if brain_state in ("present", "added"):
        ours["permissions"]["allow"].extend(BRAIN_MCP_ALLOW)
    mac_state, mac_problem = ("skipped", None) if dry_run else _register_mac(runner, paths, cfg)
    if mac_state in ("present", "added"):
        ours["permissions"]["allow"].extend(MAC_ALLOW)
    new_settings, notes = merge_settings(user_settings or {}, ours)

    changes = install_tree(source, claude_dir, plan, values, dry_run=True, roots=_roots(cfg))
    claude_md_kind = "conflict" if block_conflict else "added" if user_md is None else "merged" if new_md != user_md else "skipped"
    changes.append(Change("CLAUDE.md", claude_md_kind))
    changes.append(Change("settings.json", "added" if user_settings is None else "merged" if new_settings != user_settings else "skipped"))

    pending = [c for c in changes if c.kind in ("added", "updated", "merged")]
    conflicts = [c for c in changes if c.kind == "conflict"]
    data = {"backup": "", "added": str(sum(c.kind == "added" for c in changes)), "conflicts": str(len(conflicts))}
    details = [Detail("conflito", 0, f"{c.rel}: editado por você, mantido" if c.rel != "CLAUDE.md" else "CLAUDE.md: o bloco do Wisp foi editado por você, mantido") for c in conflicts]
    details += [Detail("settings", 0, note) for note in notes]
    if agente_problem:
        details.append(Detail("agente", 0, agente_problem))
    if email_problem:
        details.append(Detail("e-mail", 0, email_problem))
    if brain_problem:
        details.append(Detail("brain", 0, brain_problem))
    if mac_problem:
        details.append(Detail("controle do mac", 0, mac_problem))
    if dry_run:
        return StepReport("harness", "done", "dry run: nada foi escrito", details, data)

    if pending:
        saved = backup(claude_dir, paths.state / "backups", datetime.now().strftime("%Y%m%d-%H%M%S"))
        data["backup"] = str(saved) if saved else ""
        install_tree(source, claude_dir, manifest, values, roots=_roots(cfg))
        if new_md != user_md:
            atomic_write(claude_md_path, new_md.encode(), mode=_file_mode(claude_md_path))
        if new_settings != user_settings:
            atomic_write(settings_path, json.dumps(new_settings, indent=2, ensure_ascii=False) + "\n", mode=_file_mode(settings_path))
    if BLOCK_KEY in plan.files:
        manifest.files[BLOCK_KEY] = plan.files[BLOCK_KEY]
    if manifest != _load_manifest(manifest_path):
        atomic_write(manifest_path, json.dumps({"version": manifest.version, "files": manifest.files}, indent=2, sort_keys=True) + "\n")

    if not pending and "added" not in (email_state, brain_state, mac_state):
        return StepReport("harness", "skipped", "o harness já está instalado", details, data)
    summary = "harness instalado"
    if conflicts:
        summary += f"; {len(conflicts)} arquivo(s) editado(s) por você foram mantidos"
    return StepReport("harness", "done", summary, details, data)


def update_persona_block(paths: WispPaths, cfg: WispConfig, *, dry_run: bool) -> tuple[str, str, str]:
    """Re-renders only the CLAUDE.md block and its manifest sha. Returns (kind, reason, agente_problem) with kind one of
    updated | unchanged | absent | conflict | failed (agente_problem is set when agente.md fell back to the template); nothing else in ~/.claude is touched and no backup is made."""
    claude_dir = paths.home / ".claude"
    md_path = claude_dir / "CLAUDE.md"
    if _managed_elsewhere(claude_dir):
        return "failed", "o harness é gerenciado fora do Wisp", ""
    if not md_path.exists():
        return "absent", "", ""
    block, agente_problem = _block(resources_root() / "harness", cfg, _values(cfg))
    manifest_path = paths.config / MANIFEST_NAME
    manifest = _load_manifest(manifest_path)
    try:
        user_md = md_path.read_bytes().decode()
        existing = current_block(user_md)
        new_md = merge_claude_md(user_md, block)
    except (UnicodeDecodeError, ValueError):
        return "failed", "o CLAUDE.md tem marcadores do Wisp quebrados ou não é texto", ""
    if existing is None:
        return "absent", "", ""
    if new_md == user_md:
        return "unchanged", "", agente_problem or ""
    if block_digest(existing) != manifest.files.get(BLOCK_KEY):
        return "conflict", "o bloco do Wisp no CLAUDE.md foi editado por você e foi mantido", agente_problem or ""
    if not dry_run:
        atomic_write(md_path, new_md.encode(), mode=_file_mode(md_path))
        manifest.files[BLOCK_KEY] = block_digest(block)
        atomic_write(manifest_path, json.dumps({"version": manifest.version, "files": manifest.files}, indent=2, sort_keys=True) + "\n")
    return "updated", "", agente_problem or ""
