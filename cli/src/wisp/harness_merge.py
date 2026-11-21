import copy
import hashlib
import re
import shutil
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

from wisp.fsops import atomic_write, ensure_dir

BEGIN = "<!-- wisp:begin -->"
END = "<!-- wisp:end -->"
TREE_DIRS = ("agents", "skills", "commands")
BACKUP_ITEMS = ("CLAUDE.md", "settings.json", "agents", "commands", "skills", "hooks")
PERMISSION_LISTS = ("allow", "deny", "ask")
REVOKED_ALLOW = ("Bash(~/.local/bin/wisp aprender add:*)",)


@dataclass
class Change:
    rel: str
    kind: Literal["added", "updated", "skipped", "conflict", "merged"]


@dataclass
class InstalledManifest:
    version: int = 1
    files: dict[str, str] = field(default_factory=dict)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


PLACEHOLDER = re.compile(r"\{\{(\w+)\}\}")


def render(text: str, values: Mapping[str, str]) -> str:
    return PLACEHOLDER.sub(lambda m: values.get(m.group(1), m.group(0)), text)


AGENTE_PLACEHOLDER = re.compile(r"\{\{([A-Z_]+)\}\}")


def render_agente(text: str, values: Mapping[str, str]) -> str:
    rendered = AGENTE_PLACEHOLDER.sub(lambda m: values.get(m.group(1), m.group(0)), text)
    return rendered.replace(BEGIN, "").replace(END, "")


def wrap_block(body: str) -> str:
    return f"{BEGIN}\n{body}{'' if body.endswith(chr(10)) else chr(10)}{END}\n"


BLOCK_KEY = "CLAUDE.md#block"


def detect_eol(text: str) -> str:
    crlf = text.count("\r\n")
    return "\r\n" if crlf > text.count("\n") - crlf else "\n"


def block_digest(text: str) -> str:
    return sha256(text.replace("\r\n", "\n").strip("\n").encode())


def find_block(user: str, begin: str, end: str, label: str) -> str | None:
    start = user.find(begin)
    if start == -1 and end not in user:
        return None
    stop = user.find(end, start + len(begin)) if start != -1 else -1
    if stop == -1 or user.count(begin) != 1 or user.count(end) != 1:
        raise ValueError(f"os marcadores do Wisp no {label} estão incompletos")
    return user[start : stop + len(end)]


def merge_block(user: str | None, block: str, begin: str, end: str, label: str) -> str:
    if user is None:
        return block
    eol = detect_eol(user)
    inner = block.rstrip("\n").replace("\n", eol)
    existing = find_block(user, begin, end, label)
    if existing is None:
        return user + eol * 2 + inner + (eol if block.endswith("\n") else "")
    start = user.index(existing)
    return user[:start] + inner + user[start + len(existing) :]


def current_block(user: str) -> str | None:
    return find_block(user, BEGIN, END, "CLAUDE.md")


def merge_claude_md(user: str | None, block: str) -> str:
    return merge_block(user, block, BEGIN, END, "CLAUDE.md")


def _append_missing(target: list, extra: list) -> None:
    for item in extra:
        if item not in target:
            target.append(item)


def _commands(group: object) -> set[str]:
    if isinstance(group, dict) and isinstance(group.get("command"), str) and "hooks" not in group:
        return {group["command"]}
    hooks = group.get("hooks") if isinstance(group, dict) else None
    return {h["command"] for h in hooks if isinstance(h, dict) and "command" in h} if isinstance(hooks, list) else set()


def _merge_permissions(merged: dict, ours: dict, notes: list[str]) -> None:
    if "permissions" not in merged:
        merged["permissions"] = copy.deepcopy(ours)
        return
    current = merged["permissions"]
    if not isinstance(current, dict):
        notes.append("permissions: mantido o valor do usuário")
        return
    for key, value in ours.items():
        if key not in current:
            current[key] = copy.deepcopy(value)
        elif key in PERMISSION_LISTS and isinstance(current[key], list) and isinstance(value, list):
            _append_missing(current[key], value)
        elif current[key] != value:
            notes.append(f"permissions.{key}: mantido o valor do usuário")


def _revoke_allow(merged: dict) -> None:
    permissions = merged.get("permissions")
    allow = permissions.get("allow") if isinstance(permissions, dict) else None
    if isinstance(allow, list):
        allow[:] = [rule for rule in allow if rule not in REVOKED_ALLOW]


def _merge_hooks(merged: dict, ours: dict, notes: list[str]) -> None:
    if "hooks" not in merged:
        merged["hooks"] = copy.deepcopy(ours)
        return
    current = merged["hooks"]
    if not isinstance(current, dict):
        notes.append("hooks: mantido o valor do usuário")
        return
    for event, groups in ours.items():
        if event not in current:
            current[event] = copy.deepcopy(groups)
        elif isinstance(current[event], list):
            existing = set().union(*(_commands(g) for g in current[event]))
            current[event].extend(copy.deepcopy(g) for g in groups if not _commands(g) & existing)
        else:
            notes.append(f"hooks.{event}: mantido o valor do usuário")


def merge_settings(user: dict, ours: dict) -> tuple[dict, list[str]]:
    merged = copy.deepcopy(user)
    notes: list[str] = []
    for key, value in ours.items():
        if key == "permissions":
            _merge_permissions(merged, value, notes)
            _revoke_allow(merged)
        elif key == "hooks":
            _merge_hooks(merged, value, notes)
        elif key not in merged:
            merged[key] = copy.deepcopy(value)
        elif merged[key] != value:
            notes.append(f"{key}: mantido o valor do usuário")
    return merged, notes


def has_symlink(path: Path, root: Path) -> bool:
    current = path
    while True:
        if current.is_symlink():
            return True
        if current == root or current.parent == current:
            return False
        current = current.parent


def _render_bytes(src: Path, values: Mapping[str, str]) -> bytes:
    raw = src.read_bytes()
    try:
        return render(raw.decode(), values).encode()
    except UnicodeDecodeError:
        return raw


def _classify(target: Path, root: Path, payload: bytes, recorded: str | None) -> str:
    if has_symlink(target, root) or (target.exists() and not target.is_file()):
        return "conflict"
    if not target.exists():
        return "added"
    current = target.read_bytes()
    if current == payload:
        return "skipped"
    return "updated" if sha256(current) == recorded else "conflict"


def install_tree(
    src: Path,
    dst: Path,
    manifest: InstalledManifest,
    values: Mapping[str, str],
    *,
    dry_run: bool = False,
    roots: Mapping[str, Path] | None = None,
) -> list[Change]:
    changes: list[Change] = []
    for sub in TREE_DIRS:
        root = (roots or {}).get(sub, src / sub)
        for source in sorted(p for p in root.rglob("*") if p.is_file() and not has_symlink(p, root)):
            rel = f"{sub}/{source.relative_to(root).as_posix()}"
            target = dst / rel
            payload = _render_bytes(source, values)
            kind = _classify(target, dst, payload, manifest.files.get(rel))
            if kind != "conflict":
                manifest.files[rel] = sha256(payload)
            if kind in ("added", "updated") and not dry_run:
                atomic_write(target, payload, mode=source.stat().st_mode & 0o777)
            changes.append(Change(rel, kind))
    return changes


def backup(claude_dir: Path, dest_root: Path, stamp: str) -> Path | None:
    present = [name for name in BACKUP_ITEMS if (claude_dir / name).exists() or (claude_dir / name).is_symlink()]
    if not present:
        return None
    dest = dest_root / f"claude-{stamp}"
    suffix = 1
    while dest.exists():
        suffix += 1
        dest = dest_root / f"claude-{stamp}-{suffix}"
    ensure_dir(dest)
    for name in present:
        source = claude_dir / name
        if source.is_dir() and not source.is_symlink():
            shutil.copytree(source, dest / name, symlinks=True)
        else:
            shutil.copy2(source, dest / name, follow_symlinks=False)
    return dest
