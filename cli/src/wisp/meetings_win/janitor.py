from __future__ import annotations

import os
import shutil
import tempfile
from datetime import datetime, timedelta, timezone, tzinfo
from pathlib import Path
from urllib.parse import unquote

from wisp.meetings_win import recordings
from wisp.meetings_win.recordings import FOLDER_STAMP, Entry

DEFAULT_DAYS = 7
MAX_DAYS = 365
DAY_CHOICES = (7, 14, 30)
LINK_PREFIX = "[Transcrição completa]("


def clamp(days: int) -> int:
    return min(max(int(days), 0), MAX_DAYS)


def recording_date(started_at: datetime | None, folder_name: str, tz: tzinfo | None = None) -> datetime | None:
    if started_at is not None:
        return started_at
    try:
        return datetime.strptime(folder_name[:19], FOLDER_STAMP).replace(tzinfo=tz or datetime.now().astimezone().tzinfo)
    except ValueError:
        return None


def _resolved(path) -> str:
    return str(Path(path).resolve())


def contains(folder: Path, path: str) -> bool:
    root = _resolved(folder)
    target = _resolved(path)
    return target == root or target.startswith(root + os.sep)


def is_eligible(entry: Entry, now: datetime, days: int, excluded=(), brain_note_exists=os.path.exists) -> bool:
    meta = entry.meta
    if days <= 0 or meta.get("status") != recordings.NOTED or entry.id in excluded:
        return False
    if meta.get("brain_error") or meta.get("note_state") != "generated":
        return False
    brain_note = meta.get("brain_note")
    if not brain_note or not brain_note_exists(brain_note) or contains(entry.folder, brain_note):
        return False
    started = recording_date(entry.started_at, entry.id)
    return started is not None and now - started >= timedelta(days=days)


def eligible(entries: list[Entry], now: datetime, days: int, excluded=(), brain_note_exists=os.path.exists) -> list[Entry]:
    excluded = frozenset(excluded)
    return [e for e in entries if is_eligible(e, now, days, excluded, brain_note_exists)]


def stamp(now: datetime, days: int, tz: tzinfo | None = None) -> str:
    return f"Transcrição apagada em {now.astimezone(tz).strftime('%d/%m/%Y')} (limpeza automática após {days} dias)."


def scan_transcript_links(note: str, folder: Path, now: datetime, days: int, home: Path | None = None,
                          tz: tzinfo | None = None) -> dict:
    home = Path(home) if home else Path.home()
    lines = note.split("\n")
    changed = False
    foreign = 0
    for index, line in enumerate(lines):
        trimmed = line.strip()
        if not (trimmed.startswith(LINK_PREFIX) and trimmed.endswith(")")):
            continue
        path = unquote(trimmed[len(LINK_PREFIX):-1])
        if path.startswith("~/"):
            path = str(home / path[2:])
        if _resolved(Path(path).parent) != _resolved(folder):
            foreign += 1
            continue
        lines[index] = stamp(now, days, tz)
        changed = True
    return {"text": "\n".join(lines) if changed else None, "foreign": foreign}


def _snapshot(path: Path):
    try:
        return path.read_text("utf-8"), path.stat().st_mtime_ns
    except (OSError, UnicodeDecodeError):
        return None


def _replace(path: Path, text: str) -> bool:
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        shutil.copymode(path, temp)
        os.replace(temp, path)
        return True
    except OSError:
        Path(temp).unlink(missing_ok=True)
        return False


def clean(entry: Entry, now: datetime, days: int, home: Path | None = None, brain_note_exists=os.path.exists,
          is_excluded=lambda _id: False, before_write=lambda: None, trash=None, tz: tzinfo | None = None):
    try:
        meta = recordings.read_meta(entry.folder)
    except (OSError, ValueError):
        return ("skipped", None)
    note_path = meta.get("brain_note")
    if (meta.get("status") != recordings.NOTED or meta.get("note_state") != "generated" or meta.get("brain_error")
            or not note_path or not brain_note_exists(note_path) or contains(entry.folder, note_path)):
        return ("skipped", None)
    note = Path(note_path)
    before = _snapshot(note)
    if before is None:
        return ("skipped", None)
    scan = scan_transcript_links(before[0], entry.folder, now, days, home, tz)
    if scan["text"] is None and scan["foreign"] > 0:
        return ("skipped", None)
    if is_excluded(entry.id):
        return ("skipped", None)
    if scan["text"] is not None:
        before_write()
        if _snapshot(note) != before:
            return ("skipped", None)
        after = None
        if _replace(note, scan["text"]):
            after = _snapshot(note)
        if after is None or after[0] != scan["text"]:
            return ("skipped", None)
    try:
        trash(entry.folder)
        return ("removed", None)
    except Exception as problem:
        return ("failed", str(problem))


def run(roots, now: datetime | None = None, days: int = DEFAULT_DAYS, excluded=(), home: Path | None = None,
        brain_note_exists=os.path.exists, is_excluded=lambda _id: False, before_write=lambda: None, trash=None,
        tz: tzinfo | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    report = {"removed": [], "failures": []}
    for root in roots:
        for entry in eligible(recordings.list_meetings(root), now, days, excluded, brain_note_exists):
            outcome, detail = clean(entry, now, days, home, brain_note_exists, is_excluded, before_write, trash, tz)
            if outcome == "removed":
                report["removed"].append(entry.id)
            elif outcome == "failed":
                report["failures"].append(f"{entry.id}: {detail}")
    return report
