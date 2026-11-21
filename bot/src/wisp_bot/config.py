from __future__ import annotations
import json, os, re, shlex
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

DEFAULT_BRAIN = "~/Wisp/brain"
DEFAULT_TOPICS_REL = "wisp/topicos"
DEFAULT_STATE_DIR = "~/.local/state/wisp/bot"
DEFAULT_PERSONA = "Wisp"
DEFAULT_WISP_DIR = "~/Wisp"
DEFAULT_CONVERSATIONS = "~/Library/Application Support/Wisp/conversations.json"
HOSTINGS = ("solo", "pair")


class ConfigError(Exception):
    ...


@dataclass(frozen=True)
class BotConfig:
    token: str
    chat_ids: set[str]
    user_id: int
    brain: Path
    topics_dir: Path
    topics_rel: str
    state_dir: Path
    claude_bin: str | None
    persona: str
    hosting: Literal["solo", "pair"]
    brain_sync_cmd: list[str] | None
    alert_cmd: list[str] | None
    pair: dict | None
    system_topics: dict[int, str] = field(default_factory=dict)
    user_name: str = ""
    conversations_file: Path = Path(DEFAULT_CONVERSATIONS).expanduser()
    wisp_dir: Path = Path(DEFAULT_WISP_DIR).expanduser()
    codex_bin: str | None = None


def config_path(env: Mapping[str, str] = os.environ) -> Path:
    if env.get("WISP_CONFIG"):
        return Path(env["WISP_CONFIG"])
    base = env.get("XDG_CONFIG_HOME") or str(_home(env) / ".config")
    return Path(base) / "wisp" / "wisp.json"


def _home(env: Mapping[str, str]) -> Path:
    return Path(env.get("HOME") or Path.home())


def _expand(value: str, env: Mapping[str, str]) -> Path:
    if value == "~" or value.startswith("~/"):
        return _home(env) / value[2:]
    return Path(value)


def _command(value, key: str, env: Mapping[str, str]) -> list[str] | None:
    if value in (None, "", []):
        return None
    if isinstance(value, str):
        argv = shlex.split(value)
    elif isinstance(value, list) and all(isinstance(a, str) for a in value):
        argv = list(value)
    else:
        raise ConfigError(f"telegram.{key} must be a command string or a list of strings.")
    return [str(_expand(argv[0], env)), *argv[1:]] if argv else None


def rel_seguro(rel: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z0-9._/-]+", rel)) and not rel.startswith("/") and ".." not in rel.split("/")


def _chat_ids(value) -> set[str]:
    values = value if isinstance(value, list) else [value]
    return {str(int(v)) for v in values if v not in (None, "")}


def _read(env: Mapping[str, str]) -> dict:
    path = config_path(env)
    try:
        raw = json.loads(path.read_text("utf-8"))
    except FileNotFoundError:
        raise ConfigError(f"No config at {path}: run the Telegram setup first.") from None
    except (OSError, json.JSONDecodeError) as e:
        raise ConfigError(f"The config at {path} is unreadable: {e}.") from None
    if not isinstance(raw, dict):
        raise ConfigError(f"The config at {path} is not a JSON object.")
    return raw


def _build(raw: dict, env: Mapping[str, str], strict: bool) -> BotConfig:
    tg = raw.get("telegram")
    if not isinstance(tg, dict):
        if strict:
            raise ConfigError("The config has no telegram block: run the Telegram setup first.")
        tg = {}
    hosting = tg.get("hosting") or "solo"
    if hosting not in HOSTINGS:
        if strict:
            raise ConfigError(f"telegram.hosting must be one of {', '.join(HOSTINGS)}, not {hosting!r}.")
        hosting = "solo"
    pair = tg.get("pair") if isinstance(tg.get("pair"), dict) else None
    if strict and hosting == "pair" and not pair:
        raise ConfigError("telegram.hosting is pair but telegram.pair is missing.")
    if strict and pair:
        for chave, motivo in (("user", "the login of the other machine"), ("pc_name", "its node name in the tailnet")):
            if not pair.get(chave):
                raise ConfigError(f"telegram.pair.{chave} is missing: the bot needs {motivo}.")
    if strict and pair and pair.get("state_rel") and not rel_seguro(str(pair["state_rel"])):
        raise ConfigError("telegram.pair.state_rel must be a plain path relative to the peer's home.")
    try:
        user_id = int(tg.get("user_id") or 0)
        chat_ids = _chat_ids(tg.get("chat_id"))
        system_topics = {int(k): str(v) for k, v in (tg.get("system_topics") or {}).items()}
    except (TypeError, ValueError, AttributeError) as e:
        raise ConfigError(f"telegram.user_id, chat_id and system_topics must be numbers: {e}.") from None
    if strict and not user_id:
        raise ConfigError("telegram.user_id is missing: the bot would answer nobody.")
    if strict and not chat_ids:
        raise ConfigError("telegram.chat_id is missing: the bot would not know its group.")
    token = _token(tg, env) if strict else ""
    brain = _expand(str(raw.get("brain") or DEFAULT_BRAIN), env)
    topics_rel = str(tg.get("topics_rel") or DEFAULT_TOPICS_REL).strip("/")
    return BotConfig(
        token=token, chat_ids=chat_ids, user_id=user_id, brain=brain, topics_dir=brain / topics_rel,
        topics_rel=topics_rel, state_dir=_expand(str(tg.get("state_dir") or DEFAULT_STATE_DIR), env),
        claude_bin=raw.get("claude_bin") or None,
        persona=str(raw.get("persona") or DEFAULT_PERSONA),
        hosting=hosting, brain_sync_cmd=_command(tg.get("brain_sync_cmd"), "brain_sync_cmd", env),
        alert_cmd=_command(tg.get("alert_cmd"), "alert_cmd", env), pair=pair, system_topics=system_topics,
        user_name=str(raw.get("user_name") or "").strip(),
        conversations_file=_expand(str(tg.get("conversations_file") or DEFAULT_CONVERSATIONS), env),
        wisp_dir=_expand(str(raw.get("wisp_dir") or DEFAULT_WISP_DIR), env),
        codex_bin=raw.get("codex_bin") or None)


def _token(tg: dict, env: Mapping[str, str]) -> str:
    if not tg.get("token_file"):
        raise ConfigError("telegram.token_file is missing.")
    path = _expand(str(tg["token_file"]), env)
    try:
        token = path.read_text("utf-8").strip()
    except OSError:
        raise ConfigError(f"telegram.token_file {path} is unreadable.") from None
    if not token:
        raise ConfigError(f"telegram.token_file {path} is empty.")
    return token


def load_bot_config(env: Mapping[str, str] = os.environ) -> BotConfig:
    return _build(_read(env), env, strict=True)


def load_settings(env: Mapping[str, str] = os.environ) -> BotConfig:
    try:
        raw = _read(env)
    except ConfigError:
        raw = {}
    try:
        return _build(raw, env, strict=False)
    except ConfigError:
        return _build({}, env, strict=False)


CURRENT = load_settings()
