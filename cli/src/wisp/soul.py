"""The one renderer of the assistant's personality, shared by every engine (app, Telegram bot, local)."""
import argparse
import json
import re
from dataclasses import replace
from pathlib import Path

from wisp.config import WispConfig, load_config
from wisp.harness_merge import BEGIN, END, current_block, render_agente
from wisp.paths import WispPaths, resources_root
from wisp.setup.codex import codex_home
from wisp.setup.folder import wisp_root
from wisp.setup.harness import _managed_elsewhere, _values
from wisp.soul_config import Soul, effective_source, injects, load_soul, profile_path

ENGINES = ("claude", "codex", "local")
NO_BRAIN = "(sem brain configurado)"
LEFTOVER_PLACEHOLDER = re.compile(r"\{\{[A-Z_]+\}\}")

TONE_TEXT = {
    "direto": "Direct: short answers, straight to the point, no filler and no pleasantries.",
    "caloroso": "Warm: friendly and encouraging, a little personal, still brief.",
    "formal": "Formal: polite, precise and professional wording, no slang.",
}
EMOJI_TEXT = {
    True: "Emojis: allowed, used sparingly where they help. This overrides any earlier line about emojis.",
    False: "Emojis: never use them, not even if the user does. This overrides any earlier line about emojis.",
}


def _defaulted(cfg: WispConfig) -> dict[str, str]:
    values = _values(cfg)
    values["PERSONA_NAME"] = values["PERSONA_NAME"] or "Wisp"
    values["LANGUAGE"] = values["LANGUAGE"] or "pt-BR"
    values["BRAIN_DIR"] = values["BRAIN_DIR"] or NO_BRAIN
    values["TASKS_FILE"] = values["TASKS_FILE"] or f"{NO_BRAIN}/pendencias.md"
    return values


def fill(text: str, cfg: WispConfig) -> str:
    return LEFTOVER_PLACEHOLDER.sub("", render_agente(text, _defaulted(cfg))).strip()


def _agente(cfg: WispConfig) -> str:
    """The user's own agente.md as written; the shipped template when it is missing, unreadable or empty."""
    try:
        text = (wisp_root(cfg) / "agente.md").read_text("utf-8")
    except (OSError, UnicodeDecodeError):
        text = ""
    return text if text.strip() else (resources_root() / "harness" / "claude-md-block.md").read_text("utf-8")


def render(cfg: WispConfig, soul: Soul, folder: Path | None = None, agente: bool = True) -> str:
    """The agente.md (the user's own, else the shipped template) with placeholders filled, then the tone and extra rules."""
    if folder is not None:
        cfg = replace(cfg, wisp_dir=str(folder))
    parts = [fill(_agente(cfg), cfg)] if agente else []
    parts.append(f"## Tom\n- {TONE_TEXT[soul.tone]}\n- {EMOJI_TEXT[soul.emojis]}")
    extra = soul.extra.replace(BEGIN, "").replace(END, "").strip()
    if extra:
        parts.append(f"## Regras extras\n{extra}")
    return "\n\n".join(parts)


def block_installed(paths: WispPaths, engine: str) -> bool:
    """Whether the engine's own assistant config still holds a Wisp persona block (one the user edited, or one `wisp harness
    sync` has not retired yet): the agente part then already reaches the model, so it is not injected a second time."""
    path = codex_home(paths) / "AGENTS.md" if engine == "codex" else paths.home / ".claude" / "CLAUDE.md"
    try:
        return engine != "local" and current_block(path.read_text("utf-8")) is not None
    except (OSError, UnicodeDecodeError, ValueError):
        return False


def for_engine(cfg: WispConfig, paths: WispPaths, engine: str) -> tuple[str, str]:
    """(source in effect, text to inject); the text is empty when the user's own assistant supplies the personality."""
    soul = load_soul(profile_path(paths))
    source = effective_source(soul, _managed_elsewhere(paths.home / ".claude"))
    if not injects(source, engine):
        return source, ""
    return source, render(cfg, soul, agente=not block_installed(paths, engine))


def add_parser(sub) -> None:
    soul = sub.add_parser("soul")
    steps = soul.add_subparsers(dest="soul_action", required=True)
    render_cmd = steps.add_parser("render")
    render_cmd.add_argument("--engine", choices=ENGINES, default="claude")
    render_cmd.add_argument("--json", action="store_true", help="print {source, text}; text is empty when the user's own assistant supplies the personality")


def run(args: argparse.Namespace) -> int:
    paths = WispPaths.current()
    try:
        cfg = load_config()
    except (ValueError, TypeError, OSError):
        cfg = WispConfig()
    if args.json:
        source, text = for_engine(cfg, paths, args.engine)
        print(json.dumps({"source": source, "text": text}, ensure_ascii=False))
    else:
        print(render(cfg, load_soul(profile_path(paths))))
    return 0
