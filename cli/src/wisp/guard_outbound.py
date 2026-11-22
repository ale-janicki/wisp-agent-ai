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

HELPER_MESSAGE = (
    GUARD_PREFIX + " blocked, calling the wisp-mac helper directly skips the check that keeps messages from being sent without the user's approval. "
    "Use `wisp mac ...` or the mac_* tools. Best-effort defense in depth"
)

SQUASH = re.compile(r"[\"'`\\+\s,\[\]()]")
TOKEN_SPLIT = re.compile(r"[\s;|&<>(){}\"'`=,:]+")
MAIL_APP = re.compile(r"application(id)?(com\.apple\.)?mail|com\.apple\.mail")
PYTHON_LAUNCHER = re.compile(r"\bpython[\d.]*\b|\bpypy\d*\b|\bipython\b", re.I)
WISP_EMAIL = re.compile(r"wisp\.?email|fromwispimportemail|mailapp")
LIGHT = re.compile(r"[\"'`\\]")
MCP_SERVER = re.compile(r"(^|[\s/;&|(])wisp(\.exe)?\s+(-\S+\s+)*mcp(?=\s|$)|\s-m\s+wisp\b.*\smcp(?=\s|$)")
HELPER_DIRS = ("contents/helpers",)
SINGLE_VARIABLE = re.compile(r"\$\{?(\w+)\}?")
UI_SCRIPT = re.compile(r"(systemevents.*(click|keystroke|keycode))|objc\.import|cgevent")
UI_MESSAGE = (
    GUARD_PREFIX + " blocked, driving the screen with osascript, System Events or CGEvent from a shell can send without the user's approval. "
    "Use the mac_* tools. Best-effort defense in depth, not a lock"
)
OPEN_MAILTO = re.compile(r"(^|[\s/;&|(])open\s.*mailto:")
HEREDOC = re.compile(r"<<-?\s*[\"']?(\w+)[\"']?([^\n]*)\n.*?(\n\s*\1\s*(?=\n|$)|$)", re.S)
OPERATORS = {";", "&", "&&", "|", "||", "(", ")", "\n", "|&", ";;"}
REDIRECTS = {"<", "<<", "<<<", ">", ">>", "<&", ">&", "<>"}
INTERPRETER = re.compile(r"python[\d.]*|pypy\d*|ipython|node|ruby|perl|bash|sh|zsh")
SHELLS = {"bash", "sh", "zsh"}
PYTHON_PLAIN_FLAGS = "bBdEhiIOPqsSuvVxR"
PYTHON_CODE_CLUSTER = re.compile(rf"-[{PYTHON_PLAIN_FLAGS}]*c.*")
PYTHON_MODULE_CLUSTER = re.compile(rf"-[{PYTHON_PLAIN_FLAGS}]*m")
PYTHON_MODULE_ATTACHED = re.compile(rf"-[{PYTHON_PLAIN_FLAGS}]*m(.+)")
INTERPRETER_PROFILES = {
    "python": ({"-W", "-X", "--check-hash-based-pycs"}, set(), PYTHON_CODE_CLUSTER),
    "shell": ({"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}, set(), re.compile(r"-[A-Za-z]*c[A-Za-z]*")),
    "perl": ({"-I"}, set(), re.compile(r"-[lnpaWwtTuUsScCfF0-9]*[eE]")),
    "ruby": ({"-I", "-r", "-C"}, set(), re.compile(r"-[nlpaswSdyvW0-9]*e")),
    "node": ({"-r", "--require", "--import", "-C", "--conditions", "--loader", "--experimental-loader", "--input-type"}, {"-e", "-p", "-pe", "-ep", "--eval", "--print"}, None),
    "osascript": ({"-l", "-s"}, {"-e"}, None),
}
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


SHELL_SUFFIXES = {".sh", ".command", ".bash", ".zsh"}


def _shell_script_contents(command: str, cwd: Path, home: Path) -> str:
    chunks: list[str] = []
    for token in _tokens(command):
        if Path(token).suffix.lower() not in SHELL_SUFFIXES:
            continue
        path = Path(home / token[2:] if token.startswith("~/") else token)
        path = path if path.is_absolute() else cwd / path
        try:
            if path.is_file() and path.stat().st_size <= SCRIPT_READ_LIMIT:
                chunks.append(path.read_bytes().decode("utf-8", errors="replace"))
        except OSError:
            continue
    return "\n".join(chunks)


def _family(name: str) -> str:
    if name in SHELLS:
        return "shell"
    if name.startswith(("python", "pypy", "ipython")):
        return "python"
    return name


def _python_module(args: list[str], index: int) -> list[str] | None:
    word = args[index]
    module = None
    if PYTHON_MODULE_CLUSTER.fullmatch(word):
        module = args[index + 1] if index + 1 < len(args) else None
    else:
        attached = PYTHON_MODULE_ATTACHED.fullmatch(word)
        module = attached.group(1) if attached else None
    if module is None:
        return [] if PYTHON_MODULE_CLUSTER.fullmatch(word) else None
    base = module.replace(".", "/")
    return [base + ".py", base + "/__main__.py"]


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
    family = _family(name)
    value_flags, inline_flags, code_cluster = INTERPRETER_PROFILES[family]
    files: list[str] = []
    seen_file = False
    index = 0
    while index < len(args):
        word = args[index]
        if family == "python":
            module = _python_module(args, index)
            if module is not None:
                return files + module, True
        if word in inline_flags or (code_cluster is not None and code_cluster.fullmatch(word)):
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
        if word != "-" and not word.startswith(("-", "+")) and not seen_file:
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
    lexer.commenters = ""
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


def _helper_path(word: str) -> bool:
    lowered = word.lower()
    return Path(word).name == "wisp-mac" or any(d in lowered for d in HELPER_DIRS)


def _shell_code(args: list[str]) -> str | None:
    for index, word in enumerate(args):
        if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", word) and index + 1 < len(args):
            return args[index + 1]
    return None


def _helper_in_words(words: list[str], depth: int) -> bool:
    tainted: set[str] = set()
    in_helpers = False
    for segment, _ in _segments(words):
        for word in segment:
            if ASSIGNMENT.match(word) and _helper_path(word.split("=", 1)[1]):
                tainted.add(word.split("=", 1)[0])
        start = _command_index(segment)
        if start is None:
            continue
        word = segment[start]
        name = Path(word).name
        if name in {"cd", "pushd"} and len(segment) > start + 1:
            in_helpers = in_helpers or _helper_path(segment[start + 1].rstrip("/") + "/x")
            continue
        if _helper_path(word) or (in_helpers and not word.startswith("-")):
            return True
        if "$" in word:
            single = SINGLE_VARIABLE.fullmatch(word)
            if not single or single.group(1) in tainted or "mac" in single.group(1).lower():
                return True
        if "*" in word or "?" in word:
            return True
        if name in SHELLS and depth < 3:
            code = _shell_code(segment[start + 1:])
            if code is not None and _calls_helper(code, depth + 1):
                return True
    return False


def _calls_helper(text: str, depth: int = 0) -> bool:
    def words_of(chunk: str) -> list[str] | None:
        lexer = shlex.shlex(chunk.replace("\n", " ; "), posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        try:
            return list(lexer)
        except ValueError:
            return None

    words = words_of(text)
    if words is not None:
        return _helper_in_words(words, depth)
    return any(_helper_in_words(w, depth) for w in (words_of(line) for line in text.splitlines()) if w is not None)


def _osascript_in_command_position(command: str, depth: int = 0) -> bool:
    flat = HEREDOC.sub(lambda m: " " + m.group(2), command).replace("\n", " ; ")
    lexer = shlex.shlex(flat, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        words = list(lexer)
    except ValueError:
        return "osascript" in command
    for segment, _ in _segments(words):
        start = _command_index(segment)
        if start is None:
            continue
        name = Path(segment[start]).name
        if name == "osascript":
            return True
        if name in SHELLS and depth < 3:
            code = _shell_code(segment[start + 1:])
            if code is not None and _osascript_in_command_position(code, depth + 1):
                return True
    return False


def _drives_ui(command: str, combined: str) -> bool:
    return _osascript_in_command_position(command) and bool(UI_SCRIPT.search(SQUASH.sub("", combined).casefold()))


def _sends_mail(command: str, combined: str) -> bool:
    if OPEN_MAILTO.search(re.sub(r"\s+", " ", LIGHT.sub("", command)).casefold()):
        return True
    squashed = SQUASH.sub("", combined).casefold()
    if "osascript" in squashed and MAIL_APP.search(squashed):
        unsent = squashed.replace("sender", "")
        if "send" in unsent or "outgoingmessage" in unsent:
            return True
    return bool(PYTHON_LAUNCHER.search(combined) and WISP_EMAIL.search(squashed))


def hook_guard_outbound(payload: dict, paths: WispPaths, ui_scripts: bool = True) -> str | None:
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
    if _calls_helper(command + "\n" + _shell_script_contents(command, cwd, paths.home)):
        return HELPER_MESSAGE
    if ui_scripts and _drives_ui(command, combined):
        return UI_MESSAGE
    return MAIL_MESSAGE if _sends_mail(command, combined) else None
