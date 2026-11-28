import hashlib
import json
import threading

import pytest

from wisp.meetings_win import models
from wisp.meetings_win.models import (DownloadCancelled, ModelError, ModelFile, ModelSpec, ModelStore, MODELS,
                                      git_blob_sha1)


def blob(name: str, size: int) -> bytes:
    return (name.encode() * (size // len(name) + 1))[:size]


def make_spec(big=100_000, lfs=True) -> tuple[ModelSpec, dict[str, bytes]]:
    data = {"config.json": blob("c", 300), "model.bin": blob("m", big), "vocabulary.json": blob("v", 700)}
    files = []
    for name, content in data.items():
        if name == "model.bin" and lfs:
            files.append(ModelFile(name, len(content), sha256=hashlib.sha256(content).hexdigest(), git_sha1=None))
        else:
            files.append(ModelFile(name, len(content), sha256=None, git_sha1=git_blob_sha1(content)))
    return ModelSpec("tiny", "owner/tiny", "a" * 40, tuple(files), "MIT", "tiny"), data


class Response:
    def __init__(self, body: bytes, status: int, headers=None):
        self._body, self.status, self.headers = body, status, headers or {}
        self._at = 0

    def read(self, count=-1):
        count = len(self._body) - self._at if count < 0 else count
        out = self._body[self._at:self._at + count]
        self._at += len(out)
        return out

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class Server:
    def __init__(self, data, corrupt=None):
        self.data, self.corrupt, self.requests, self.on_chunk = data, corrupt, [], None

    def __call__(self, request, timeout=None):
        name = request.full_url.rsplit("/", 1)[1]
        self.requests.append((request.full_url, request.get_header("Range")))
        body = self.data[name]
        if name == self.corrupt:
            body = b"x" + body[1:]
        wanted = request.get_header("Range")
        if wanted:
            start = int(wanted.split("=")[1].rstrip("-"))
            return Response(body[start:], 206)
        return Response(body, 200)


def test_pinned_manifests_are_complete_and_safe():
    assert set(MODELS) == {"small", "large-v3", "large-v3-turbo"}
    for spec in MODELS.values():
        assert len(spec.revision) == 40 and all(c in "0123456789abcdef" for c in spec.revision)
        names = [f.name for f in spec.files]
        assert "model.bin" in names and "config.json" in names and len(set(names)) == len(names)
        for f in spec.files:
            assert "/" not in f.name and "\\" not in f.name and not f.name.startswith(".")
            assert (f.sha256 is None) != (f.git_sha1 is None) or (f.sha256 and f.git_sha1)
        big = next(f for f in spec.files if f.name == "model.bin")
        assert big.sha256 and len(big.sha256) == 64
    assert MODELS["large-v3"].total_bytes == sum(f.size for f in MODELS["large-v3"].files) > 3_000_000_000
    assert MODELS["small"].url("model.bin").startswith("https://huggingface.co/Systran/faster-whisper-small/resolve/")


def test_download_installs_verifies_and_reports_progress(tmp_path):
    spec, data = make_spec()
    store = ModelStore(tmp_path, {"tiny": spec})
    seen = []
    assert not store.is_installed("tiny")
    store.download("tiny", progress=lambda done, total: seen.append((done, total)), opener=Server(data),
                   free_bytes=lambda _: 10**12)
    assert store.is_installed("tiny") and store.verify("tiny")
    assert seen[-1] == (spec.total_bytes, spec.total_bytes)
    assert [d for d, _ in seen] == sorted(d for d, _ in seen)
    marker = json.loads((store.folder("tiny") / ".wisp-verified").read_text())
    assert marker["revision"] == "a" * 40 and marker["files"]["model.bin"]
    assert not (tmp_path / "tiny.partial").exists()
    assert (store.folder("tiny") / "model.bin").read_bytes() == data["model.bin"]


def test_a_hash_mismatch_is_refused_and_nothing_is_kept_or_installed(tmp_path):
    spec, data = make_spec()
    store = ModelStore(tmp_path, {"tiny": spec})
    with pytest.raises(ModelError, match="não confere"):
        store.download("tiny", opener=Server(data, corrupt="model.bin"), free_bytes=lambda _: 10**12)
    assert not store.is_installed("tiny")
    assert not (tmp_path / "tiny.partial" / "model.bin").exists()


def test_a_retry_resumes_the_part_file_and_keeps_verified_files(tmp_path):
    spec, data = make_spec()
    store = ModelStore(tmp_path, {"tiny": spec})
    partial = tmp_path / "tiny.partial"
    partial.mkdir()
    (partial / "config.json").write_bytes(data["config.json"])
    (partial / "model.bin.part").write_bytes(data["model.bin"][:40_000])
    server = Server(data)
    store.download("tiny", opener=server, free_bytes=lambda _: 10**12)
    asked = {url.rsplit("/", 1)[1]: rng for url, rng in server.requests}
    assert "config.json" not in asked
    assert asked["model.bin"] == "bytes=40000-"
    assert store.verify("tiny")


def test_cancel_stops_between_chunks_and_leaves_the_partial_folder(tmp_path):
    spec, data = make_spec(big=3_000_000)
    store = ModelStore(tmp_path, {"tiny": spec})
    cancel = threading.Event()

    def progress(done, total):
        if done > 1_500_000:
            cancel.set()

    with pytest.raises(DownloadCancelled):
        store.download("tiny", progress=progress, cancel=cancel, opener=Server(data), free_bytes=lambda _: 10**12)
    assert (tmp_path / "tiny.partial").exists() and not store.is_installed("tiny")
    store.download("tiny", opener=Server(data), free_bytes=lambda _: 10**12)
    assert store.is_installed("tiny")


def test_not_enough_disk_is_refused_before_any_request(tmp_path):
    spec, data = make_spec()
    server = Server(data)
    store = ModelStore(tmp_path, {"tiny": spec})
    with pytest.raises(ModelError, match="espaço"):
        store.download("tiny", opener=server, free_bytes=lambda _: spec.total_bytes + 1_000)
    assert server.requests == []


def test_a_truncated_file_makes_the_model_not_installed_and_verify_catches_a_flipped_byte(tmp_path):
    spec, data = make_spec()
    store = ModelStore(tmp_path, {"tiny": spec})
    store.download("tiny", opener=Server(data), free_bytes=lambda _: 10**12)
    big = store.folder("tiny") / "model.bin"
    flipped = bytearray(big.read_bytes())
    flipped[5] ^= 0xFF
    big.write_bytes(bytes(flipped))
    assert store.is_installed("tiny") and not store.verify("tiny")
    big.write_bytes(b"short")
    assert not store.is_installed("tiny")


def test_unknown_model_is_an_error(tmp_path):
    with pytest.raises(ModelError):
        ModelStore(tmp_path).download("nope")


class Oversized(Server):
    def __init__(self, data, extra):
        super().__init__(data)
        self.extra, self.reads = extra, 0

    def __call__(self, request, timeout=None):
        name = request.full_url.rsplit("/", 1)[1]
        body = self.data[name] + (b"z" * self.extra if name == "model.bin" else b"")
        outer = self

        class Counting(Response):
            def read(self, count=-1):
                chunk = super().read(count)
                outer.reads += len(chunk)
                return chunk

        return Counting(body, 200)


def test_a_server_that_sends_more_than_the_pinned_size_is_cut_off_while_streaming(tmp_path):
    spec, data = make_spec(big=100_000)
    server = Oversized(data, extra=50_000_000)
    store = ModelStore(tmp_path, {"tiny": spec})
    with pytest.raises(ModelError, match="maior"):
        store.download("tiny", opener=server, free_bytes=lambda _: 10**12)
    big = len(data["model.bin"])
    assert server.reads <= big + 1 + len(data["config.json"]) + len(data["vocabulary.json"])
    assert not (tmp_path / "tiny.partial" / "model.bin.part").exists()
    assert not store.is_installed("tiny")


def redirect(url, target):
    import urllib.request

    request = urllib.request.Request(url)
    return models.SafeRedirect().redirect_request(request, None, 302, "Found", {}, target)


@pytest.mark.parametrize("target", [
    "https://huggingface.co/x", "https://hf.co/x", "https://us.aws.cdn.hf.co/repos/a/b", "https://cdn-lfs-us-1.hf.co/a",
    "https://cas-bridge.xethub.hf.co/a", "https://cdn-lfs.huggingface.co/a"])
def test_redirects_may_only_go_to_https_hugging_face_hosts(target):
    assert redirect("https://huggingface.co/a", target).full_url == target


@pytest.mark.parametrize("target", [
    "http://huggingface.co/x", "http://cdn.hf.co/x", "https://evil.example.org/x", "https://hf.co.evil.org/x",
    "https://nothf.co/x", "https://huggingface.co.evil.org/x", "ftp://huggingface.co/x", "https://user@huggingface.co@evil.org/x",
    "https://127.0.0.1/x"])
def test_everything_else_is_refused_including_a_downgrade_to_http(target):
    with pytest.raises(ModelError, match="redirecionou"):
        redirect("https://huggingface.co/a", target)


def test_the_default_opener_is_the_restricted_one(tmp_path):
    import urllib.request

    handlers = [type(h) for h in models.safe_opener().handlers]
    assert models.SafeRedirect in handlers and urllib.request.HTTPRedirectHandler not in handlers
