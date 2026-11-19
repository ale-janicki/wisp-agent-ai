import json
import shlex
from pathlib import Path

from wisp.fsops import atomic_write


def check_writable(profile_path: Path) -> None:
    if profile_path.is_symlink():
        raise ValueError("o perfil é gerenciado fora do Wisp; o Wisp não o altera")


MEMORY_SEARCH = "/usr/bin/grep -rIin --null --include='*.md' --exclude-dir='.*' -m 1 -F -e {query} {root} | head -n 200"


def _load(profile_path: Path) -> dict:
    profile = json.loads(profile_path.read_text()) if profile_path.exists() else {}
    if not isinstance(profile, dict) or not isinstance(profile.get("blocks", {}), dict) or not isinstance(profile.get("persona", {}), dict):
        raise ValueError("o perfil existente não tem o formato esperado")
    return profile


def render_persona(profile_path: Path, *, name: str, user_name: str, language: str, avatar: str | None, brain: str | None) -> str:
    check_writable(profile_path)
    profile = _load(profile_path)
    persona = profile.get("persona", {})
    persona.update({"name": name, "user": user_name, "language": language})
    if avatar:
        persona["avatar"] = avatar
    profile["persona"] = persona
    agent = profile.get("agent")
    profile["agent"] = agent if isinstance(agent, dict) else {"cwd": "~"}
    profile["agent"].setdefault("cwd", "~")
    blocks = profile.setdefault("blocks", {})
    if brain:
        tasks, memory = blocks.get("tasks"), blocks.get("memory")
        blocks["tasks"] = {**(tasks if isinstance(tasks, dict) else {}), "file": f"{brain}/pendencias.md"}
        memory = memory if isinstance(memory, dict) else {}
        blocks["memory"] = {"search": MEMORY_SEARCH, **memory, "root": brain}
    return json.dumps(profile, indent=2, ensure_ascii=False) + "\n"


def _telegram_block(wisp_bin: str, attachments: str | None) -> dict:
    wisp = shlex.quote(wisp_bin)
    block = {
        "status": f"{wisp} topic status --json",
        "list": f"{wisp} topic listar --json",
        "share": f"{wisp} topic compartilhar --session={{session}} --cwd={{cwd}} --nome={{name}} --json",
        "post": f"{wisp} topic postar --json",
        "close": f"{wisp} topic encerrar --sem-pull {{thread}}",
    }
    if attachments:
        block["attachments"] = attachments
    return block


def render_telegram_block(
    profile_path: Path, wisp_bin: str, attachments: str | None = None, *, name: str = "Wisp", language: str = "pt-BR"
) -> str:
    check_writable(profile_path)
    profile = _load(profile_path)
    if not profile.get("persona"):
        profile["persona"] = {"name": name, "language": language}
    if not isinstance(profile.get("agent"), dict):
        profile["agent"] = {"cwd": "~"}
    profile.setdefault("blocks", {})["telegram"] = _telegram_block(wisp_bin, attachments)
    return json.dumps(profile, indent=2, ensure_ascii=False) + "\n"


def set_telegram_block(
    profile_path: Path, wisp_bin: str, attachments: str | None = None, *, name: str = "Wisp", language: str = "pt-BR"
) -> None:
    atomic_write(profile_path, render_telegram_block(profile_path, wisp_bin, attachments, name=name, language=language), mode=0o600)


def has_telegram_block(profile_path: Path) -> bool:
    if profile_path.is_symlink() or not profile_path.is_file():
        return False
    try:
        return "telegram" in _load(profile_path).get("blocks", {})
    except (ValueError, OSError):
        return False


def remove_telegram_block(profile_path: Path) -> None:
    check_writable(profile_path)
    profile = _load(profile_path)
    profile.get("blocks", {}).pop("telegram", None)
    atomic_write(profile_path, json.dumps(profile, indent=2, ensure_ascii=False) + "\n", mode=0o600)
