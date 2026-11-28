import logging
import os
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest

from wisp.meetings_win import recordings
from wisp.meetings_win import transcript as transcript_module

START = datetime(2026, 5, 1, 13, 30, 5, tzinfo=timezone.utc)


class WindowsSwap:
    def __init__(self, monkeypatch):
        self.open = threading.Event()
        real_replace, real_stat, real_read = os.replace, os.stat, Path.read_text
        window = self

        def replace(src, dst, *args, **kwargs):
            if Path(dst).name != recordings.META_FILE:
                return real_replace(src, dst, *args, **kwargs)
            window.open.set()
            try:
                time.sleep(0.01)
                return real_replace(src, dst, *args, **kwargs)
            finally:
                window.open.clear()

        def stat(path, *args, **kwargs):
            if window.open.is_set() and Path(path).name == recordings.META_FILE:
                raise PermissionError(13, "sharing violation")
            return real_stat(path, *args, **kwargs)

        def read_text(self, *args, **kwargs):
            if window.open.is_set() and self.name == recordings.META_FILE:
                raise PermissionError(13, "sharing violation")
            return real_read(self, *args, **kwargs)

        monkeypatch.setattr(os, "replace", replace)
        monkeypatch.setattr(transcript_module.os, "replace", replace)
        monkeypatch.setattr(os, "stat", stat)
        monkeypatch.setattr(Path, "read_text", read_text)


@pytest.fixture
def folder(tmp_path):
    root = tmp_path / "reunioes"
    made = recordings.create_folder(root, START)
    recordings.write_meta(made, recordings.new_meta(START))
    return made


def hammer_writer(folder, stop):
    count = 0
    while not stop.is_set():
        count += 1
        recordings.update_meta(folder, lambda m, n=count: m.update(progress=n))


def test_a_reader_never_loses_the_meeting_while_meta_is_being_swapped(folder, monkeypatch):
    WindowsSwap(monkeypatch)
    stop = threading.Event()
    writer = threading.Thread(target=hammer_writer, args=(folder, stop))
    writer.start()
    misses = []
    try:
        deadline = time.time() + 1.5
        while time.time() < deadline:
            if not recordings.has_meta(folder):
                misses.append("has_meta")
            if [e.id for e in recordings.list_meetings(folder.parent)] != [folder.name]:
                misses.append("list_meetings")
    finally:
        stop.set()
        writer.join()
    assert misses == []


def test_reading_meta_retries_a_sharing_violation_from_a_writer_outside_this_process(folder, monkeypatch):
    real_read = Path.read_text
    failures = []

    def flaky(self, *args, **kwargs):
        if self.name == recordings.META_FILE and len(failures) < 3:
            failures.append(1)
            raise PermissionError(13, "sharing violation")
        return real_read(self, *args, **kwargs)

    monkeypatch.setattr(Path, "read_text", flaky)
    assert recordings.read_meta(folder)["status"] == recordings.RECORDING
    assert len(failures) == 3


def test_a_missing_meta_is_missing_and_a_permission_error_is_not(folder, monkeypatch):
    assert recordings.has_meta(folder) is True
    assert recordings.has_meta(folder.parent / "nope") is False
    real_stat = os.stat

    def locked(path, *args, **kwargs):
        if Path(path).name == recordings.META_FILE:
            raise PermissionError(13, "sharing violation")
        return real_stat(path, *args, **kwargs)

    monkeypatch.setattr(os, "stat", locked)
    assert recordings.has_meta(folder) is True
