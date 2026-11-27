import getpass
import os
import signal
import socket
import subprocess
import sys

IS_WINDOWS = sys.platform == "win32"

SIGTERM = signal.SIGTERM
SIGKILL = getattr(signal, "SIGKILL", signal.SIGTERM)


class NotSupportedHere(OSError):
    pass


try:
    import fcntl
except ImportError:
    fcntl = None
try:
    import msvcrt
except ImportError:
    msvcrt = None


def _fileno(fh) -> int:
    return fh if isinstance(fh, int) else fh.fileno()


def lock_file(fh, exclusive: bool = True, blocking: bool = True) -> None:
    fd = _fileno(fh)
    if not IS_WINDOWS:
        flags = (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | (0 if blocking else fcntl.LOCK_NB)
        fcntl.flock(fd, flags)
        return
    os.lseek(fd, 0, os.SEEK_SET)
    if not blocking:
        try:
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        except OSError as error:
            raise BlockingIOError(*error.args) from None
        return
    while True:
        try:
            msvcrt.locking(fd, msvcrt.LK_LOCK, 1)
            return
        except OSError:
            continue


def unlock_file(fh) -> None:
    fd = _fileno(fh)
    if not IS_WINDOWS:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return
    os.lseek(fd, 0, os.SEEK_SET)
    msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)


def kill_process_tree(pid: int, sig: int = SIGKILL) -> None:
    if not IS_WINDOWS:
        os.killpg(pid, sig)
        return
    done = subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True, check=False)
    if done.returncode != 0:
        raise ProcessLookupError(pid)


def new_session_kwargs() -> dict:
    if IS_WINDOWS:
        return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    return {"start_new_session": True}


def current_uid() -> int | None:
    return None if IS_WINDOWS else os.getuid()


def user_name() -> str:
    if IS_WINDOWS:
        return getpass.getuser()
    import pwd
    return pwd.getpwuid(os.getuid()).pw_name


def home_dir() -> str:
    if IS_WINDOWS:
        return os.path.expanduser("~")
    import pwd
    return pwd.getpwuid(os.getuid()).pw_dir


def unix_socket_family() -> int:
    family = getattr(socket, "AF_UNIX", None)
    if family is None:
        raise NotSupportedHere("Unix sockets are not available on this platform")
    return family
