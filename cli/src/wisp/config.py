import json
import os
from dataclasses import asdict, dataclass, fields
from pathlib import Path

from wisp.fsops import atomic_write
from wisp.paths import WispPaths


@dataclass
class TelegramConfig:
    chat_id: int
    user_id: int
    token_file: str
    topics_rel: str = "wisp/topicos"
    state_dir: str = "~/.local/state/wisp/bot"
    hosting: str = "solo"
    brain_sync_cmd: str | None = None
    alert_cmd: str | None = None
    pair: dict | None = None


@dataclass
class WispConfig:
    version: int = 1
    user_name: str = ""
    persona: str = "Wisp"
    language: str = "pt-BR"
    brain: str | None = None
    claude_bin: str | None = None
    telegram: TelegramConfig | None = None
    telegram_token_at: int | None = None


def _known(cls, raw: dict) -> dict:
    names = {f.name for f in fields(cls)}
    return {k: v for k, v in raw.items() if k in names}


def _default_path() -> Path:
    env = os.environ.get("WISP_CONFIG")
    return Path(env) if env else WispPaths.current().config / "wisp.json"


def load_config(path: Path | None = None) -> WispConfig:
    path = path or _default_path()
    if not path.exists():
        return WispConfig()
    raw = json.loads(path.read_text())
    telegram = raw.get("telegram")
    data = _known(WispConfig, raw)
    data["telegram"] = TelegramConfig(**_known(TelegramConfig, telegram)) if telegram else None
    return WispConfig(**data)


def save_config(cfg: WispConfig, path: Path | None = None) -> None:
    atomic_write(path or _default_path(), json.dumps(asdict(cfg), indent=2, ensure_ascii=False) + "\n", mode=0o600)
