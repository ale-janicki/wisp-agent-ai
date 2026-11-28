from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from wisp.serve.claude_session import ClaudeNotFound, Event, _run_shell, _usable, resolve_launch
from wisp.serve.engines import DISPLAY
from wisp.serve.engines.process import run_command

SUMMARY_LIMIT = 80
INCOMPLETE = "o Codex terminou sem concluir o turno"
LOST_SESSION = "codex session not found: the saved conversation will be replayed"
PROJECT_UNCHECKED = "não consegui conferir as configurações do Codex desta pasta"
NO_WISP_BINARY = "não achei o CLI do Wisp; o Codex não roda sem a trava de aprovação do e-mail"
NO_APPROVAL_CHANNEL = "o canal de aprovação do e-mail só existe no Mac do Wisp"
NO_WORKSPACE = ("o Codex não tem uma pasta de trabalho segura neste computador (a pasta do Wisp é a pasta pessoal ou "
                "fica acima dela); esta conversa roda no Claude")
EMAIL_SERVER, BRAIN_SERVER, MAC_SERVER = "wisp-email", "wisp-brain", "wisp-mac"
MAC_READ_ONLY_TOOLS = ("mac_apps", "mac_battery", "mac_dnd_status", "mac_screenshot", "mac_shortcuts_list",
                       "mac_ui_tree", "mac_wifi", "mac_windows")
MAC_ALL_TOOLS = ("mac_app", "mac_apps", "mac_battery", "mac_brightness", "mac_dark_mode", "mac_dnd_status", "mac_media",
                 "mac_notify", "mac_open", "mac_open_url", "mac_screenshot", "mac_script", "mac_send", "mac_settings_pane",
                 "mac_shortcut", "mac_shortcuts_list", "mac_ui_click", "mac_ui_key", "mac_ui_menu", "mac_ui_scroll",
                 "mac_ui_tree", "mac_ui_type", "mac_volume", "mac_wifi", "mac_windows")


class CodexNotFound(Exception):
    pass


def locate_codex(configured: str | None = None, env=None, platform: str | None = None, home: str | None = None) -> str:
    env = os.environ if env is None else env
    platform = platform or sys.platform
    home = home or os.path.expanduser("~")
    if configured:
        path = os.path.expanduser(configured)
        if not _usable(path, platform):
            raise CodexNotFound(f"o codex configurado ({path}) não existe ou não é executável")
        return path
    names = ["codex.exe", "codex.cmd", "codex.bat"] if platform == "win32" else ["codex"]
    for folder in filter(None, env.get("PATH", "").split(";" if platform == "win32" else ":")):
        for name in names:
            if _usable(os.path.join(folder, name), platform):
                return os.path.join(folder, name)
    if platform == "darwin":
        found = _run_shell("command -v codex")
        if found and found.startswith("/") and _usable(found, platform):
            return found
    if platform == "win32":
        candidates = [os.path.join(home, ".local", "bin", "codex.exe"), os.path.join(home, ".bun", "bin", "codex.exe")]
        if env.get("USERPROFILE"):
            candidates.append(os.path.join(env["USERPROFILE"], ".local", "bin", "codex.exe"))
        if env.get("APPDATA"):
            candidates.append(os.path.join(env["APPDATA"], "npm", "codex.cmd"))
    else:
        candidates = [os.path.join(home, ".local", "bin", "codex"), os.path.join(home, ".npm-global", "bin", "codex"),
                      os.path.join(home, ".bun", "bin", "codex")]
        if platform == "darwin":
            candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    for path in candidates:
        if _usable(path, platform):
            return path
    raise CodexNotFound("Codex não encontrado")


def launch_prefix(executable: str, platform: str | None = None, **hooks) -> list[str]:
    try:
        return resolve_launch(executable, platform, **hooks)
    except ClaudeNotFound as error:
        raise CodexNotFound(str(error).replace("Claude Code", "Codex").replace("claude.exe", "codex.exe")) from None


def sandbox_arguments(permission: str | None) -> list[str]:
    return ["--sandbox", "workspace-write" if permission in ("auto", "bypassPermissions") else "read-only"]


def changes_allowed(permission: str | None) -> bool:
    return permission in ("auto", "bypassPermissions")


def _same(a: str, b: str) -> bool:
    return os.path.normcase(a) == os.path.normcase(b)


def _is_root(path: str) -> bool:
    return os.path.dirname(path) == path


def safe_directory(raw: str | None, home: str | None = None) -> str | None:
    if not raw or not raw.strip():
        return None
    home_path = os.path.realpath(home or os.path.expanduser("~"))
    path = os.path.realpath(os.path.expanduser(raw))
    if not os.path.isdir(path) or _is_root(path) or _same(path, home_path):
        return None
    prefix = os.path.normcase(path).rstrip("/\\") + os.sep
    if os.path.normcase(home_path).startswith(prefix):
        return None
    return path


def workspace(preferred: str | None, wisp_dir: str, home: str | None = None) -> str | None:
    return safe_directory(preferred, home) or safe_directory(wisp_dir, home)


def extra_directories(root: str, candidates: list[str], home: str | None = None) -> list[str]:
    base = os.path.realpath(root)
    out: list[str] = []
    for candidate in candidates:
        path = safe_directory(candidate, home)
        if path is None or _same(path, base) or os.path.normcase(path).startswith(os.path.normcase(base) + os.sep) \
                or path in out:
            continue
        out.append(path)
    return out


def configured_model(home: str | None = None, env=None) -> str:
    env = os.environ if env is None else env
    codex_home = Path(os.path.expanduser(env["CODEX_HOME"])) if env.get("CODEX_HOME") else \
        Path(home or os.path.expanduser("~")) / ".codex"
    try:
        import tomllib
        value = tomllib.loads((codex_home / "config.toml").read_text("utf-8")).get("model")
    except (OSError, ValueError):
        return ""
    return value if isinstance(value, str) else ""


def toml_string(text: str) -> str:
    out = ['"']
    for char in text:
        if char == '"':
            out.append('\\"')
        elif char == "\\":
            out.append("\\\\")
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif ord(char) < 0x20 or ord(char) == 0x7F:
            out.append(f"\\u{ord(char):04X}")
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def mcp_overrides(wisp_binary: str, owned: set[str] | frozenset[str] = frozenset(), allow_changes: bool = True,
                  platform: str | None = None, socket_variable: str = "WISP_APPROVAL_SOCKET") -> list[str]:
    platform = platform or sys.platform

    def fields(server: str, env: str, timeout: str = "660", tools: str | None = None) -> list[tuple[str, str]]:
        return [("command", toml_string(wisp_binary)), ("args", f'["mcp", "{server}"]'), ("env_vars", env),
                ("default_tools_approval_mode", '"approve"'), ("startup_timeout_sec", "30"),
                ("tool_timeout_sec", timeout)] + ([("enabled_tools", tools)] if tools else []) + [("enabled", "true")]

    def lines(name: str, entries: list[tuple[str, str]]) -> list[str]:
        return [f"mcp_servers.{name}.{key}={value}" for key, value in entries]

    brain_env = ["WISP_CONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME"]
    if platform == "win32":
        brain_env += ["APPDATA", "LOCALAPPDATA", "USERPROFILE"]
    out = lines(EMAIL_SERVER, fields("email", json.dumps(["WISP_TELEGRAM_THREAD", socket_variable])))
    if BRAIN_SERVER not in owned:
        out += lines(BRAIN_SERVER, fields("brain", json.dumps(brain_env), timeout="60"))
    if MAC_SERVER not in owned and platform == "darwin":
        tools = json.dumps(list(MAC_ALL_TOOLS if allow_changes else MAC_READ_ONLY_TOOLS))
        out += lines(MAC_SERVER, fields("mac", json.dumps(["WISP_TELEGRAM_THREAD", socket_variable]), tools=tools))
    return out


def environment(executable: str, overrides: dict[str, str] | None = None, wisp_binary: str | None = None,
                base: dict[str, str] | None = None, platform: str | None = None) -> dict[str, str]:
    platform = platform or sys.platform
    env = dict(os.environ if base is None else base)
    separator = ";" if platform == "win32" else ":"
    folder = os.path.dirname(executable)
    current = env.get("PATH") or ("" if platform == "win32" else "/usr/bin:/bin")
    if platform == "darwin":
        from wisp.serve.claude_session import login_shell_path
        login = login_shell_path()
        env["PATH"] = login if login else current + ":" + folder + ":/opt/homebrew/bin:/usr/local/bin"
    elif folder and folder not in current.split(separator):
        env["PATH"] = (current + separator + folder).strip(separator)
    env.update(overrides or {})
    if wisp_binary:
        env["WISP_BIN"] = wisp_binary
    return env


def arguments(root: str, permission: str | None, add_dirs: list[str] = (), instructions: str = "",
              wisp_binary: str = "", resume: str | None = None, owned: set[str] = frozenset(),
              platform: str | None = None) -> list[str]:
    args = ["exec", "--json", "--skip-git-repo-check", "-C", root, *sandbox_arguments(permission)]
    for directory in add_dirs:
        args += ["--add-dir", directory]
    if instructions:
        args += ["-c", f"developer_instructions={toml_string(instructions)}"]
    for override in mcp_overrides(wisp_binary, owned, changes_allowed(permission), platform):
        args += ["-c", override]
    if resume:
        args += ["resume", resume]
    return args + ["-"]


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ""


class CodexDecoder:
    def __init__(self, model: str = "", resumed: bool = False):
        self.model = model
        self.resumed = resumed
        self.thread_id: str | None = None
        self.turn_started = False
        self.finished = False
        self._last = ""
        self._failure: str | None = None

    def decode(self, line: str) -> list[Event]:
        try:
            obj = json.loads(line)
        except ValueError:
            return [Event("malformed", {"line": line})]
        kind = obj.get("type") if isinstance(obj, dict) else None
        if not isinstance(kind, str):
            return [Event("malformed", {"line": line})]
        item = obj.get("item") if isinstance(obj.get("item"), dict) else {}
        if kind == "thread.started":
            thread = obj.get("thread_id")
            if not isinstance(thread, str) or not thread:
                return [Event("ignored", {"type": kind})]
            self.thread_id = thread
            return [Event("initialized", {"session_id": "", "model": self.model, "subscription": True}),
                    Event("engine_session", {"engine": "codex", "id": thread})]
        if kind == "turn.started":
            self.turn_started = True
            return [Event("thinking")]
        if kind == "turn.completed":
            self.finished = True
            return [self._result(self._last, False)]
        if kind == "turn.failed":
            self.finished = True
            error = obj.get("error") if isinstance(obj.get("error"), dict) else {}
            return [self._result(_text(error.get("message")) or self._failure or "o Codex falhou", True)]
        if kind == "error":
            self._failure = _text(obj.get("message")) or self._failure
            return [Event("ignored", {"type": kind})]
        if kind == "item.started":
            return self._started(item)
        if kind == "item.completed":
            return self._completed(item)
        return [Event("ignored", {"type": kind})]

    @staticmethod
    def _result(text: str, is_error: bool) -> Event:
        return Event("result", {"session_id": "", "text": text, "is_error": is_error, "denials": [], "usage": {}})

    def closing(self, code: int, stderr_tail: str) -> list[Event]:
        if self.finished:
            return []
        tail = stderr_tail.strip()
        if code == 0:
            return [self._result(INCOMPLETE, True)]
        if self.resumed and not self.turn_started and not _looks_like_login(tail + (self._failure or "")):
            return [self._result(LOST_SESSION, True)]
        detail = self._failure or tail
        hint = "\nConserto: rodar `codex login` no Terminal." if _looks_like_login(detail) else ""
        head = f"codex saiu com código {code}"
        return [self._result(f"{head}: {detail}{hint}" if detail else head, True)]

    @staticmethod
    def _use(item_id: str, name: str, tool_input: dict, summary: str) -> Event:
        return Event("tool_use", {"id": item_id, "name": name, "input": tool_input, "summary": summary[:SUMMARY_LIMIT]})

    def _started(self, item: dict) -> list[Event]:
        item_id, kind = _text(item.get("id")), item.get("type")
        if kind == "command_execution":
            command = _text(item.get("command"))
            return [self._use(item_id, "Bash", {"command": command}, command)]
        if kind == "mcp_tool_call":
            arguments = item.get("arguments") if isinstance(item.get("arguments"), dict) else {}
            return [self._use(item_id, f"{_text(item.get('server')) or 'mcp'}.{_text(item.get('tool'))}", arguments, "")]
        if kind == "web_search":
            query = _text(item.get("query"))
            return [self._use(item_id, "WebSearch", {"query": query}, query)]
        return [Event("ignored", {"type": f"item.started.{kind if isinstance(kind, str) else ''}"})]

    def _completed(self, item: dict) -> list[Event]:
        item_id, kind = _text(item.get("id")), item.get("type")
        if kind == "agent_message":
            text = _text(item.get("text"))
            if not text:
                return []
            self._last = text
            return [Event("text", {"text": text})]
        if kind == "reasoning":
            return [Event("thinking")]
        if kind == "command_execution":
            code = item.get("exit_code")
            failed = item.get("status") in ("failed", "declined") or (isinstance(code, int) and code != 0)
            return [Event("tool_result", {"tool_use_id": item_id, "is_error": failed,
                                          "text": _text(item.get("aggregated_output"))})]
        if kind == "mcp_tool_call":
            error = item.get("error") if isinstance(item.get("error"), dict) else {}
            return [Event("tool_result", {"tool_use_id": item_id, "is_error": item.get("status") == "failed",
                                          "text": _text(error.get("message"))})]
        if kind == "file_change":
            changes = item.get("changes") if isinstance(item.get("changes"), list) else []
            first = changes[0] if changes and isinstance(changes[0], dict) else {}
            path = _text(first.get("path"))
            return [self._use(item_id, "Edit", {"file_path": path}, path),
                    Event("tool_result", {"tool_use_id": item_id, "is_error": False, "text": ""})]
        return [Event("ignored", {"type": f"item.completed.{kind if isinstance(kind, str) else ''}"})]


def _looks_like_login(text: str) -> bool:
    lowered = text.lower()
    return any(marker in lowered for marker in ("not logged in", "codex login", "401", "unauthorized", "authentication"))


@dataclass
class Readiness:
    installed: bool
    logged_in: bool
    send_gate_ok: bool = True
    project_problem: str | None = None
    owned: set[str] = field(default_factory=set)

    @property
    def ready(self) -> bool:
        return self.installed and self.logged_in and self.send_gate_ok and self.project_problem is None

    def note(self, kind: str = "codex") -> str:
        name = DISPLAY[kind]
        if self.installed and self.logged_in and self.send_gate_ok and self.project_problem:
            return f"o {name} não roda aqui: {self.project_problem}; esta conversa roda no Claude"
        if self.installed and self.logged_in and not self.send_gate_ok:
            return (f"o {name} está com o envio de e-mail sem a trava de aprovação; rode `wisp harness sync`; "
                    "esta conversa roda no Claude")
        if self.installed:
            return f"o {name} não está com o login feito neste computador; esta conversa roda no Claude"
        return f"o {name} não está instalado neste computador; esta conversa roda no Claude"


def _verdict(wisp_binary: str | None, env: dict[str, str], extra: list[str]) -> dict | None:
    if not wisp_binary:
        return None
    ran = run_command([wisp_binary, "codex", "check", *extra], env, 15)
    if ran.timed_out or not ran.started:
        return None
    try:
        verdict = json.loads(ran.stdout)
    except ValueError:
        return None
    return verdict if isinstance(verdict, dict) and isinstance(verdict.get("ready"), bool) else None


def send_gate(wisp_binary: str | None, env: dict[str, str]) -> bool:
    verdict = _verdict(wisp_binary, env, [])
    return bool(verdict and verdict["ready"] is True)


def preflight(wisp_binary: str | None, env: dict[str, str], root: str) -> tuple[str | None, set[str]]:
    verdict = _verdict(wisp_binary, env, ["--workspace", root])
    if verdict is None:
        return PROJECT_UNCHECKED, set()
    owned = verdict.get("owned")
    project = verdict.get("project")
    return (project if isinstance(project, str) and project else None,
            {o for o in owned if isinstance(o, str)} if isinstance(owned, list) else set())


def check(configured: str | None, wisp_binary: str | None, env: dict[str, str] | None = None,
          root: str | None = None) -> Readiness:
    try:
        executable = locate_codex(configured)
        prefix = launch_prefix(executable)
    except CodexNotFound:
        return Readiness(False, False)
    launch_env = environment(executable, env or {})
    ran = run_command([*prefix, "login", "status"], launch_env, 10)
    if ran.timed_out or ran.status != 0:
        return Readiness(True, False)
    problem, owned = preflight(wisp_binary, launch_env, root) if root else (None, set())
    return Readiness(True, True, send_gate(wisp_binary, launch_env), problem, owned)
