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
SHELLS = {"bash", "sh", "zsh"}
CODE_FLAG_CLUSTER = re.compile(r"-[A-Za-z]*c[A-Za-z]*")
EVAL_FLAG_CLUSTER = re.compile(r"-[A-Za-z]*e[A-Za-z]*")
INLINE_FLAGS = {"-m", "-p", "-E", "--eval", "--print"}
INTERPRETER_VALUE_FLAGS = {"-W", "-X", "-r", "-I", "-o", "--require", "--import"}
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*=")
FD_REDIRECT = re.compile(r"\d*[<>]+&?\d*")
WRAPPER_VALUE_FLAGS = {
    "env": {"-u", "-C", "-S", "--unset", "--chdir"},
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U"},
    "exec": {"-a"},
    "nohup": set(),
    "command": set(),
    "time": {"-o", "-f"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "xargs": {"-n", "-I", "-L", "-P", "-s", "-d", "-E", "-a", "-J"},
}
UV_VALUE_FLAGS = {"-p", "--python", "--with", "--with-requirements", "--directory", "--project", "--env-file", "--index", "--extra", "--group", "--package"}
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


def _inline_flag(name: str, word: str) -> bool:
    if word in INLINE_FLAGS:
        return True
    if name in SHELLS or name.startswith(("python", "pypy", "ipython")):
        return bool(CODE_FLAG_CLUSTER.fullmatch(word))
    return bool(EVAL_FLAG_CLUSTER.fullmatch(word))


def _command_index(segment: list[str]) -> int | None:
    index = 0
    while index < len(segment):
        word = segment[index]
        name = Path(word).name
        if ASSIGNMENT.match(word):
            index += 1
            continue
        if name not in WRAPPER_VALUE_FLAGS:
            return index
        value_flags = WRAPPER_VALUE_FLAGS[name]
        index += 1
        if name == "command" and index < len(segment) and segment[index] in {"-v", "-V"}:
            return None
        while index < len(segment) and (segment[index].startswith("-") or ASSIGNMENT.match(segment[index])):
            index += 2 if segment[index] in value_flags else 1
        if name == "timeout" and index < len(segment):
            index += 1
    return None


def _interpreter_args(name: str, args: list[str]) -> tuple[list[str], bool]:
    osascript = name == "osascript"
    value_flags = OSASCRIPT_VALUE_FLAGS if osascript else INTERPRETER_VALUE_FLAGS
    files: list[str] = []
    seen_file = False
    index = 0
    while index < len(args):
        word = args[index]
        if not osascript and _inline_flag(name, word):
            return files, True
        if word == "<" and index + 1 < len(args):
            files.append(args[index + 1])
            index += 2
            continue
        if word in value_flags:
            index += 2
            continue
        if word in REDIRECTS or FD_REDIRECT.fullmatch(word):
            index += 2
            continue
        if word != "-" and not word.startswith("-") and not seen_file:
            files.append(word)
            seen_file = True
        index += 1
    return files, False


def _uv_args(args: list[str]) -> tuple[list[str], bool]:
    if not args or args[0] != "run":
        return [], False
    index = 1
    while index < len(args):
        word = args[index]
        if word == "--script" and index + 1 < len(args):
            return [args[index + 1]], False
        if word in UV_VALUE_FLAGS:
            index += 2
            continue
        if word.startswith("-"):
            index += 1
            continue
        name = Path(word).name
        if INTERPRETER.fullmatch(name):
            return _interpreter_args(name, args[index + 1:])
        return [word], False
    return [], False


def _segments(words: list[str]) -> list[tuple[list[str], str]]:
    segments: list[tuple[list[str], str]] = []
    current: list[str] = []
    for word in words:
        if word in OPERATORS:
            segments.append((current, word))
            current = []
        else:
            current.append(word)
    segments.append((current, ""))
    return segments


def _segment_files(segment: list[str]) -> tuple[list[str], bool, bool]:
    start = _command_index(segment)
    if start is None:
        return [], False, False
    name = Path(segment[start]).name
    args = segment[start + 1:]
    if name == "uv":
        files, inline = _uv_args(args)
    elif name == "osascript" or INTERPRETER.fullmatch(name):
        files, inline = _interpreter_args(name, args)
    else:
        return [], False, False
    return files, inline, True


def _script_files(command: str) -> list[str] | None:
    flat = HEREDOC.sub(lambda m: " " + m.group(2), command).replace("\n", " ; ")
    lexer = shlex.shlex(flat, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        words = list(lexer)
    except ValueError:
        return None
    segments = _segments(words)
    files: list[str] = []
    for position, (segment, _) in enumerate(segments):
        segment_files, inline, interpreter = _segment_files(segment)
        files.extend(segment_files)
        if not interpreter or inline or segment_files or position == 0:
            continue
        previous, separator = segments[position - 1]
        if separator != "|":
            continue
        source = _command_index(previous)
        if source is not None and Path(previous[source]).name == "cat":
            files.extend(w for w in previous[source + 1:] if not w.startswith("-"))
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
            info = path.stat()
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError:
            return "", True
        try:
            if not path.is_file() or info.st_size > SCRIPT_READ_LIMIT:
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
