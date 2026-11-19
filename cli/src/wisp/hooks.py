import os
import re
import sys
import time
from datetime import date
from pathlib import Path

from wisp.config import WispConfig
from wisp.paths import WispPaths
from wisp.runner import Runner
from wisp.secrets_scan import scan_paths

PENDENCIAS_LINES = 60
COMMIT_BUDGET_SECONDS = 10
GIT_EMAIL = "wisp@localhost"
BOOT_LABELS = {"pt": ("Hoje", "Cérebro", "Pendências"), "en": ("Today", "Brain", "Pendências")}
GUARD_TOKEN_SPLIT = re.compile(r"[\s;|&<>(){}\"'`=,:]+")
GUARD_PREFIX = "wisp-guard:"
GUARD_MESSAGE = GUARD_PREFIX + " blocked access to the Wisp secrets folder ({where}). Best-effort defense in depth"
TELEGRAM_GUARD_MESSAGE = (
    GUARD_PREFIX + " the Wisp bot's token and config are off limits ({where}). Best-effort defense in depth. "
    'In the app reply with a [name](file:///abs/path) link; in Telegram, only when the user asked, run '
    '"$WISP_BIN" topic enviar --thread="$WISP_TOPIC_THREAD" <absolute file>'
)
TELEGRAM_API = re.compile(r"api\.telegram\.org", re.I)
WISP_BOT_NAME = re.compile(r"\bwisp_bot\b|\bload_bot_config\b|\bBotConfig\b")
BOT_CONFIG_LOADER = re.compile(r"\bload_bot_config\b|\bload_settings\b|\bBotConfig\b|\bCURRENT\b")
TOKEN_ATTRIBUTE = re.compile(r"\.token\b")
TELEGRAM_SHELL_TOOLS = {"Bash"}
TELEGRAM_WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
HELD_NOTE = "Arquivo {rel} ficou fora do commit por parecer conter um segredo"


def _brain_dir(cfg: WispConfig) -> Path | None:
    if not cfg.brain:
        return None
    brain = Path(cfg.brain).expanduser()
    return brain if brain.is_dir() else None


def hook_boot(cfg: WispConfig, paths: WispPaths) -> str:
    brain = _brain_dir(cfg)
    if brain is None:
        return ""
    today, brain_label, pending_label = BOOT_LABELS["pt" if cfg.language.lower().startswith("pt") else "en"]
    lines = [f"{today}: {date.today().isoformat()}", f"{brain_label}: {brain}"]
    pendencias = brain / "pendencias.md"
    if pendencias.is_file():
        head = pendencias.read_text(errors="replace").splitlines()[:PENDENCIAS_LINES]
        lines += ["", f"{pending_label} (pendencias.md):", *head]
    return "\n".join(lines) + "\n"


def _changed_paths(status_z: str) -> list[str]:
    return [entry[3:] for entry in status_z.split("\0") if len(entry) > 3]


def _note_held(brain: Path, held: list[str], persona: str) -> bool:
    pendencias = brain / "pendencias.md"
    text = pendencias.read_text(errors="replace") if pendencias.is_file() else ""
    new = [rel for rel in held if HELD_NOTE.format(rel=rel) not in text]
    if not new:
        return False
    lines = [
        f"- **[{persona}] Segurança — {HELD_NOTE.format(rel=rel)}**. Próximo: tirar o segredo do arquivo. Pronto quando: o arquivo entra no commit."
        for rel in new
    ]
    separator = "" if not text or text.endswith("\n") else "\n"
    pendencias.write_text(text + separator + "\n".join(lines) + "\n")
    return True


def hook_brain_commit(cfg: WispConfig, runner: Runner) -> int:
    try:
        _commit(cfg, runner)
    except Exception as e:
        print(f"wisp: o cérebro não foi salvo agora ({type(e).__name__})", file=sys.stderr)
    return 0


def _commit(cfg: WispConfig, runner: Runner) -> None:
    brain = _brain_dir(cfg)
    if brain is None or not (brain / ".git").exists():
        return
    deadline = time.monotonic() + COMMIT_BUDGET_SECONDS

    def git(*args: str):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("budget spent")
        return runner.run(["git", "-C", str(brain), *args], timeout=remaining)

    status = git("status", "--porcelain", "-z", "-uall", "--no-renames")
    if status.exit != 0:
        return
    changed = _changed_paths(status.stdout)
    present = [brain / rel for rel in changed if (brain / rel).is_file()]
    held = {path.relative_to(brain).as_posix() for path in scan_paths(present)}
    for rel in sorted(held):
        print(f"wisp: não salvei {rel} no cérebro porque parece conter uma senha ou chave", file=sys.stderr)
    safe = [rel for rel in changed if rel not in held]
    if held and _note_held(brain, sorted(held), cfg.persona) and "pendencias.md" not in held and "pendencias.md" not in safe:
        safe.append("pendencias.md")
    if not safe:
        return
    identity: list[str] = []
    if not git("config", "user.name").stdout.strip():
        identity += ["-c", f"user.name={cfg.user_name or 'Wisp'}"]
    if not git("config", "user.email").stdout.strip():
        identity += ["-c", f"user.email={GIT_EMAIL}"]
    if git("add", "--", *safe).exit != 0:
        return
    git(*identity, "commit", "-q", "-m", f"chore: save the brain {date.today().isoformat()}", "--", *safe)


def _secret_roots(paths: WispPaths) -> list[Path]:
    declared = [paths.config / "secrets", paths.home / ".config" / "wisp" / "secrets"]
    normal = [Path(os.path.normpath(r)) for r in declared]
    return list(dict.fromkeys(normal + [r.resolve() for r in normal]))


def _expand(token: str, paths: WispPaths, cwd: Path) -> Path:
    home = str(paths.home)
    token = re.sub(r"\$\{?HOME\}?", lambda _: home, token)
    token = re.sub(r"\$\{?XDG_CONFIG_HOME\}?", lambda _: str(paths.config.parent), token)
    token = home + token[1:] if token == "~" or token.startswith("~/") else token
    path = Path(token)
    return Path(os.path.normpath(path if path.is_absolute() else cwd / path))


def _under(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _touches_secrets(text: str, paths: WispPaths, cwd: Path, *, ancestors: bool) -> bool:
    roots = _secret_roots(paths)
    config = paths.config
    for token in filter(None, GUARD_TOKEN_SPLIT.split(text)):
        if "/" not in token and not token.startswith("~") and token != "secrets":
            continue
        for candidate in {_expand(token, paths, cwd), _expand(token, paths, cwd).resolve()}:
            if any(_under(candidate, root) for root in roots):
                return True
            if ancestors and any(_under(root, candidate) and _under(candidate, config) for root in roots):
                return True
    return False


def _strings(value) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [s for v in value.values() for s in _strings(v)]
    if isinstance(value, list):
        return [s for v in value for s in _strings(v)]
    return []


def hook_guard_secrets(payload: dict, paths: WispPaths) -> str | None:
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    cwd = Path(payload["cwd"]) if isinstance(payload.get("cwd"), str) and payload["cwd"] else paths.home
    is_shell = payload.get("tool_name") == "Bash"
    texts = _strings(tool_input)
    if is_shell:
        texts = [re.sub(r"\$\{(\w+)\}", r"$\1", re.sub(r"/{2,}", "/", s)) for s in texts]
    for text in texts:
        if _touches_secrets(text, paths, cwd, ancestors=not is_shell):
            return GUARD_MESSAGE.format(where=payload.get("tool_name") or "tool")
        if is_shell and re.search(r"wisp/\{[^}]*secrets", text):
            return GUARD_MESSAGE.format(where="Bash")
        if is_shell and _shell_enters_config(text, paths, cwd) and re.search(r"(^|[\s/])secrets(/|\s|$|[\"'])", text):
            return GUARD_MESSAGE.format(where="Bash")
    return None


def _shell_enters_config(text: str, paths: WispPaths, cwd: Path) -> bool:
    roots = [r.parent for r in _secret_roots(paths)]
    for token in filter(None, GUARD_TOKEN_SPLIT.split(text)):
        if "/" in token or token.startswith("~"):
            if any(_under(_expand(token, paths, cwd), r) for r in roots):
                return True
    return False


def _wisp_roots(paths: WispPaths) -> list[Path]:
    declared = [paths.config, paths.home / ".config" / "wisp"]
    normal = [Path(os.path.normpath(r)) for r in declared]
    return list(dict.fromkeys(_fold(r) for r in normal + [r.resolve() for r in normal]))


def _fold(path: Path) -> Path:
    return Path(str(path).casefold())


def _token_paths(cfg: WispConfig, paths: WispPaths) -> set[Path]:
    declared = [paths.config / "secrets" / "telegram-token"]
    if cfg.telegram and cfg.telegram.token_file:
        declared.append(_expand(cfg.telegram.token_file, paths, paths.home))
    return {_fold(p) for path in declared for p in (path, path.resolve())}


def _names_wisp_files(text: str, paths: WispPaths, cwd: Path, roots: list[Path], token_paths: set[Path]) -> bool:
    for token in filter(None, GUARD_TOKEN_SPLIT.split(text)):
        if "/" not in token and not token.startswith("~"):
            continue
        expanded = _expand(token, paths, cwd)
        for candidate in {_fold(expanded), _fold(expanded.resolve())}:
            if candidate in token_paths or any(_under(candidate, root) for root in roots):
                return True
    return False


def _in_wisp_checkout(file_path: str, cwd: Path) -> bool:
    path = Path(os.path.normpath(Path(file_path).expanduser() if Path(file_path).is_absolute() else cwd / file_path))
    return any((root / "bot/src/wisp_bot").is_dir() and (root / "cli/src/wisp").is_dir() for root in path.parents)


def _reads_bot_token(text: str) -> bool:
    return bool(TOKEN_ATTRIBUTE.search(text) and WISP_BOT_NAME.search(text) and BOT_CONFIG_LOADER.search(text))


def hook_guard_telegram(payload: dict, paths: WispPaths, cfg: WispConfig) -> str | None:
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    tool = payload.get("tool_name") or "tool"
    cwd = Path(payload["cwd"]) if isinstance(payload.get("cwd"), str) and payload["cwd"] else paths.home
    roots, token_paths = _wisp_roots(paths), _token_paths(cfg, paths)
    message = TELEGRAM_GUARD_MESSAGE.format(where=tool)
    texts = _strings(tool_input)
    if tool in TELEGRAM_SHELL_TOOLS:
        texts = [re.sub(r"\$\{(\w+)\}", r"$\1", re.sub(r"/{2,}", "/", s)) for s in texts]
    file_path = tool_input.get("file_path") or tool_input.get("notebook_path")
    code = list(texts)
    if tool in TELEGRAM_WRITE_TOOLS and isinstance(file_path, str) and _in_wisp_checkout(file_path, cwd):
        code = []
        texts = [file_path]
    if any(_names_wisp_files(text, paths, cwd, roots, token_paths) for text in texts):
        return message
    if any(_reads_bot_token(text) for text in code):
        return message
    if any(TELEGRAM_API.search(text) and WISP_BOT_NAME.search(text) for text in code):
        return message
    return None
