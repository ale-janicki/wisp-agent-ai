import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest
from local_fakes import FakeHub

from wisp.local import fetch
from wisp.local.catalog import ModelEntry

FILES = {"config.json": b'{"a": 1}', "tokenizer.json": b"tok" * 50, "model.safetensors": b"w" * 5000}


def entry(hub: FakeHub, revision="r" * 40) -> ModelEntry:
    return ModelEntry(tag="t:1b", name="T", params="1B", size_bytes=sum(map(len, FILES.values())), tier="pequeno", context_tokens=8192,
                      memory_overhead_bytes=1, speed="rapido", limitations="x", library_url="u", repo="o/t", revision=revision,
                      files=tuple(hub.manifest()))


def hub(**kw):
    return FakeHub("o/t", "r" * 40, FILES, **kw)


def test_a_verified_download_lands_in_the_models_folder_and_the_partial_folder_is_gone(tmp_path):
    events = []
    with hub() as h:
        done = fetch.download(tmp_path, entry(h), events.append, margin=0, base=h.url)
    assert done == fetch.model_dir(tmp_path, "t:1b") and {p.name for p in done.iterdir()} == set(FILES)
    assert fetch.is_complete(tmp_path, entry(h)) and not fetch.partial_dir(tmp_path, "t:1b").exists()
    assert events[0] == {"status": "downloading", "completed": 0, "total": sum(map(len, FILES.values()))}
    assert events[-1]["completed"] == events[-1]["total"] or events[-1]["status"] == "verifying"


@pytest.mark.parametrize("victim", ["model.safetensors", "config.json"])
def test_any_changed_byte_fails_the_hash_and_nothing_is_installed(tmp_path, victim):
    with hub(tamper={victim}) as h:
        with pytest.raises(fetch.FetchError, match="verificação"):
            fetch.download(tmp_path, entry(h), lambda e: None, margin=0, base=h.url)
    assert not fetch.model_dir(tmp_path, "t:1b").exists() and not (fetch.partial_dir(tmp_path, "t:1b") / victim).exists()


def test_a_file_longer_than_the_manifest_says_is_cut_off(tmp_path):
    with hub() as h:
        small = entry(h)
        small = ModelEntry(**{**small.__dict__, "files": tuple({**f, "size": 3} if f["path"] == "tokenizer.json" else f for f in small.files)})
        with pytest.raises(fetch.FetchError, match="passou do tamanho"):
            fetch.download(tmp_path, small, lambda e: None, margin=0, base=h.url)
    assert not fetch.model_dir(tmp_path, "t:1b").exists()


def test_not_enough_disk_stops_before_any_request(tmp_path):
    with hub() as h:
        with pytest.raises(fetch.FetchError, match="falta espaço"):
            fetch.download(tmp_path, entry(h), lambda e: None, margin=10, base=h.url, free=lambda p: 100)
        assert h.hits == []


def test_the_disk_falling_under_the_margin_mid_download_stops_it(tmp_path, monkeypatch):
    monkeypatch.setattr(fetch, "DISK_CHECK_INTERVAL", 0)
    reads = iter([10_000_000, 5, 5, 5, 5, 5, 5])
    with hub() as h:
        with pytest.raises(fetch.FetchError, match="abaixo da folga"):
            fetch.download(tmp_path, entry(h), lambda e: None, margin=1000, base=h.url, free=lambda p: next(reads))
    assert not fetch.model_dir(tmp_path, "t:1b").exists()


def test_files_already_verified_in_the_partial_folder_are_not_downloaded_again(tmp_path):
    with hub() as h:
        partial = fetch.partial_dir(tmp_path, "t:1b")
        partial.mkdir(parents=True)
        (partial / "model.safetensors").write_bytes(FILES["model.safetensors"])
        (partial / "config.json").write_bytes(b"bad")
        fetch.download(tmp_path, entry(h), lambda e: None, margin=0, base=h.url)
    assert "model.safetensors" not in h.hits and "config.json" in h.hits


def test_a_manifest_path_that_escapes_the_folder_is_refused(tmp_path):
    with hub() as h:
        evil = entry(h)
        evil = ModelEntry(**{**evil.__dict__, "files": ({"path": "../x", "size": 1, "git_sha1": "0" * 40},)})
        with pytest.raises(fetch.FetchError, match="inválido"):
            fetch.download(tmp_path, evil, lambda e: None, margin=0, base=h.url)


def test_sigterm_stops_a_download_and_keeps_the_verified_part(tmp_path):
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Slow(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "100000000")
            self.end_headers()
            try:
                for _ in range(1000):
                    self.wfile.write(b"x" * 1000)
                    self.wfile.flush()
                    time.sleep(0.02)
            except OSError:
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    code = (
        "import sys\nfrom pathlib import Path\nfrom wisp.local import fetch\nfrom wisp.local.catalog import ModelEntry\n"
        "e=ModelEntry(tag='t:1b',name='T',params='1B',size_bytes=100000000,tier='pequeno',context_tokens=8192,memory_overhead_bytes=1,"
        "speed='rapido',limitations='x',library_url='u',repo='o/t',revision='r'*40,files=({'path':'model.safetensors','size':100000000,'sha256':'0'*64},))\n"
        f"fetch.download(Path({str(tmp_path)!r}), e, lambda ev: print('p', flush=True), margin=0, base='http://127.0.0.1:{server.server_address[1]}')\n")
    proc = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True, start_new_session=True)
    try:
        assert proc.stdout.readline().strip() == "p"
        os.killpg(proc.pid, signal.SIGTERM)
        assert proc.wait(timeout=15) == 1
    finally:
        server.shutdown()
        subprocess.run(["pkill", "-f", "fetch.download"])
    assert not fetch.model_dir(tmp_path, "t:1b").exists()


def test_a_second_download_of_the_same_model_is_refused_while_one_runs(tmp_path):
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    gate = threading.Event()

    class Held(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "5000")
            self.end_headers()
            self.wfile.write(b"w" * 10)
            self.wfile.flush()
            gate.wait(10)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Held)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with hub() as h:
        item = entry(h)
        item = ModelEntry(**{**item.__dict__, "files": ({"path": "model.safetensors", "size": 5000, "sha256": "0" * 64},)})
        first = threading.Thread(target=lambda: _ignore(fetch.download, tmp_path, item, lambda e: None, margin=0, base=f"http://127.0.0.1:{server.server_address[1]}"))
        first.start()
        time.sleep(1)
        with pytest.raises(fetch.FetchError, match="já há um download"):
            fetch.download(tmp_path, item, lambda e: None, margin=0, base=h.url)
        gate.set()
        first.join(15)
    server.shutdown()
    other = ModelEntry(**{**item.__dict__, "tag": "t:2b"})
    assert fetch.lock_path(tmp_path, "t:2b") != fetch.lock_path(tmp_path, "t:1b") and other.tag == "t:2b"


def _ignore(fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except fetch.FetchError:
        pass


def test_the_lock_is_released_after_a_failure_so_the_next_try_can_run(tmp_path):
    with hub(tamper={"model.safetensors"}) as h:
        with pytest.raises(fetch.FetchError):
            fetch.download(tmp_path, entry(h), lambda e: None, margin=0, base=h.url)
    with hub() as h:
        assert fetch.download(tmp_path, entry(h), lambda e: None, margin=0, base=h.url).is_dir()


def test_a_new_download_replaces_the_old_model_atomically_and_keeps_no_backup(tmp_path):
    old = fetch.model_dir(tmp_path, "t:1b")
    old.mkdir(parents=True)
    (old / "marcador").write_text("velho")
    with hub() as h:
        fetch.download(tmp_path, entry(h), lambda e: None, margin=0, base=h.url)
    assert not (old / "marcador").exists() and (old / "config.json").is_file() and not fetch.backup_dir(tmp_path, "t:1b").exists()


def test_when_the_swap_fails_the_old_model_is_put_back(tmp_path, monkeypatch):
    old = fetch.model_dir(tmp_path, "t:1b")
    old.mkdir(parents=True)
    (old / "marcador").write_text("velho")
    real = os.replace
    calls = []

    def flaky(src, dst):
        calls.append((Path(src).name, Path(dst).name))
        if Path(dst).name == "t-1b" and Path(src).name.startswith(".baixando"):
            raise OSError("disco")
        return real(src, dst)

    monkeypatch.setattr(fetch.os, "replace", flaky)
    with hub() as h:
        with pytest.raises(OSError):
            fetch.download(tmp_path, entry(h), lambda e: None, margin=0, base=h.url)
    assert (old / "marcador").read_text() == "velho" and not fetch.backup_dir(tmp_path, "t:1b").exists()


def test_a_crash_between_the_two_renames_is_recovered_on_the_next_download(tmp_path):
    backup = fetch.backup_dir(tmp_path, "t:1b")
    backup.mkdir(parents=True)
    (backup / "marcador").write_text("velho")
    fetch.recover(fetch.model_dir(tmp_path, "t:1b"), backup)
    assert (fetch.model_dir(tmp_path, "t:1b") / "marcador").read_text() == "velho" and not backup.exists()


@pytest.mark.parametrize("error", [__import__("http.client").client.IncompleteRead(b"x"), __import__("http.client").client.RemoteDisconnected("x"),
                                   __import__("http.client").client.BadStatusLine("x"), ConnectionResetError()])
def test_connection_level_errors_become_fetch_errors_and_install_nothing(tmp_path, monkeypatch, error):
    def boom(*a, **k):
        raise error

    monkeypatch.setattr(fetch.urllib.request, "urlopen", boom)
    with hub() as h:
        with pytest.raises(fetch.FetchError, match="não consegui baixar"):
            fetch.download(tmp_path, entry(h), lambda e: None, margin=0, base=h.url)
    assert not fetch.model_dir(tmp_path, "t:1b").exists()
