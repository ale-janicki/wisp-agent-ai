from __future__ import annotations
import asyncio, contextlib, fcntl, os, re
from pathlib import Path

BASE = Path(os.environ.get("HOME") or Path.home()) / ".local/state/wisp/locks"
_SID = re.compile(r"^[A-Za-z0-9-]{1,64}$")


def path_for(session_id: str, base: Path | None = None) -> Path:
    if not _SID.match(session_id or ""):
        raise ValueError(f"session_id invalido: {session_id!r}")
    return (base or BASE) / f"{session_id}.lock"


class SessionLock:
    def __init__(self, session_id: str, base: Path | None = None):
        self.path = path_for(session_id, base)
        self._fd: int | None = None

    def _open(self) -> int:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        return os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)

    def try_acquire(self) -> bool:
        fd = self._open()
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
        self._fd = fd
        return True

    def acquire(self) -> None:
        fd = self._open()
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except BaseException:
            os.close(fd)
            raise
        self._fd = fd

    def release(self) -> None:
        fd, self._fd = self._fd, None
        if fd is not None:
            os.close(fd)


async def _in_thread(lock: SessionLock, fn) -> bool | None:
    fut = asyncio.ensure_future(asyncio.to_thread(fn))
    try:
        return await asyncio.shield(fut)
    except asyncio.CancelledError:
        def _give_back(f: asyncio.Future) -> None:
            if not f.cancelled() and f.exception() is None and f.result() is not False:
                lock.release()
        fut.add_done_callback(_give_back)
        raise


@contextlib.asynccontextmanager
async def guard(session_id: str, on_wait=None, base: Path | None = None):
    lock = SessionLock(session_id, base)
    if not await _in_thread(lock, lock.try_acquire):
        if on_wait:
            try:
                await on_wait()
            except Exception:
                pass
        await _in_thread(lock, lock.acquire)
    try:
        yield
    finally:
        lock.release()
