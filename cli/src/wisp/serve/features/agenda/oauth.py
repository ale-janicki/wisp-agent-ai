from __future__ import annotations

import asyncio
import base64
import hashlib
import secrets
from typing import Awaitable, Callable, NamedTuple
from urllib.parse import parse_qsl, quote, urlsplit

HEAD_LIMIT = 16 * 1024
LOGIN_TIMEOUT = 300.0


def _base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def make_verifier() -> str:
    return _base64url(secrets.token_bytes(48))


def make_state() -> str:
    return _base64url(secrets.token_bytes(16))


def challenge(verifier: str) -> str:
    return _base64url(hashlib.sha256(verifier.encode()).digest())


def form_encode(value: str) -> str:
    return quote(value, safe="-._~")


def query(fields: list[tuple[str, str]]) -> str:
    return "&".join(f"{name}={form_encode(value)}" for name, value in fields)


class Callback(NamedTuple):
    kind: str
    value: str


class CallbackError(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def request_target(head: str) -> str | None:
    line = head.split("\r\n", 1)[0]
    parts = line.split(" ")
    if len(parts) != 3 or parts[0] != "GET" or not parts[2].startswith("HTTP/"):
        return None
    return parts[1]


def parse_callback(target: str, path: str, state: str) -> Callback:
    parts = urlsplit(target)
    if parts.path != path:
        raise CallbackError("notCallback")
    values: dict[str, str] = {}
    for name, value in parse_qsl(parts.query, keep_blank_values=True):
        values.setdefault(name, value)
    if values.get("state") != state:
        raise CallbackError("stateMismatch")
    if values.get("error"):
        return Callback("denied", values["error"])
    if not values.get("code"):
        raise CallbackError("missingCode")
    return Callback("code", values["code"])


class LoginFailure(Exception):
    def __init__(self, reason: str, detail: str = "") -> None:
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


def _page(message: str) -> bytes:
    return ('<!doctype html><html lang="pt-BR"><meta charset="utf-8"><title>Wisp</title>'
            '<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;'
            'background:#111214;color:#F2F2F3;font:15px system-ui,sans-serif">'
            f"<p>{message}</p></body></html>").encode()


class Loopback:
    def __init__(self, port: int, path: str, state: str, brand: str) -> None:
        self.port, self.path, self.state, self.brand = port, path, state, brand
        self._server: asyncio.base_events.Server | None = None
        self._outcome: asyncio.Future[Callback] | None = None

    async def start(self) -> int:
        self._outcome = asyncio.get_running_loop().create_future()
        try:
            self._server = await asyncio.start_server(self._handle, "127.0.0.1", self.port)
        except OSError as error:
            raise LoginFailure("portBusy" if self.port else "listener", str(error)) from error
        return self._server.sockets[0].getsockname()[1]

    async def result(self, timeout: float) -> Callback:
        assert self._outcome is not None
        try:
            return await asyncio.wait_for(asyncio.shield(self._outcome), timeout)
        except asyncio.TimeoutError:
            self._finish(error=LoginFailure("timedOut"))
            raise LoginFailure("timedOut") from None
        finally:
            await self.close()

    def cancel(self) -> None:
        self._finish(error=LoginFailure("cancelled"))

    async def close(self) -> None:
        if self._server is not None:
            self._server.close()
            self._server = None

    def _finish(self, value: Callback | None = None, error: Exception | None = None) -> None:
        if self._outcome is None or self._outcome.done():
            return
        if error is not None:
            self._outcome.set_exception(error)
            self._outcome.exception()
        else:
            self._outcome.set_result(value)  # type: ignore[arg-type]

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            head = b""
            while b"\r\n\r\n" not in head and len(head) <= HEAD_LIMIT:
                chunk = await reader.read(8192)
                if not chunk:
                    break
                head += chunk
            await self._answer(head.decode("utf-8", "replace"), writer)
        except (ConnectionError, OSError):
            pass
        finally:
            writer.close()

    async def _answer(self, head: str, writer: asyncio.StreamWriter) -> None:
        if self._outcome is None or self._outcome.done():
            return
        target = request_target(head)
        if target is None:
            return await self._reply(writer, "400 Bad Request", None)
        try:
            callback = parse_callback(target, self.path, self.state)
        except CallbackError as error:
            if error.reason == "notCallback":
                return await self._reply(writer, "404 Not Found", None)
            await self._reply(writer, "400 Bad Request",
                              f"A resposta do {self.brand} não confere. Volte ao Wisp e conecte de novo.")
            return self._finish(error=LoginFailure("callback", error.reason))
        message = (f"{self.brand} conectado. Pode fechar esta aba e voltar ao Wisp." if callback.kind == "code"
                   else "O Wisp não foi autorizado. Pode fechar esta aba.")
        await self._reply(writer, "200 OK", message)
        self._finish(value=callback)

    @staticmethod
    async def _reply(writer: asyncio.StreamWriter, status: str, message: str | None) -> None:
        body = _page(message) if message else b""
        writer.write((f"HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {len(body)}\r\n"
                      "Cache-Control: no-store\r\nConnection: close\r\n\r\n").encode() + body)
        try:
            await writer.drain()
        except (ConnectionError, OSError):
            pass


class LoginSession:
    def __init__(self, *, port: Callable[[], int], path: str, brand: str,
                 authorize_url: Callable[[str, str, str], str],
                 exchange: Callable[[str, str, str], Awaitable[None]],
                 opener: Callable[[str], object], timeout: float = LOGIN_TIMEOUT, attempts: int = 1) -> None:
        self._port, self.path, self.brand = port, path, brand
        self._authorize_url, self._exchange, self._opener = authorize_url, exchange, opener
        self.timeout, self.attempts = timeout, attempts
        self._loopback: Loopback | None = None
        self._cancelled = False

    def cancel(self) -> None:
        self._cancelled = True
        if self._loopback is not None:
            self._loopback.cancel()

    async def run(self) -> str:
        verifier, state = make_verifier(), make_state()
        for attempt in range(self.attempts):
            loopback = Loopback(self._port(), self.path, state, self.brand)
            try:
                port = await loopback.start()
                break
            except LoginFailure as failure:
                if failure.reason != "portBusy" or attempt == self.attempts - 1:
                    raise
        self._loopback = loopback
        if self._cancelled:
            loopback.cancel()
        redirect = f"http://127.0.0.1:{port}{self.path}"
        self._opener(self._authorize_url(redirect, state, challenge(verifier)))
        callback = await loopback.result(self.timeout)
        if callback.kind == "denied":
            return "denied"
        await self._exchange(callback.value, verifier, redirect)
        return "connected"


class LoginRunner:
    def __init__(self) -> None:
        self.session: LoginSession | None = None
        self.task: asyncio.Task | None = None

    @property
    def running(self) -> bool:
        return self.task is not None and not self.task.done()

    def start(self, session: LoginSession, on_done: Callable[[str, Exception | None], None]) -> None:
        if self.running:
            return
        self.session = session

        async def run() -> None:
            try:
                outcome = await session.run()
            except LoginFailure as failure:
                on_done("cancelled" if failure.reason == "cancelled" else "failed", failure)
            except asyncio.CancelledError:
                raise
            except Exception as error:  # noqa: BLE001
                on_done("failed", error)
            else:
                on_done(outcome, None)

        self.task = asyncio.get_running_loop().create_task(run())

    def cancel(self) -> None:
        if self.session is not None:
            self.session.cancel()
