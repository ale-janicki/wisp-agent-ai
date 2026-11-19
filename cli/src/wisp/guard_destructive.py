import os
import re
import shlex
from pathlib import Path

from wisp.config import WispConfig
from wisp.paths import WispPaths

GUARD_PREFIX = "wisp-guard:"
SAFE_WAY = "For files, move them to the Trash instead (`trash <path>`, or `mv <path> ~/.Trash/`); for anything else ask the user to do it themselves"
MESSAGE = GUARD_PREFIX + " blocked, this could destroy the user's data or Mac irreversibly ({what}). " + SAFE_WAY + ". Best-effort defense in depth"

USER_FOLDERS = ("Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library", "Applications",
                "Library/Mobile Documents", ".Trash")
SYSTEM_ROOTS = ("/", "/System", "/Library", "/Users", "/Applications", "/Volumes", "/usr", "/bin", "/sbin", "/etc")
WRAPPERS = {"sudo", "env", "command", "builtin", "nohup", "time", "exec", "nice", "doas", "caffeinate", "xargs"}
WRAPPER_ARG_FLAGS = {"sudo": {"-u", "-g", "-C", "-h"}, "doas": {"-u"}, "env": {"-u", "-C"}, "nice": {"-n"},
                     "xargs": {"-I", "-n", "-P", "-L", "-d", "-s", "-E", "-a"}}
KEYWORDS = {"{", "}", "(", ")", "if", "then", "elif", "else", "fi", "do", "done", "while", "until", "!"}
LOOP_HEADERS = {"for", "select"}
DECLARERS = {"export", "declare", "local", "readonly", "typeset"}
ASSIGN = re.compile(r"^\w+=")
SUBSTITUTION = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
DESTROYS = re.compile(r"\b(?:rm\s+(?:-\S*[rRf]|--(?:recursive|force))|rmdir|unlink)\b")
SHELL_C_CLUSTER = re.compile(r"-[A-Za-z]*c[A-Za-z]*")
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
GLOB_CHARS = re.compile(r"[*?\[]")
SAFE_DEVICES = {"/dev/null", "/dev/zero", "/dev/stdout", "/dev/stderr", "/dev/stdin", "/dev/tty"}
EMPTY_TRASH = re.compile(r"empty\s+(the\s+)?trash", re.I)
DEVICE_REDIRECT = re.compile(r">\s*/dev/r?disk", re.I)
OPERATORS = {";", "&&", "||", "|", "&", "(", ")", "|&", ";;"}
MAX_DEPTH = 3


class _Policy:
    def __init__(self, cfg: WispConfig, paths: WispPaths):
        self.home = Path(os.path.normpath(paths.home))
        self.brain = Path(os.path.normpath(os.path.expanduser(cfg.brain))) if cfg.brain else None
        self.wisp_dir = self.home / "Wisp"
        folders = {self.home / f for f in USER_FOLDERS}
        self.roots = {self.home, self.wisp_dir, *folders, *(Path(r) for r in SYSTEM_ROOTS)}
        if self.brain:
            self.roots.add(self.brain)
        self.trash = self.home / ".Trash"
        self.glob_parents = self.roots - {self.wisp_dir}
        self.root_keys = {str(r).casefold() for r in self.roots}
        self.glob_keys = {str(r).casefold() for r in self.glob_parents}
        self.sweep_keys = {str(self.home).casefold(), "/", "/users", "/volumes"}
        self.git_guarded = [p for p in (self.brain, self.wisp_dir) if p]

    def expand(self, token: str, cwd: Path) -> str:
        home = str(self.home)
        token = re.sub(r"\$\{?HOME\}?", lambda _: home, token)
        if token == "~" or token.startswith("~/"):
            token = home + token[1:]
        return os.path.normpath(token if os.path.isabs(token) else str(cwd / token))

    def is_root(self, path: str) -> bool:
        if path.casefold() in self.root_keys:
            return True
        try:
            if os.path.realpath(path).casefold() in self.root_keys:
                return True
            return os.path.exists(path) and any(os.path.exists(r) and os.path.samefile(r, path) for r in self.roots)
        except (OSError, ValueError):
            return False

    def hits(self, token: str, cwd: Path) -> bool:
        return any(self._hits(t, cwd) for t in _braces(token))

    def _hits(self, token: str, cwd: Path) -> bool:
        path = self.expand(token, cwd)
        parts = Path(path).parts
        for i, part in enumerate(parts):
            if not GLOB_CHARS.search(part):
                continue
            parent = str(Path(*parts[:i]) if i else Path("/")).casefold()
            literal = re.sub(r"[*?\[\]{}!.,^\-]", "", part)
            if parent in self.glob_keys or parent.startswith("/volumes"):
                if parent in self.sweep_keys or not literal:
                    return True
            return False
        return self.is_root(path) or self._volume_root(path)

    @staticmethod
    def _volume_root(path: str) -> bool:
        p = Path(path)
        return len(p.parts) == 3 and (p.parts[0], p.parts[1].casefold()) == ("/", "volumes")

    def in_guarded_git(self, cwd: Path) -> bool:
        return any(cwd == g or g in cwd.parents for g in self.git_guarded)

    def is_trash(self, token: str, cwd: Path) -> bool:
        path = Path(self.expand(token, cwd))
        trash = str(self.trash).casefold()
        return str(path).casefold() == trash or (str(path.parent).casefold() == trash
                                                 and GLOB_CHARS.search(path.name) is not None
                                                 and not re.sub(r"[*?\[\]!.]", "", path.name))


def _braces(token: str) -> list[str]:
    start = token.find("{")
    while start != -1:
        depth, commas = 0, []
        for i in range(start, len(token)):
            c = token[i]
            if c == "{":
                depth += 1
            elif c == "," and depth == 1:
                commas.append(i)
            elif c == "}":
                depth -= 1
                if depth == 0:
                    if commas:
                        bounds = [start, *commas, i]
                        out: list[str] = []
                        for a, b in zip(bounds, bounds[1:]):
                            out += _braces(token[:start] + token[a + 1:b] + token[i + 1:])
                        return out[:256]
                    break
        start = token.find("{", start + 1)
    return [token]


def _subst(word: str, env: dict[str, str]) -> str:
    return re.sub(r"\$(?:\{(\w+)\}|(\w+))", lambda m: env.get(m.group(1) or m.group(2), m.group(0)), word)


def _shell_command(args: list[str]) -> str | None:
    i = 0
    while i < len(args):
        a = args[i]
        if SHELL_C_CLUSTER.fullmatch(a):
            return args[i + 1] if i + 1 < len(args) else None
        if a in ("-o", "+o"):
            i += 1
        elif not a.startswith(("-", "+")) or a == "--":
            return None
        i += 1
    return None


def _flags(args: list[str]) -> tuple[set[str], set[str], list[str]]:
    shorts: set[str] = set()
    longs: set[str] = set()
    rest: list[str] = []
    done = False
    for a in args:
        if done:
            rest.append(a)
        elif a == "--":
            done = True
        elif a.startswith("--"):
            longs.add(a.split("=", 1)[0])
        elif a.startswith("-") and len(a) > 1:
            shorts.update(a[1:])
        else:
            rest.append(a)
    return shorts, longs, rest


def _strip_wrappers(words: list[str]) -> tuple[list[str], set[str]]:
    i = 0
    seen: set[str] = set()
    while i < len(words):
        w = words[i].lstrip("\\")
        name = os.path.basename(w)
        if ASSIGN.match(w):
            i += 1
        elif w in KEYWORDS:
            i += 1
        elif name in WRAPPERS:
            seen.add(name)
            takes_arg = WRAPPER_ARG_FLAGS.get(name, set())
            i += 1
            while i < len(words) and (words[i].startswith("-") or ASSIGN.match(words[i])):
                i += 2 if words[i] in takes_arg else 1
        else:
            break
    return [words[i].lstrip("\\"), *words[i + 1:]] if i < len(words) else [], seen


def _segments(command: str) -> list[list[str]]:
    segments: list[list[str]] = []
    for line in command.splitlines():
        try:
            lex = shlex.shlex(line, posix=True, punctuation_chars=True)
            lex.whitespace_split = True
            lex.commenters = ""
            tokens = list(lex)
        except ValueError:
            tokens = line.split()
        current: list[str] = []
        for t in tokens:
            if t in OPERATORS or (t and set(t) <= set("();&|")):
                if current:
                    segments.append(current)
                current = []
            else:
                current.append(t)
        if current:
            segments.append(current)
    return segments


def _check_rm(policy: _Policy, args: list[str], cwd: Path, fed: bool = False) -> str | None:
    shorts, longs, targets = _flags(args)
    if not (shorts & {"r", "R", "f"} or longs & {"--recursive", "--force"}):
        return None
    if fed:
        return "xargs rm fed from a protected folder"
    for t in (b for t in targets for b in _braces(t)):
        if policy.is_trash(t, cwd):
            return "emptying the Trash"
        if policy.hits(t, cwd):
            return f"rm of {t}"
    return None


def _check_find(policy: _Policy, args: list[str], cwd: Path) -> str | None:
    starts = []
    for a in args:
        if a.startswith("-") and a != "-" or a in ("(", "!"):
            break
        starts.append(a)
    deletes = "-delete" in args or any(a == "-exec" and i + 1 < len(args) and os.path.basename(args[i + 1]) == "rm"
                                       for i, a in enumerate(args))
    if deletes and any(policy.hits(s, cwd) or policy.is_trash(s, cwd) for s in starts):
        return "find ... -delete on a protected folder"
    return None


def _check_dd(args: list[str]) -> str | None:
    for a in args:
        if a.startswith("of=/dev/") and a[3:] not in SAFE_DEVICES and not a[3:].startswith("/dev/fd/"):
            return "dd onto a device"
    return None


def _check_git(policy: _Policy, args: list[str], cwd: Path) -> str | None:
    rest = list(args)
    while rest and rest[0].startswith("-"):
        if rest[0] == "-C" and len(rest) > 1:
            cwd = Path(policy.expand(rest[1], cwd))
            rest = rest[2:]
        else:
            rest = rest[1:]
    if not rest or not policy.in_guarded_git(cwd):
        return None
    shorts, longs, _ = _flags(rest[1:])
    if rest[0] == "clean" and ("f" in shorts or "--force" in longs):
        return "git clean in the brain or Wisp folder"
    if rest[0] == "reset" and "--hard" in longs:
        return "git reset --hard in the brain or Wisp folder"
    return None


def _check_command(policy: _Policy, words: list[str], cwd: Path, depth: int, fed: bool = False,
                   env: dict[str, str] | None = None) -> str | None:
    name, args = os.path.basename(words[0]), words[1:]
    script = _shell_command(args) if name in SHELLS else None
    if script is not None and depth < MAX_DEPTH:
        return _check(policy, script, cwd, depth + 1, env)
    if name == "eval" and depth < MAX_DEPTH:
        return _check(policy, " ".join(args), cwd, depth + 1, env)
    if name == "rm":
        return _check_rm(policy, args, cwd, fed)
    if name in ("unlink", "rmdir"):
        if any(policy.hits(t, cwd) for t in _flags(args)[2]):
            return f"{name} of a protected folder"
        return None
    if name == "find":
        return _check_find(policy, args, cwd)
    if name == "dd":
        return _check_dd(args)
    if name.startswith(("mkfs", "newfs")):
        return "formatting a disk"
    if name == "diskutil" and args:
        sub = args[0].lower()
        if sub.startswith(("erase", "secureerase", "zerodisk", "reformat", "partitiondisk")) or (
                sub == "apfs" and len(args) > 1 and args[1].lower().startswith(("delete", "erase"))):
            return "diskutil " + args[0]
    if name == "asr" and "restore" in args:
        return "asr restore"
    if name == "tmutil" and any(a.lower().startswith("delete") for a in args):
        return "deleting Time Machine backups"
    if name == "csrutil" and args and args[0] != "status":
        return "csrutil"
    if name == "nvram" and "-c" in args:
        return "nvram -c"
    if name == "launchctl" and "bootout" in args and any(a.startswith("system") for a in args):
        return "launchctl bootout system"
    if name in ("shutdown", "reboot", "halt"):
        return name
    if name in ("chmod", "chown", "chgrp"):
        shorts, longs, targets = _flags(args)
        if ("R" in shorts or "--recursive" in longs) and any(policy.hits(t, cwd) for t in targets):
            return f"recursive {name} on a protected folder"
    if name == "rsync":
        _, longs, targets = _flags(args)
        if any(f.startswith("--delete") for f in longs) and len(targets) >= 2 and policy.hits(targets[-1], cwd):
            return "rsync --delete into a protected folder"
    if name == "git":
        return _check_git(policy, args, cwd)
    return None


def _check(policy: _Policy, command: str, cwd: Path, depth: int = 0, env: dict[str, str] | None = None) -> str | None:
    env = dict(env or {})
    if DEVICE_REDIRECT.search(command):
        return "writing onto a disk device"
    if re.search(r"\bosascript\b", command) and EMPTY_TRASH.search(command):
        return "emptying the Trash"
    for m in SUBSTITUTION.finditer(command):
        inner = m.group(1) if m.group(1) is not None else m.group(2)
        found = _check(policy, inner, cwd, depth + 1, env) if depth < MAX_DEPTH else None
        if found:
            return found
        if DESTROYS.search(command) and any(policy.hits(_subst(t, env), cwd) for seg in _segments(inner) for t in seg):
            return "rm of a protected folder through a command substitution"
    prepared: list[list[str]] = []
    for seg in _segments(command):
        body = seg[1:] if seg[0] in DECLARERS else seg
        if all(ASSIGN.match(w) for w in body):
            for w in body:
                name, value = w.split("=", 1)
                env[name] = _subst(value, env)
        else:
            prepared.append([_subst(w, env) for w in seg])
    names_root = [any(t and policy.hits(t, cwd) for t in seg) for seg in prepared]
    for i, seg in enumerate(prepared):
        words, wrapped = _strip_wrappers(seg)
        if not words or words[0] in LOOP_HEADERS:
            continue
        if os.path.basename(words[0]) in ("cd", "pushd") and len(words) > 1:
            cwd = Path(policy.expand(words[1], cwd))
            continue
        fed = "xargs" in wrapped and any(n for j, n in enumerate(names_root) if j != i)
        found = _check_command(policy, words, cwd, depth, fed, env)
        if found:
            return found
    return None


def hook_guard_destructive(payload: dict, paths: WispPaths, cfg: WispConfig) -> str | None:
    tool_input = payload.get("tool_input")
    if payload.get("tool_name") != "Bash" or not isinstance(tool_input, dict) or not isinstance(tool_input.get("command"), str):
        return None
    cwd = Path(payload["cwd"]) if isinstance(payload.get("cwd"), str) and payload["cwd"] else paths.home
    what = _check(_Policy(cfg, paths), tool_input["command"], cwd)
    return MESSAGE.format(what=what) if what else None
