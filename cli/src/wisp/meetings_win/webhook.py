from __future__ import annotations

import hashlib
import hmac
import json
import socket
import ssl
import time
from dataclasses import dataclass
from typing import Callable
from urllib.parse import urlsplit

MAXIMUM_URL_LENGTH = 2048
PREVIEW_LIMIT = 280
SEND_TIMEOUT = 20.0
BLOCKED_SUFFIXES = ("localhost", "local", "internal", "lan", "home", "corp", "intranet", "arpa", "test", "invalid", "example")
IPV4_BLOCKS = ((0x00000000, 8), (0x0A000000, 8), (0x64400000, 10), (0x7F000000, 8), (0xA9FE0000, 16), (0xAC100000, 12),
               (0xC0000000, 24), (0xC0000200, 24), (0xC0A80000, 16), (0xC6120000, 15), (0xC6336400, 24), (0xCB007100, 24),
               (0xE0000000, 3))


class WebhookError(Exception):
    pass


class NotSent(Exception):
    pass


class HandedOver(Exception):
    pass


ERRORS = {
    "invalid": "O endereço do webhook não é uma URL válida.",
    "not_https": "O webhook precisa de um endereço https.",
    "credentials": "O endereço do webhook não pode ter usuário e senha.",
    "redirected": "o servidor tentou redirecionar o envio.",
    "bad_request": "não consegui montar o pedido.",
    "bad_reply": "o servidor não respondeu como HTTP.",
    "timed_out": "o servidor não respondeu a tempo.",
    "unconfirmed": "o servidor não confirmou depois de receber o envio; ele pode ter chegado e não tentei de novo.",
}


@dataclass(frozen=True)
class Target:
    url: str
    host: str
    port: int
    explicit_port: bool
    path: str
    request_target: str


def _private(host: str) -> WebhookError:
    return WebhookError(f"O webhook não pode apontar para {host}: é um endereço local ou privado.")


def validate(text: str) -> Target:
    trimmed = (text or "").strip()
    if (not trimmed or len(trimmed) > MAXIMUM_URL_LENGTH or "\\" in trimmed
            or any(not (0x20 < ord(c) < 0x7F) for c in trimmed)):
        raise WebhookError(ERRORS["invalid"])
    try:
        parts = urlsplit(trimmed)
        host = parts.hostname
        port = parts.port
    except ValueError:
        raise WebhookError(ERRORS["invalid"]) from None
    if not host or "%" in parts.netloc.rpartition("@")[2] or host.endswith("."):
        raise WebhookError(ERRORS["invalid"])
    if parts.scheme.lower() != "https":
        raise WebhookError(ERRORS["not_https"])
    if "@" in parts.netloc or parts.username is not None or parts.password is not None:
        raise WebhookError(ERRORS["credentials"])
    if not is_public(host):
        raise _private(host)
    path = parts.path or "/"
    return Target(trimmed, host.lower(), port or 443, port is not None, parts.path,
                  path + (f"?{parts.query}" if parts.query else ""))


def _public_ipv4(value: int) -> bool:
    return not any(value >> (32 - bits) == base >> (32 - bits) for base, bits in IPV4_BLOCKS)


def _inet_aton(host: str) -> int | None:
    try:
        return int.from_bytes(socket.inet_aton(host), "big")
    except (OSError, ValueError):
        return None


def _public_ipv6(host: str) -> bool:
    try:
        raw = socket.inet_pton(socket.AF_INET6, host.split("%")[0])
    except (OSError, ValueError):
        return False
    if all(b == 0 for b in raw[:10]) and raw[10] == 0xFF and raw[11] == 0xFF:
        return _public_ipv4(int.from_bytes(raw[12:16], "big"))
    if raw[0] & 0xE0 != 0x20:
        return False
    if raw[0] == 0x20 and raw[1] == 0x02:
        return _public_ipv4(int.from_bytes(raw[2:6], "big"))
    if raw[0] == 0x20 and raw[1] == 0x01 and raw[2] == 0x00 and raw[3] == 0x00:
        return False
    if raw[0] == 0x20 and raw[1] == 0x01 and raw[2] == 0x0D and raw[3] == 0xB8:
        return False
    return True


def is_public(host: str) -> bool:
    host = host.strip("[]").lower().strip(".")
    if ":" in host:
        return _public_ipv6(host)
    labels = host.split(".")
    last = labels[-1]
    if last.isdigit() or last.startswith("0x") or last == "":
        value = _inet_aton(host)
        return value is not None and _public_ipv4(value)
    if len(labels) < 2 or host == "localhost":
        return False
    return last not in BLOCKED_SUFFIXES


def section(heading: str, note: str) -> str:
    inside = captured = False
    lines: list[str] = []
    for line in note.split("\n"):
        stripped = line.strip()
        if stripped.startswith("## "):
            if inside:
                captured = True
            inside = not captured and stripped == heading
            continue
        if inside and not stripped.startswith(">"):
            lines.append(line)
    return "\n".join(lines).strip()


def _value(label: str, parts: list[str]) -> str | None:
    for part in parts[1:]:
        if part.strip().startswith(label):
            value = part.strip()[len(label):].strip()
            return None if not value or value == "não definido" else value
    return None


def action_items(note: str) -> list[dict]:
    inside = False
    items = []
    for line in note.split("\n"):
        stripped = line.strip()
        if stripped.startswith("## "):
            inside = stripped == "## Ações"
            continue
        prefix = next((p for p in ("- [ ] ", "- [x] ", "- [X] ") if stripped.startswith(p)), None)
        if not inside or prefix is None:
            continue
        parts = stripped[len(prefix):].split(" — ")
        text = parts[0].strip()
        if text:
            items.append({"text": text, "owner": _value("responsável:", parts), "due": _value("prazo:", parts)})
    return items


def content(title: str, started_at: str, duration_s: float, note: str, metrics: dict | None) -> tuple[bytes, str]:
    overview = section("## Resumo", note)
    key_points = section("## Pontos principais", note)
    actions = action_items(note)
    body = {"event": "meeting.finished", "title": title, "started_at": started_at, "duration_s": duration_s,
            "overview": overview, "key_points": key_points, "action_items": actions}
    if metrics is not None:
        body["metrics"] = metrics
    raw = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    topics = sum(1 for line in key_points.split("\n") if line.startswith("### "))
    lead = overview[:PREVIEW_LIMIT] + "…" if len(overview) > PREVIEW_LIMIT else overview
    counts = f"{topics} tópico(s) · {len(actions)} ação(ões)"
    return raw, counts if not lead else f"{lead}\n{counts}"


def signature(body: bytes, secret: str, timestamp: int) -> str:
    return "sha256=" + hmac.new(secret.encode("utf-8"), f"{timestamp}.".encode() + body, hashlib.sha256).hexdigest()


@dataclass(frozen=True)
class Pending:
    target: Target
    body: bytes
    preview: str = ""
    signed: bool = False

    @property
    def host(self) -> str:
        return self.target.host

    @property
    def masked_url(self) -> str:
        port = f":{self.target.port}" if self.target.explicit_port else ""
        hidden = "" if self.target.path in ("", "/") else "/•••"
        return f"https://{self.target.host}{port}{hidden}"

    @property
    def size_text(self) -> str:
        return f"{len(self.body)} B" if len(self.body) < 1024 else f"{len(self.body) / 1024:.1f} KB"

    @property
    def body_text(self) -> str:
        return self.body.decode("utf-8", "replace")

    @property
    def formatted_body_text(self) -> str:
        try:
            return json.dumps(json.loads(self.body), indent=2, sort_keys=True, ensure_ascii=False)
        except ValueError:
            return self.body_text


def request_bytes(pending: Pending, secret: str | None, timestamp: int) -> bytes | None:
    if pending.signed and secret is None:
        return None
    target = pending.target
    port = f":{target.port}" if target.explicit_port and target.port != 443 else ""
    authority = (f"[{target.host}]" if ":" in target.host else target.host) + port
    lines = [f"POST {target.request_target} HTTP/1.1", f"Host: {authority}", "Content-Type: application/json",
             f"Content-Length: {len(pending.body)}", "User-Agent: Wisp", "Connection: close"]
    if pending.signed and secret is not None:
        lines += [f"X-Wisp-Timestamp: {timestamp}", f"X-Wisp-Signature: {signature(pending.body, secret, timestamp)}"]
    if any(ord(c) < 0x20 or ord(c) == 0x7F for line in lines for c in line) or " " in target.request_target:
        return None
    return ("\r\n".join(lines) + "\r\n\r\n").encode("utf-8") + pending.body


def status_code(response: bytes) -> int | None:
    first = response[:64].decode("utf-8", "replace").split("\r\n", 1)[0]
    parts = first.split(" ")
    if len(parts) < 2 or not parts[0].startswith("HTTP/1.") or len(parts[1]) != 3 or not parts[1].isdigit():
        return None
    return int(parts[1])


class WebhookApproval:
    def __init__(self):
        self.offers: dict[str, Pending] = {}

    def offer(self, pending: Pending, meeting: str) -> None:
        self.offers[meeting] = pending

    def approve(self, meeting: str) -> Pending | None:
        return self.offers.pop(meeting, None)

    def dismiss(self, meeting: str) -> None:
        self.offers.pop(meeting, None)


def _wrap_tls(sock: socket.socket, host: str):
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(["http/1.1"])
    return context.wrap_socket(sock, server_hostname=host)


def pinned_post(host: str, address: str, port: int, request: bytes, timeout: float = SEND_TIMEOUT,
                wrap: Callable = _wrap_tls) -> int:
    deadline = time.monotonic() + timeout
    try:
        sock = socket.create_connection((address, port), timeout=timeout)
    except OSError as problem:
        raise NotSent(str(problem)) from problem
    try:
        try:
            channel = wrap(sock, host)
        except (OSError, ssl.SSLError) as problem:
            raise NotSent(str(problem)) from problem
        try:
            channel.sendall(request)
        except OSError as problem:
            raise HandedOver(str(problem)) from problem
        received = b""
        while len(received) < 65536:
            channel.settimeout(max(0.1, deadline - time.monotonic()))
            try:
                chunk = channel.recv(4096)
            except (OSError, ssl.SSLError) as problem:
                raise HandedOver(str(problem)) from problem
            if not chunk:
                break
            received += chunk
            if b"\r\n" in received and status_code(received) is not None:
                break
        code = status_code(received)
        if code is None:
            raise WebhookError(ERRORS["bad_reply"])
        return code
    finally:
        try:
            sock.close()
        except OSError:
            pass


def resolve(host: str, port: int) -> list[str]:
    seen: list[str] = []
    for family, _, _, _, sockaddr in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM):
        address = sockaddr[0].split("%")[0]
        if address not in seen:
            seen.append(address)
    return seen


def send(pending: Pending, secret: str | None, resolver: Callable[[str, int], list[str]] = resolve,
         post: Callable = pinned_post, now: Callable[[], float] = time.time) -> None:
    host = pending.host
    try:
        addresses = resolver(host, pending.target.port)
    except OSError as problem:
        raise WebhookError(f"não consegui resolver {host}: {problem}") from problem
    if not addresses or not all(is_public(a) for a in addresses):
        raise WebhookError(f"{host} aponta para um endereço local ou privado.")
    request = request_bytes(pending, secret if pending.signed else None, int(now()))
    if request is None:
        raise WebhookError(ERRORS["bad_request"])
    last: Exception | None = None
    for address in addresses:
        try:
            code = post(host, address, pending.target.port, request)
        except NotSent as problem:
            last = problem
            continue
        except HandedOver:
            raise WebhookError(ERRORS["unconfirmed"]) from None
        if 300 <= code < 400:
            raise WebhookError(ERRORS["redirected"])
        if not 200 <= code < 300:
            raise WebhookError(f"o servidor respondeu {code}.")
        return
    raise WebhookError(f"não consegui conectar ({last})" if last else ERRORS["invalid"])
