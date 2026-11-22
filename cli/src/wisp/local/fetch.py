import fcntl
import hashlib
import http.client
import json
import os
import shutil
import signal
import threading
import time
import urllib.request
from collections.abc import Callable
from pathlib import Path

from wisp.layout import resolve_layout
from wisp.local import certs, storage

HF_URL = "https://huggingface.co"
CHUNK = 1 << 20
DISK_CHECK_INTERVAL = 1.0


class FetchError(Exception):
    pass


class _Cancelled(SystemExit):
    pass


def _terminate(signum, frame):
    raise _Cancelled(1)


def models_root(folder: Path) -> Path:
    return resolve_layout({"wisp_dir": str(folder)}, Path.home()).modelos_dir


def dirname(tag: str) -> str:
    return tag.replace(":", "-")


def model_dir(folder: Path, tag: str) -> Path:
    return models_root(folder) / dirname(tag)


def partial_dir(folder: Path, tag: str) -> Path:
    return models_root(folder) / f".baixando-{dirname(tag)}"


def lock_path(folder: Path, tag: str) -> Path:
    return models_root(folder) / f".baixando-{dirname(tag)}.lock"


def backup_dir(folder: Path, tag: str) -> Path:
    return models_root(folder) / f".anterior-{dirname(tag)}"


def install_atomically(partial: Path, final: Path, backup: Path) -> None:
    shutil.rmtree(backup, ignore_errors=True)
    had = final.exists()
    if had:
        os.replace(final, backup)
    try:
        os.replace(partial, final)
    except OSError:
        if had:
            os.replace(backup, final)
        raise
    shutil.rmtree(backup, ignore_errors=True)


def recover(final: Path, backup: Path) -> None:
    if backup.exists() and not final.exists():
        os.replace(backup, final)


def is_complete(folder: Path, entry) -> bool:
    root = model_dir(folder, entry.tag)
    return bool(entry.files) and all(
        (root / f["path"]).is_file() and (root / f["path"]).stat().st_size == f["size"] for f in entry.files)


def _filled(path: Path) -> bool:
    try:
        return path.is_file() and path.stat().st_size > 0
    except OSError:
        return False


def has_content(root: Path) -> bool:
    if not _filled(root / "config.json"):
        return False
    index = root / "model.safetensors.index.json"
    if not index.is_file():
        return _filled(root / "model.safetensors")
    try:
        shards = set(json.loads(index.read_text("utf-8"))["weight_map"].values())
    except (OSError, ValueError, KeyError, AttributeError, TypeError):
        return False
    return bool(shards) and all(isinstance(s, str) and "/" not in s and _filled(root / s) for s in shards)


def lock_is_live(folder: Path, tag: str) -> bool:
    path = lock_path(folder, tag)
    try:
        guard = os.open(path, os.O_RDWR)
    except OSError:
        return False
    try:
        try:
            fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        path.unlink(missing_ok=True)
        return False
    finally:
        os.close(guard)


def state_of(folder: Path, tag: str) -> str:
    if lock_is_live(folder, tag):
        return "downloading"
    root = model_dir(folder, tag)
    if has_content(root):
        return "downloaded"
    if root.exists() or partial_dir(folder, tag).exists():
        return "partial"
    return "absent"


def remove(folder: Path, tag: str) -> None:
    if lock_is_live(folder, tag):
        raise FetchError(f"o download de {tag} está em andamento; cancele antes de apagar")
    for target in (model_dir(folder, tag), partial_dir(folder, tag), backup_dir(folder, tag)):
        shutil.rmtree(target, ignore_errors=True)
    lock_path(folder, tag).unlink(missing_ok=True)


def _git_blob_sha1(path: Path) -> str:
    digest = hashlib.sha1(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def verify_file(path: Path, expected: dict) -> bool:
    if not path.is_file() or path.stat().st_size != expected["size"]:
        return False
    if "sha256" in expected:
        return _sha256(path) == expected["sha256"]
    return _git_blob_sha1(path) == expected["git_sha1"]


def _safe(relative: str) -> str:
    if not relative or relative.startswith("/") or ".." in Path(relative).parts:
        raise FetchError(f"o catálogo tem um caminho de arquivo inválido: {relative}")
    return relative


def download(folder: Path, entry, emit: Callable[[dict], None], *, margin: int, base: str | None = None,
             free: Callable[[Path], int] | None = None) -> Path:
    free = free or storage.free_bytes
    base = (base or os.environ.get("WISP_HF_URL") or HF_URL).rstrip("/")
    models_root(folder).mkdir(parents=True, exist_ok=True)
    guard = os.open(lock_path(folder, entry.tag), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(guard)
        raise FetchError(f"já há um download de {entry.tag} em andamento") from None
    try:
        return _download(folder, entry, emit, margin=margin, base=base, free=free)
    finally:
        os.close(guard)


def _download(folder: Path, entry, emit: Callable[[dict], None], *, margin: int, base: str, free: Callable[[Path], int]) -> Path:
    recover(model_dir(folder, entry.tag), backup_dir(folder, entry.tag))
    total = sum(f["size"] for f in entry.files)
    problem = storage.room_problem(total, free(folder), margin)
    if problem:
        raise FetchError(problem)
    partial = partial_dir(folder, entry.tag)
    partial.mkdir(parents=True, exist_ok=True)
    main = threading.current_thread() is threading.main_thread()
    previous = signal.signal(signal.SIGTERM, _terminate) if main else None
    done, last, checked = 0, -1, time.monotonic()
    try:
        emit({"status": "downloading", "completed": 0, "total": total})
        for item in entry.files:
            target = partial / _safe(item["path"])
            target.parent.mkdir(parents=True, exist_ok=True)
            if verify_file(target, item):
                done += item["size"]
                continue
            target.unlink(missing_ok=True)
            url = f"{base}/{entry.repo}/resolve/{entry.revision}/{item['path']}"
            written = 0
            try:
                with urllib.request.urlopen(url, timeout=60, context=certs.context()) as response, target.open("wb") as out:
                    while chunk := response.read(CHUNK):
                        written += len(chunk)
                        if written > item["size"]:
                            raise FetchError(f"o arquivo {item['path']} passou do tamanho esperado; parei")
                        out.write(chunk)
                        step = (done + written) * 100 // total
                        if step != last:
                            last = step
                            emit({"status": "downloading", "completed": done + written, "total": total})
                        if time.monotonic() - checked >= DISK_CHECK_INTERVAL:
                            checked = time.monotonic()
                            left = free(folder)
                            if left < margin:
                                raise FetchError(
                                    f"o disco ficou com {storage.gb(left)} GB livres, abaixo da folga de {storage.gb(margin)} GB; parei o download")
            except (OSError, http.client.HTTPException) as e:
                target.unlink(missing_ok=True)
                reason = getattr(e, "reason", None)
                raise FetchError(f"não consegui baixar {item['path']} ({type(e).__name__}{': ' + str(reason) if reason else ''})") from None
            except FetchError:
                target.unlink(missing_ok=True)
                raise
            emit({"status": "verifying", "completed": done + written, "total": total})
            if not verify_file(target, item):
                target.unlink(missing_ok=True)
                raise FetchError(f"a verificação de {item['path']} falhou (tamanho ou hash diferente do esperado); não instalei")
            done += item["size"]
        final = model_dir(folder, entry.tag)
        install_atomically(partial, final, backup_dir(folder, entry.tag))
        return final
    finally:
        if main:
            signal.signal(signal.SIGTERM, previous)
