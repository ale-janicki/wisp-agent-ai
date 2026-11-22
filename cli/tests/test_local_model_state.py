import fcntl
import json
import os

import pytest

from wisp.local import fetch

TAG = "qwen3:8b"


def put(root, name, data=b"x"):
    (root / name).parent.mkdir(parents=True, exist_ok=True)
    (root / name).write_bytes(data)


def complete(folder, sharded=True):
    root = fetch.model_dir(folder, TAG)
    put(root, "config.json", b"{}")
    if sharded:
        put(root, "model.safetensors.index.json", json.dumps({"weight_map": {"a": "s1.safetensors", "b": "s2.safetensors"}}).encode())
        put(root, "s1.safetensors")
        put(root, "s2.safetensors")
    else:
        put(root, "model.safetensors")
    return root


def stale_lock(folder):
    path = fetch.lock_path(folder, TAG)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()
    return path


@pytest.mark.parametrize("sharded", [True, False])
def test_a_complete_folder_with_a_stale_lock_is_downloaded_and_the_lock_is_removed(tmp_path, sharded):
    complete(tmp_path / "Wisp", sharded)
    lock = stale_lock(tmp_path / "Wisp")
    assert fetch.state_of(tmp_path / "Wisp", TAG) == "downloaded"
    assert not lock.exists()


def test_a_partial_folder_with_a_stale_lock_can_be_resumed(tmp_path):
    root = complete(tmp_path / "Wisp")
    (root / "s2.safetensors").write_bytes(b"")
    lock = stale_lock(tmp_path / "Wisp")
    assert fetch.state_of(tmp_path / "Wisp", TAG) == "partial"
    assert not lock.exists()


def test_a_missing_shard_or_an_unreadable_index_is_not_downloaded(tmp_path):
    root = complete(tmp_path / "Wisp")
    (root / "s1.safetensors").unlink()
    assert fetch.state_of(tmp_path / "Wisp", TAG) == "partial"
    (root / "model.safetensors.index.json").write_text("{")
    assert not fetch.has_content(root)


def test_a_partial_download_folder_alone_is_resumable_and_nothing_is_absent(tmp_path):
    folder = tmp_path / "Wisp"
    assert fetch.state_of(folder, TAG) == "absent"
    put(fetch.partial_dir(folder, TAG), "config.json")
    assert fetch.state_of(folder, TAG) == "partial"


def test_a_complete_folder_with_a_live_lock_is_downloading_and_the_lock_stays(tmp_path):
    folder = tmp_path / "Wisp"
    complete(folder)
    lock = stale_lock(folder)
    holder = os.open(lock, os.O_RDWR)
    try:
        fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert fetch.state_of(folder, TAG) == "downloading"
        assert lock.exists()
        with pytest.raises(fetch.FetchError, match="em andamento"):
            fetch.remove(folder, TAG)
    finally:
        os.close(holder)
    assert fetch.state_of(folder, TAG) == "downloaded"


def test_remove_deletes_the_model_the_partial_folder_and_the_lock(tmp_path):
    folder = tmp_path / "Wisp"
    complete(folder)
    put(fetch.partial_dir(folder, TAG), "config.json")
    stale_lock(folder)
    fetch.remove(folder, TAG)
    assert fetch.state_of(folder, TAG) == "absent" and not fetch.lock_path(folder, TAG).exists()
