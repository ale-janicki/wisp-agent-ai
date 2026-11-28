import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse

from wisp.jobs import JobSpec, JobState
from wisp.jobs.taskscheduler import NOT_FAILURES, TaskInfo, TaskSchedulerJobs
from wisp.paths import WispPaths
from wisp.runner import Runner, SubprocessRunner

from . import store

LOG_LINES = 50
LOG_BYTES = 64 * 1024
FILE_LIMIT = 5_000_000
CLAUDE_CONFIG_LIMIT = 50_000_000
HOOK_TITLE_LIMIT = 60
COMMENT_BYTES = 4096
VERSION_TIMEOUT = 2
MAX_PARALLEL = 4
SAFE_ID = re.compile(r"^[\w.@:+/\\ -]+$")
HOOK_EVENTS = [
    ("SessionStart", "Início da sessão"), ("UserPromptSubmit", "Ao enviar mensagem"), ("PreToolUse", "Antes de cada ferramenta"),
    ("PostToolUse", "Depois de cada ferramenta"), ("Stop", "Fim do turno"), ("SessionEnd", "Fim da sessão"),
]
WINDOWS = sys.platform == "win32"
COMMAND_SUFFIXES = {".exe", ".cmd", ".bat", ".ps1", ".com", ".py", ".sh"}


def runner() -> Runner:
    return SubprocessRunner()


def task_manager() -> TaskSchedulerJobs:
    return TaskSchedulerJobs(WispPaths.current(), runner())


def _expand(path: str) -> str:
    return os.path.expandvars(os.path.expanduser(path))


def _block(name: str) -> dict:
    found = store.blocks().get(name)
    return found if isinstance(found, dict) else {}


def _registry(path: str) -> list[dict]:
    try:
        data = json.loads(Path(_expand(path)).read_text("utf-8"))
        jobs = data["jobs"]
        if not isinstance(jobs, list) or not all(isinstance(j, dict) and isinstance(j.get("label"), str) and j["label"] for j in jobs):
            raise ValueError
    except OSError:
        raise ValueError(f"não consegui ler {path}") from None
    except (ValueError, KeyError, TypeError):
        raise ValueError('o registro de rotinas não está no formato {"jobs": [...]}') from None
    return jobs


def _summary(task: TaskInfo | None) -> str:
    if task is None:
        return "tarefa não instalada"
    if not task.enabled:
        return "desligado"
    parts = ["rodando" if task.state == JobState.RUNNING else "aguardando"]
    if task.last_result not in NOT_FAILURES or (task.last_result == 0 and task.state != JobState.RUNNING):
        parts.append(f"saída {task.last_result}")
    return " · ".join(parts)


def _state_word(task: TaskInfo | None) -> str:
    if task is None:
        return "missing"
    if not task.enabled:
        return "unloaded"
    return "running" if task.state == JobState.RUNNING else ("failed" if task.state == JobState.FAILED else "waiting")


def routines() -> dict:
    block = _block("routines")
    prefixes = [p for p in block.get("prefixes") or [] if isinstance(p, str) and p]
    registry_path = block.get("registry") if isinstance(block.get("registry"), str) else None
    if not registry_path and not prefixes:
        return {"available": False, "rows": [], "running": 0}
    try:
        registered = _registry(registry_path) if registry_path else []
    except ValueError as error:
        return {"available": True, "rows": [], "running": 0, "error": f"Não consegui ler as rotinas: {error}"}
    tasks = {t.label: t for t in task_manager().list_tasks(prefixes, tuple(j["label"] for j in registered))}
    order = [j["label"] for j in registered] + [label for label in tasks if label not in {j["label"] for j in registered}]
    known = {j["label"]: j for j in registered}
    rows = []
    for label in order:
        entry, task = known.get(label, {}), tasks.get(label)
        logs = [_expand(p) for p in entry.get("logs") or [] if isinstance(p, str)] or (task.logs if task else [])
        rows.append({
            "label": label,
            "name": entry.get("name") or label.split(".")[-1] or label,
            "description": entry.get("description") or (task.schedule if task else None),
            "summary": _summary(task), "state": _state_word(task), "installed": task is not None,
            "logs": logs, "always_on": bool(task and task.schedule == "sempre ligado"),
        })
    return {"available": True, "rows": rows, "running": sum(1 for r in rows if r["state"] == "running")}


def toggle_routine(label: str, on: bool) -> dict:
    row = next((r for r in routines()["rows"] if r["label"] == label and r["installed"]), None)
    if row is None:
        return {"ok": False, "error": "Essa rotina não está instalada."}
    details = task_manager().set_enabled(label, on, run=row["always_on"])
    wanted = [d for d in details if " /Change " in f" {d.command} " or " /Run " in f" {d.command} "]
    bad = next((d for d in wanted if d.exit != 0), None)
    if bad is not None:
        verb = "ligar" if on else "desligar"
        return {"ok": False, "error": f"Não consegui {verb} {row['name']}: {bad.output.strip() or 'o agendador recusou'}"}
    return {"ok": True}


def routine_log(label: str, index: int) -> dict:
    row = next((r for r in routines()["rows"] if r["label"] == label), None)
    if row is None or not row["logs"]:
        return {"ok": False, "error": "Essa rotina não tem log."}
    paths = row["logs"]
    path = paths[min(max(index, 0), len(paths) - 1)]
    try:
        with open(path, "rb") as handle:
            size = handle.seek(0, os.SEEK_END)
            start = max(0, size - LOG_BYTES)
            handle.seek(start)
            data = handle.read()
    except OSError:
        return {"ok": False, "error": f"Este log ainda não existe: {path}", "paths": paths, "path": path}
    lines = data.decode("utf-8", errors="replace").splitlines()
    if start > 0 and lines:
        lines = lines[1:]
    while lines and not lines[-1]:
        lines.pop()
    return {"ok": True, "lines": lines[-LOG_LINES:], "path": path, "paths": paths}


def shell_argv(command: str) -> list[str]:
    return ["cmd.exe", "/d", "/s", "/c", command] if WINDOWS else ["/bin/sh", "-c", command]


def _quote(value: str) -> str:
    return f'"{value}"' if WINDOWS else "'" + value.replace("'", "'\\''") + "'"


def _clean(text: object) -> str | None:
    return text.strip() or None if isinstance(text, str) else None


def _hook(raw: dict) -> dict:
    command = raw.get("command") if isinstance(raw.get("command"), str) else ""
    script, summary, matcher = _clean(raw.get("script")), _clean(raw.get("summary")), _clean(raw.get("matcher"))
    flat = " ".join(command.split("\n"))
    title = script or (flat if len(flat) <= HOOK_TITLE_LIMIT else flat[: HOOK_TITLE_LIMIT - 1] + "…")
    detail = " · ".join(p for p in (summary, matcher) if p) or None
    return {"id": raw["id"], "event": raw["event"], "title": title, "detail": detail, "command": command,
            "enabled": raw.get("enabled", True) is not False, "locked": raw.get("locked") is True, "missing": raw.get("missing") is True}


def hooks() -> dict:
    block = _block("hooks")
    listing = block.get("list")
    if not isinstance(listing, str) or not listing.strip():
        return {"available": False, "groups": [], "count": 0, "locked": 0}
    result = runner().run(shell_argv(listing), timeout=30)
    if result.exit != 0:
        return {"available": True, "groups": [], "count": 0, "locked": 0,
                "error": f"Não consegui listar os hooks: {(result.stderr or result.stdout).strip()[-200:] or 'o comando falhou'}"}
    try:
        raw = json.loads(result.stdout)["hooks"]
        entries = [_hook(h) for h in raw if isinstance(h.get("id"), str) and isinstance(h.get("event"), str)]
    except (ValueError, KeyError, TypeError, AttributeError):
        return {"available": True, "groups": [], "count": 0, "locked": 0,
                "error": 'Não consegui ler os hooks: a lista de hooks não está no formato {"hooks": [...], "orphans": [...]}'}
    order = [e for e, _ in HOOK_EVENTS] + [h["event"] for h in entries if h["event"] not in dict(HOOK_EVENTS)]
    titles = dict(HOOK_EVENTS)
    groups = []
    for event in dict.fromkeys(order):
        members = [h for h in entries if h["event"] == event]
        if members:
            groups.append({"event": event, "title": titles.get(event, event), "hooks": members})
    return {"available": True, "groups": groups, "count": len(entries), "locked": sum(1 for h in entries if h["locked"]),
            "can_disable": bool(block.get("disable")), "can_enable": bool(block.get("enable"))}


def toggle_hook(hook_id: str, on: bool) -> dict:
    report = hooks()
    hook = next((h for g in report["groups"] for h in g["hooks"] if h["id"] == hook_id), None)
    template = _block("hooks").get("enable" if on else "disable")
    if hook is None or hook["locked"] or not isinstance(template, str) or not SAFE_ID.fullmatch(hook_id):
        return {"ok": False, "error": "Esse hook não pode ser alterado."}
    result = runner().run(shell_argv(template.replace("{id}", _quote(hook_id))), timeout=30)
    if result.exit != 0:
        verb = "ligar" if on else "desligar"
        return {"ok": False, "error": f"Não consegui {verb} {hook['title']}: {(result.stderr or result.stdout).strip()[-200:] or 'o comando falhou'}"}
    return {"ok": True}


def first_comment(text: str) -> str | None:
    for index, raw in enumerate(text.splitlines()):
        line = raw.strip()
        if index == 0 and line.startswith("#!"):
            continue
        if not line:
            continue
        head = re.match(r"^(#+|::|rem\b)\s*", line, re.I)
        if not head:
            return None
        body = line[head.end():].strip()
        if body:
            return body
    return None


def _executable(path: Path) -> bool:
    return path.suffix.lower() in COMMAND_SUFFIXES if WINDOWS else os.access(path, os.X_OK)


def commands() -> dict:
    block = _block("commands")
    dirs = [d for d in block.get("dirs") or [] if isinstance(d, str)]
    if not dirs:
        return {"available": False, "entries": []}
    entries = []
    for folder in dirs:
        try:
            names = sorted(os.listdir(_expand(folder)))
        except OSError:
            continue
        for name in names:
            path = Path(_expand(folder)) / name
            if name.startswith(".") or not path.resolve().is_file() or not _executable(path):
                continue
            detail = None
            try:
                with open(path, "rb") as handle:
                    head = handle.read(COMMENT_BYTES)
                if b"\0" not in head:
                    detail = first_comment(head.decode("utf-8", errors="replace"))
            except OSError:
                pass
            entries.append({"name": name, "detail": detail, "path": str(path)})
    entries.sort(key=lambda e: (e["name"], e["path"]))
    return {"available": True, "entries": entries}


def _json_object(path: Path, limit: int = FILE_LIMIT) -> dict | None:
    try:
        if path.stat().st_size > limit:
            return None
        value = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _basename(command: str) -> str:
    first = command.split(" ")[0] if command else command
    return re.split(r"[\\/]", first)[-1]


def _transport(kind: str | None, command: str | None, url: str | None) -> str:
    if url:
        return f"{'sse' if kind == 'sse' else 'http'} · {urlparse(url).hostname or '?'}"
    return f"stdio · {_basename(command) if command else '?'}"


WISP_SERVERS = {"wisp-email", "wisp-brain", "wisp-mac"}
LOCAL_BUILT_IN = ["wisp-email", "wisp-brain"]


def _servers(table: object, scope: str, disabled_names: frozenset = frozenset()) -> list[dict]:
    if not isinstance(table, dict):
        return []
    found = []
    for name in sorted(table):
        entry = table[name]
        if not isinstance(entry, dict) or not (isinstance(entry.get("command"), str) or isinstance(entry.get("url"), str)):
            continue
        command = entry.get("command") if isinstance(entry.get("command"), str) else None
        found.append({
            "name": name, "scope": scope, "transport": _transport(entry.get("type"), command, entry.get("url")),
            "installed_by_wisp": scope == "usuário" and name in WISP_SERVERS and command is not None and _basename(command) in ("wisp", "wisp.exe", "wisp.cmd"),
            "disabled": entry.get("disabled") is True or entry.get("enabled") is False or name in disabled_names,
        })
    return found


def _unique(servers: list[dict]) -> list[dict]:
    seen: set[str] = set()
    return [s for s in servers if not (s["name"] in seen or seen.add(s["name"]))]


def _mcp_folders(cwd: str, home: str) -> list[str]:
    start, top = Path(cwd), Path(home)
    if start != top and top not in start.parents:
        return [str(start)]
    folders = [start]
    while folders[-1] != top:
        folders.append(folders[-1].parent)
    return [str(f) for f in folders]


def mcp_claude(home: str, cwd: str) -> list[dict]:
    root = _json_object(Path(home) / ".claude.json", CLAUDE_CONFIG_LIMIT) or {}
    projects = root.get("projects") if isinstance(root.get("projects"), dict) else {}
    entry = next((projects[k] for k in (cwd, cwd.replace("\\", "/"), cwd.replace("/", "\\")) if isinstance(projects.get(k), dict)), {})
    disabled = {s for s in entry.get("disabledMcpServers") or [] if isinstance(s, str)}
    disabled_json = frozenset(s for s in entry.get("disabledMcpjsonServers") or [] if isinstance(s, str))
    found = _servers(entry.get("mcpServers"), "projeto")
    for folder in _mcp_folders(cwd, home):
        file = _json_object(Path(folder) / ".mcp.json") or {}
        found += _servers(file.get("mcpServers", file), "projeto", disabled_json)
    found += _servers(root.get("mcpServers"), "usuário")
    found += _plugin_servers(Path(home))
    result = _unique(found)
    for server in result:
        if server["scope"] != "plugin" and server["name"] in disabled:
            server["disabled"] = True
    return result


def _plugin_servers(home: Path) -> list[dict]:
    installed = (_json_object(home / ".claude/plugins/installed_plugins.json") or {}).get("plugins")
    enabled = (_json_object(home / ".claude/settings.json") or {}).get("enabledPlugins")
    installed = installed if isinstance(installed, dict) else {}
    enabled = enabled if isinstance(enabled, dict) else {}
    root = (home / ".claude/plugins").resolve()
    found: list[dict] = []
    for plugin in sorted(installed):
        installs = installed[plugin]
        if enabled.get(plugin) is False or not isinstance(installs, list) or not installs or not isinstance(installs[0], dict):
            continue
        path = installs[0].get("installPath")
        if not isinstance(path, str):
            continue
        resolved = Path(path).resolve()
        if root not in resolved.parents:
            continue
        file = _json_object(resolved / ".mcp.json") or {}
        servers = _servers(file.get("mcpServers", file), "plugin")
        if not servers:
            manifest = _json_object(resolved / ".claude-plugin/plugin.json") or {}
            servers = _servers(manifest.get("mcpServers"), "plugin")
        found += servers
    return found


def mcp_codex(home: str) -> list[dict]:
    path = Path(home) / ".codex/config.toml"
    try:
        if path.stat().st_size > FILE_LIMIT:
            return []
        table = tomllib.loads(path.read_text("utf-8")).get("mcp_servers")
    except (OSError, ValueError):
        return []
    return _unique(_servers(table, "usuário"))


def mcp_local(wisp_dir: Path) -> list[dict]:
    found = [{"name": n, "scope": "Wisp", "transport": "stdio · wisp", "installed_by_wisp": True, "disabled": False} for n in LOCAL_BUILT_IN]
    folder = wisp_dir / "ferramentas"
    for file in sorted(folder.glob("*.toml")) if folder.is_dir() else []:
        try:
            if file.stat().st_size > FILE_LIMIT:
                continue
            data = tomllib.loads(file.read_text("utf-8"))
        except (OSError, ValueError):
            continue
        command = data.get("command")
        name = data.get("name") if isinstance(data.get("name"), str) else file.stem
        if isinstance(command, str) and name not in LOCAL_BUILT_IN:
            found.append({"name": name, "scope": "Wisp", "transport": _transport(None, command, None), "installed_by_wisp": False, "disabled": False})
    return _unique(found)


def mcp_servers() -> dict:
    from wisp.engines import read_active

    cfg = store.config()
    wisp_dir = Path(cfg.wisp_dir).expanduser()
    engine = read_active(wisp_dir)
    home = str(Path.home())
    cwd = _expand(((store.read_profile() or {}).get("agent") or {}).get("cwd") or "~")
    servers = {"codex": lambda: mcp_codex(home), "local": lambda: mcp_local(wisp_dir)}.get(engine, lambda: mcp_claude(home, cwd))()
    return {"engine": engine, "servers": servers}


CLI_TOOLS = [
    ("gh", ["--version"], "gh"), ("git", ["--version"], None), ("supabase", ["--version"], None), ("aws", ["--version"], "aws"),
    ("gcloud", ["--version"], None), ("az", ["--version"], None), ("vercel", ["--version"], None), ("netlify", ["--version"], None),
    ("flyctl", ["version"], None), ("firebase", ["--version"], None), ("docker", ["--version"], None),
    ("kubectl", ["version", "--client"], None), ("terraform", ["version"], None), ("stripe", ["--version"], None),
    ("psql", ["--version"], None), ("mysql", ["--version"], None), ("redis-cli", ["--version"], None), ("node", ["--version"], None),
    ("npm", ["--version"], None), ("pnpm", ["--version"], None), ("bun", ["--version"], None), ("python", ["--version"], None),
    ("uv", ["--version"], None), ("pip", ["--version"], None), ("go", ["version"], None), ("cargo", ["--version"], None),
    ("java", ["-version"], None), ("ffmpeg", ["-version"], None), ("jq", ["--version"], None), ("rg", ["--version"], None),
    ("winget", ["--version"], None), ("codex", ["--version"], None), ("claude", ["--version"], None), ("ollama", ["--version"], None),
]
_versions: dict[str, str] = {}


def version_line(output: str) -> str | None:
    line = next((raw.strip() for raw in output.splitlines() if raw.strip()), None)
    return None if line is None else (line if len(line) <= 80 else line[:79] + "…")


def _display(directory: str, home: str) -> str:
    if directory == home:
        return "~"
    for sep in ("/", "\\"):
        if directory.startswith(home + sep):
            return "~" + directory[len(home):]
    return directory


def _auth(name: str, kind: str | None, path: str, run: Runner) -> str | None:
    if kind == "gh":
        for rel in (".config/gh/hosts.yml", "AppData/Roaming/GitHub CLI/hosts.yml"):
            try:
                text = (Path.home() / rel).read_text("utf-8")
            except OSError:
                continue
            if any(line.strip().startswith(("oauth_token:", "user:")) for line in text.splitlines()):
                return "logado"
    if kind == "aws":
        result = run.run([path, "configure", "list-profiles"], timeout=VERSION_TIMEOUT)
        return "perfil configurado" if result.exit == 0 and result.stdout.strip() else None
    return None


def _probe(spec: tuple[str, list[str], str | None], path: str, home: str, run: Runner) -> dict:
    name, args, kind = spec
    try:
        key = f"{path}|{os.stat(path).st_mtime}"
    except OSError:
        key = path
    version = _versions.get(key)
    if version is None:
        result = run.run([path, *args], timeout=VERSION_TIMEOUT)
        version = None if result.timed_out else (version_line(result.stdout) or version_line(result.stderr))
        if version:
            _versions[key] = version
    return {"name": name, "directory": _display(str(Path(path).parent), home), "version": version, "auth": _auth(name, kind, path, run)}


def clis(force: bool = False) -> dict:
    if force:
        _versions.clear()
    home, run = str(Path.home()), runner()
    located = [(spec, shutil.which(spec[0])) for spec in CLI_TOOLS]
    with ThreadPoolExecutor(MAX_PARALLEL) as pool:
        probes = list(pool.map(lambda item: _probe(item[0], item[1], home, run) if item[1] else None, located))
    installed = [p for p in probes if p]
    return {"installed": installed, "missing": [spec[0] for (spec, path) in located if path is None]}
