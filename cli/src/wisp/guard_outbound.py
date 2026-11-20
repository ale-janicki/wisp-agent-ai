import re
import shlex
from pathlib import Path

from wisp.paths import WispPaths

GUARD_PREFIX = "wisp-guard:"
MAIL_MESSAGE = (
    GUARD_PREFIX + " blocked, sending mail from a script skips the user's approval. "
    "Use the email_send tool, which asks the user first. Best-effort defense in depth"
)

SERVER_MESSAGE = (
    GUARD_PREFIX + " blocked, starting the email server by hand or touching WISP_APPROVAL_SOCKET would skip the user's approval. "
    "Use the email_send tool, which asks the user first. Best-effort defense in depth"
)

SQUASH = re.compile(r"[\"'`\\+\s,\[\]()]")
TOKEN_SPLIT = re.compile(r"[\s;|&<>(){}\"'`=,:]+")
MAIL_APP = re.compile(r"application(id)?(com\.apple\.)?mail|com\.apple\.mail")
PYTHON_LAUNCHER = re.compile(r"\bpython[\d.]*\b|\bpypy\d*\b|\bipython\b", re.I)
WISP_EMAIL = re.compile(r"wisp\.?email|fromwispimportemail|mailapp")
LIGHT = re.compile(r"[\"'`\\]")
MCP_SERVER = re.compile(r"(^|[\s/;&|(])wisp(\.exe)?\s+(-\S+\s+)*mcp(?=\s|$)|\s-m\s+wisp\b.*\smcp(?=\s|$)")
OPEN_MAILTO = re.compile(r"(^|[\s/;&|(])open\s.*mailto:")
HEREDOC = re.compile(r"<<-?\s*[\"']?(\w+)[\"']?([^\n]*)\n.*?(\n\s*\1\s*(?=\n|$)|$)", re.S)
OPERATORS = {";", "&", "&&", "|", "||", "(", ")", "\n", "|&", ";;"}
REDIRECTS = {"<", "<<", "<<<", ">", ">>", "<&", ">&", "<>"}
OSASCRIPT_VALUE_FLAGS = {"-e", "-l", "-s"}
INTERPRETER = re.compile(r"python[\d.]*|pypy\d*|ipython|node|ruby|perl|bash|sh|zsh")
INLINE_FLAGS = {"-c", "-e", "-m", "-p", "-E", "--eval", "--print"}
INTERPRETER_VALUE_FLAGS = {"-W", "-X", "-r", "-I", "-o", "--require", "--import"}
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


def _script_files(command: str) -> list[str] | None:
    flat = HEREDOC.sub(lambda m: " " + m.group(2), command).replace("\n", " ; ")
    lexer = shlex.shlex(flat, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        words = list(lexer)
    except ValueError:
        return None
    files: list[str] = []
    index = 0
    while index < len(words):
        name = Path(words[index]).name
        osascript = name == "osascript"
        if not osascript and not INTERPRETER.fullmatch(name):
            index += 1
            continue
        value_flags = OSASCRIPT_VALUE_FLAGS if osascript else INTERPRETER_VALUE_FLAGS
        index += 1
        seen_file = False
        while index < len(words) and words[index] not in OPERATORS:
            word = words[index]
            if not osascript and (word in INLINE_FLAGS or word == "-"):
                break
            if word in value_flags:
                index += 2
                continue
            if word in REDIRECTS or re.fullmatch(r"\d*[<>]+&?\d*", word):
                index += 2
                continue
            if word != "-" and not word.startswith("-") and not seen_file:
                files.append(word)
                seen_file = True
            index += 1
    return files


def _interpreter_contents(command: str, cwd: Path, home: Path) -> tuple[str, bool]:
    files = _script_files(command)
    if files is None:
        return "", True
    chunks: list[str] = []
    for name in files:
        path = Path(home / name[2:] if name.startswith("~/") else name)
        path = path if path.is_absolute() else cwd / path
        try:
            if not path.is_file() or path.stat().st_size > SCRIPT_READ_LIMIT:
                return "", True
            chunks.append(path.read_bytes().decode("utf-8", errors="replace"))
        except OSError:
            return "", True
    return "\n".join(chunks), False


def _starts_server(text: str) -> bool:
    plain = re.sub(r"\s+", " ", LIGHT.sub("", text)).casefold()
    squashed = SQUASH.sub("", text).casefold()
    listed = re.sub(r"\s+", " ", re.sub(r"[\"'`\\,\[\]()]", " ", text)).casefold()
    return bool(MCP_SERVER.search(plain) or MCP_SERVER.search(listed) or "wisp_approval_socket" in plain or "wisp_approval_socket" in squashed)


def _sends_mail(command: str, combined: str) -> bool:
    if OPEN_MAILTO.search(re.sub(r"\s+", " ", LIGHT.sub("", command)).casefold()):
        return True
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
    file_text, unreadable = _interpreter_contents(command, cwd, paths.home)
    if unreadable:
        return MAIL_MESSAGE
    combined = command + "\n" + _script_contents(command, cwd, paths.home) + "\n" + file_text
    if _starts_server(combined):
        return SERVER_MESSAGE
    return MAIL_MESSAGE if _sends_mail(command, combined) else None
