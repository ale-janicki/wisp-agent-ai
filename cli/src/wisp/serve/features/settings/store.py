import contextlib
import json
import os
from pathlib import Path

from wisp.config import WispConfig, load_config, save_config
from wisp.fsops import atomic_write
from wisp.paths import WispPaths
from wisp.serve.store import data_dir

CHOICES = ("default", "auto", "bypassPermissions")
MODE_CHOICE = {"default": "default", "manual": "default", "auto": "auto", "bypassPermissions": "bypassPermissions"}
NOTICE_KINDS = ("reply", "telegram", "reminder", "update", "approval", "meeting", "invite")
NOTICE_DEFAULTS = {**dict.fromkeys(NOTICE_KINDS, True), "doNotDisturb": False}


def config() -> WispConfig:
    try:
        return load_config()
    except (ValueError, TypeError, OSError):
        return WispConfig()


def set_brain_learn(on: bool) -> None:
    cfg = load_config()
    cfg.brain_learn = on
    save_config(cfg)


def profile_path() -> Path:
    return Path(WispPaths.current().config) / "profile.json"


def profile_is_link() -> bool:
    return profile_path().is_symlink()


def read_profile() -> dict | None:
    try:
        value = json.loads(profile_path().read_text("utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def blocks() -> dict:
    found = (read_profile() or {}).get("blocks")
    return found if isinstance(found, dict) else {}


def settings_path() -> Path:
    return data_dir() / "settings.json"


def read_settings() -> dict:
    try:
        value = json.loads(settings_path().read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def write_settings(patch: dict) -> None:
    merged = {**read_settings(), **patch}
    for key in [k for k, v in merged.items() if v is None]:
        del merged[key]
    atomic_write(settings_path(), json.dumps(merged, indent=2, ensure_ascii=False, sort_keys=True) + "\n", mode=0o600)


def claude_default_mode() -> str | None:
    base = os.environ.get("CLAUDE_CONFIG_DIR")
    folder = Path(base).expanduser() if base else Path.home() / ".claude"
    try:
        mode = json.loads((folder / "settings.json").read_text("utf-8"))["permissions"]["defaultMode"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return mode if isinstance(mode, str) and mode else None


def permission() -> dict:
    wisp_mode = read_settings().get("permissionMode")
    profile_mode = ((read_profile() or {}).get("agent") or {}).get("permissionMode")
    claude = claude_default_mode()
    link = profile_is_link()
    for source, mode in (("wisp", wisp_mode), ("profile", profile_mode)):
        if isinstance(mode, str) and mode in MODE_CHOICE:
            return {"choice": MODE_CHOICE[mode], "source": source, "claude_mode": None, "profile_is_link": link}
    if claude:
        return {"choice": MODE_CHOICE.get(claude), "source": "claude", "claude_mode": claude, "profile_is_link": link}
    return {"choice": "default", "source": "standard", "claude_mode": None, "profile_is_link": link}


def set_permission(choice: str) -> str | None:
    if choice not in CHOICES:
        return "Escolha inválida."
    if profile_is_link():
        write_settings({"permissionMode": choice})
        return None
    path = profile_path()
    try:
        profile = json.loads(path.read_text("utf-8")) if path.exists() else {}
    except (OSError, ValueError):
        profile = None
    if not isinstance(profile, dict):
        return "Não consegui salvar no perfil: o perfil existente não tem o formato esperado"
    if not isinstance(profile.get("persona"), dict):
        profile["persona"] = {"name": "Wisp", "language": "pt-BR"}
    agent = profile.get("agent") if isinstance(profile.get("agent"), dict) else {}
    agent.setdefault("cwd", "~")
    agent["permissionMode"] = choice
    profile["agent"] = agent
    try:
        atomic_write(path, json.dumps(profile, indent=2, ensure_ascii=False, sort_keys=True) + "\n", mode=0o600)
    except OSError as error:
        return f"Não consegui salvar no perfil: {error.strerror or type(error).__name__}"
    with contextlib.suppress(OSError):
        write_settings({"permissionMode": None})
    return None


def notices() -> dict:
    saved = read_settings().get("notices")
    saved = saved if isinstance(saved, dict) else {}
    return {key: saved[key] if isinstance(saved.get(key), bool) else default for key, default in NOTICE_DEFAULTS.items()}


def set_notices(patch: dict) -> dict:
    current = notices()
    current.update({key: value for key, value in patch.items() if key in NOTICE_DEFAULTS and isinstance(value, bool)})
    write_settings({"notices": current})
    return current


def setup_finished() -> bool:
    return isinstance(read_settings().get("setupFinishedAt"), str)


def finish_setup(now: str) -> None:
    write_settings({"setupFinishedAt": now})
