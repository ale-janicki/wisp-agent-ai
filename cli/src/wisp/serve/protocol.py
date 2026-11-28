from __future__ import annotations

import json
from typing import Any

STATE_THINKING = "thinking"
STATE_IDLE = "idle"
STATE_ERROR = "error"

ALLOWED_ORIGINS = ["http://tauri.localhost", "https://tauri.localhost", "tauri://localhost"]
HEARTBEAT_SECONDS = 15.0
DEFAULT_TITLE = "Nova conversa"
ENGINE = "claude"
MAX_UPLOAD_BYTES = 100 * 1024 * 1024


def event(conversation_id: str, type_: str, **fields: Any) -> dict[str, Any]:
    return {"conversation_id": conversation_id, "type": type_, **fields}


def feature_event(feature: str, type_: str, **fields: Any) -> dict[str, Any]:
    return {"feature": feature, "type": type_, **fields}


def sse_data(payload: dict[str, Any]) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
