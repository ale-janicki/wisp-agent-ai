from __future__ import annotations

import contextlib
import json
import os
import re
import sys
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterator

from wisp.compat import lock_file, unlock_file

VERSION = 1
RECENT_MESSAGES = 6
RECENT_CHARS = 3000
OLDER_CHARS = 400
BUDGET_CHARS = 24000
HEADER = ("[Wisp conversation memory: this conversation continues from Wisp's own transcript because the engine "
          "session was not available. Older messages are shortened.]")
FOOTER = "[end of Wisp conversation memory]"
LOST_SESSION_MARKERS = ("no conversation found with session id", "codex session not found: the saved conversation "
                        "will be replayed")
TITLE_FALLBACK_LIMIT = 32
_ID = re.compile(r"[0-9A-Za-z-]{1,64}")
_WRAPPERS = ("<command-", "<local-command", "<system-reminder", "<task-notification", "<bash-")
_SYNTHETIC_PROMPTS = ("[Request interrupted by user",)


def _home(home: str | None) -> Path:
    return Path(home) if home else Path.home()


def data_dir(env=None, platform: str | None = None, home: str | None = None) -> Path:
    env = os.environ if env is None else env
    platform = platform or sys.platform
    if env.get("WISP_DATA_DIR"):
        return Path(env["WISP_DATA_DIR"])
    base = _home(home)
    if platform == "darwin":
        return base / "Library" / "Application Support" / "Wisp"
    if platform == "win32":
        return Path(env["APPDATA"]) / "Wisp" if env.get("APPDATA") else base / "AppData" / "Roaming" / "Wisp"
    xdg = env.get("XDG_DATA_HOME")
    return (Path(xdg) if xdg else base / ".local" / "share") / "wisp"


def wisp_root(env=None, home: str | None = None) -> Path:
    env = os.environ if env is None else env
    if env.get("WISP_DATA_DIR"):
        return Path(env["WISP_DATA_DIR"])
    base = _home(home)
    if env.get("WISP_CONFIG"):
        config = Path(os.path.expanduser(env["WISP_CONFIG"]))
    else:
        xdg = env.get("XDG_CONFIG_HOME")
        config = (Path(xdg) if xdg else base / ".config") / "wisp" / "wisp.json"
    raw = None
    with contextlib.suppress(OSError, ValueError):
        raw = json.loads(config.read_text(encoding="utf-8"))
    chosen = raw.get("wisp_dir") if isinstance(raw, dict) else None
    chosen = chosen if isinstance(chosen, str) and chosen else "~/Wisp"
    if chosen == "~":
        return base
    if chosen.startswith(("~/", "~\\")):
        return base / chosen[2:]
    return Path(chosen)


def conversas_dir(env=None, home: str | None = None) -> Path:
    return wisp_root(env, home) / "conversas"


@contextlib.contextmanager
def _locked(fd: int) -> Iterator[None]:
    lock_file(fd)
    try:
        yield
    finally:
        unlock_file(fd)


def format_time(moment: datetime) -> str:
    moment = moment.astimezone(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S") + f".{moment.microsecond // 1000:03d}Z"


def parse_time(text: str) -> datetime:
    moment = datetime.fromisoformat(text)
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


def stamp() -> str:
    return format_time(datetime.now(timezone.utc))


def title_fallback(text: str, limit: int = TITLE_FALLBACK_LIMIT) -> str:
    flat = " ".join(text.split())
    if len(flat) <= limit:
        return flat
    head = flat[:limit]
    if flat[limit] == " ":
        return head.strip(" \t")
    space = head.rfind(" ")
    return head[:space].strip(" \t") if space >= 0 else head


def is_lost_session(text: str) -> bool:
    lowered = text.lower()
    return any(marker in lowered for marker in LOST_SESSION_MARKERS)


class ConversationStore:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.last_recovery_note: str | None = None
        self._mutex = threading.Lock()

    @property
    def _file(self) -> Path:
        return self.directory / "conversations.json"

    @property
    def _bad(self) -> Path:
        return self.directory / "conversations.json.bad"

    @contextlib.contextmanager
    def _file_lock(self) -> Iterator[None]:
        self.directory.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.directory / "conversations.json.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            with _locked(fd):
                yield
        finally:
            os.close(fd)

    def _load(self) -> list[dict]:
        try:
            raw = json.loads(self._file.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return []
        except (OSError, ValueError):
            return self._quarantine()
        if not isinstance(raw, list):
            return self._quarantine()
        records = []
        try:
            for item in raw:
                record = dict(item)
                record["updatedAt"] = parse_time(record["updatedAt"])
                if "closedAt" in record:
                    try:
                        record["closedAt"] = parse_time(record["closedAt"])
                    except (TypeError, ValueError):
                        record.pop("closedAt")
                        record.pop("closedFrom", None)
                if not {"id", "title"} <= record.keys():
                    raise KeyError("id/title")
                records.append(record)
        except (KeyError, TypeError, ValueError, AttributeError):
            return self._quarantine()
        return records

    def _quarantine(self) -> list[dict]:
        with contextlib.suppress(OSError):
            self._bad.unlink()
        with contextlib.suppress(OSError):
            os.replace(self._file, self._bad)
        self.last_recovery_note = f"o índice de conversas estava corrompido; guardei uma cópia em {self._bad}"
        return []

    @staticmethod
    def _sorted(records: list[dict]) -> list[dict]:
        return sorted(records, key=lambda r: r["updatedAt"], reverse=True)

    def _persist(self, records: list[dict]) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        out = []
        for record in self._sorted(records):
            item = dict(record)
            item["updatedAt"] = format_time(item["updatedAt"])
            if isinstance(item.get("closedAt"), datetime):
                item["closedAt"] = format_time(item["closedAt"])
            out.append(item)
        temporary = self.directory / f".conversations.json.{uuid.uuid4().hex}.tmp"
        temporary.write_text(json.dumps(out, indent=2, sort_keys=True, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, self._file)

    def all(self) -> list[dict]:
        with self._mutex:
            return self._sorted(self._load())

    def get(self, conversation_id: str) -> dict | None:
        wanted = conversation_id.lower()
        return next((r for r in self.all() if str(r["id"]).lower() == wanted), None)

    def upsert(self, record: dict) -> None:
        with self._mutex, self._file_lock():
            records = self._load()
            for index, current in enumerate(records):
                if str(current["id"]).lower() == str(record["id"]).lower():
                    records[index] = record
                    break
            else:
                records.append(record)
            self._persist(records)

    def update(self, conversation_id: str, change: Callable[[dict], None]) -> dict | None:
        wanted = conversation_id.lower()
        with self._mutex, self._file_lock():
            records = self._load()
            for record in records:
                if str(record["id"]).lower() == wanted:
                    change(record)
                    self._persist(records)
                    return record
        return None

    def create(self, title: str | None, default_title: str = "Nova conversa") -> dict:
        record = {"id": str(uuid.uuid4()).upper(), "title": title or default_title,
                  "updatedAt": datetime.now(timezone.utc), "titleGenerated": False, "awayOnPhone": False}
        self.upsert(record)
        return record

    def delete(self, conversation_id: str) -> None:
        wanted = conversation_id.lower()
        with self._mutex, self._file_lock():
            self._persist([r for r in self._load() if str(r["id"]).lower() != wanted])


def encode_entry(entry: dict) -> str:
    return json.dumps({"v": VERSION, **{k: v for k, v in entry.items() if v is not None}}, sort_keys=True,
                      separators=(",", ":"), ensure_ascii=False)


def decode_entries(data: bytes) -> list[dict]:
    entries = []
    for line in data.split(b"\n"):
        if not line:
            continue
        try:
            raw = json.loads(line)
        except ValueError:
            continue
        if isinstance(raw, dict) and raw.get("kind") in ("session", "user", "assistant"):
            entries.append({"kind": raw["kind"], "at": raw.get("at", ""), **{
                key: raw[key] for key in ("surface", "text", "engine", "model", "session", "reason")
                if isinstance(raw.get(key), str)}})
    return entries


def _clip(text: str, limit: int) -> str:
    trimmed = text.strip()
    return trimmed if len(trimmed) <= limit else trimmed[:limit].strip() + "…"


def build_context(entries: list[dict]) -> str | None:
    for index in range(len(entries) - 1, -1, -1):
        if entries[index]["kind"] == "session" and entries[index].get("reason") == "reset":
            entries = entries[index + 1:]
            break
    messages = [e for e in entries if e["kind"] in ("user", "assistant") and (e.get("text") or "").strip()]
    if not any(e["kind"] == "assistant" for e in messages):
        return None
    kept: list[str] = []
    used = 0
    for index, entry in enumerate(reversed(messages)):
        label = "User" if entry["kind"] == "user" else "Assistant"
        block = f"{label}: {_clip(entry['text'], RECENT_CHARS if index < RECENT_MESSAGES else OLDER_CHARS)}"
        if used + len(block) + 2 > BUDGET_CHARS:
            break
        kept.append(block)
        used += len(block) + 2
    if not kept:
        return None
    omitted = len(messages) - len(kept)
    notice = [f"({omitted} older messages not shown.)"] if omitted > 0 else []
    return "\n\n".join([HEADER, *notice, *reversed(kept), FOOTER])


def prime(context: str | None, prompt: str) -> str:
    return prompt if context is None else f"{context}\n\n{prompt}"


class TranscriptStore:
    def __init__(self, folder: Path, stamp: Callable[[], str] = stamp):
        self.folder = Path(folder)
        self._stamp = stamp

    def _path(self, conversation: str) -> Path | None:
        return self.folder / f"{conversation}.jsonl" if _ID.fullmatch(conversation) else None

    def find(self, session: str | None) -> str | None:
        if not session or not _ID.fullmatch(session):
            return None
        if (self.folder / f"{session}.jsonl").exists():
            return session
        needle = f'"session":"{session}"'.encode()
        for file in sorted(self.folder.glob("*.jsonl")):
            try:
                data = file.read_bytes()
            except OSError:
                continue
            if needle in data and any(e["kind"] == "session" and e.get("session") == session
                                      for e in decode_entries(data)):
                return file.stem
        return None

    def entries(self, conversation: str) -> list[dict]:
        path = self._path(conversation)
        try:
            return decode_entries(path.read_bytes()) if path else []
        except OSError:
            return []

    def messages(self, conversation: str) -> list[dict]:
        return [{"role": e["kind"], "text": e["text"]} for e in self.entries(conversation)
                if e["kind"] in ("user", "assistant") and e.get("text")]

    def last_engine(self, conversation: str | None) -> str | None:
        if not conversation:
            return None
        found = [e["engine"] for e in self.entries(conversation) if e["kind"] == "assistant" and e.get("engine")]
        return found[-1] if found else None

    def engine_session(self, conversation: str | None, engine: str) -> str | None:
        if not conversation:
            return None
        found = [e["session"] for e in self.entries(conversation)
                 if e["kind"] == "session" and e.get("engine") == engine and e.get("session")]
        return found[-1] if found else None

    def context(self, conversation: str | None, drop_trailing_users: int = 0) -> str | None:
        if not conversation:
            return None
        entries = self.entries(conversation)
        dropped = 0
        while dropped < drop_trailing_users and entries and entries[-1]["kind"] == "user":
            entries.pop()
            dropped += 1
        return build_context(entries)

    def append_user(self, conversation: str, opening_session: str | None, text: str, surface: str) -> str:
        return self._append({"kind": "user", "at": self._stamp(), "surface": surface, "text": text},
                            conversation, opening_session)

    def append_assistant(self, conversation: str, opening_session: str | None, text: str, surface: str, engine: str,
                         model: str | None) -> str:
        return self._append({"kind": "assistant", "at": self._stamp(), "surface": surface, "text": text,
                             "engine": engine, "model": model or ""}, conversation, opening_session)

    def link(self, session: str, conversation: str, engine: str, reason: str) -> None:
        self._append({"kind": "session", "at": self._stamp(), "engine": engine, "session": session,
                      "reason": reason}, conversation, None)

    def _append(self, entry: dict, conversation: str, opening_session: str | None) -> str:
        path = self._path(conversation)
        if path is None:
            raise ValueError(f"id de conversa inválido: {conversation}")
        lines = []
        if not path.exists() and opening_session:
            lines.append(encode_entry({"kind": "session", "at": entry["at"], "engine": "claude",
                                       "session": opening_session, "reason": "new"}))
        lines.append(encode_entry(entry))
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            with _locked(fd):
                broken = False
                if os.fstat(fd).st_size > 0:
                    with open(path, "rb") as probe:
                        probe.seek(-1, os.SEEK_END)
                        broken = probe.read(1) != b"\n"
                payload = ("\n" if broken else "") + "".join(line + "\n" for line in lines)
                os.write(fd, payload.encode("utf-8"))
        finally:
            os.close(fd)
        return entry["at"]


def project_directory_name(cwd: str) -> str:
    path = cwd
    while len(path) > 1 and path.endswith(("/", "\\")):
        path = path[:-1]
    return re.sub(r"[^0-9A-Za-z]", "-", path)


def locate_claude_session(session_id: str, cwd: str | None, projects_root: Path | None = None) -> Path | None:
    if not session_id or "/" in session_id or "\\" in session_id or session_id.startswith("."):
        return None
    root = projects_root or Path.home() / ".claude" / "projects"
    name = f"{session_id}.jsonl"
    if cwd:
        expected = root / project_directory_name(cwd) / name
        if expected.is_file():
            return expected
    try:
        return next((folder / name for folder in sorted(root.iterdir()) if (folder / name).is_file()), None)
    except OSError:
        return None


def claude_history(path: Path) -> list[dict]:
    messages: list[dict] = []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return messages
    for line in text.splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        message = obj.get("message") if isinstance(obj, dict) else None
        if not isinstance(message, dict) or obj.get("isMeta") or obj.get("isSidechain"):
            continue
        content = message.get("content")
        if obj.get("type") == "user":
            if isinstance(content, str):
                trimmed = content.strip()
                if trimmed and not trimmed.startswith(_WRAPPERS + _SYNTHETIC_PROMPTS):
                    messages.append({"role": "user", "blocks": [{"type": "text", "text": trimmed}]})
            elif isinstance(content, list):
                blocks = [{"type": "tool_result", "tool_use_id": b.get("tool_use_id", ""),
                           "content": tool_result_text(b.get("content")), "is_error": bool(b.get("is_error"))}
                          for b in content if isinstance(b, dict) and b.get("type") == "tool_result"]
                if blocks:
                    messages.append({"role": "user", "blocks": blocks})
        elif obj.get("type") == "assistant" and isinstance(content, list) and message.get("model") != "<synthetic>":
            blocks = assistant_blocks(content)
            if blocks:
                messages.append({"role": "assistant", "blocks": blocks})
    return messages


def tool_result_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b["text"] for b in content if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def assistant_blocks(content: list) -> list[dict]:
    blocks = []
    for item in content:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text" and isinstance(item.get("text"), str) and item["text"].strip():
            blocks.append({"type": "text", "text": item["text"]})
        elif item.get("type") == "tool_use":
            blocks.append({"type": "tool_use", "id": item.get("id", ""), "name": item.get("name", ""),
                           "input": item.get("input") if isinstance(item.get("input"), dict) else {}})
    return blocks


def wisp_history(messages: list[dict]) -> list[dict]:
    return [{"role": m["role"], "blocks": [{"type": "text", "text": m["text"]}]} for m in messages]
