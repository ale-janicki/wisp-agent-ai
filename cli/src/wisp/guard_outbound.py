import re
from pathlib import Path

from wisp.paths import WispPaths

GUARD_PREFIX = "wisp-guard:"
MAIL_MESSAGE = (
    GUARD_PREFIX + " blocked, sending mail from a script skips the user's approval. "
    "Use the email_send tool, which asks the user first. Best-effort defense in depth"
)

SQUASH = re.compile(r"[\"'`\\+\s,\[\]()]")
TOKEN_SPLIT = re.compile(r"[\s;|&<>(){}\"'`=,:]+")
MAIL_APP = re.compile(r"application(id)?(com\.apple\.)?mail|com\.apple\.mail")
PYTHON_LAUNCHER = re.compile(r"\bpython[\d.]*\b|\bpypy\d*\b|\bipython\b", re.I)
WISP_EMAIL = re.compile(r"wisp\.?email|fromwispimportemail|mailapp")
SCRIPT_SUFFIXES = {".py", ".js", ".jxa", ".scpt", ".applescript", ".sh", ".command"}
SCRIPT_READ_LIMIT = 1_000_000


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


def hook_guard_outbound(payload: dict, paths: WispPaths) -> str | None:
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict) or payload.get("tool_name") != "Bash":
        return None
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    cwd = Path(payload["cwd"]) if isinstance(payload.get("cwd"), str) and payload["cwd"] else paths.home
    return MAIL_MESSAGE if _sends_mail(command, cwd, paths.home) else None
