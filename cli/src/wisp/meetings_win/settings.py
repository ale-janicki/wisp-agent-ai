from __future__ import annotations

import json
from pathlib import Path

from wisp.meetings_win.language import LANGUAGES, POST_CALL_ENGINES
from wisp.meetings_win.transcript import write_private

DEFAULT_LIMIT_MINUTES = 120
LIMIT_CHOICES = (30, 60, 90, 120, 180, 240)
MAX_CLEANUP_DAYS = 365
DEFAULTS = {"webhookEnabled": False, "webhookSigns": False, "limitMinutes": DEFAULT_LIMIT_MINUTES, "autoSummary": True,
            "language": "pt", "postCallEngine": "whisperLargeV3", "cleanupDays": 0}
ENGINE_IDS = tuple(e["id"] for e in POST_CALL_ENGINES)


def _load(path: Path) -> dict:
    try:
        data = json.loads(Path(path).read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _bool(value, default: bool) -> bool:
    return value if isinstance(value, bool) else default


def _int(value, default: int) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) else default


def read(path: Path) -> dict:
    raw = _load(path).get("meetings")
    raw = raw if isinstance(raw, dict) else {}
    language = raw.get("language")
    engine = raw.get("postCallEngine")
    return {
        "webhookEnabled": _bool(raw.get("webhookEnabled"), False),
        "webhookSigns": _bool(raw.get("webhookSigns"), False),
        "limitMinutes": _int(raw.get("limitMinutes"), DEFAULT_LIMIT_MINUTES),
        "autoSummary": _bool(raw.get("autoSummary"), True),
        "language": language if language in LANGUAGES else "pt",
        "postCallEngine": engine if engine in ENGINE_IDS else "whisperLargeV3",
        "cleanupDays": min(max(_int(raw.get("cleanupDays"), 0), 0), MAX_CLEANUP_DAYS),
    }


def limit_seconds(values: dict) -> float:
    return float(min(max(_int(values.get("limitMinutes"), DEFAULT_LIMIT_MINUTES), 15), 720) * 60)


def update(path: Path, changes: dict) -> dict:
    for key, value in changes.items():
        if key not in DEFAULTS:
            raise ValueError(f"configuração desconhecida: {key}")
        if key == "language" and value not in LANGUAGES:
            raise ValueError("idioma inválido")
        if key == "postCallEngine" and value not in ENGINE_IDS:
            raise ValueError("motor inválido")
        if key == "limitMinutes" and value not in LIMIT_CHOICES:
            raise ValueError("limite inválido")
        if key == "cleanupDays" and (not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= MAX_CLEANUP_DAYS):
            raise ValueError("dias inválidos")
        if key in ("webhookEnabled", "webhookSigns", "autoSummary") and not isinstance(value, bool):
            raise ValueError(f"{key} precisa ser verdadeiro ou falso")
    whole = _load(path)
    block = whole.get("meetings") if isinstance(whole.get("meetings"), dict) else {}
    whole["meetings"] = {**block, **changes}
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    write_private(Path(path), json.dumps(whole, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    return read(path)


def recordings_root(values: dict, wisp_dir: Path, home: Path) -> Path:
    configured = str(values.get("recordingsPath") or "").strip()
    if not configured:
        return Path(wisp_dir) / "reunioes"
    if configured == "~":
        return Path(home)
    if configured.startswith(("~/", "~\\")):
        return Path(home) / configured[2:]
    return Path(configured)


def load(path: Path) -> dict:
    return _load(path)
