from __future__ import annotations

import asyncio
import contextlib
import json
import ntpath
import os
import re
import shutil
import subprocess
import sys
import traceback
import uuid
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from wisp.compat import kill_process_tree, new_session_kwargs
from wisp.serve import engines, guards, protocol
from wisp.serve.engines import card
from wisp.serve.engines.card import ASK_TOOLS
from wisp.serve.guards import GuardsUnavailable
from wisp.serve.store import (attachments_summary, is_lost_session, parse_attachments, prime, reply_split,
                              title_fallback, unparsed_attachments)

SUMMARY_LIMIT = 80
DENY_MESSAGE = ("O usuário negou esta ação no Wisp. Não tente de novo do mesmo jeito; siga sem ela ou pergunte o que "
                "fazer.")
STDERR_LIMIT = 2048
PREVIEW_LIMIT = 120
NO_CAPTION = "(sem texto — veja o que é e me diga)"


def claude_arguments(model: str | None = None, resume: str | None = None, permission_mode: str | None = None,
                     append_system_prompt: str | None = None, settings: str | None = None,
                     disallowed_tools: list[str] | tuple[str, ...] = ()) -> list[str]:
    args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--replay-user-messages"]
    for flag, value in (("--model", model), ("--resume", resume), ("--permission-mode", permission_mode),
                        ("--append-system-prompt", append_system_prompt), ("--settings", settings)):
        if value:
            args += [flag, value]
    if disallowed_tools:
        args += ["--disallowedTools", *disallowed_tools]
    return args + ["--permission-prompt-tool", "stdio"]


@dataclass
class ResumePlan:
    resume: str | None
    prime: bool
    switched: bool
    link_reason: str
    drop_claude_session: bool


def plan_resume(kind: str, last_engine: str | None, claude_session: str | None, codex_session: str | None,
                lost: bool) -> ResumePlan:
    switched = last_engine is not None and last_engine != kind
    if kind == "local":
        return ResumePlan(None, False, switched, "new", False)
    known = codex_session if kind == "codex" else claude_session
    missing = last_engine is not None and known is None
    if not (lost or switched or missing):
        return ResumePlan(known, False, False, "new", False)
    return ResumePlan(None, True, switched, "rebuilt", kind == "claude" and (switched or lost))


class ClaudeNotFound(Exception):
    pass


def _usable(path: str, platform: str) -> bool:
    return os.path.isfile(path) and (platform == "win32" or os.access(path, os.X_OK))


def _run_shell(script: str, timeout: float = 5.0, shell: str = "/bin/zsh") -> str | None:
    try:
        proc = subprocess.Popen([shell, "-lc", script], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, **new_session_kwargs())
    except OSError:
        return None
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            kill_process_tree(proc.pid)
        proc.communicate()
        return None
    if proc.returncode != 0:
        return None
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    return lines[-1] if lines else None


_login_path: list[str | None] = []


def login_shell_path() -> str | None:
    if not _login_path:
        _login_path.append(_run_shell('printf %s "$PATH"'))
    return _login_path[0]


def locate_claude(configured: str | None = None, env=None, platform: str | None = None,
                  home: str | None = None) -> str:
    env = os.environ if env is None else env
    platform = platform or sys.platform
    home = home or os.path.expanduser("~")
    if configured:
        path = os.path.expanduser(configured)
        if not _usable(path, platform):
            raise ClaudeNotFound(f"o claude configurado ({path}) não existe ou não é executável")
        return path
    names = ["claude.exe", "claude.cmd", "claude.bat"] if platform == "win32" else ["claude"]
    for folder in filter(None, env.get("PATH", "").split(";" if platform == "win32" else ":")):
        for name in names:
            if _usable(os.path.join(folder, name), platform):
                return os.path.join(folder, name)
    if platform == "darwin":
        found = _run_shell("command -v claude")
        if found and found.startswith("/") and _usable(found, platform):
            return found
    candidates = [os.path.join(home, ".local", "bin", "claude")]
    if platform == "win32":
        candidates = [os.path.join(home, ".local", "bin", "claude.exe")]
        if env.get("USERPROFILE"):
            candidates.append(os.path.join(env["USERPROFILE"], ".local", "bin", "claude.exe"))
        if env.get("APPDATA"):
            candidates.append(os.path.join(env["APPDATA"], "npm", "claude.cmd"))
    elif platform == "darwin":
        candidates.append("/opt/homebrew/bin/claude")
    for path in candidates:
        if _usable(path, platform):
            return path
    raise ClaudeNotFound("Claude Code não encontrado")


CMD_REFUSAL = ("não consigo abrir o Claude Code pelo atalho .cmd com segurança; "
               "instale a versão nativa (claude.exe)")


def _is_batch(path: str) -> bool:
    return path.rstrip(" .").lower().endswith((".cmd", ".bat"))


def resolve_launch(executable: str, platform: str | None = None, which=None,
                   exists=os.path.isfile, read=None) -> list[str]:
    platform = platform or sys.platform
    which = which or shutil.which
    if platform != "win32" or not _is_batch(executable):
        return [executable]
    try:
        text = read(executable) if read else Path(executable).read_text(encoding="utf-8", errors="replace")
        lines = [line.strip() for line in text.splitlines() if line.strip()]
    except OSError:
        raise ClaudeNotFound(CMD_REFUSAL) from None
    if not lines or "%*" not in lines[-1]:
        raise ClaudeNotFound(CMD_REFUSAL)
    folder = ntpath.dirname(ntpath.abspath(executable)) if read is None else ntpath.dirname(executable)
    tail = lines[-1].rsplit("&", 1)[-1]
    tokens = re.findall(r'"[^"]*"|\S+', tail)
    if not tokens or tokens[-1] != "%*" or len(tokens) > 3:
        raise ClaudeNotFound(CMD_REFUSAL)

    def expand(token: str) -> str:
        token = token.strip('"')
        for name in ("%~dp0", "%dp0%"):
            token = re.sub(re.escape(name) + r"[\\/]*", lambda _: folder.rstrip("\\/") + "\\", token, flags=re.I)
        return ntpath.normpath(token)

    words = tokens[:-1]
    if len(words) == 1:
        program = expand(words[0])
        if "%" in program or not program.lower().endswith(".exe") or not exists(program):
            raise ClaudeNotFound(CMD_REFUSAL)
        return [program]
    if len(words) == 2 and words[0].strip('"').lower() in ("%_prog%", "node", "node.exe"):
        script = expand(words[1])
        beside = ntpath.join(folder, "node.exe")
        node = beside if exists(beside) else which("node")
        if ("%" in script or not script.lower().endswith((".js", ".mjs", ".cjs")) or not exists(script)
                or not node or _is_batch(node)):
            raise ClaudeNotFound(CMD_REFUSAL)
        return [node, script]
    raise ClaudeNotFound(CMD_REFUSAL)


def child_environment(executable: str, platform: str | None = None) -> dict[str, str]:
    platform = platform or sys.platform
    env = dict(os.environ)
    env.pop("WISP_SERVE_TOKEN", None)
    separator = ";" if platform == "win32" else ":"
    if platform == "darwin" and login_shell_path():
        home = os.path.expanduser("~")
        parts = [p for p in login_shell_path().split(":") if p]
        for common in (f"{home}/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"):
            if common not in parts:
                parts.append(common)
        env["PATH"] = ":".join(parts)
    else:
        current = env.get("PATH") or ("" if platform == "win32" else "/usr/bin:/bin")
        folder = os.path.dirname(executable)
        env["PATH"] = current if folder in current.split(separator) else (current + separator + folder).strip(separator)
    return env


@dataclass
class Event:
    kind: str
    data: dict[str, Any] = field(default_factory=dict)


@dataclass
class PermissionRequest:
    request_id: str
    tool_name: str
    tool_use_id: str | None
    input: dict[str, Any]
    persist: list[dict[str, Any]]
    summary: str = ""
    detail: str = ""
    summary_truncated: bool = False
    requires_expansion: bool = True
    persist_rules: list[str] = field(default_factory=list)
    persist_where: list[str] = field(default_factory=list)
    engine: str = "claude"

    @property
    def asker(self) -> str:
        return "Codex" if self.engine == "codex" else "Claude"

    @property
    def can_persist(self) -> bool:
        return bool(self.persist)

    @classmethod
    def parse(cls, request_id: str, request: dict[str, Any], home: str | None = None,
              engine: str = "claude") -> PermissionRequest | None:
        if request.get("subtype") != "can_use_tool" or not request_id:
            return None
        tool = request.get("tool_name") if isinstance(request.get("tool_name"), str) else ""
        suggestions = request.get("permission_suggestions")
        persist, rules, where, rules_hidden = ([], [], [], False) if tool in ASK_TOOLS else \
            card.rebuild_persist(suggestions)
        tool_input = request.get("input") if isinstance(request.get("input"), dict) else {}
        use_id = request.get("tool_use_id")
        description = request.get("description") if isinstance(request.get("description"), str) else None
        if engine == "codex" and tool in ASK_TOOLS:
            said = "enviar um e-mail" if tool == ASK_TOOLS[0] else "enviar uma mensagem pelo app"
        else:
            said = card.phrase(tool, tool_input, home or os.path.expanduser("~"))
        truncated = len(said) > card.SUMMARY_LIMIT
        return cls(request_id, tool, use_id if isinstance(use_id, str) else None, tool_input, persist,
                   card.escaped(card.clip_summary(said)),
                   card.escaped(card.detail(tool, tool_input, description)), truncated,
                   card.requires_expansion(tool, tool_input, truncated) or rules_hidden, rules, where, engine)

    def card(self) -> dict[str, Any]:
        return {"summary": self.summary, "detail": self.detail, "summary_truncated": self.summary_truncated,
                "requires_expansion": self.requires_expansion, "can_persist": self.can_persist,
                "persist_rules": self.persist_rules, "persist_where": self.persist_where, "engine": self.engine, "asker": self.asker}


def permission_response_line(request: PermissionRequest, allow: bool, message: str | None = None,
                             always: bool = False) -> bytes:
    if always and allow and not request.persist:
        raise ValueError("nothing to persist")
    answer = {"behavior": "allow", "updatedInput": request.input} if allow else {
        "behavior": "deny", "message": message or DENY_MESSAGE}
    if allow and always:
        answer["updatedPermissions"] = request.persist
    line = {"type": "control_response",
            "response": {"subtype": "success", "request_id": request.request_id, "response": answer}}
    return (json.dumps(line, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def _window(raw: Any) -> dict[str, Any] | None:
    utilization = raw.get("utilization") if isinstance(raw, dict) else None
    if isinstance(utilization, bool) or not isinstance(utilization, (int, float)):
        return None
    resets = raw.get("resetsAt")
    return {"utilization": utilization,
            "resets_at": resets if isinstance(resets, (int, float)) and not isinstance(resets, bool) else None}


def usage_windows(info: dict[str, Any] | None) -> dict[str, Any]:
    windows = info.get("unifiedWindows") if isinstance(info, dict) else None
    windows = windows if isinstance(windows, dict) else {}
    return {"five_hour": _window(windows.get("five_hour")), "seven_day": _window(windows.get("seven_day"))}


def _result_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    blocks = content if isinstance(content, list) else []
    return "\n".join(b["text"] for b in blocks if isinstance(b, dict) and isinstance(b.get("text"), str))


def _decode_item(item: dict[str, Any]) -> list[Event]:
    kind = item.get("type")
    if kind == "thinking":
        return [Event("thinking")]
    if kind == "text":
        return [Event("text", {"text": item.get("text") if isinstance(item.get("text"), str) else ""})]
    if kind == "tool_use":
        tool_input = item.get("input") if isinstance(item.get("input"), dict) else {}
        first = next((tool_input[k] for k in sorted(tool_input) if isinstance(tool_input[k], str)), "")
        return [Event("tool_use", {"id": item.get("id") if isinstance(item.get("id"), str) else "",
                                   "name": item.get("name") if isinstance(item.get("name"), str) else "",
                                   "input": tool_input, "summary": first[:SUMMARY_LIMIT]})]
    return [Event("ignored", {"type": f"assistant.{kind if isinstance(kind, str) else ''}"})]


def _items(obj: dict[str, Any]) -> list[dict[str, Any]]:
    message = obj.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    return [i for i in content if isinstance(i, dict)] if isinstance(content, list) else []


def decode_line(line: str) -> list[Event]:
    try:
        obj = json.loads(line)
    except ValueError:
        return [Event("malformed", {"line": line})]
    kind = obj.get("type") if isinstance(obj, dict) else None
    if not isinstance(kind, str):
        return [Event("malformed", {"line": line})]
    if kind == "system":
        if obj.get("subtype") != "init":
            return [Event("ignored", {"type": kind})]
        events = [Event("initialized", {"session_id": obj.get("session_id") or "", "model": obj.get("model") or "",
                                        "subscription": obj.get("apiKeySource") == "none"})]
        if isinstance(obj.get("permissionMode"), str) and obj["permissionMode"]:
            events.append(Event("permission_mode", {"mode": obj["permissionMode"]}))
        return events
    if kind == "assistant":
        return [event for item in _items(obj) for event in _decode_item(item)]
    if kind == "user":
        if obj.get("isReplay") is True:
            return [Event("user_replayed")]
        results = [Event("tool_result", {"tool_use_id": i.get("tool_use_id") or "", "is_error": i.get("is_error") is True,
                                         "text": _result_text(i.get("content"))})
                   for i in _items(obj) if i.get("type") == "tool_result"]
        return results or [Event("ignored", {"type": kind})]
    if kind == "control_request":
        request = obj.get("request") if isinstance(obj.get("request"), dict) else {}
        parsed = PermissionRequest.parse(obj.get("request_id") or "", request)
        if parsed is None:
            return [Event("ignored", {"type": f"control_request.{request.get('subtype') or ''}"})]
        return [Event("permission_request", {"request": parsed})]
    if kind == "control_cancel_request":
        request_id = obj.get("request_id")
        return [Event("permission_cancelled", {"id": request_id})] if isinstance(request_id, str) and request_id \
            else [Event("ignored", {"type": kind})]
    if kind == "rate_limit_event":
        info = obj.get("rate_limit_info")
        return [Event("usage", {"info": info if isinstance(info, dict) else {}})]
    if kind == "stream_event":
        inner = obj.get("event") if isinstance(obj.get("event"), dict) else {}
        delta = inner.get("delta") if isinstance(inner.get("delta"), dict) else {}
        if inner.get("type") == "content_block_delta" and delta.get("type") == "text_delta" \
                and isinstance(delta.get("text"), str):
            return [Event("text_delta", {"text": delta["text"]})]
        return [Event("ignored", {"type": kind})]
    if kind == "result":
        errors = obj.get("errors")
        text = obj["result"] if isinstance(obj.get("result"), str) else (
            errors[0] if isinstance(errors, list) and errors and isinstance(errors[0], str) else "")
        denials = [d["tool_name"] for d in obj.get("permission_denials") or []
                   if isinstance(d, dict) and isinstance(d.get("tool_name"), str)]
        usage = obj.get("usage") if isinstance(obj.get("usage"), dict) else {}
        return [Event("result", {"session_id": obj.get("session_id") or "", "text": text,
                                 "is_error": obj.get("is_error") is True, "denials": denials, "usage": usage})]
    return [Event("ignored", {"type": kind})]


class LineBuffer:
    def __init__(self) -> None:
        self._pending = b""

    def append(self, data: bytes) -> list[str]:
        self._pending += data
        *lines, self._pending = self._pending.split(b"\n")
        return [text for text in (self._decode(line) for line in lines) if text]

    def flush(self) -> str | None:
        rest, self._pending = self._pending, b""
        return self._decode(rest) or None

    @staticmethod
    def _decode(raw: bytes) -> str:
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            return ""


@dataclass
class LedgerEntry:
    id: str
    text: str
    user: str = ""
    files: list[str] = field(default_factory=list)
    stage: str = "queued"
    consumed: bool = False
    covered: bool = False


class TurnLedger:
    def __init__(self) -> None:
        self.entries: list[LedgerEntry] = []
        self._echoes = False

    @property
    def pending(self) -> int:
        return len(self.entries)

    @property
    def in_flight_entries(self) -> list[LedgerEntry]:
        return [e for e in self.entries if e.stage != "queued"]

    def submit(self, id: str, text: str, user: str = "", files: list[str] | None = None) -> None:
        self.entries.append(LedgerEntry(id, text, user or text, files or []))

    def writing(self, id: str) -> None:
        self._stage(id, "writing")

    def written(self, id: str) -> LedgerEntry | None:
        entry = next((e for e in self.entries if e.id == id), None)
        if entry is None:
            return None
        if entry.covered:
            self.entries.remove(entry)
            return entry
        entry.stage = "written"
        return None

    def write_failed(self, id: str) -> None:
        self.entries = [e for e in self.entries if e.id != id]

    def consumed(self) -> None:
        self._echoes = True
        entry = next((e for e in self.entries if e.stage != "queued" and not e.consumed), None)
        if entry:
            entry.consumed = True

    def result(self, is_error: bool = False, engine: str = "claude") -> list[LedgerEntry]:
        if is_error:
            closed = self.in_flight_entries
        elif engine != "claude":
            closed = [e for e in self.entries if e.stage == "written"][:1]
        elif self._echoes:
            seen = [e for e in self.entries if e.consumed]
            closed = seen or [e for e in self.entries if e.stage == "written"][:1]
        else:
            closed = [e for e in self.entries if e.stage == "written"]
            for entry in self.entries:
                if entry.stage == "writing":
                    entry.covered = True
        ids = {e.id for e in closed}
        self.entries = [e for e in self.entries if e.id not in ids]
        return closed

    def reset(self) -> None:
        self.entries = []
        self._echoes = False

    def process_restarted(self) -> None:
        self.entries = [e for e in self.entries if e.stage == "queued"]
        self._echoes = False

    def requeue_in_flight(self) -> None:
        redo = [e for e in self.entries if e.stage != "queued"]
        for entry in redo:
            entry.stage, entry.consumed, entry.covered = "queued", False, False
        self.entries = [e for e in self.entries if e.stage == "queued" and e not in redo] + redo
        self._echoes = False

    def _stage(self, id: str, stage: str) -> None:
        entry = next((e for e in self.entries if e.id == id), None)
        if entry:
            entry.stage = stage


def compose_attachments(paths: list[str], caption: str, origin: str = "Wisp", user: str = "usuario") -> str:
    lines = []
    for path in paths:
        try:
            size = os.path.getsize(path)
        except OSError:
            size = 0
        lines.append(f"- {path} ({os.path.basename(path)}, {size} bytes)")
    head = f"[o {user} enviou {len(paths)} arquivo(s) pelo {origin}, ja salvos nesta maquina:"
    return head + "\n" + "\n".join(lines) + "]\n\n" + (caption.strip() or NO_CAPTION)


def preview_line(text: str) -> str:
    found = parse_attachments(text) or unparsed_attachments(text)
    collapsed = " ".join(("📎 " + attachments_summary(found) if found else text).split())
    return collapsed if len(collapsed) <= PREVIEW_LIMIT else collapsed[:PREVIEW_LIMIT - 1].strip() + "…"


class SessionGone(Exception):
    pass


def _kill_tree(proc: asyncio.subprocess.Process) -> None:
    try:
        kill_process_tree(proc.pid)
    except (ProcessLookupError, PermissionError):
        with contextlib.suppress(ProcessLookupError):
            proc.kill()


class ClaudeProcess:
    def __init__(self, proc: asyncio.subprocess.Process):
        self.proc = proc
        self.stderr_tail = b""

    @classmethod
    async def spawn(cls, executable: str, args: list[str], cwd: str, env: dict[str, str]) -> ClaudeProcess:
        if sys.platform == "win32" and _is_batch(executable):
            raise ClaudeNotFound(CMD_REFUSAL)
        proc = await asyncio.create_subprocess_exec(
            executable, *args, cwd=cwd, env=env, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, **new_session_kwargs())
        return cls(proc)

    @property
    def alive(self) -> bool:
        return self.proc.returncode is None and self.proc.stdin is not None and not self.proc.stdin.is_closing()

    async def write(self, data: bytes) -> None:
        stdin = self.proc.stdin
        if not self.alive or stdin is None:
            raise SessionGone("a sessão com o claude não está rodando")
        try:
            stdin.write(data)
            await stdin.drain()
        except (BrokenPipeError, ConnectionResetError, OSError):
            raise SessionGone("a sessão com o claude não está rodando") from None

    async def lines(self):
        buffer = LineBuffer()
        stream = self.proc.stdout
        while stream is not None:
            chunk = await stream.read(65536)
            if not chunk:
                break
            for line in buffer.append(chunk):
                yield line
        rest = buffer.flush()
        if rest:
            yield rest

    async def drain_stderr(self) -> None:
        stream = self.proc.stderr
        while stream is not None:
            chunk = await stream.read(65536)
            if not chunk:
                return
            self.stderr_tail = (self.stderr_tail + chunk)[-STDERR_LIMIT:]

    async def close_input(self) -> None:
        stdin = self.proc.stdin
        if stdin is None:
            return
        with contextlib.suppress(BrokenPipeError, ConnectionResetError, OSError):
            await stdin.drain()
        with contextlib.suppress(Exception):
            stdin.close()

    def kill(self) -> None:
        with contextlib.suppress(Exception):
            if self.proc.stdin:
                self.proc.stdin.close()
        _kill_tree(self.proc)

    async def stop(self) -> None:
        with contextlib.suppress(Exception):
            if self.proc.stdin:
                self.proc.stdin.close()
        try:
            await asyncio.wait_for(self.proc.wait(), 3)
        except asyncio.TimeoutError:
            _kill_tree(self.proc)


@dataclass
class Delivery:
    id: str
    text: str
    user: str
    record: bool = True


class EngineFailed(Exception):
    pass


@dataclass
class TurnSpec:
    argv: list[str]
    cwd: str
    env: dict[str, str]
    stdin: bytes | None
    keep_stdin: bool
    decode: Any
    closing: Any


class ConversationSession:
    def __init__(self, conversation_id: str, host: Any):
        self.id = conversation_id.lower()
        self.host = host
        self.ledger = TurnLedger()
        self.permissions: dict[str, PermissionRequest] = {}
        self._proc: ClaudeProcess | None = None
        self._turn: ClaudeProcess | None = None
        self._generation = 0
        self._queue: deque[Delivery] = deque()
        self._wake = asyncio.Event()
        self._worker: asyncio.Task | None = None
        self._tasks: set[asyncio.Task] = set()
        self._prime: str | None = None
        self._rebuilt_from: str | None = None
        self._linked: set[str] = set()
        self._model: str | None = None
        self._kind: str | None = None
        self._session_mode: str | None = None
        self._forget_engine = False
        self._link_reason = "new"
        self._approval_noted = False
        record = host.store.get(self.id) or {}
        self._title_requested = bool(record.get("titleGenerated") or record.get("lastFrom"))
        self._first_user: str | None = None

    def submit(self, text: str, attachments: list[str]) -> None:
        prompt = compose_attachments(attachments, text) if attachments else text
        item = Delivery(uuid.uuid4().hex, prompt, text)
        self.ledger.submit(item.id, prompt, text, list(attachments))
        self._queue.append(item)
        if self._first_user is None:
            self._first_user = prompt
        self._record_submit(prompt)
        self._publish("status", state=protocol.STATE_THINKING)
        if self._worker is None or self._worker.done():
            self._worker = asyncio.get_running_loop().create_task(self._work())
        self._wake.set()

    async def answer(self, request_id: str, allow: bool, message: str | None, always: bool = False) -> None:
        request = self.permissions.get(request_id)
        if request is None:
            raise KeyError(request_id)
        line = permission_response_line(request, allow, message, always)
        writer = self._turn if self._turn is not None else self._proc
        if writer is None:
            raise SessionGone("a sessão com o claude não está rodando")
        await writer.write(line)
        self.permissions.pop(request_id, None)
        self.host.forget_permission(request_id)

    def stop(self) -> None:
        self._discard()
        self._publish("status", state=protocol.STATE_IDLE)

    async def close(self) -> None:
        proc = self._discard(kill=False)
        if proc:
            await proc.stop()
        if self._worker:
            self._worker.cancel()


    async def _work(self) -> None:
        while True:
            while not self._queue:
                self._wake.clear()
                await self._wake.wait()
            await self._deliver(self._queue.popleft())

    async def _deliver(self, item: Delivery) -> None:
        gen = self._generation
        try:
            kind, gen = await self._choose_engine(gen)
            if gen != self._generation:
                return
            if kind == "claude":
                await self._deliver_claude(item, gen)
            else:
                await self._deliver_turn(kind, item, gen)
        except asyncio.CancelledError:
            raise
        except (ClaudeNotFound, GuardsUnavailable, SessionGone, EngineFailed, OSError) as error:
            if gen == self._generation:
                self._fail(str(error) or error.__class__.__name__)
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            if gen == self._generation:
                self._fail(f"erro inesperado: {error.__class__.__name__}: {error}")

    async def _choose_engine(self, gen: int) -> tuple[str, int]:
        kind, note = await self.host.engine_choice(self)
        if gen != self._generation:
            return kind, gen
        if note and self._kind != "claude":
            self._publish("system", text=note)
        if self._proc is not None and self._proc.alive:
            if kind != "claude" and not self.ledger.in_flight_entries:
                self._restart_process()
                gen = self._generation
            elif kind != "claude":
                kind = "claude"
        self._kind = kind
        return kind, gen

    async def _deliver_claude(self, item: Delivery, gen: int) -> None:
        proc = await self._ensure_process()
        if gen != self._generation:
            return
        outgoing = prime(self._prime, item.text)
        self._prime = None
        if item.record:
            self._record_user(item.user)
        self.ledger.writing(item.id)
        try:
            await proc.write((json.dumps({"type": "user", "message": {"role": "user", "content": outgoing}},
                                         ensure_ascii=False) + "\n").encode("utf-8"))
        except SessionGone:
            if gen == self._generation:
                self.ledger.write_failed(item.id)
            raise
        if gen == self._generation and self.ledger.written(item.id) is not None:
            self._settle_if_idle()

    async def _deliver_turn(self, kind: str, item: Delivery, gen: int) -> None:
        plan = self._prepare_resume(kind)
        outgoing = prime(self._prime, item.text)
        spec = await (self._local_spec(outgoing) if kind == "local" else self._codex_spec(outgoing, plan))
        if gen != self._generation:
            return
        proc = await ClaudeProcess.spawn(spec.argv[0], spec.argv[1:], spec.cwd, spec.env)
        if gen != self._generation:
            proc.kill()
            return
        self._prime = None
        self._turn = proc
        self._spawn(proc.drain_stderr())
        if item.record:
            self._record_user(item.user)
        self.ledger.writing(item.id)
        try:
            if spec.stdin is not None:
                await proc.write(spec.stdin)
            if not spec.keep_stdin:
                await proc.close_input()
        except SessionGone:
            if gen == self._generation:
                self.ledger.write_failed(item.id)
            raise
        if gen != self._generation:
            return
        self.ledger.written(item.id)
        async for line in proc.lines():
            if gen != self._generation:
                return
            self._handle(spec.decode(line))
        code = await proc.proc.wait()
        await asyncio.sleep(0.05)
        if gen != self._generation:
            return
        self._turn = None
        self._handle(spec.closing(code, proc.stderr_tail.decode("utf-8", "replace")))
        await proc.close_input()
        if gen == self._generation and self.ledger.in_flight_entries:
            self._fail(f"{engines.DISPLAY[kind]} encerrou sem concluir o turno")

    async def _local_spec(self, outgoing: str) -> TurnSpec:
        from wisp.serve.engines import local as engines_local
        wisp = await asyncio.to_thread(guards.wisp_binary)
        if not wisp:
            raise GuardsUnavailable(engines_local.NO_BINARY)
        if engines_local.too_large(outgoing):
            raise EngineFailed(engines_local.TOO_LARGE)
        record = self.host.store.get(self.id) or {}
        mode = guards.permission_mode(self.host.store.directory) or "default"
        env = dict(os.environ)
        env["WISP_BIN"] = wisp
        seen: dict[str, Any] = {"result": False, "error": None}

        def decode(line: str) -> list[Event]:
            try:
                obj = json.loads(line)
            except ValueError:
                obj = None
            if isinstance(obj, dict) and obj.get("type") == "error" and isinstance(obj.get("message"), str):
                seen["error"] = obj["message"]
            events = decode_line(line)
            seen["result"] = seen["result"] or any(e.kind == "result" for e in events)
            return events

        def closing(code: int, tail: str) -> list[Event]:
            if seen["result"]:
                return []
            detail = seen["error"] or tail.strip() or f"a IA local terminou sem concluir o turno (código {code})"
            return [Event("result", {"session_id": "", "text": detail, "is_error": True, "denials": [], "usage": {}})]

        return TurnSpec([wisp, *engines_local.arguments(outgoing, self._key(record), mode)],
                        str(self.host.workspace), env, None, True, decode, closing)

    async def _codex_spec(self, outgoing: str, plan: ResumePlan) -> TurnSpec:
        from wisp.serve.engines import codex
        record = self.host.store.get(self.id) or {}
        wisp = await asyncio.to_thread(guards.wisp_binary)
        if not wisp:
            raise EngineFailed(f"codex encerrou (código -1): {codex.NO_WISP_BINARY}")
        wisp_dir = str(self.host.workspace)
        root = codex.workspace(record.get("cwd"), wisp_dir)
        if root is None:
            raise GuardsUnavailable(codex.NO_WORKSPACE)
        try:
            executable = await asyncio.to_thread(codex.locate_codex, None)
            prefix = await asyncio.to_thread(codex.launch_prefix, executable)
        except codex.CodexNotFound as error:
            raise EngineFailed(str(error)) from None
        env = codex.environment(executable, {}, wisp)
        problem, owned = await asyncio.to_thread(codex.preflight, wisp, env, root)
        if problem:
            raise EngineFailed(f"codex encerrou (código -1): {problem}")
        mode = guards.permission_mode(self.host.store.directory)
        soul = await asyncio.to_thread(guards.soul_text, "codex")
        add_dirs = codex.extra_directories(root, [wisp_dir, *self._brain_dirs()])
        arguments = codex.arguments(root, mode, add_dirs, guards.instructions(soul, extra=guards.CODEX_NOTE), wisp,
                                    plan.resume, owned)
        if not self._approval_noted and sys.platform != "darwin":
            self._approval_noted = True
            self._publish("system", text=("não consegui abrir o canal de aprovação do e-mail; nesta conversa o Codex "
                                          f"não envia e-mails ({codex.NO_APPROVAL_CHANNEL})"))
        decoder = codex.CodexDecoder(codex.configured_model(), resumed=plan.resume is not None)
        return TurnSpec([*prefix, *arguments], root, env, outgoing.encode("utf-8"), False, decoder.decode,
                        lambda code, tail: decoder.closing(code, tail))

    def _brain_dirs(self) -> list[str]:
        try:
            from wisp.config import load_config
            from wisp.layout import layout_of
            return [str(layout_of(load_config(), Path.home()).brain)]
        except Exception:
            return []

    def _prepare_resume(self, kind: str) -> ResumePlan:
        record = self.host.store.get(self.id) or {}
        key = self._key(record)
        transcripts = self.host.transcripts
        plan = plan_resume(kind, transcripts.last_engine(key), record.get("sessionId"),
                           transcripts.engine_session(key, "codex"), lost=self._forget_engine)
        self._forget_engine = False
        self._link_reason = plan.link_reason
        if plan.switched and not plan.prime and kind == "local":
            self._switched_note(kind)
        if plan.prime and self._prime is None:
            self._prime = transcripts.context(key)
        if plan.switched and plan.prime and self._prime is not None:
            self._switched_note(kind)
        if plan.drop_claude_session:
            self._rebuilt_from = record.get("sessionId") or key
            self._set_record(sessionId=None)
        elif record.get("sessionId"):
            self._linked.add(record["sessionId"])
        return plan

    def _switched_note(self, kind: str) -> None:
        self._publish("system", text=f"↻ agora quem responde é o {engines.DISPLAY[kind]}; ele retomou pela conversa "
                                     "guardada no Wisp.")

    def _restart_process(self) -> None:
        self._generation += 1
        self.ledger.process_restarted()
        self._prime = None
        for request_id in list(self.permissions):
            self.host.forget_permission(request_id)
        self.permissions.clear()
        proc, self._proc = self._proc, None
        if proc:
            proc.kill()

    def _fail(self, message: str) -> None:
        self._discard()
        self._publish("error", message=message)
        self._publish("status", state=protocol.STATE_ERROR)

    def _settle_if_idle(self) -> None:
        if self.ledger.pending == 0:
            self._publish("status", state=protocol.STATE_IDLE)

    def _discard(self, kill: bool = True) -> ClaudeProcess | None:
        self._generation += 1
        self._queue.clear()
        self.ledger.reset()
        self._prime = None
        for request_id in list(self.permissions):
            self.host.forget_permission(request_id)
        self.permissions.clear()
        proc, self._proc = self._proc, None
        turn, self._turn = self._turn, None
        if turn and kill:
            turn.kill()
        if proc and kill:
            proc.kill()
        return proc

    async def _ensure_process(self) -> ClaudeProcess:
        if self._proc is not None and self._proc.alive:
            return self._proc
        gen = self._generation
        executable = await asyncio.to_thread(self.host.claude_path)
        record = self.host.store.get(self.id) or {}
        plan = self._prepare_resume("claude")
        cwd = record.get("cwd")
        workdir = Path(cwd) if cwd and Path(cwd).is_dir() else self.host.workspace
        workdir.mkdir(parents=True, exist_ok=True)
        launch = await asyncio.to_thread(guards.prepare, self.host.store.directory)
        self._session_mode = launch.permission_mode
        env = await asyncio.to_thread(child_environment, executable)
        env.update(launch.environment)
        arguments = claude_arguments(model=guards.profile_text("model"), resume=plan.resume, permission_mode=launch.permission_mode,
                                     append_system_prompt=launch.append_system_prompt, settings=launch.settings,
                                     disallowed_tools=launch.disallowed_tools)
        program, *lead = await asyncio.to_thread(resolve_launch, executable)
        proc = await ClaudeProcess.spawn(program, [*lead, *arguments], str(workdir), env)
        if gen != self._generation:
            proc.kill()
            raise SessionGone("a sessão foi encerrada")
        self._proc = proc
        self._spawn(self._read(proc, gen))
        self._spawn(proc.drain_stderr())
        return proc

    def _spawn(self, coroutine) -> None:
        task = asyncio.get_running_loop().create_task(coroutine)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)


    async def _read(self, proc: ClaudeProcess, gen: int) -> None:
        async for line in proc.lines():
            if gen != self._generation:
                return
            self._handle(decode_line(line))
        code = await proc.proc.wait()
        await asyncio.sleep(0.05)
        if gen != self._generation:
            return
        self._exited(code, proc.stderr_tail.decode("utf-8", "replace").strip())

    def _exited(self, code: int, tail: str) -> None:
        had_work = self.ledger.pending > 0
        self._proc = None
        self.ledger.reset()
        self._queue.clear()
        for request_id in list(self.permissions):
            self.host.forget_permission(request_id)
        self.permissions.clear()
        if had_work or code != 0:
            self._publish("error", message=f"claude encerrou (código {code})" + (f": {tail}" if tail else ""))
            self._publish("status", state=protocol.STATE_ERROR)

    def _handle(self, events: list[Event]) -> None:
        prefix = self.host.status_prefix()
        blocks = [{"type": "text", "text": reply_split(e.data["text"], prefix)[0]} if e.kind == "text" else
                  {"type": "tool_use", "id": e.data["id"], "name": e.data["name"], "input": e.data["input"]}
                  for e in events if e.kind in ("text", "tool_use") and (e.kind != "text" or e.data["text"].strip())]
        blocks = [b for b in blocks if b["type"] != "text" or b["text"].strip()]
        if blocks:
            self._publish("assistant_message", message={"role": "assistant", "blocks": blocks})
        for event in events:
            data = event.data
            if event.kind == "initialized":
                self._initialized(data["session_id"], data["model"])
            elif event.kind == "text_delta":
                self._publish("text_delta", text=data["text"])
            elif event.kind == "tool_use":
                self._publish("tool_use", id=data["id"], name=data["name"], input=data["input"])
            elif event.kind == "tool_result":
                self._publish("tool_result", tool_use_id=data["tool_use_id"], content=data["text"],
                              is_error=data["is_error"])
            elif event.kind == "permission_request":
                request: PermissionRequest = data["request"]
                self.permissions[request.request_id] = request
                self.host.register_permission(request.request_id, self)
                self._publish("permission_request", request_id=request.request_id, tool_name=request.tool_name,
                              input=request.input, **request.card())
            elif event.kind == "permission_cancelled":
                self.permissions.pop(data["id"], None)
                self.host.forget_permission(data["id"])
            elif event.kind == "permission_mode":
                self._reported_mode(data["mode"])
            elif event.kind == "engine_session":
                self._link_engine_session(data["engine"], data["id"])
            elif event.kind == "usage":
                windows = usage_windows(data["info"])
                if windows["five_hour"] or windows["seven_day"]:
                    self.host.rate_limit = windows
                    self._publish("usage", **windows)
            elif event.kind == "user_replayed":
                self.ledger.consumed()
            elif event.kind == "result":
                self._result(data)
                return

    def _result(self, data: dict[str, Any]) -> None:
        text, is_error, session = data["text"], data["is_error"], data["session_id"]
        if is_error and is_lost_session(text) and self._rebuild_after_lost():
            return
        self.ledger.result(is_error=is_error, engine=self._kind or "claude")
        if session:
            self._link_session(session)
            self._set_record(sessionId=session)
        body, status = reply_split(text, self.host.status_prefix()) if not is_error else (text, None)
        if not is_error and body.strip():
            self._record_assistant(body)
            self._maybe_title(body)
        self._publish("result", usage=data["usage"], text=body, is_error=is_error, session_id=session, status=status)
        if is_error:
            self._publish("error", message=text or "erro")
        if self.ledger.pending == 0:
            self._publish("status", state=protocol.STATE_ERROR if is_error else protocol.STATE_IDLE)

    def _reported_mode(self, mode: str) -> None:
        if self._session_mode == "auto" and mode != "auto":
            self._publish("system", text=f"o modo Automático não está disponível nesta conta; esta conversa roda no modo {mode}")

    def _maybe_title(self, reply: str) -> None:
        first = self._first_user
        if self._title_requested or first is None or not reply.strip():
            return
        self._title_requested = True
        if self._kind == "local":
            return
        found = parse_attachments(first)
        user = attachments_summary(found) if found else first
        self._spawn(self._generate_title(user, reply))

    async def _generate_title(self, user: str, reply: str) -> None:
        title = await self.host.generate_title(user, reply)
        record = self.host.store.get(self.id)
        if not title or record is None or record.get("titleGenerated") or self.host.sessions.get(self.id) is not self:
            return
        self._set_record(title=title, titleGenerated=True)
        self._publish("title", title=title)

    def _rebuild_after_lost(self) -> bool:
        pending = self.ledger.in_flight_entries
        record = self.host.store.get(self.id) or {}
        key = self._key(record)
        lost = record.get("sessionId") or (self.host.transcripts.engine_session(key, "codex")
                                           if self._kind == "codex" else None)
        memory = self.host.transcripts.context(key, drop_trailing_users=len(pending)) if pending else None
        if not pending or not lost or memory is None:
            return False
        redo = [Delivery(e.id, e.text, e.user, record=False) for e in pending]
        self.ledger.requeue_in_flight()
        queued = list(self._queue)
        self._queue.clear()
        self._generation += 1
        proc, self._proc = self._proc, None
        turn, self._turn = self._turn, None
        for old in (proc, turn):
            if old:
                old.kill()
        kind = self._kind or "claude"
        if kind == "claude":
            self._set_record(sessionId=None)
            self._rebuilt_from = lost
        else:
            self._forget_engine = True
        self._prime = memory
        self._publish("system", text=f"↻ a sessão do {engines.DISPLAY[kind]} não estava aqui; retomei pela conversa "
                                     "guardada no Wisp.")
        self._queue.extend(redo + queued)
        self._publish("status", state=protocol.STATE_THINKING)
        self._wake.set()
        return True


    def _publish(self, type_: str, **fields: Any) -> None:
        self.host.publish(self.id, type_, **fields)

    def _key(self, record: dict) -> str:
        transcripts = self.host.transcripts
        if (transcripts.folder / f"{self.id}.jsonl").exists():
            return self.id
        return transcripts.find(record.get("sessionId")) or self.id

    def _set_record(self, **fields: Any) -> None:
        def apply(record: dict) -> None:
            for key, value in fields.items():
                if value is None:
                    record.pop(key, None)
                else:
                    record[key] = value
            record["updatedAt"] = datetime.now(timezone.utc)

        self.host.store.update(self.id, apply)

    def _record_submit(self, text: str) -> None:
        workspace = str(self.host.workspace)

        def apply(record: dict) -> None:
            first = not record.get("lastFrom") and not record.get("lastPreview")
            found = parse_attachments(text)
            if first and not record.get("titleGenerated") and record.get("title") in (None, protocol.DEFAULT_TITLE):
                record["title"] = title_fallback(attachments_summary(found) if found else text) or protocol.DEFAULT_TITLE
            record.setdefault("cwd", workspace)
            record["lastPreview"] = preview_line(text)
            record["lastFrom"] = "user"
            record["updatedAt"] = datetime.now(timezone.utc)

        self.host.store.update(self.id, apply)

    def _initialized(self, session_id: str, model: str) -> None:
        if model:
            self._model = model
        if session_id:
            self._set_record(sessionId=session_id)
            self._link_session(session_id)

    def _link_session(self, session_id: str) -> None:
        transcripts = self.host.transcripts
        key = self._key(self.host.store.get(self.id) or {})
        if not session_id or session_id in self._linked or not (transcripts.folder / f"{key}.jsonl").exists():
            return
        self._linked.add(session_id)
        reason = "rebuilt" if self._rebuilt_from else "new"
        self._rebuilt_from = None
        if session_id != key:
            self._safely(lambda: transcripts.link(session_id, key, "claude", reason))

    def _link_engine_session(self, engine: str, session_id: str) -> None:
        transcripts = self.host.transcripts
        key = self._key(self.host.store.get(self.id) or {})
        if not session_id or session_id in self._linked or not (transcripts.folder / f"{key}.jsonl").exists():
            return
        self._linked.add(session_id)
        reason, self._link_reason = self._link_reason, "new"
        self._safely(lambda: transcripts.link(session_id, key, engine, reason))

    def _record_user(self, text: str) -> None:
        record = self.host.store.get(self.id) or {}
        key = self._key(record)
        self._safely(lambda: self.host.transcripts.append_user(key, record.get("sessionId"), text, "app"))

    def _record_assistant(self, text: str) -> None:
        record = self.host.store.get(self.id) or {}
        key = self._key(record)
        engine = self._kind or "claude"
        self._safely(lambda: self.host.transcripts.append_assistant(key, record.get("sessionId"), text, "app",
                                                                    engine, self._model))
        self._set_record(lastPreview=preview_line(text), lastFrom="agent")

    def _safely(self, write) -> None:
        try:
            write()
        except (OSError, ValueError) as error:
            self._publish("error", message=f"não consegui guardar a conversa na pasta do Wisp: {error}")


__all__ = ["ClaudeNotFound", "ConversationSession", "EngineFailed", "Event", "PermissionRequest", "SessionGone",
           "TurnLedger", "usage_windows",
           "GuardsUnavailable", "claude_arguments", "decode_line", "locate_claude", "resolve_launch", "permission_response_line",
           "plan_resume"]
