import os
import re
from pathlib import Path

from wisp.aprendizados import REL, lessons_path, pending_path
from wisp.config import WispConfig
from wisp.paths import WispPaths

GUARD_PREFIX = "wisp-guard:"
MESSAGE = (
    GUARD_PREFIX + " blocked, the learned-lessons files are the user's to change ({what}). "
    "Save a preference with `wisp aprender add \"<rule>\"` and let the user confirm it. Best-effort defense in depth"
)
FILE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
PATH_KEYS = ("file_path", "notebook_path", "path")
NAMES = ("aprendizados.md", "aprendizados-pendentes.md")
MENTION = re.compile(r"aprendizados", re.I)
HARMLESS_REDIRECT = re.compile(r"\d*>&\d+|\d*>>?\s*/dev/null")
WRITE_OPERATOR = re.compile(
    r">|\btee\b|\bsed\b[^|;&]*\s-\w*i|\bperl\b[^|;&]*\s-\w*i|\bmv\b|\bcp\b|\bdd\b|\btruncate\b|\binstall\b|\bln\b"
    r"|\bpython\d?(?:\.\d+)?\s+-c\b|\bnode\s+-e\b|\bruby\s+-e\b|\bperl\s+-e\b|\bawk\b[^|;&]*inplace"
)


def _protected(brain: str | None) -> set[str]:
    if not brain:
        return set()
    root = Path(brain).expanduser()
    return {os.path.realpath(p) for p in (lessons_path(root), pending_path(root))}


def _is_lessons_file(path: Path, protected: set[str]) -> bool:
    real = os.path.realpath(path)
    named = lambda p: p.name in NAMES and p.parent.name == REL.parent.name  # noqa: E731
    return real in protected or named(path) or named(Path(real))


def hook_guard_lessons(payload: dict, paths: WispPaths, cfg: WispConfig) -> str | None:
    tool, tool_input = payload.get("tool_name"), payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    cwd = Path(payload["cwd"]) if isinstance(payload.get("cwd"), str) and payload["cwd"] else paths.home
    protected = _protected(cfg.brain)
    if tool in FILE_TOOLS:
        for key in PATH_KEYS:
            raw = tool_input.get(key)
            if isinstance(raw, str) and raw and _is_lessons_file(cwd / os.path.expanduser(raw), protected):
                return MESSAGE.format(what=f"{tool} on {Path(raw).name}")
        return None
    command = tool_input.get("command")
    if tool == "Bash" and isinstance(command, str) and MENTION.search(command):
        if WRITE_OPERATOR.search(HARMLESS_REDIRECT.sub("", command)):
            return MESSAGE.format(what="a shell command that writes where `aprendizados` is named")
    return None
