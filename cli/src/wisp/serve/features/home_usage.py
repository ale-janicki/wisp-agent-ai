from __future__ import annotations

import json
import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path


@dataclass
class _Entry:
    id: str
    when: datetime
    input: int
    output: int
    cache_creation: int
    cache_read: int

    @property
    def billable(self) -> int:
        return self.input + self.output + self.cache_creation


@dataclass
class _FileState:
    size: int = 0
    modified: float = 0.0
    offset: int = 0
    entries: list[_Entry] = field(default_factory=list)
    tail: list[_Entry] = field(default_factory=list)


def default_root() -> Path:
    return Path.home() / ".claude" / "projects"


def _parse_time(text: str) -> datetime | None:
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


def _entry(line: bytes) -> _Entry | None:
    if b'"usage"' not in line or b'"assistant"' not in line:
        return None
    try:
        raw = json.loads(line)
    except ValueError:
        return None
    if not isinstance(raw, dict) or raw.get("type") != "assistant":
        return None
    message = raw.get("message")
    if not isinstance(message, dict) or message.get("model") == "<synthetic>" or not isinstance(message.get("usage"), dict):
        return None
    ident = message.get("id") or raw.get("uuid")
    stamp = _parse_time(raw["timestamp"]) if isinstance(raw.get("timestamp"), str) else None
    if not isinstance(ident, str) or stamp is None:
        return None
    usage = message["usage"]

    def tokens(key: str) -> int:
        value = usage.get(key)
        return value if isinstance(value, int) and not isinstance(value, bool) else 0

    return _Entry(ident, stamp, tokens("input_tokens"), tokens("output_tokens"),
                  tokens("cache_creation_input_tokens"), tokens("cache_read_input_tokens"))


class UsageIndex:
    def __init__(self, root: Path | None = None) -> None:
        self.root = root or default_root()
        self._files: dict[Path, _FileState] = {}
        self._lock = threading.Lock()

    def summary(self, now: datetime | None = None, days: int = 7) -> dict:
        with self._lock:
            now = (now or datetime.now().astimezone()).astimezone()
            today = now.date()
            first = today - timedelta(days=max(1, days) - 1)
            window_start = datetime.combine(first, datetime.min.time()).astimezone().timestamp()
            current = self._transcripts(window_start)
            self._files = {p: s for p, s in self._files.items() if p in {c[0] for c in current}}
            seen: set[str] = set()
            week = day = 0
            for path, size, modified in current:
                state = self._refreshed(path, size, modified)
                self._files[path] = state
                for entry in state.entries + state.tail:
                    if entry.id in seen:
                        continue
                    local = entry.when.astimezone().date()
                    if not first <= local <= today:
                        continue
                    seen.add(entry.id)
                    week += entry.billable
                    if local == today:
                        day += entry.billable
            return {"today": day, "week": week}

    def _transcripts(self, since: float) -> list[tuple[Path, int, float]]:
        found = []
        try:
            for path in self.root.rglob("*.jsonl"):
                try:
                    info = path.stat()
                except OSError:
                    continue
                if path.is_file() and info.st_mtime >= since:
                    found.append((path, info.st_size, info.st_mtime))
        except OSError:
            return []
        return found

    def _refreshed(self, path: Path, size: int, modified: float) -> _FileState:
        cached = self._files.get(path)
        kept = cached if cached and cached.offset <= size and (cached.size < size or (cached.size == size and cached.modified == modified)) else None
        if kept and kept.size == size:
            return kept
        state = kept or _FileState()
        state.size, state.modified, state.tail = size, modified, []
        try:
            with path.open("rb") as handle:
                handle.seek(state.offset)
                position = state.offset
                for line in handle:
                    complete = line.endswith(b"\n")
                    entry = _entry(line.rstrip(b"\r\n"))
                    position += len(line)
                    if complete:
                        if entry:
                            state.entries.append(entry)
                        state.offset = position
                    elif entry:
                        state.tail.append(entry)
        except OSError:
            return state
        return state
