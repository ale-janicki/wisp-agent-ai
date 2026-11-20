import json
import queue
import select
import threading
import termios
import time
import unicodedata
import uuid
from collections.abc import Callable, Iterable
from typing import IO, Literal, Protocol

import anyio
import anyio.to_thread

Outcome = Literal["allow", "deny", "timeout"]

APPROVAL_TIMEOUT = 600.0
SUMMARY_CHARS = 120
TTY_PATH = "/dev/tty"
TTY_SLICE = 0.25
POLL = 0.02
YES = frozenset({"s", "sim", "y", "yes"})


class Approver(Protocol):
    async def ask(self, tool: str, arguments: dict, tool_use_id: str) -> Outcome: ...


def clean(text: str) -> str:
    return "".join(f"\\u{ord(c):04x}" if unicodedata.category(c) in ("Cc", "Cf", "Zl", "Zp") else c for c in text)


def describe(tool: str, arguments: dict) -> tuple[str, str]:
    first = next((v for k, v in sorted(arguments.items()) if isinstance(v, str)), "")
    detail = json.dumps(arguments, ensure_ascii=False, indent=2, default=str)
    return clean(f"{tool}: {first}"[:SUMMARY_CHARS]), "\n".join(clean(line) for line in detail.split("\n"))


class DenyApprover:
    async def ask(self, tool: str, arguments: dict, tool_use_id: str) -> Outcome:
        return "deny"


def open_controlling_tty() -> tuple[IO[str], IO[str]]:
    return open(TTY_PATH, "r", encoding="utf-8"), open(TTY_PATH, "w", encoding="utf-8")


class TtyApprover:
    def __init__(self, open_tty: Callable[[], tuple[IO[str], IO[str]]] = open_controlling_tty, timeout: float = APPROVAL_TIMEOUT):
        self.open_tty = open_tty
        self.timeout = timeout

    async def ask(self, tool: str, arguments: dict, tool_use_id: str) -> Outcome:
        stop = threading.Event()
        try:
            return await anyio.to_thread.run_sync(lambda: self._prompt(tool, arguments, stop), abandon_on_cancel=True)
        finally:
            stop.set()

    def _prompt(self, tool: str, arguments: dict, stop: threading.Event) -> Outcome:
        try:
            reader, writer = self.open_tty()
        except OSError:
            return "deny"
        with reader, writer:
            try:
                termios.tcflush(reader.fileno(), termios.TCIFLUSH)
            except (termios.error, OSError, ValueError):
                pass
            summary, detail = describe(tool, arguments)
            writer.write(f"\nO Wisp quer executar {summary}\n{detail}\nPermitir? [s/N] ")
            writer.flush()
            deadline = time.monotonic() + self.timeout
            while not stop.is_set():
                left = deadline - time.monotonic()
                if left <= 0:
                    writer.write("\nsem resposta a tempo: negado\n")
                    writer.flush()
                    return "timeout"
                ready, _, _ = select.select([reader], [], [], min(TTY_SLICE, left))
                if ready:
                    line = reader.readline()
                    return "allow" if line.strip().lower() in YES else "deny"
        return "deny"


class StdioApprover:
    def __init__(self, emit: Callable[[dict], None], lines: Iterable[str], timeout: float = APPROVAL_TIMEOUT,
                 new_id: Callable[[], str] = lambda: uuid.uuid4().hex):
        self.emit = emit
        self.lines = lines
        self.timeout = timeout
        self.new_id = new_id
        self.inbox: queue.Queue[str | None] = queue.Queue()
        self.reader: threading.Thread | None = None

    def _pump(self) -> None:
        for line in self.lines:
            self.inbox.put(line)
        self.inbox.put(None)

    def _start(self) -> None:
        if self.reader is None:
            self.reader = threading.Thread(target=self._pump, daemon=True)
            self.reader.start()

    async def ask(self, tool: str, arguments: dict, tool_use_id: str) -> Outcome:
        self._start()
        request_id = f"req_{self.new_id()}"
        summary, _ = describe(tool, arguments)
        self.emit({"type": "control_request", "request_id": request_id, "request": {
            "subtype": "can_use_tool", "tool_name": clean(tool), "display_name": clean(tool), "input": arguments, "description": summary,
            "permission_suggestions": [], "tool_use_id": tool_use_id}})
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            try:
                line = self.inbox.get_nowait()
            except queue.Empty:
                await anyio.sleep(POLL)
                continue
            if line is None:
                self.inbox.put(None)
                return "deny"
            answer = self._answer(line, request_id)
            if answer is not None:
                return answer
        return "timeout"

    @staticmethod
    def _answer(line: str, request_id: str) -> Outcome | None:
        try:
            message = json.loads(line)
        except ValueError:
            return None
        body = message.get("response") if isinstance(message, dict) and message.get("type") == "control_response" else None
        if not isinstance(body, dict) or body.get("request_id") != request_id:
            return None
        inner = body.get("response")
        if body.get("subtype") == "success" and isinstance(inner, dict) and inner.get("behavior") == "allow":
            return "allow"
        return "deny"
