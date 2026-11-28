from __future__ import annotations

import asyncio
import contextlib
import json
import os
import re
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from wisp.config import load_config
from wisp.paths import WispPaths

LOCK_WAIT = 10.0
URGENT = re.compile(r"(?<!\S)#urgente(?!\S)")
ALERT = re.compile(r"<!--\s*alerta:(\S+?)(?:\s+tema:.*?)?\s*-->")


class LineChanged(Exception):
    pass


class LockBusy(Exception):
    pass


@dataclass(frozen=True)
class Item:
    line: str
    occurrence: int
    index: int
    owner: str | None
    front: str | None
    title: str
    detail: str
    urgent: bool
    alert_id: str | None


def _without_comments(text: str) -> str:
    while (open_at := text.find("<!--")) >= 0:
        close = text.find("-->", open_at + 4)
        text = text[:open_at] + (text[close + 3 :] if close >= 0 else "")
    return text


def _clean(tail: str) -> str:
    bare = URGENT.sub("", _without_comments(tail))
    return " ".join(part for part in bare.split(" ") if part)


def plain(markdown: str) -> str:
    text = markdown.replace("**", "").replace("`", "")
    while (open_at := text.find("[[")) >= 0 and (close := text.find("]]", open_at + 2)) >= 0:
        inner = text[open_at + 2 : close]
        shown = inner.split("|", 1)[-1] if inner else ""
        text = text[:open_at] + shown + text[close + 2 :]
    return text.strip(" \t")


def _item(raw: str, line: str, occurrence: int, index: int) -> Item:
    body = line[2:]
    alert = ALERT.search(line)
    alert_id = alert.group(1) if alert else None
    owner_end = body.find("]") if body.startswith("**[") else -1
    bold_end = body.find("**", owner_end + 1) if owner_end >= 0 else -1
    if bold_end < 0:
        return Item(raw, occurrence, index, None, None, plain(_clean(body)), "", bool(URGENT.search(_without_comments(body))), alert_id)
    heading = body[owner_end + 1 : bold_end].strip(" \t")
    tail = body[bold_end + 2 :]
    detail = _clean(tail)
    detail = detail.removeprefix(".")
    parts = heading.split(" — ")
    front = parts[0] if len(parts) > 1 else None
    title = " — ".join(parts[1:]) if len(parts) > 1 else heading
    return Item(raw, occurrence, index, body[3:owner_end], front, plain(title), plain(detail),
                bool(URGENT.search(_without_comments(tail))), alert_id)


def parse(text: str) -> list[dict]:
    groups: list[dict] = []
    title: str | None = None
    items: list[Item] = []
    seen: dict[str, int] = {}
    fenced = False
    lines = text.split("\n")
    start = 0
    if lines and lines[0].rstrip() == "---":
        start = next((i + 1 for i in range(1, len(lines)) if lines[i].rstrip() == "---"), 0)

    def close() -> None:
        nonlocal items
        if items:
            groups.append({"title": title, "items": [asdict(i) for i in items]})
        items = []

    for index, raw in enumerate(lines):
        occurrence = seen.get(raw, 0)
        seen[raw] = occurrence + 1
        if index < start:
            continue
        line = raw.removesuffix("\r")
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
        elif fenced:
            continue
        elif line.startswith("## "):
            close()
            title = line[3:].strip(" \t")
        elif line.startswith("- "):
            items.append(_item(raw, line, occurrence, index))
    close()
    return groups


def deleting(text: str, line: str, occurrence: int) -> str:
    parts = text.split("\n")
    matches = [i for i, p in enumerate(parts) if p == line]
    if not 0 <= occurrence < len(matches):
        raise LineChanged
    index = matches[occurrence]
    del parts[index]
    result = "\n".join(parts)
    if index == len(parts) and index > 0:
        result += "\n"
    return result


def _expand(path: str) -> Path:
    return Path(path.strip()).expanduser()


def _profile_blocks() -> dict:
    try:
        blocks = json.loads((WispPaths.current().config / "profile.json").read_text(encoding="utf-8")).get("blocks")
    except (OSError, ValueError, AttributeError):
        return {}
    return blocks if isinstance(blocks, dict) else {}


def tasks_file() -> Path | None:
    block = _profile_blocks().get("tasks")
    configured = block.get("file") if isinstance(block, dict) else None
    if isinstance(configured, str) and configured.strip():
        return _expand(configured)
    try:
        brain = load_config().brain
    except (OSError, ValueError, TypeError):
        brain = None
    fallback = _expand(brain) / "pendencias.md" if brain else None
    return fallback if fallback and fallback.is_file() else None


def lock_path() -> Path:
    block = _profile_blocks().get("tasks")
    profile = block.get("lock") if isinstance(block, dict) else None
    if isinstance(profile, str) and profile.strip():
        return _expand(profile)
    env = os.environ.get("WISP_TASKS_LOCK")
    if env:
        return _expand(env)
    return Path.home() / ".cache" / "wisp" / "tasks.lock"


def _try_lock(fd: int) -> None:
    if sys.platform == "win32":
        import msvcrt

        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)  # type: ignore[attr-defined]
    else:
        import fcntl

        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)


def _unlock(fd: int) -> None:
    if sys.platform == "win32":
        import msvcrt

        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)  # type: ignore[attr-defined]
    else:
        import fcntl

        fcntl.flock(fd, fcntl.LOCK_UN)


@contextlib.contextmanager
def file_lock(path: Path, wait: float = LOCK_WAIT):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o644)
    try:
        deadline = time.monotonic() + wait
        while True:
            try:
                _try_lock(fd)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise LockBusy from None
                time.sleep(0.05)
        try:
            yield
        finally:
            _unlock(fd)
    finally:
        os.close(fd)


def complete(file: Path, line: str, occurrence: int, lock: Path, wait: float = LOCK_WAIT) -> None:
    with file_lock(lock, wait):
        text = file.read_bytes().decode("utf-8")
        updated = deleting(text, line, occurrence)
        data = updated.encode("utf-8")
        from .brain.vault import Vault

        Vault.write_bytes_atomic(file.resolve(), data)


def brain_relative(file: Path) -> str | None:
    from .brain import configured_root

    root = configured_root()
    if root is None:
        return None
    try:
        return file.resolve().relative_to(root.resolve()).as_posix()
    except (ValueError, OSError):
        return None


def _missing() -> Response:
    return JSONResponse({"configured": False, "groups": [], "open_count": 0})


async def list_tasks(request: Request) -> Response:
    file = tasks_file()
    if file is None:
        return _missing()
    try:
        text = (await asyncio.to_thread(file.read_bytes)).decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return JSONResponse({"error": f"Não consegui ler {file.name}"}, status_code=500)
    groups = parse(text)
    return JSONResponse({"configured": True, "file": file.name, "brain_path": brain_relative(file), "groups": groups,
                         "open_count": sum(len(g["items"]) for g in groups)})


async def complete_task(request: Request) -> Response:
    file = tasks_file()
    if file is None:
        return _missing()
    try:
        data = await request.json()
    except ValueError:
        data = {}
    line, occurrence = (data.get("line"), data.get("occurrence")) if isinstance(data, dict) else (None, None)
    if not isinstance(line, str) or not isinstance(occurrence, int) or isinstance(occurrence, bool):
        return JSONResponse({"error": "line e occurrence são obrigatórios"}, status_code=400)
    try:
        await asyncio.to_thread(complete, file, line, occurrence, lock_path())
    except LineChanged:
        return JSONResponse({"error": "essa linha mudou no arquivo; recarreguei a lista"}, status_code=409)
    except LockBusy:
        return JSONResponse({"error": "o arquivo está ocupado por outro escritor; nada foi apagado"}, status_code=423)
    except OSError as error:
        return JSONResponse({"error": str(error)}, status_code=500)
    return JSONResponse({"ok": True})


routes = [Route("/list", list_tasks, methods=["GET"]), Route("/complete", complete_task, methods=["POST"])]
