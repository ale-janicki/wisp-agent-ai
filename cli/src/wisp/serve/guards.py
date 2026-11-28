from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

from wisp.paths import WispPaths, exe, venv_bin

MATCHER = "Bash|Read|Edit|MultiEdit|Write|NotebookEdit|Grep|Glob"
HOOKS = ("guard-secrets", "guard-telegram", "guard-destructive", "guard-lessons", "guard-agenda", "guard-outbound")
RECALL_TIMEOUT = 5
ASK_RULES = ["Bash(*aprender add*)", "Bash(*aprender confirmar*)", "Bash(*aprender descartar*)",
             "Bash(*topic unir*--aplicar*)", "Bash(*topic unir*--forcar*)"]
AGENDA_ASK = ("criar-evento", "editar-evento", "apagar-evento", "criar-lembrete", "concluir-lembrete", "permissao --pedir")
AGENDA_HEADS = ('"$WISP_BIN" agenda', "$WISP_BIN agenda", "wisp agenda", '"$WISP_AGENDA_BIN"')
AGENDA_ASK_RULES = [f"Bash({head} {sub}:*)" for sub in AGENDA_ASK for head in AGENDA_HEADS]
ASK_TOOLS = ("mcp__wisp-email__email_send", "mcp__wisp-mac__mac_send")
DENY_RULES = [
    "Write(~/Library/Preferences/ai.wisp.app.plist)",
    "Edit(~/Library/Preferences/ai.wisp.app.plist)",
    "Write(~/Library/Application Support/Wisp/**)",
    "Edit(~/Library/Application Support/Wisp/**)",
    "Write(~/.config/wisp/**)",
    "Edit(~/.config/wisp/**)",
    "Write(~/.local/state/wisp/mac-callers/**)",
    "Edit(~/.local/state/wisp/mac-callers/**)",
    "Bash(*defaults*ai.wisp.app*)",
    "Bash(*Preferences/ai.wisp.app*)",
    "Bash(*ai.wisp.app.plist*)",
    "Bash(plutil*ai.wisp.app*)",
    "Bash(*PlistBuddy*ai.wisp.app*)",
]
WINDOWS_DENY_RULES = [f"{tool}(~/AppData/{root}/{name}/**)" for root in ("Roaming", "Local") for name in ("wisp", "Wisp")
                      for tool in ("Write", "Edit")]
PHONE_DISALLOWED_TOOLS = ("AskUserQuestion",)

APP_FILES = """The user is reading the Wisp app: "here" means the app. To give the user a file or an image, \
reply with a Markdown link to its absolute path, like [name](file:///abs/path/name.ext) (percent-encode spaces as %20); \
the app opens it on click. Write normal Markdown, never HTML tags.
Never call the Telegram API directly and never read the bot token.
A guard blocks direct API use and token reads.
Never say you cannot send files."""

CODEX_NOTE = """
You are running under Codex, whose sandbox has no network: you cannot send files to Telegram, even when asked; say so \
plainly. Your working folder is the Wisp folder or a project folder, never the user's whole home."""

UNAVAILABLE = "não consegui ativar as travas do Wisp: "
_MODES = {"default": "default", "manual": "default", "auto": "auto", "bypassPermissions": "bypassPermissions"}


class GuardsUnavailable(Exception):
    def __init__(self, reason: str):
        super().__init__(UNAVAILABLE + reason)
        self.reason = reason


def quote_command(path: str, platform: str | None = None) -> str:
    if (platform or sys.platform) == "win32":
        if any(c in path for c in '"$`'):
            raise GuardsUnavailable("o caminho do CLI do Wisp tem um caractere que o shell dos hooks não aceita")
        return '"' + path.replace("\\", "/") + '"'
    return "'" + path.replace("'", "'\\''") + "'"


def guard_settings(wisp_binary: str, platform: str | None = None) -> dict:
    quoted = quote_command(wisp_binary, platform)
    deny = DENY_RULES + (WINDOWS_DENY_RULES if (platform or sys.platform) == "win32" else [])
    hooks = [{"type": "command", "command": f"{quoted} hook {name}"} for name in HOOKS]
    recall = [{"type": "command", "command": f"{quoted} hook recall", "timeout": RECALL_TIMEOUT}]
    lessons = [{"type": "command", "command": f"{quoted} hook aprendizados", "timeout": RECALL_TIMEOUT}]
    return {
        "permissions": {"ask": ASK_RULES + AGENDA_ASK_RULES + list(ASK_TOOLS), "deny": deny},
        "hooks": {
            "PreToolUse": [{"matcher": MATCHER, "hooks": hooks}],
            "UserPromptSubmit": [{"hooks": recall}],
            "SessionStart": [{"hooks": lessons}],
        },
    }


def wisp_binary(home: str | None = None) -> str | None:
    candidates = [venv_bin(Path(sys.prefix)) / exe("wisp")]
    candidates.append((Path(home) if home else Path.home()) / ".local" / "bin" / exe("wisp"))
    return next((str(p) for p in candidates if p.is_file()), None)


def install(wisp_bin: str, path: Path) -> Path:
    text = json.dumps(guard_settings(wisp_bin), indent=2, sort_keys=True) + "\n"
    try:
        if path.read_text("utf-8") == text:
            return path
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, "utf-8")
    os.replace(tmp, path)
    return path


def settings_path(paths: WispPaths | None = None) -> Path:
    return Path((paths or WispPaths.current()).state) / "guard-settings-app.json"


def guard_settings_file() -> tuple[str, str]:
    binary = wisp_binary()
    if binary is None:
        raise GuardsUnavailable("não achei o CLI do Wisp")
    try:
        return str(install(binary, settings_path())), binary
    except OSError as error:
        raise GuardsUnavailable(str(error)) from error


def _mode_in(path: Path, *keys: str) -> str | None:
    try:
        value = json.loads(path.read_text("utf-8"))
        for key in keys:
            value = value.get(key)
    except (OSError, ValueError, AttributeError):
        return None
    return _MODES.get(value) if isinstance(value, str) else None


def permission_mode(data_dir: Path, paths: WispPaths | None = None) -> str | None:
    paths = paths or WispPaths.current()
    return _mode_in(Path(data_dir) / "settings.json", "permissionMode") \
        or _mode_in(Path(paths.config) / "profile.json", "agent", "permissionMode")


def profile_agent(paths: WispPaths | None = None) -> dict:
    paths = paths or WispPaths.current()
    try:
        agent = json.loads((Path(paths.config) / "profile.json").read_text("utf-8")).get("agent")
    except (OSError, ValueError, AttributeError):
        return {}
    return agent if isinstance(agent, dict) else {}


def profile_text(key: str, paths: WispPaths | None = None) -> str | None:
    value = profile_agent(paths).get(key)
    return value if isinstance(value, str) and value.strip() else None


def instructions(soul: str, platform: str | None = None, extra: str = "") -> str:
    text = APP_FILES
    if (platform or sys.platform) == "darwin":
        from wisp_bot.claude_runner import AGENDA, MAC_TOOLS
        text += "\n\n" + MAC_TOOLS + "\n\n" + AGENDA
    text += extra
    return text + "\n\n" + soul if soul else text


def soul_text(engine: str = "claude") -> str:
    try:
        from wisp.config import WispConfig, load_config
        from wisp.soul import for_engine
        try:
            cfg = load_config()
        except (ValueError, TypeError, OSError):
            cfg = WispConfig()
        return for_engine(cfg, WispPaths.current(), engine)[1]
    except Exception:
        return ""


@dataclass
class Launch:
    settings: str
    permission_mode: str | None
    append_system_prompt: str
    disallowed_tools: tuple[str, ...] = field(default=())
    environment: dict[str, str] = field(default_factory=dict)


def prepare(data_dir: Path, away_on_phone: bool = False) -> Launch:
    settings, binary = guard_settings_file()
    return Launch(settings, permission_mode(data_dir), instructions(soul_text()),
                  PHONE_DISALLOWED_TOOLS if away_on_phone else (), {"WISP_BIN": binary})
