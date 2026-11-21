from __future__ import annotations
import fcntl, json, logging, os, re
from collections.abc import Iterable
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger("wisp.transcript")

VERSION = 1
ID = re.compile(r"^[A-Za-z0-9-]{1,64}$")
RECENT_MESSAGES = 6
RECENT_CHARS = 3000
OLDER_CHARS = 400
BUDGET_CHARS = 24000
LABELS = {"user": "User", "assistant": "Assistant"}
HEADER = ("[Wisp conversation memory: this conversation continues from Wisp's own transcript because the "
          "engine session was not available. Older messages are shortened.]")
FOOTER = "[end of Wisp conversation memory]"
REBUILT_NOTE = "<i>↻ a sessão do Claude não estava aqui; retomei pela conversa guardada no Wisp.</i>"
ENGINE_NAMES = {"claude": "Claude", "codex": "Codex"}


def switched_note(engine: str) -> str:
    return f"<i>↻ agora quem responde é o {ENGINE_NAMES.get(engine, engine)}; ele retomou pela conversa guardada no Wisp.</i>"


def stamp(moment: datetime | None = None) -> str:
    moment = (moment or datetime.now(timezone.utc)).astimezone(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def encode(entry: dict) -> str:
    return json.dumps(entry, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def append_line(path: Path, line: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        size = os.fstat(fd).st_size
        broken = size > 0 and os.pread(fd, 1, size - 1) != b"\n"
        data = (("\n" if broken else "") + line + "\n").encode("utf-8")
        while data:
            data = data[os.write(fd, data):]
    finally:
        os.close(fd)


def read_entries(path: Path) -> list[dict]:
    try:
        raw = path.read_text("utf-8", errors="replace")
    except OSError:
        return []
    entries = []
    for line in raw.split("\n"):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and isinstance(entry.get("kind"), str):
            entries.append(entry)
    return entries


def clip(text: str, limit: int) -> str:
    text = text.strip()
    return text if len(text) <= limit else text[:limit].rstrip() + "…"


def after_reset(entries: Iterable[dict]) -> list[dict]:
    entries = list(entries)
    for index in range(len(entries) - 1, -1, -1):
        if entries[index].get("kind") == "session" and entries[index].get("reason") == "reset":
            return entries[index + 1:]
    return entries


def coverage(entries: Iterable[dict]) -> dict[str, int]:
    owner = None
    out: dict[str, int] = {}
    for e in entries:
        if e.get("kind") == "session" and (e.get("engine") or "claude") == "claude" and isinstance(e.get("session"), str):
            owner = e["session"]
            out.setdefault(owner, 0)
        elif owner and e.get("kind") in LABELS and isinstance(e.get("text"), str) and e["text"].strip():
            out[owner] += 1
    return out


def build_context(entries: Iterable[dict]) -> str | None:
    messages = [e for e in after_reset(entries) if e.get("kind") in LABELS and isinstance(e.get("text"), str) and e["text"].strip()]
    if not any(e["kind"] == "assistant" for e in messages):
        return None
    kept: list[str] = []
    used = 0
    for index, entry in enumerate(reversed(messages)):
        limit = RECENT_CHARS if index < RECENT_MESSAGES else OLDER_CHARS
        block = f"{LABELS[entry['kind']]}: {clip(entry['text'], limit)}"
        if used + len(block) + 2 > BUDGET_CHARS:
            break
        kept.append(block)
        used += len(block) + 2
    if not kept:
        return None
    omitted = len(messages) - len(kept)
    parts = [HEADER] + ([f"({omitted} older messages not shown.)"] if omitted else []) + kept[::-1] + [FOOTER]
    return "\n\n".join(parts)


def prime(context: str | None, prompt: str) -> str:
    return f"{context}\n\n{prompt}" if context else prompt


class Transcripts:
    def __init__(self, folder: Path, secrets: Iterable[str] = ()):
        self.folder = folder
        self.secrets = [s for s in secrets if s]
        self.failed = False
        self.notice: str | None = None
        self.found: dict[str, str] = {}

    def path(self, conversation: str) -> Path:
        if not ID.match(conversation):
            raise ValueError(f"invalid conversation id: {conversation!r}")
        return self.folder / f"{conversation}.jsonl"

    def find(self, session_id: str) -> str | None:
        if not ID.match(session_id or ""):
            return None
        if session_id in self.found and self.path(self.found[session_id]).exists():
            return self.found[session_id]
        if self.path(session_id).exists():
            return session_id
        needle = f'"session":"{session_id}"'
        try:
            candidates = sorted(self.folder.glob("*.jsonl"))
        except OSError:
            return None
        for candidate in candidates:
            try:
                raw = candidate.read_text("utf-8", errors="replace")
            except OSError:
                continue
            if needle in raw and any(e.get("kind") == "session" and e.get("session") == session_id
                                     for e in read_entries(candidate)):
                self.found[session_id] = candidate.stem
                return candidate.stem
        return None

    def entries(self, session_id: str) -> list[dict]:
        conversation = self.find(session_id)
        return read_entries(self.path(conversation)) if conversation else []

    def context(self, session_id: str, drop_last_user: bool = False) -> str | None:
        entries = self.entries(session_id)
        if drop_last_user and entries and entries[-1].get("kind") == "user":
            entries = entries[:-1]
        return build_context(entries)

    def last_engine(self, session_id: str) -> str | None:
        for entry in reversed(self.entries(session_id)):
            if entry.get("kind") == "assistant" and isinstance(entry.get("engine"), str):
                return entry["engine"]
        return None

    def engine_session(self, session_id: str, engine: str) -> str | None:
        for entry in reversed(self.entries(session_id)):
            if entry.get("kind") == "session" and entry.get("engine") == engine and isinstance(entry.get("session"), str):
                return entry["session"]
        return None

    def engine_started(self, session_id: str, engine_session: str, engine: str, reason: str) -> None:
        self._write(session_id, {"kind": "session", "session": engine_session, "engine": engine, "reason": reason})

    def user(self, session_id: str, text: str, surface: str) -> None:
        self._write(session_id, {"kind": "user", "surface": surface, "text": text})

    def assistant(self, session_id: str, text: str, surface: str, engine: str, model: str | None) -> None:
        self._write(session_id, {"kind": "assistant", "surface": surface, "text": text,
                                 "engine": engine, "model": model or ""})

    def link(self, conversation: str, session_id: str, reason: str, engine: str = "claude") -> bool:
        try:
            append_line(self.path(conversation), encode({"v": VERSION, "at": stamp(), "kind": "session",
                                                         "session": session_id, "engine": engine, "reason": reason}))
            self.found[session_id] = conversation
            return True
        except (OSError, ValueError) as error:
            log.error("could not link %s to %s: %s", session_id, conversation, error)
            return False

    def conversation_entries(self, conversation: str) -> list[dict]:
        return read_entries(self.path(conversation))

    def rebuilt(self, old_session_id: str, new_session_id: str, engine: str) -> None:
        self._write(old_session_id, {"kind": "session", "session": new_session_id, "engine": engine,
                                     "reason": "rebuilt"})

    def _redact(self, entry: dict) -> dict:
        text = entry.get("text")
        if not isinstance(text, str):
            return entry
        for secret in self.secrets:
            text = text.replace(secret, "[redacted]")
        return {**entry, "text": text}

    def _write(self, session_id: str, entry: dict) -> None:
        try:
            conversation = self.find(session_id) or session_id
            path = self.path(conversation)
            at = stamp()
            lines = [encode({"v": VERSION, "at": at, **self._redact(entry)})]
            if not path.exists():
                lines.insert(0, encode({"v": VERSION, "at": at, "kind": "session", "session": session_id,
                                        "engine": "claude", "reason": "new"}))
            append_line(path, "\n".join(lines))
        except (OSError, ValueError) as error:
            log.error("could not write the transcript of %s: %s", session_id, error)
            if not self.failed:
                self.failed = True
                self.notice = f"não consegui guardar a conversa na pasta do Wisp: {error}"

    def take_notice(self) -> str | None:
        notice, self.notice = self.notice, None
        return notice
