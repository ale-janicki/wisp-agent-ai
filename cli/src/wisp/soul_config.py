"""The soul block of profile.json: where the assistant's personality comes from, and how it sounds."""
import json
from dataclasses import dataclass
from pathlib import Path

from wisp.paths import WispPaths

SOURCES = ("wisp", "assistant", "both")
TONES = ("direto", "caloroso", "formal")
DEFAULT_TONE = "direto"


@dataclass(frozen=True)
class Soul:
    source: str | None = None       # None: the user never chose, so the default applies
    tone: str = DEFAULT_TONE
    emojis: bool = False
    extra: str = ""


def profile_path(paths: WispPaths | None = None) -> Path:
    return (paths or WispPaths.current()).config / "profile.json"


def load_soul(path: Path | None = None) -> Soul:
    """Tolerant: a missing, unreadable or malformed block gives defaults, a bad field gives that field's default."""
    try:
        raw = json.loads((path or profile_path()).read_text("utf-8")).get("soul")
    except (OSError, ValueError, AttributeError):
        return Soul()
    if not isinstance(raw, dict):
        return Soul()
    source, tone, emojis, extra = raw.get("source"), raw.get("tone"), raw.get("emojis"), raw.get("extra")
    return Soul(
        source if source in SOURCES else None,
        tone if tone in TONES else DEFAULT_TONE,
        emojis if isinstance(emojis, bool) else False,
        extra if isinstance(extra, str) else "",
    )


def effective_source(soul: Soul, managed_elsewhere: bool) -> str:
    """The user's choice, else their own assistant when ~/.claude is managed outside Wisp, else the Wisp soul."""
    return soul.source or ("assistant" if managed_elsewhere else "wisp")


def injects(source: str, engine: str) -> bool:
    """Whether Wisp puts the soul into the prompt. The local engine has no outside assistant, so it always does."""
    return engine == "local" or source != "assistant"
