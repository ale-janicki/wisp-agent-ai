import json
import sys

import pytest

from wisp.meetings_win import winsys
from wisp.meetings_win.winsys import CredentialStore


def protect(data: bytes) -> bytes:
    return bytes(b ^ 0x5A for b in data)


def test_a_secret_roundtrips_and_the_file_never_holds_the_clear_text(tmp_path):
    store = CredentialStore(tmp_path / "s.json", protect, protect)
    store.set("secret", "chave-super-secreta")
    assert store.get("secret") == "chave-super-secreta"
    assert "chave-super-secreta" not in (tmp_path / "s.json").read_text("utf-8")
    assert store.get("url") is None
    store.set("url", "https://example.org/hook")
    store.delete("secret")
    assert store.get("secret") is None and store.get("url") == "https://example.org/hook"
    assert set(json.loads((tmp_path / "s.json").read_text("utf-8"))) == {"url"}


def test_a_corrupt_file_or_entry_reads_as_missing(tmp_path):
    path = tmp_path / "s.json"
    path.write_text("{nope", encoding="utf-8")
    store = CredentialStore(path, protect, protect)
    assert store.get("url") is None
    store.set("url", "x")
    path.write_text(json.dumps({"url": "!!not base64!!"}), encoding="utf-8")
    assert store.get("url") is None


@pytest.mark.skipif(sys.platform == "win32", reason="the real calls only run on Windows")
def test_away_from_windows_the_system_calls_say_so(tmp_path):
    with pytest.raises(winsys.NotWindows):
        winsys.trash(tmp_path)
    with pytest.raises(winsys.NotWindows):
        winsys.dpapi_protect(b"x")
    with pytest.raises(winsys.NotWindows):
        winsys.reveal(tmp_path)
