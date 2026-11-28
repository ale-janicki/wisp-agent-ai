from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from typing import Callable, Protocol

from . import images
from .store import MAX_TEXT_BYTES, ClipboardStore, ClipItem, fingerprint, kind_of, opted_out, should_capture

POLL_SECONDS = 0.5
EXPIRY_SECONDS = 600.0
MAX_IMAGE_BYTES = 25_000_000


class ClipboardBusy(OSError):
    pass


class ClipboardSource(Protocol):
    def sequence(self) -> int: ...
    def formats(self) -> list[str]: ...
    def read_flag(self, name: str) -> int | None: ...
    def read_text(self) -> str | None: ...
    def read_image(self) -> bytes | None: ...
    def write_text(self, text: str) -> None: ...
    def write_image(self, png: bytes) -> None: ...


class Clipboard:
    def __init__(self, store: ClipboardStore, source: ClipboardSource | None, clock: Callable[[], float] = time.time) -> None:
        self.store, self.source, self.clock = store, source, clock
        self.history = store.load()
        self.notice: str | None = store.last_recovery_note
        self.notify: Callable[[], None] = lambda: None
        self._lock = threading.RLock()
        self._last = source.sequence() if source else 0
        self._swept = clock()
        self.expire_old()

    @property
    def _setting_file(self) -> Path:
        return self.store.directory / "capture.json"

    @property
    def capture_enabled(self) -> bool:
        try:
            return json.loads(self._setting_file.read_text("utf-8")).get("enabled", True) is not False
        except (OSError, ValueError, AttributeError):
            return True

    def set_capture(self, enabled: bool) -> None:
        self.store.directory.mkdir(parents=True, exist_ok=True)
        self._setting_file.write_text(json.dumps({"enabled": bool(enabled)}), "utf-8")

    def tick(self) -> bool:
        if self.source is None:
            return False
        now = self.clock()
        if now - self._swept >= EXPIRY_SECONDS:
            self._swept = now
            self.expire_old()
        sequence = self.source.sequence()
        if sequence == self._last:
            return False
        try:
            changed = self._capture()
        except ClipboardBusy:
            return False
        self._last = sequence
        return changed

    def _capture(self) -> bool:
        assert self.source is not None
        if not self.capture_enabled:
            return False
        formats = self.source.formats()
        if not should_capture(formats) or opted_out(formats, self.source.read_flag):
            return False
        text = self.source.read_text()
        if text is not None and text.strip():
            data = text.encode("utf-8")
            if len(data) > MAX_TEXT_BYTES:
                return False
            self._add(ClipItem.new(kind_of(text), text, None, fingerprint(data), self.clock()))
            return True
        raw = self.source.read_image()
        if raw and len(raw) <= MAX_IMAGE_BYTES:
            return self._capture_image(raw)
        return False

    def _capture_image(self, raw: bytes) -> bool:
        fp = fingerprint(raw)
        with self._lock:
            known = self.history.contains(fp)
        if known:
            self._add(ClipItem.new("image", None, None, fp, self.clock()))
            return True
        encoded = images.encode(raw)
        if encoded is None:
            return False
        item_id = ClipItem.new("image", None, None, fp, 0).id
        try:
            name = self.store.write_image(encoded[0], encoded[1], item_id)
        except OSError as error:
            self.notice = f"Não consegui salvar os copiados: {error}"
            return False
        self._add(ClipItem.new("image", None, name, fp, self.clock(), item_id))
        return True

    def _add(self, item: ClipItem) -> None:
        with self._lock:
            self.store.delete_files(self.history.insert(item))
            self.store.delete_files(self.history.expire(self.clock()))
            self._save()
        self.notify()

    def expire_old(self) -> None:
        with self._lock:
            expired = self.history.expire(self.clock())
            if expired:
                self.store.delete_files(expired)
                self._save()

    def _save(self) -> None:
        try:
            self.store.save(self.history)
            self.notice = None
        except OSError as error:
            self.notice = f"Não consegui salvar os copiados: {error}"

    def items(self, query: str = "") -> list[ClipItem]:
        with self._lock:
            return list(self.history.visible(query))

    def total(self) -> int:
        with self._lock:
            return len(self.history.items)

    def find(self, item_id: str) -> ClipItem | None:
        with self._lock:
            return next((i for i in self.history.items if i.id == item_id.upper()), None)

    def copy(self, item: ClipItem) -> bool:
        if self.source is None:
            return False
        if item.kind == "image":
            path = self.store.path_of(item.image or "")
            if path is None or not path.exists():
                return False
            self.source.write_image(path.read_bytes())
        else:
            self.source.write_text(item.text or "")
        self._last = self.source.sequence()
        with self._lock:
            self.history.insert(ClipItem(item.id, item.kind, item.text, item.image, item.fingerprint, self.clock(), item.pinned))
            self._save()
        self.notify()
        return True

    def toggle_pin(self, item_id: str) -> None:
        with self._lock:
            self.history.toggle_pin(item_id.upper())
            self._save()
        self.notify()

    def remove(self, item_id: str) -> bool:
        with self._lock:
            removed = self.history.remove(item_id.upper())
            if removed is None:
                return False
            self.store.delete_files([removed])
            self._save()
        self.notify()
        return True

    def clear_unpinned(self) -> None:
        with self._lock:
            self.store.delete_files(self.history.clear_unpinned())
            self._save()
        self.notify()

    def run(self, stop: threading.Event) -> None:
        while not stop.wait(POLL_SECONDS):
            try:
                self.tick()
            except Exception:  # noqa: BLE001
                continue
