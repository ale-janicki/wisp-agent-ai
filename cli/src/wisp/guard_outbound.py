import os
import re
from pathlib import Path

from wisp.paths import WispPaths

GUARD_PREFIX = "wisp-guard:"
MAIL_MESSAGE = (
    GUARD_PREFIX + " blocked, sending mail from a script skips the user's approval. "
    "Use the email_send tool, which asks the user first. Best-effort defense in depth"
)
APPROVALS_MESSAGE = (
    GUARD_PREFIX + " the approvals folder is off limits ({where}): only the user answers an approval. "
    "Best-effort defense in depth"
)

SQUASH = re.compile(r"[\"'`\\+\s,\[\]()]")
UNQUOTE = re.compile(r"[\"'`\\]")
TOKEN_SPLIT = re.compile(r"[\s;|&<>(){}\"'`=,:]+")
MAIL_APP = re.compile(r"application(id)?(com\.apple\.)?mail|com\.apple\.mail")
PYTHON_LAUNCHER = re.compile(r"\bpython[\d.]*\b|\bpypy\d*\b|\bipython\b", re.I)
WISP_EMAIL = re.compile(r"wisp\.?email|fromwispimportemail|mailapp")
SCRIPT_SUFFIXES = {".py", ".js", ".jxa", ".scpt", ".applescript", ".sh", ".command"}
SCRIPT_READ_LIMIT = 1_000_000
PATH_KEYS = ("file_path", "notebook_path", "path", "pattern")
APPROVALS_COMPONENT = re.compile(r"(^|/)approvals(/|$)")


def _tokens(text: str) -> list[str]:
    return [t for t in TOKEN_SPLIT.split(text) if t]


def _script_contents(command: str, cwd: Path, home: Path) -> str:
    chunks: list[str] = []
    for token in _tokens(command):
        if Path(token).suffix.lower() not in SCRIPT_SUFFIXES:
            continue
        path = Path(home / token[2:] if token.startswith("~/") else token)
        path = path if path.is_absolute() else cwd / path
        try:
            if path.is_file() and path.stat().st_size <= SCRIPT_READ_LIMIT:
                chunks.append(path.read_bytes().decode("utf-8", errors="replace"))
        except OSError:
            continue
    return "\n".join(chunks)


def _sends_mail(command: str, cwd: Path, home: Path) -> bool:
    combined = command + "\n" + _script_contents(command, cwd, home)
    squashed = SQUASH.sub("", combined).casefold()
    if "osascript" in squashed and MAIL_APP.search(squashed):
        unsent = squashed.replace("sender", "")
        if "send" in unsent or "outgoingmessage" in unsent:
            return True
    return bool(PYTHON_LAUNCHER.search(combined) and WISP_EMAIL.search(squashed))


def _approvals_roots(paths: WispPaths) -> list[Path]:
    declared = Path(os.path.normpath(paths.state / "approvals"))
    return list(dict.fromkeys([declared, declared.resolve()]))


def _expand(token: str, paths: WispPaths, cwd: Path) -> Path:
    token = re.sub(r"\$\{?HOME\}?", lambda _: str(paths.home), token)
    token = re.sub(r"\$\{?XDG_STATE_HOME\}?", lambda _: str(paths.state.parent), token)
    if token == "~" or token.startswith("~/"):
        token = str(paths.home) + token[1:]
    path = Path(token)
    return Path(os.path.normpath(path if path.is_absolute() else cwd / path))


def _under(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _names_approvals(sources: list[str], paths: WispPaths, cwd: Path, *, shell: bool) -> bool:
    roots = _approvals_roots(paths)
    parents = {paths.state, paths.state.resolve()}
    parent_named = bool({cwd, cwd.resolve()} & parents)
    for source in sources:
        for token in _tokens(source):
            if shell and token.casefold().endswith(".decision"):
                return True
            if "/" not in token and not token.startswith("~") and token != "approvals":
                continue
            expanded = _expand(token, paths, cwd)
            for candidate in {expanded, expanded.resolve()}:
                if any(_under(candidate, root) for root in roots):
                    return True
                parent_named = parent_named or candidate in parents
    return parent_named and any(APPROVALS_COMPONENT.search(source) for source in sources)


def _shell_forms(command: str) -> list[str]:
    plain = re.sub(r"\$\{(\w+)\}", r"$\1", re.sub(r"/{2,}", "/", command))
    return [plain, UNQUOTE.sub("", plain)]


def hook_guard_outbound(payload: dict, paths: WispPaths) -> str | None:
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    tool = payload.get("tool_name") or "tool"
    cwd = Path(payload["cwd"]) if isinstance(payload.get("cwd"), str) and payload["cwd"] else paths.home
    if tool == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str):
            return None
        if _sends_mail(command, cwd, paths.home):
            return MAIL_MESSAGE
        if _names_approvals(_shell_forms(command), paths, cwd, shell=True):
            return APPROVALS_MESSAGE.format(where="Bash")
        return None
    targets = [v for key in PATH_KEYS if isinstance(v := tool_input.get(key), str)]
    if _names_approvals(targets, paths, cwd, shell=False):
        return APPROVALS_MESSAGE.format(where=tool)
    return None
