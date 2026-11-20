import json
import os
import socket
import stat
import time
from collections.abc import Callable, Mapping

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
    """str() is the sentence the assistant reads: the mail was not sent."""


def _trusted(path: str) -> None:
    if not os.path.isabs(path) or len(path) > MAX_SOCKET_PATH:
        raise Refused(NO_CHANNEL)
    try:
        leaf, folder = os.lstat(path), os.lstat(os.path.dirname(path))
    except OSError:
        raise Refused(NO_CHANNEL) from None
    uid = os.getuid()
    if not stat.S_ISSOCK(leaf.st_mode) or leaf.st_uid != uid:
        raise Refused(NO_CHANNEL)
    if not stat.S_ISDIR(folder.st_mode) or folder.st_uid != uid or stat.S_IMODE(folder.st_mode) & 0o077:
        raise Refused(NO_CHANNEL)


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


def ask_broker(path: str | None, request: dict, wait: float = WAIT_SECONDS) -> None:
    """Returns only when the host answered an explicit allow; every other outcome raises Refused."""
    if not path:
        raise Refused(NO_CHANNEL)
    _trusted(path)
    deadline = time.monotonic() + wait
    line = json.dumps({"op": OP_REQUEST, "tool": TOOL, "input": request}, ensure_ascii=False).encode() + b"\n"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(wait)
            conn.connect(path)
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


def gate_from_env(environ: Mapping[str, str]) -> Gate:
    path = environ.get(SOCKET_ENV)
    return lambda request: ask_broker(path, request)
