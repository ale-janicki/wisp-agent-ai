import ctypes
import json
import os
import socket
import stat
import struct
import sys
import time
from collections.abc import Callable, Mapping
from wisp import compat

SOCKET_ENV = "WISP_APPROVAL_SOCKET"
OP_REQUEST = "request"
TOOL = "email_send"
WAIT_SECONDS = 620
MAX_REPLY = 65536
MAX_SOCKET_PATH = 103

NO_CHANNEL = ("não enviei: o envio precisa da aprovação do usuário e o canal de aprovação do Wisp não está disponível aqui "
              "(só o app e o Telegram do Wisp aprovam; um terminal sem o Wisp aberto não envia). "
              "Peça para ele enviar pelo app ou pelo Telegram.")
NOT_ANSWERED = "não enviei: ninguém aprovou a tempo. Pergunte ao usuário o que fazer."
BAD_REPLY = "não enviei: a resposta do canal de aprovação não foi entendida."
DENIED = "não enviei: o usuário negou o envio. Não tente de novo do mesmo jeito; siga sem ele ou pergunte o que fazer."

Gate = Callable[[dict], None]


class Refused(Exception):
    pass


def _trusted(path: str) -> None:
    if not os.path.isabs(path) or len(path) > MAX_SOCKET_PATH:
        raise Refused(NO_CHANNEL)
    try:
        leaf, folder = os.lstat(path), os.lstat(os.path.dirname(path))
    except OSError:
        raise Refused(NO_CHANNEL) from None
    uid = compat.current_uid()
    if uid is None:
        raise Refused(NO_CHANNEL)
    if not stat.S_ISSOCK(leaf.st_mode) or leaf.st_uid != uid:
        raise Refused(NO_CHANNEL)
    if not stat.S_ISDIR(folder.st_mode) or folder.st_uid != uid or stat.S_IMODE(folder.st_mode) & 0o077:
        raise Refused(NO_CHANNEL)


SOL_LOCAL = 0
LOCAL_PEERPID = 2
PROC_PIDTBSDINFO = 3
PROC_BSDINFO_SIZE = 136
PROC_PPID_OFFSET = 16
PATH_BUFFER = 4096
MAX_DEPTH = 64
FRAMEWORK_PYTHON = "Resources/Python.app/Contents/MacOS/Python"
RUNTIME_ROOT = ".local/share/wisp/runtime"
APP_BINARIES = ("/Applications/Wisp.app/Contents/MacOS/Wisp", "Applications/Wisp.app/Contents/MacOS/Wisp")


def _libproc():
    return ctypes.CDLL(None, use_errno=True)


def _peer_pid(conn: socket.socket) -> int:
    if sys.platform == "darwin":
        return struct.unpack("i", conn.getsockopt(SOL_LOCAL, LOCAL_PEERPID, 4))[0]
    return struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0]


def _parent_of(pid: int) -> int:
    if sys.platform == "darwin":
        buffer = ctypes.create_string_buffer(PROC_BSDINFO_SIZE)
        if _libproc().proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer, PROC_BSDINFO_SIZE) != PROC_BSDINFO_SIZE:
            return 0
        return struct.unpack_from("I", buffer.raw, PROC_PPID_OFFSET)[0]
    try:
        with open(f"/proc/{pid}/stat", "rb") as file:
            return int(file.read().rsplit(b")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        return 0


def _ancestors(pid: int) -> list[int]:
    chain: list[int] = []
    current = _parent_of(pid)
    while current > 1 and current not in chain and len(chain) < MAX_DEPTH:
        chain.append(current)
        current = _parent_of(current)
    return chain


def _exe_of(pid: int) -> str:
    if sys.platform == "darwin":
        buffer = ctypes.create_string_buffer(PATH_BUFFER)
        if _libproc().proc_pidpath(pid, buffer, PATH_BUFFER) <= 0:
            return ""
        return os.fsdecode(buffer.value)
    try:
        return os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return ""


def _host_executables() -> set[str]:
    home = compat.home_dir()
    found = {os.path.realpath(APP_BINARIES[0]), os.path.realpath(os.path.join(home, APP_BINARIES[1]))}
    root = os.path.realpath(os.path.join(home, RUNTIME_ROOT)) + os.sep
    bin_dir = os.path.join(home, RUNTIME_ROOT, "venv/bin")
    try:
        names = os.listdir(bin_dir)
    except OSError:
        names = []
    for name in names:
        if name.startswith("python"):
            real = os.path.realpath(os.path.join(bin_dir, name))
            if not real.startswith(root):
                continue
            found.add(real)
            found.add(os.path.join(os.path.dirname(os.path.dirname(real)), FRAMEWORK_PYTHON))
    return found


def _check_host(conn: socket.socket) -> None:
    try:
        peer = _peer_pid(conn)
        if peer <= 1 or peer not in _ancestors(os.getpid()):
            raise Refused(NO_CHANNEL)
        exe = _exe_of(peer)
        if not exe or os.path.realpath(exe) not in _host_executables():
            raise Refused(NO_CHANNEL)
    except (OSError, AttributeError, ValueError, struct.error):
        raise Refused(NO_CHANNEL) from None


def _read_line(conn: socket.socket, deadline: float) -> bytes:
    data = b""
    while b"\n" not in data:
        left = deadline - time.monotonic()
        if left <= 0:
            raise Refused(NOT_ANSWERED)
        conn.settimeout(left)
        chunk = conn.recv(4096)
        if not chunk:
            raise Refused(BAD_REPLY)
        data += chunk
        if len(data) > MAX_REPLY:
            raise Refused(BAD_REPLY)
    return data.split(b"\n", 1)[0]


def ask_broker(path: str | None, request: dict, wait: float = WAIT_SECONDS, tool: str = TOOL) -> None:
    if not path:
        raise Refused(NO_CHANNEL)
    _trusted(path)
    deadline = time.monotonic() + wait
    line = json.dumps({"op": OP_REQUEST, "tool": tool, "input": request}, ensure_ascii=False).encode() + b"\n"
    try:
        with socket.socket(compat.unix_socket_family(), socket.SOCK_STREAM) as conn:
            conn.settimeout(wait)
            conn.connect(path)
            _check_host(conn)
            conn.sendall(line)
            reply = _read_line(conn, deadline)
    except TimeoutError:
        raise Refused(NOT_ANSWERED) from None
    except OSError:
        raise Refused(NO_CHANNEL) from None
    try:
        answer = json.loads(reply)
    except ValueError:
        raise Refused(BAD_REPLY) from None
    decision = answer.get("decision") if isinstance(answer, dict) else None
    if decision == "allow":
        return
    if decision == "deny":
        message = answer.get("message")
        raise Refused(message if isinstance(message, str) and message else DENIED)
    raise Refused(BAD_REPLY)


def gate_from_env(environ: Mapping[str, str], tool: str = TOOL) -> Gate:
    path = environ.get(SOCKET_ENV)
    return lambda request: ask_broker(path, request, tool=tool)
