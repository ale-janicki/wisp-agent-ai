import asyncio
import json
import os
import time

from wisp_bot import claude_runner, codex_runner, soul


def _fake_wisp(tmp_path, text, count=None):
    fake = tmp_path / "wisp"
    tick = f"echo x >> {count}\n" if count else ""
    fake.write_text(f"#!/bin/sh\n{tick}printf '%s' '{json.dumps({'source': 'both', 'text': text})}'\n")
    fake.chmod(0o755)
    return str(fake)


def test_append_joins_with_a_blank_line_and_skips_empties():
    assert soul.append("a", "b") == "a\n\nb"
    assert soul.append("", "b") == "b"
    assert soul.append("a", "") == "a"


def test_decode_reads_the_text_field_only():
    assert soul.decode(b'{"source":"wisp","text":"oi"}') == "oi"
    assert soul.decode(b'{"source":"assistant","text":""}') == ""
    assert soul.decode(b"nope") is None
    assert soul.decode(b'{"text":3}') is None


def test_text_runs_the_cli_once_per_change(tmp_path, monkeypatch):
    monkeypatch.setattr(soul, "_cache", {})
    count = tmp_path / "count"
    wisp = _fake_wisp(tmp_path, "alma", count)
    assert asyncio.run(soul.text("claude", wisp)) == "alma"
    assert asyncio.run(soul.text("claude", wisp)) == "alma"
    assert len(count.read_text().split()) == 1
    assert asyncio.run(soul.text("codex", wisp)) == "alma"
    assert len(count.read_text().split()) == 2


def test_a_missing_or_failing_cli_gives_no_soul(tmp_path, monkeypatch):
    monkeypatch.setattr(soul, "_cache", {})
    assert asyncio.run(soul.text("claude", str(tmp_path / "nope"))) == ""
    bad = tmp_path / "bad"
    bad.write_text("#!/bin/sh\nexit 3\n")
    bad.chmod(0o755)
    assert asyncio.run(soul.text("claude", str(bad))) == ""


def test_the_codex_command_carries_the_soul_in_developer_instructions(tmp_path):
    cmd = codex_runner.command(root=tmp_path, mode="default", extra_prompt=soul.append("EXTRA", "ALMA-DO-WISP"), session=None, wisp_bin="/opt/wisp")
    instructions = next(c for c in cmd if c.startswith("developer_instructions="))
    assert "EXTRA" in instructions and "ALMA-DO-WISP" in instructions


def test_the_claude_runner_and_codex_runner_import_the_soul():
    assert claude_runner.soul is soul and codex_runner.soul is soul


def _watch(tmp_path, monkeypatch):
    """Point the cache stamp at one file the test controls, and start from empty caches."""
    watched = tmp_path / "profile.json"
    watched.write_text("{}")
    monkeypatch.setattr(soul, "_files", lambda: [watched])
    monkeypatch.setattr(soul, "_cache", {})
    monkeypatch.setattr(soul, "_failures", {})
    return watched


def _touch(path, seconds):
    stat = path.stat()
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + int(seconds * 1e9)))


def test_a_changed_file_renders_again(tmp_path, monkeypatch):
    watched = _watch(tmp_path, monkeypatch)
    count = tmp_path / "count"
    wisp = _fake_wisp(tmp_path, "alma", count)
    asyncio.run(soul.text("claude", wisp))
    asyncio.run(soul.text("claude", wisp))
    assert len(count.read_text().split()) == 1
    _touch(watched, 5)
    asyncio.run(soul.text("claude", wisp))
    assert len(count.read_text().split()) == 2


def test_the_managed_state_of_claude_is_part_of_the_stamp(tmp_path, monkeypatch):
    _watch(tmp_path, monkeypatch)
    monkeypatch.setattr(soul, "_managed_elsewhere", lambda: False)
    before = soul._stamp()
    monkeypatch.setattr(soul, "_managed_elsewhere", lambda: True)
    assert soul._stamp() != before


def test_the_default_timeout_is_five_seconds():
    assert soul.TIMEOUT_S == 5 and soul.FAILURE_TTL_S == 60


def test_a_hanging_cli_times_out_and_the_failure_is_cached(tmp_path, monkeypatch):
    _watch(tmp_path, monkeypatch)
    monkeypatch.setattr(soul, "TIMEOUT_S", 0.3)
    count = tmp_path / "count"
    hang = tmp_path / "wisp"
    hang.write_text(f"#!/bin/sh\necho x >> {count}\nsleep 30\n")
    hang.chmod(0o755)
    started = time.monotonic()
    assert asyncio.run(soul.text("claude", str(hang))) == ""
    assert time.monotonic() - started < 5
    assert len(count.read_text().split()) == 1
    assert asyncio.run(soul.text("claude", str(hang))) == ""
    assert len(count.read_text().split()) == 1          # inside the minute: not run again


def test_the_negative_cache_expires_after_a_minute_and_after_a_file_change(tmp_path, monkeypatch):
    watched = _watch(tmp_path, monkeypatch)
    count = tmp_path / "count"
    bad = tmp_path / "wisp"
    bad.write_text(f"#!/bin/sh\necho x >> {count}\nexit 3\n")
    bad.chmod(0o755)
    clock = [1000.0]
    monkeypatch.setattr(soul, "_now", lambda: clock[0])
    runs = lambda: len(count.read_text().split())
    asyncio.run(soul.text("claude", str(bad)))
    asyncio.run(soul.text("claude", str(bad)))
    assert runs() == 1
    clock[0] += 61
    asyncio.run(soul.text("claude", str(bad)))
    assert runs() == 2
    _touch(watched, 5)
    asyncio.run(soul.text("claude", str(bad)))
    assert runs() == 3
