"""File-based approval channel: a tool asks, the app or the Telegram bot answers."""

import json
import os
import re
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

from wisp.fsops import atomic_write, ensure_dir
from wisp.paths import WispPaths

Outcome = Literal["allow", "deny", "timeout"]
Finished = Literal["allow", "deny", "cancelled", "expired", "failed"]
TOMBSTONE_TTL = 600.0


class ApprovalDirError(Exception):
    pass


_ID = re.compile(r"[0-9a-f]{32}")


@dataclass(frozen=True)
class ApprovalRequest:
    id: str
    tool: str
    summary: str
    detail: str
    created: float
    thread: int | None


def _dir(paths: WispPaths) -> Path:
    directory = paths.state / "approvals"
    if directory.is_symlink():
        raise ApprovalDirError(f"approvals directory is a symlink, refusing: {directory}")
    ensure_dir(directory, 0o700)
    if directory.stat().st_mode & 0o777 != 0o700:
        directory.chmod(0o700)
    return directory


def _write_request(paths: WispPaths, req: ApprovalRequest) -> None:
    atomic_write(_dir(paths) / f"{req.id}.json", json.dumps(asdict(req)), mode=0o600)


def _read_decision(path: Path) -> Outcome | None:
    try:
        text = path.read_text().strip()
    except OSError:
        return None
    if text == "allow":
        return "allow"
    if text == "deny":
        return "deny"
    return None


def _claim_timeout(decision_file: Path) -> Outcome | None:
    """Takes the decision file for the timeout, so a late "Permitir" can no longer create it. If someone got there
    first, their answer wins; a file with anything else in it (forged or half written for good) counts as a timeout."""
    try:
        fd = os.open(decision_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        for _ in range(5):
            decision = _read_decision(decision_file)
            if decision is not None:
                return decision
            time.sleep(0.01)
        return "timeout"
    except OSError:
        return "timeout"
    with os.fdopen(fd, "w") as f:
        f.write("timeout")
    return "timeout"


def _open(paths: WispPaths, tool: str, summary: str, detail: str, thread: int | None, wall: Callable[[], float]) -> tuple[ApprovalRequest, Path, Path]:
    req = ApprovalRequest(uuid.uuid4().hex, tool, summary, detail, wall(), thread)
    directory = _dir(paths)
    _write_request(paths, req)
    return req, directory / f"{req.id}.json", directory / f"{req.id}.decision"


def _outcome(
    req: ApprovalRequest, decision_file: Path, start: float, timeout: float, clock: Callable[[], float], wall: Callable[[], float]
) -> Outcome | None:
    """The decision, "timeout" once either clock passed the deadline (the monotonic one stops while the Mac sleeps), else None."""
    decision = _read_decision(decision_file)
    if decision is not None:
        return decision
    if clock() - start >= timeout or wall() - req.created > timeout:
        return _claim_timeout(decision_file)
    return None


def _withdraw(req: ApprovalRequest, req_file: Path, decision_file: Path, outcome: Outcome | None, failed: bool = False) -> None:
    """Leaves `<id>.done` (what happened) for the bot, then removes the request and its decision.
    No outcome means the wait ended by an exception or cancellation; `failed` means the approved action itself failed."""
    finished: Finished = "failed" if failed else "cancelled" if outcome is None else "expired" if outcome == "timeout" else outcome
    try:
        atomic_write(req_file.with_suffix(".done"), json.dumps({"id": req.id, "outcome": finished}), mode=0o600)
    except OSError:
        pass                                # the bot falls back to its time-based label
    req_file.unlink(missing_ok=True)
    decision_file.unlink(missing_ok=True)


def request(
    paths: WispPaths,
    tool: str,
    summary: str,
    detail: str,
    *,
    thread: int | None = None,
    timeout: float = 600.0,
    poll: float = 0.5,
    clock: Callable[[], float] = time.monotonic,
    wall: Callable[[], float] = time.time,
    sleep: Callable[[float], None] = time.sleep,
) -> Outcome:
    req, req_file, decision_file = _open(paths, tool, summary, detail, thread, wall)
    outcome: Outcome | None = None
    try:
        start = clock()
        while (outcome := _outcome(req, decision_file, start, timeout, clock, wall)) is None:
            sleep(poll)
        return outcome
    finally:
        _withdraw(req, req_file, decision_file, outcome)


async def request_async(
    paths: WispPaths,
    tool: str,
    summary: str,
    detail: str,
    *,
    thread: int | None = None,
    timeout: float = 600.0,
    poll: float = 0.5,
    clock: Callable[[], float] = time.monotonic,
    wall: Callable[[], float] = time.time,
    sleep: Callable[[float], Awaitable[None]] | None = None,
    act: Callable[[], Awaitable[None]] | None = None,
) -> Outcome:
    """Same as `request`, but cancelling the awaiting task withdraws the request (the `finally` runs at the sleep).
    `act` runs after an allow, while the request is still on disk; if it raises, the tombstone says "failed"."""
    if sleep is None:
        import anyio

        sleep = anyio.sleep
    req, req_file, decision_file = _open(paths, tool, summary, detail, thread, wall)
    outcome: Outcome | None = None
    failed = False
    try:
        start = clock()
        while (outcome := _outcome(req, decision_file, start, timeout, clock, wall)) is None:
            await sleep(poll)
        if outcome == "allow" and act is not None:
            try:
                await act()
            except BaseException:
                failed = True
                raise
        return outcome
    finally:
        _withdraw(req, req_file, decision_file, outcome, failed)


def pending(paths: WispPaths) -> list[ApprovalRequest]:
    found: list[ApprovalRequest] = []
    if not (paths.state / "approvals").is_dir():
        return found
    directory = _dir(paths)
    now = time.time()
    for stale in directory.glob("*.done"):
        try:
            if now - stale.lstat().st_mtime > TOMBSTONE_TTL:
                stale.unlink(missing_ok=True)
        except OSError:
            continue
    for file in directory.glob("*.json"):
        if not _ID.fullmatch(file.stem) or (directory / f"{file.stem}.decision").exists():
            continue
        try:
            req = ApprovalRequest(**json.loads(file.read_text()))
        except (OSError, ValueError, TypeError):
            continue
        if req.id == file.stem:
            found.append(req)
    return sorted(found, key=lambda r: r.created)


def _still_open(directory: Path, id: str) -> bool:
    """False once the tool gave up on the request (its tombstone says expired or cancelled) or took it away without
    leaving one: an answer written now would be shown as "permitido" for something that did not happen."""
    try:
        data = json.loads((directory / f"{id}.done").read_text())
    except (OSError, ValueError):
        return (directory / f"{id}.json").exists()
    return not (isinstance(data, dict) and data.get("outcome") in ("expired", "cancelled"))


def decide(paths: WispPaths, id: str, allow: bool) -> bool:
    if not _ID.fullmatch(id):
        return False
    directory = _dir(paths)
    if not (directory / f"{id}.json").exists():
        return False
    target = directory / f"{id}.decision"
    try:
        fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "w") as f:
            f.write("allow" if allow else "deny")
    except OSError:
        target.unlink(missing_ok=True)
        return False
    if not _still_open(directory, id):
        target.unlink(missing_ok=True)
        return False
    return True
