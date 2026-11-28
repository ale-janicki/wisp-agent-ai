from __future__ import annotations

import hashlib
import json
import os
import shutil
import threading
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

MARKER = ".wisp-verified"
EXTRA_FREE_BYTES = 2 * 1024 ** 3
CHUNK = 1024 * 1024
TIMEOUT_SECONDS = 60
FOLDER = "faster-whisper"


class ModelError(Exception):
    pass


ALLOWED_HOSTS = ("huggingface.co", "hf.co")


def allowed_host(host: str | None) -> bool:
    host = (host or "").lower()
    return any(host == base or host.endswith("." + base) for base in ALLOWED_HOSTS)


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parts = urlsplit(newurl)
        if parts.scheme != "https" or parts.username is not None or not allowed_host(parts.hostname):
            raise ModelError(f"o servidor redirecionou o download para um endereço não permitido ({parts.scheme}://{parts.hostname})")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def safe_opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(SafeRedirect)


class DownloadCancelled(Exception):
    pass


@dataclass(frozen=True)
class ModelFile:
    name: str
    size: int
    sha256: str | None
    git_sha1: str | None


@dataclass(frozen=True)
class ModelSpec:
    id: str
    repo: str
    revision: str
    files: tuple[ModelFile, ...]
    license: str
    label: str

    @property
    def total_bytes(self) -> int:
        return sum(f.size for f in self.files)

    def url(self, name: str) -> str:
        return f"https://huggingface.co/{self.repo}/resolve/{self.revision}/{name}"


def git_blob_sha1(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def _file_digests(path: Path, wants_sha1: bool) -> tuple[str, str | None]:
    sha256 = hashlib.sha256()
    sha1 = hashlib.sha1(b"blob %d\0" % path.stat().st_size) if wants_sha1 else None
    with open(path, "rb") as handle:
        while chunk := handle.read(CHUNK):
            sha256.update(chunk)
            if sha1:
                sha1.update(chunk)
    return sha256.hexdigest(), sha1.hexdigest() if sha1 else None


def file_matches(path: Path, expected: ModelFile) -> bool:
    try:
        if path.stat().st_size != expected.size:
            return False
        sha256, sha1 = _file_digests(path, expected.git_sha1 is not None)
    except OSError:
        return False
    return (expected.sha256 is None or sha256 == expected.sha256) and (expected.git_sha1 is None or sha1 == expected.git_sha1)


def _small(name: str, size: int, git: str) -> ModelFile:
    return ModelFile(name, size, None, git)


MODELS: dict[str, ModelSpec] = {
    "small": ModelSpec(
        "small", "Systran/faster-whisper-small", "536b0662742c02347bc0e980a01041f333bce120",
        (_small("config.json", 2370, "e5047537059bd8f182d9ca64c470201585015187"),
         ModelFile("model.bin", 483546902, "3e305921506d8872816023e4c273e75d2419fb89b24da97b4fe7bce14170d671",
                   "504a7fe023f19460564a623887a9f77ea53ac708"),
         _small("tokenizer.json", 2203239, "7818adb6de9fa3064d3ff81226fdd675be1f6344"),
         _small("vocabulary.txt", 459861, "c9074644d9d1205686f16d411564729461324b75")),
        "MIT", "Whisper small (ao vivo)"),
    "large-v3": ModelSpec(
        "large-v3", "Systran/faster-whisper-large-v3", "edaa852ec7e145841d8ffdb056a99866b5f0a478",
        (_small("config.json", 2394, "75336feae814999bae6ccccdecf177639ffc6f9d"),
         ModelFile("model.bin", 3087284237, "69f74147e3334731bc3a76048724833325d2ec74642fb52620eda87352e3d4f1",
                   "e91bbba72de41ca3cdc9a656b17aa9407c7e85b6"),
         _small("preprocessor_config.json", 340, "931c77a740890c46365c7ae0c9d350ba3cca908f"),
         _small("tokenizer.json", 2480617, "3a5e2ba63acdcac9a19ba56cf9bd27f185bfff61"),
         _small("vocabulary.json", 1068114, "0adcd01e7c237205d593b707e66dd5d7bc785d2d")),
        "MIT", "Whisper large-v3"),
    "large-v3-turbo": ModelSpec(
        "large-v3-turbo", "dropbox-dash/faster-whisper-large-v3-turbo", "0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf",
        (_small("config.json", 2263, "0351d1d6870005e865747b781b5d7c23ea0459cd"),
         ModelFile("model.bin", 1617884929, "e76620f83d5f5b69efd3d87e3dc180c1bd21df9fbebacfd4335e5e1efcc018da",
                   "c849f26401bf079fdea48ac9f7461fdff2e743ea"),
         _small("preprocessor_config.json", 340, "931c77a740890c46365c7ae0c9d350ba3cca908f"),
         _small("tokenizer.json", 2710337, "17456db595adc78a973f97d69d8cb50bc87c0b1c"),
         _small("vocabulary.json", 1068114, "0adcd01e7c237205d593b707e66dd5d7bc785d2d")),
        "MIT", "Whisper large-v3 turbo"),
}


class ModelStore:
    def __init__(self, root: Path, specs: dict[str, ModelSpec] | None = None):
        self.root = Path(root)
        self._specs = MODELS if specs is None else specs

    @classmethod
    def for_wisp(cls, wisp_dir: Path) -> "ModelStore":
        return cls(Path(wisp_dir) / "modelos" / FOLDER)

    def spec(self, model_id: str) -> ModelSpec:
        try:
            return self._specs[model_id]
        except KeyError:
            raise ModelError(f"modelo desconhecido: {model_id}") from None

    def folder(self, model_id: str) -> Path:
        return self.root / model_id

    def is_installed(self, model_id: str) -> bool:
        spec = self.spec(model_id)
        folder = self.folder(model_id)
        try:
            marker = json.loads((folder / MARKER).read_text("utf-8"))
        except (OSError, ValueError):
            return False
        if not isinstance(marker, dict) or marker.get("revision") != spec.revision:
            return False
        try:
            return all((folder / f.name).stat().st_size == f.size for f in spec.files)
        except OSError:
            return False

    def verify(self, model_id: str) -> bool:
        spec = self.spec(model_id)
        return all(file_matches(self.folder(model_id) / f.name, f) for f in spec.files)

    def download(self, model_id: str, progress: Callable[[int, int], None] | None = None,
                 cancel: threading.Event | None = None, opener=None,
                 free_bytes: Callable[[Path], int] | None = None) -> None:
        spec = self.spec(model_id)
        if self.is_installed(model_id):
            return
        opener = opener or safe_opener().open
        partial = self.root / f"{model_id}.partial"
        partial.mkdir(parents=True, exist_ok=True)
        held = sum(f.size if (partial / f.name).exists() else self._part_size(partial, f) for f in spec.files)
        free = (free_bytes or (lambda p: shutil.disk_usage(p).free))(partial)
        if free < spec.total_bytes - held + EXTRA_FREE_BYTES:
            raise ModelError("Sem espaço em disco para baixar o modelo: libere pelo menos "
                             f"{(spec.total_bytes - held + EXTRA_FREE_BYTES) // 1024 ** 2} MB.")
        done = 0
        total = spec.total_bytes
        for file in spec.files:
            final = partial / file.name
            if final.exists() and file_matches(final, file):
                done += file.size
                if progress:
                    progress(done, total)
                continue
            final.unlink(missing_ok=True)
            done = self._fetch(spec, file, partial, done, total, progress, cancel, opener)
        marker = {"revision": spec.revision, "files": {f.name: f.sha256 or f.git_sha1 for f in spec.files}}
        (partial / MARKER).write_text(json.dumps(marker, sort_keys=True), encoding="utf-8")
        self._install(partial, self.folder(model_id))

    @staticmethod
    def _part_size(partial: Path, file: ModelFile) -> int:
        try:
            return (partial / (file.name + ".part")).stat().st_size
        except OSError:
            return 0

    def _fetch(self, spec: ModelSpec, file: ModelFile, partial: Path, done: int, total: int, progress, cancel, opener) -> int:
        part = partial / (file.name + ".part")
        have = part.stat().st_size if part.exists() else 0
        if have > file.size:
            part.unlink()
            have = 0
        request = urllib.request.Request(spec.url(file.name), headers={"User-Agent": "wisp"})
        if have:
            request.add_header("Range", f"bytes={have}-")
        try:
            with opener(request, timeout=TIMEOUT_SECONDS) as response:
                if have and getattr(response, "status", 200) != 206:
                    have = 0
                with open(part, "ab" if have else "wb") as out:
                    base = done + have
                    written = 0
                    while True:
                        if cancel is not None and cancel.is_set():
                            raise DownloadCancelled()
                        chunk = response.read(min(CHUNK, file.size - (have + written) + 1))
                        if not chunk:
                            break
                        out.write(chunk)
                        written += len(chunk)
                        if have + written > file.size:
                            raise ModelError(f"{file.name} veio maior que o esperado; parei o download e apaguei")
                        if progress:
                            progress(base + written, total)
        except DownloadCancelled:
            raise
        except ModelError:
            part.unlink(missing_ok=True)
            raise
        except OSError as problem:
            raise ModelError(f"não consegui baixar {file.name}: {problem}") from problem
        final = partial / file.name
        os.replace(part, final)
        if not file_matches(final, file):
            final.unlink(missing_ok=True)
            raise ModelError(f"{file.name} não confere com o esperado; apaguei e tente de novo")
        return done + file.size

    @staticmethod
    def _install(partial: Path, target: Path) -> None:
        backup = target.with_name(target.name + ".backup")
        if backup.exists():
            shutil.rmtree(backup)
        if target.exists():
            os.replace(target, backup)
        try:
            os.replace(partial, target)
        except OSError:
            if backup.exists():
                os.replace(backup, target)
            raise
        if backup.exists():
            shutil.rmtree(backup, ignore_errors=True)
