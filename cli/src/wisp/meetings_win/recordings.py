from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass
from datetime import datetime, tzinfo
from pathlib import Path

from wisp.meetings_win.audio import SAMPLE_RATE
from wisp.meetings_win.transcript import clock, iso, parse_iso, transcript_path, write_private
from wisp.meetings_win.wavfile import repair_header

AUDIO_FILE = "audio.wav"
META_FILE = "meta.json"
NOTE_FILE = "nota.md"
FOLDER_STAMP = "%Y-%m-%d_%H-%M-%S"

RECORDING, TRANSCRIBING, TRANSCRIBED, NOTED, FAILED, INTERRUPTED = (
    "recording", "transcribing", "transcribed", "noted", "failed", "interrompida")

_META_LOCK = threading.RLock()


def new_meta(started_at: datetime, mic: str | None = None, system: str | None = None, sources: str = "both",
             detected_app: str | None = None, language: str | None = None, title: str | None = None) -> dict:
    meta = {"version": 1, "mode": "call", "started_at": iso(started_at), "devices": {"mic": mic, "system": system},
            "status": RECORDING, "sources": sources}
    for key, value in (("detected_app", detected_app), ("language", language), ("title", title)):
        if value:
            meta[key] = value
    return meta


def _retrying(action):
    for attempt in range(8):
        try:
            return action()
        except PermissionError:
            if attempt == 7:
                raise
            time.sleep(0.02 * (attempt + 1))


def read_meta(folder: Path) -> dict:
    with _META_LOCK:
        data = json.loads(_retrying(lambda: (Path(folder) / META_FILE).read_text("utf-8")))
    if not isinstance(data, dict):
        raise ValueError("meta.json has no object at the top")
    return data


def has_meta(folder: Path) -> bool:
    with _META_LOCK:
        try:
            _retrying(lambda: os.stat(Path(folder) / META_FILE))
        except PermissionError:
            return True
        except OSError:
            return False
    return True


def write_meta(folder: Path, meta: dict) -> None:
    with _META_LOCK:
        write_private(Path(folder) / META_FILE, json.dumps(meta, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def update_meta(folder: Path, change) -> dict:
    with _META_LOCK:
        meta = read_meta(folder)
        change(meta)
        write_meta(folder, meta)
        return meta


def create_folder(root: Path, moment: datetime) -> Path:
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    base = moment.astimezone().strftime(FOLDER_STAMP)
    suffix = 1
    while True:
        folder = root / (base if suffix == 1 else f"{base}-{suffix}")
        try:
            folder.mkdir(mode=0o700)
            return folder
        except FileExistsError:
            suffix += 1


@dataclass(frozen=True)
class Entry:
    folder: Path
    meta: dict
    has_transcript: bool
    has_note: bool

    @property
    def id(self) -> str:
        return self.folder.name

    @property
    def status(self) -> str:
        return str(self.meta.get("status") or "")

    @property
    def started_at(self) -> datetime | None:
        try:
            return parse_iso(str(self.meta["started_at"]))
        except (KeyError, ValueError):
            return None


def list_meetings(root: Path) -> list[Entry]:
    try:
        names = os.listdir(root)
    except OSError:
        return []
    entries = []
    for name in names:
        folder = Path(root) / name
        try:
            meta = read_meta(folder)
        except (OSError, ValueError):
            continue
        entries.append(Entry(folder, meta, transcript_path(folder).exists(), (folder / NOTE_FILE).exists()))
    entries.sort(key=lambda e: (str(e.meta.get("started_at") or ""), e.id), reverse=True)
    return entries


def needs_processing(entry: Entry) -> bool:
    if entry.status in (TRANSCRIBING, INTERRUPTED):
        return True
    return (entry.status == TRANSCRIBED and entry.has_transcript and not entry.has_note
            and not entry.meta.get("failure") and entry.meta.get("summary_deferred") is not True)


def pending(root: Path, excluding=()) -> list[Entry]:
    return [e for e in list_meetings(root) if needs_processing(e) and e.id not in set(excluding)]


def badge(status: str, working: bool, has_note: bool) -> dict:
    if status == RECORDING:
        return {"label": "gravando", "tone": "recording"}
    if status in (TRANSCRIBING, INTERRUPTED):
        return {"label": "transcrevendo", "tone": "working"}
    if status == TRANSCRIBED:
        if working:
            return {"label": "gerando nota", "tone": "working"}
        return {"label": "pronto", "tone": "ready"} if has_note else {"label": "transcrito", "tone": "ready"}
    if status == NOTED:
        return {"label": "pronto", "tone": "ready"}
    return {"label": "falhou", "tone": "failed"}


def default_title(moment: datetime, tz: tzinfo | None = None) -> str:
    return "Reunião de " + moment.astimezone(tz).strftime("%d/%m às %H:%M")


def row_model(entry: Entry, working: bool, tz: tzinfo | None = None) -> dict:
    moment = entry.started_at or datetime.fromtimestamp(0, tz)
    duration = entry.meta.get("duration_s")
    return {
        "id": entry.id,
        "title": entry.meta.get("title") or default_title(moment, tz),
        "date_text": moment.astimezone(tz).strftime("%d/%m %H:%M"),
        "duration_text": clock(duration) if isinstance(duration, (int, float)) and duration > 0 else "—",
        "badge": badge(entry.status, working, entry.has_note),
        "detail": entry.meta.get("failure"),
        "notice": entry.meta.get("notice"),
        "has_note": entry.has_note,
        "has_transcript": entry.has_transcript,
    }


def brain_button(brain_note: str | None, exists: bool) -> dict:
    if brain_note and exists:
        return {"label": "Abrir no brain", "opens_note": True}
    return {"label": "Salvar no brain", "opens_note": False}


def has_active_recording(root: Path, within: float = 60.0, now: float | None = None) -> bool:
    import time

    now = time.time() if now is None else now
    try:
        names = os.listdir(root)
    except OSError:
        return False
    for name in names:
        folder = Path(root) / name
        touched = []
        for path in (folder, folder / AUDIO_FILE, folder / META_FILE):
            try:
                touched.append(path.stat().st_mtime)
            except OSError:
                pass
        if touched and now - max(touched) < within:
            try:
                if read_meta(folder).get("status") == RECORDING:
                    return True
            except (OSError, ValueError):
                pass
    return False


def recover(root: Path, active=()) -> list[dict]:
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return []
    recovered = []
    for name in names:
        if name in set(active):
            continue
        folder = Path(root) / name
        try:
            meta = read_meta(folder)
        except (OSError, ValueError):
            continue
        if meta.get("status") != RECORDING:
            continue
        frames = repair_header(folder / AUDIO_FILE)
        if frames <= 0:
            reason = "a gravação foi interrompida antes de gravar áudio"
            update_meta(folder, lambda m: m.update(status=FAILED, failure=reason))
            recovered.append({"id": name, "duration_s": 0.0, "failure": reason})
            continue
        duration = frames / SAMPLE_RATE

        def interrupted(m, duration=duration):
            m.update(status=INTERRUPTED, duration_s=duration)
            m.pop("failure", None)

        update_meta(folder, interrupted)
        recovered.append({"id": name, "duration_s": duration, "failure": None})
    return recovered
