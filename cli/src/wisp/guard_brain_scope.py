import os
import re
from collections.abc import Mapping
from pathlib import Path

GUARD_PREFIX = "wisp-guard:"
SCOPE_ENV = "WISP_BRAIN_SCOPE"
PATH_KEYS = ("file_path", "notebook_path", "path")
SEARCH_TOOLS = {"Glob", "Grep"}
GLOB_CHARS = re.compile(r"[*?\[{]")
PROTECTED = {".git", ".obsidian"}
MESSAGE = GUARD_PREFIX + " blocked, the brain harvest may only touch files inside the brain folder ({what}). Stay inside the working directory"


def _inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _protected(path: Path, root: Path) -> bool:
    return path != root and bool(PROTECTED.intersection(path.relative_to(root).parts))


def _resolve(raw: str, base: Path) -> Path:
    return Path(os.path.realpath(base / os.path.expanduser(raw)))


def _pattern_escapes(pattern: str, base: Path, root: Path) -> bool:
    expanded = os.path.expanduser(pattern)
    segments = expanded.split("/")
    static: list[str] = []
    for segment in segments:
        if GLOB_CHARS.search(segment):
            break
        static.append(segment)
    rest = segments[len(static) :]
    if ".." in rest or PROTECTED.intersection(segments):
        return True
    prefix = "/".join(static) if len(static) < len(segments) else expanded
    if not prefix:
        prefix = "/" if expanded.startswith("/") else "."
    return not _inside(_resolve(prefix, base), root)


def hook_guard_brain_scope(payload: dict, env: Mapping[str, str]) -> str | None:
    scope = env.get(SCOPE_ENV)
    if not scope:
        return None
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    root = Path(os.path.realpath(scope))
    cwd = payload.get("cwd")
    base = Path(cwd) if isinstance(cwd, str) and cwd else root
    tool = payload.get("tool_name") or "tool"
    given = [(key, tool_input[key]) for key in PATH_KEYS if tool_input.get(key) is not None]
    if tool in SEARCH_TOOLS and not any(key == "path" and value for key, value in given):
        given.append(("path", "."))
    for _, value in given:
        if not isinstance(value, str):
            return MESSAGE.format(what=tool)
        resolved = _resolve(value or ".", base)
        if not _inside(resolved, root) or _protected(resolved, root):
            return MESSAGE.format(what=tool)
    pattern = tool_input.get("pattern")
    if tool == "Glob" and isinstance(pattern, str):
        search = _resolve(str(tool_input.get("path") or "."), base)
        if _pattern_escapes(pattern, search, root):
            return MESSAGE.format(what="Glob pattern")
    return None
