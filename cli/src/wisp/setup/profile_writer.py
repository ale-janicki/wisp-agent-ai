import json
import shlex
from pathlib import Path

from wisp.fsops import atomic_write


def check_writable(profile_path: Path) -> None:
    """A profile that is a symlink belongs to someone else's setup: the block is never written through it."""
    if profile_path.is_symlink():
        raise ValueError("o perfil é gerenciado fora do Wisp; o Wisp não o altera")


MEMORY_SEARCH = "/usr/bin/grep -rIin --null --include='*.md' --exclude-dir='.*' -m 1 -F -e {query} {root} | head -n 200"


def _load(profile_path: Path) -> dict:
    profile = json.loads(profile_path.read_text()) if profile_path.exists() else {}
    if not isinstance(profile, dict) or not isinstance(profile.get("blocks", {}), dict) or not isinstance(profile.get("persona", {}), dict):
        raise ValueError("o perfil existente não tem o formato esperado")
    return profile


def render_persona(profile_path: Path, *, name: str, user_name: str, language: str, avatar: str | None, brain: str | None) -> str:
    """Profile text with persona/agent set and the brain blocks pointed at the current brain (their other keys kept); every other key is kept.
    `persona.user` is the key the CLI adds for the user's name (the Swift `Persona` ignores it until it reads it)."""
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


def set_telegram_block(profile_path: Path, wisp_bin: str, attachments: str | None = None) -> None:
    """Writes blocks.telegram into the profile, keeping every other key. `{anexos}` stays in the send template
    so the profile matches the app once `wisp topic falar` accepts attachments."""
    check_writable(profile_path)
    wisp = shlex.quote(wisp_bin)
    block = {
        "status": f"{wisp} topic status --json",
        "list": f"{wisp} topic listar --json",
        "create": f"{wisp} topic novo --cwd {{cwd}} -- {{name}}",
        "send": f"{wisp} topic falar --sem-pull --origem Wisp {{anexos}} -- {{thread}} {{text}}",
        "close": f"{wisp} topic encerrar --sem-pull {{thread}}",
        "claim": f"{wisp} topic assumir --json --thread {{thread}}",
    }
    if attachments:
        block["attachments"] = attachments
    profile = _load(profile_path)
    profile.setdefault("blocks", {})["telegram"] = block
    atomic_write(profile_path, json.dumps(profile, indent=2, ensure_ascii=False) + "\n")
