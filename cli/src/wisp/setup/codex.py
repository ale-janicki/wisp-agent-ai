import json
import os
import shutil
import tomllib
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from wisp.config import WispConfig
from wisp.send_gate import SOCKET_ENV
from wisp.engines import read_active
from wisp.fsops import atomic_write, ensure_dir
from wisp.mac_control import READ_ONLY as MAC_READ_ONLY, TOOLS as MAC_TOOLS
from wisp.harness_merge import END, block_digest, find_block, merge_block, remove_block
from wisp.paths import WispPaths, resources_root
from wisp.report import Detail
from wisp.setup.folder import wisp_root
from wisp.setup.harness import BRAIN_MCP_NAME, MAC_MCP_NAME, MANIFEST_NAME, MCP_NAME, _block, _file_mode, _load_manifest, _values, soul_injected, KEPT_NOTE, REMOVED_NOTE, WOULD_REMOVE_NOTE

AGENTS_KEY = "codex/AGENTS.md#block"
CONFIG_KEY = "codex/config.toml#block"
TOML_BEGIN = "# wisp:begin"
TOML_END = "# wisp:end"
APPROVAL_WAIT_SECONDS = 660
CODEX_NOTE = """
## Running under Codex
- Only the rules above reach you here. The `operator`, `reviewer` and `reader` agents, the slash commands and Wisp's guard hooks exist only under Claude Code: do the work yourself and never mention them as available.
- Never write memory under `~/.codex/` either; the brain and `{wisp_dir}` are the only places.
- Sending an email asks {user} for approval through the app or Telegram before it leaves, in every mode. A refusal, a timeout or no answer channel means it was not sent: tell {user}, never retry around it.
- You control the Mac through the `wisp-mac` tools (`mac_open_url`, `mac_open`, `mac_ui_tree`, `mac_ui_click`, `mac_ui_type`, `mac_ui_key`, `mac_media`, `mac_volume`, `mac_script` and the rest): use them to act, not to describe. Sending a message through an app (`mac_send`) asks {user} for approval first, like an email.
"""


STALE_GATE = ("o servidor de e-mail do Wisp no config.toml do Codex não está com a trava de aprovação "
              "({why}); sem ela o envio sairia sem pedir. Rode `wisp harness sync`.")


@dataclass
class CodexSync:
    state: str = "skipped"
    details: list[Detail] = field(default_factory=list)


def codex_home(paths: WispPaths) -> Path:
    env = os.environ.get("CODEX_HOME")
    return Path(env).expanduser() if env else paths.home / ".codex"


def wanted(paths: WispPaths, cfg: WispConfig) -> bool:
    return read_active(wisp_root(cfg)) == "codex" or codex_home(paths).is_dir()


def _forwards(env_vars: object, name: str) -> bool:
    if not isinstance(env_vars, list):
        return False
    return any(item == name or (isinstance(item, dict) and item.get("name") == name) for item in env_vars)


def gate_problem_in(text: str | None) -> str | None:
    if text is None:
        return STALE_GATE.format(why="não há config.toml")
    try:
        servers = tomllib.loads(text).get("mcp_servers")
    except tomllib.TOMLDecodeError:
        return STALE_GATE.format(why="o config.toml não é um TOML válido")
    server = servers.get(MCP_NAME) if isinstance(servers, dict) else None
    if not isinstance(server, dict):
        return STALE_GATE.format(why=f"não há o servidor {MCP_NAME}")
    if not _forwards(server.get("env_vars"), SOCKET_ENV):
        return STALE_GATE.format(why=f"falta {SOCKET_ENV} em env_vars")
    return None


INLINE_LEFT_ALONE = "o config.toml do Codex tem uma tabela mcp_servers inline; o Wisp deixou o servidor do brain de fora (inline table)"
MAC_LEFT_ALONE = "o config.toml do Codex tem uma tabela mcp_servers inline; o Wisp deixou o servidor do controle do Mac de fora (inline table)"
SERVERS = (MCP_NAME, BRAIN_MCP_NAME, MAC_MCP_NAME)
PROJECT_DEFINES = ("o arquivo {file} define o servidor {name} do Codex; o Wisp não usa o Codex nesta pasta "
                   "enquanto ele existir (apague essa parte do arquivo ou use outra pasta)")
PROJECT_UNREADABLE = ("não consegui ler {file} como TOML; o Wisp não usa o Codex nesta pasta enquanto ele estiver assim "
                      "(corrija o arquivo ou use outra pasta)")


def project_config_problem(workspace: Path, home: Path) -> str | None:
    stop = home.resolve()
    folder = workspace.resolve()
    while folder != stop and folder != folder.parent:
        file = folder / ".codex" / "config.toml"
        if file.is_file():
            try:
                servers = tomllib.loads(file.read_bytes().decode()).get("mcp_servers")
            except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
                return PROJECT_UNREADABLE.format(file=file)
            taken = next((name for name in SERVERS if isinstance(servers, dict) and name in servers), None)
            if taken:
                return PROJECT_DEFINES.format(file=file, name=taken)
        folder = folder.parent
    return None


def gate_problem(paths: WispPaths) -> str | None:
    try:
        text = _read(codex_home(paths) / "config.toml")
    except (OSError, UnicodeDecodeError):
        return STALE_GATE.format(why="não consegui ler o config.toml")
    return gate_problem_in(text)


def render_agents_block(cfg: WispConfig) -> tuple[str, str | None]:
    values = _values(cfg)
    block, problem = _block(resources_root() / "harness", cfg, values)
    note = CODEX_NOTE.format(wisp_dir=values["WISP_DIR"], user=values["USER_NAME"])
    return block.replace(END, note + END, 1), problem


def tool_list(names) -> str:
    return "[" + ", ".join(json.dumps(name) for name in sorted(names)) + "]"


def server_fields(wisp_bin: str, server: str = "email", mac_tools=None) -> list[tuple[str, str]]:
    fields = [
        ("command", json.dumps(wisp_bin, ensure_ascii=False)),
        ("args", f'["mcp", "{server}"]'),
        ("env_vars", f'["WISP_TELEGRAM_THREAD", "{SOCKET_ENV}"]'),
        ("default_tools_approval_mode", '"approve"'),
        ("startup_timeout_sec", "30"),
        ("tool_timeout_sec", str(APPROVAL_WAIT_SECONDS)),
    ]
    if server == "mac":
        fields.append(("enabled_tools", tool_list(MAC_READ_ONLY if mac_tools is None else mac_tools)))
    return fields


def brain_fields(wisp_bin: str) -> list[tuple[str, str]]:
    return [
        ("command", json.dumps(wisp_bin, ensure_ascii=False)),
        ("args", '["mcp", "brain"]'),
        ("env_vars", '["WISP_CONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME"]'),
        ("default_tools_approval_mode", '"approve"'),
        ("startup_timeout_sec", "30"),
        ("tool_timeout_sec", "60"),
    ]


def render_config_block(wisp_bin: str, *, email: bool = True, brain: bool = True, mac: bool = True) -> str:
    lines = [TOML_BEGIN, "# Managed by Wisp. Edit outside this block; changes inside it are replaced on the next sync."]
    servers = ((email, MCP_NAME, server_fields(wisp_bin)), (brain, BRAIN_MCP_NAME, brain_fields(wisp_bin)), (mac, MAC_MCP_NAME, server_fields(wisp_bin, "mac")))
    for wanted, name, fields in servers:
        if wanted:
            lines += [f"[mcp_servers.{name}]", *(f"{key} = {value}" for key, value in fields)]
    lines.append(TOML_END)
    return "\n".join(lines) + "\n"


def mcp_overrides(wisp_bin: str, owned: frozenset[str] = frozenset(), allow_changes: bool = True) -> list[str]:
    mac_tools = MAC_TOOLS if allow_changes else MAC_READ_ONLY
    out = []
    servers = ((MCP_NAME, server_fields(wisp_bin)), (BRAIN_MCP_NAME, brain_fields(wisp_bin)), (MAC_MCP_NAME, server_fields(wisp_bin, "mac", mac_tools)))
    for name, fields in servers:
        if name in owned and name != MCP_NAME:
            continue
        out += [f"mcp_servers.{name}.{key}={value}" for key, value in [*fields, ("enabled", "true")]]
    return out


def _read(path: Path) -> str | None:
    return path.read_bytes().decode() if path.exists() else None


def _merged(user: str | None, block: str, begin: str, end: str, label: str, recorded: str | None) -> tuple[str, str, str | None]:
    existing = find_block(user, begin, end, label) if user is not None else None
    new = merge_block(user, block, begin, end, label)
    if existing is not None and new != user and block_digest(existing) != recorded:
        return user, "conflict", None
    kind = "added" if user is None else "updated" if new != user else "unchanged"
    return new, kind, block_digest(block)


def sync_codex(paths: WispPaths, cfg: WispConfig, *, dry_run: bool) -> CodexSync:
    if not wanted(paths, cfg):
        return CodexSync()
    home = codex_home(paths)
    manifest_path = paths.config / MANIFEST_NAME
    manifest = _load_manifest(manifest_path)
    result = CodexSync(state="unchanged")
    pending: dict[Path, str] = {}

    agents_path, config_path = home / "AGENTS.md", home / "config.toml"
    for path in (agents_path, config_path):
        if path.is_symlink() or (path.exists() and not path.is_file()):
            return CodexSync("failed", [Detail("codex", 0, f"{path.name} é um link ou não é um arquivo; o Wisp não mexeu")])
    try:
        user_agents, user_config = _read(agents_path), _read(config_path)
    except UnicodeDecodeError:
        return CodexSync("failed", [Detail("codex", 0, "o AGENTS.md ou o config.toml do Codex não é texto; nada foi alterado")])

    plans = []
    retired: str | None = None
    block, problem = render_agents_block(cfg)
    if problem:
        result.details.append(Detail("agente", 0, problem))
    try:
        if not soul_injected(paths):
            plans.append((agents_path, AGENTS_KEY, user_agents, _merged(
                user_agents, block, "<!-- wisp:begin -->", "<!-- wisp:end -->", "AGENTS.md", manifest.files.get(AGENTS_KEY))))
        else:          # the soul is injected into the conversation: no persona block is installed, an old one is retired
            old = find_block(user_agents, "<!-- wisp:begin -->", "<!-- wisp:end -->", "AGENTS.md") if user_agents is not None else None
            if old is not None and block_digest(old) == manifest.files.get(AGENTS_KEY):
                retired = remove_block(user_agents, "<!-- wisp:begin -->", "<!-- wisp:end -->", "AGENTS.md")
            elif old is not None:
                result.details.append(Detail("alma", 0, KEPT_NOTE))
        outside = _outside_block(user_config) if user_config is not None else None
        foreign = outside is not None and _owns_server(outside)
        brain_foreign = outside is not None and _owns_server(outside, BRAIN_MCP_NAME)
        mac_foreign = outside is not None and _owns_server(outside, MAC_MCP_NAME)
        if foreign:
            result.details.append(Detail("e-mail", 0, f"já existe outro servidor chamado {MCP_NAME} no Codex; o Wisp não mexeu nele"))
        if brain_foreign:
            result.details.append(Detail("brain", 0, f"já existe outro servidor chamado {BRAIN_MCP_NAME} no Codex; o Wisp não mexeu nele"))
        if mac_foreign:
            result.details.append(Detail("controle do mac", 0, f"já existe outro servidor chamado {MAC_MCP_NAME} no Codex; o Wisp não mexeu nele"))
        wisp_bin = str(paths.runtime / "venv/bin/wisp")
        chosen = _config_plan(user_config, wisp_bin, manifest.files.get(CONFIG_KEY), foreign, brain_foreign, mac_foreign)
        if chosen is not None:
            plans.append((config_path, CONFIG_KEY, user_config, chosen[0]))
        dropped = chosen[1] if chosen is not None else frozenset()
        if (chosen is None and not (foreign and brain_foreign)) or (BRAIN_MCP_NAME in dropped and not brain_foreign):
            result.details.append(Detail("brain", 0, INLINE_LEFT_ALONE))
        if MAC_MCP_NAME in dropped and not mac_foreign:
            result.details.append(Detail("controle do mac", 0, MAC_LEFT_ALONE))
    except tomllib.TOMLDecodeError as e:
        return CodexSync("failed", [Detail("codex", 0, f"o config.toml do Codex não ficaria um TOML válido ({e}); nada foi alterado")])
    except ValueError as e:
        return CodexSync("failed", [Detail("codex", 0, f"{e}; nada foi alterado")])

    for path, key, user, (text, kind, digest) in plans:
        if kind == "conflict":
            result.details.append(Detail("conflito", 0, f"{path.name} do Codex: o bloco do Wisp foi editado por você, mantido"))
            continue
        if digest:
            manifest.files[key] = digest
        if kind in ("added", "updated"):
            pending[path] = text
            result.state = "updated"
    config_after = pending.get(config_path, user_config)
    problem = gate_problem_in(config_after)
    if problem:
        result.state = "failed"
        result.details.append(Detail("e-mail", 0, problem))
    if retired is not None:
        result.state = "updated"
        pending[agents_path] = retired
        if dry_run:
            result.details.append(Detail("alma", 0, WOULD_REMOVE_NOTE))
    if dry_run:
        return result
    if retired is not None:
        saved = _backup_agents(paths, agents_path)
        result.details.append(Detail("alma", 0, REMOVED_NOTE.format(backup=saved)))
        manifest.files.pop(AGENTS_KEY, None)
    for path, text in pending.items():
        atomic_write(path, text.encode(), mode=_file_mode(path))
    if manifest != _load_manifest(manifest_path):
        atomic_write(manifest_path, json.dumps({"version": manifest.version, "files": manifest.files}, indent=2, sort_keys=True) + "\n")
    return result


def _backup_agents(paths: WispPaths, agents_path: Path) -> Path:
    base = paths.state / "backups" / f"codex-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    folder, suffix = base, 1
    while folder.exists():
        suffix += 1
        folder = base.with_name(f"{base.name}-{suffix}")
    ensure_dir(folder)
    shutil.copy2(agents_path, folder / agents_path.name)
    return folder


def user_owned_servers(paths: WispPaths) -> frozenset[str]:
    try:
        text = _read(codex_home(paths) / "config.toml")
        outside = _outside_block(text) if text is not None else ""
        return frozenset(name for name in SERVERS if _owns_server(outside, name))
    except (OSError, UnicodeDecodeError, ValueError):
        return frozenset()


def _config_plan(
    user: str | None, wisp_bin: str, recorded: str | None, foreign: bool, brain_foreign: bool, mac_foreign: bool
) -> tuple[tuple[str, str, str | None], frozenset[str]] | None:
    base = (not foreign, not brain_foreign, not mac_foreign)
    options = [base]
    if base[0]:
        if base[1]:
            options.append((True, False, base[2]))
        if base[2]:
            options.append((True, base[1], False))
        if base[1] and base[2]:
            options.append((True, False, False))
    for email, brain, mac in options:
        if not (email or brain or mac):
            continue
        merged = _merged(user, render_config_block(wisp_bin, email=email, brain=brain, mac=mac), TOML_BEGIN, TOML_END, "config.toml", recorded)
        if merged[1] != "conflict":
            try:
                tomllib.loads(merged[0])
            except tomllib.TOMLDecodeError:
                continue
        dropped = frozenset(name for name, was, now in ((BRAIN_MCP_NAME, base[1], brain), (MAC_MCP_NAME, base[2], mac)) if was and not now)
        return merged, dropped
    return None


def _owns_server(outside: str, name: str = MCP_NAME) -> bool:
    servers = tomllib.loads(outside).get("mcp_servers")
    return isinstance(servers, dict) and name in servers


def _outside_block(text: str) -> str:
    block = find_block(text, TOML_BEGIN, TOML_END, "config.toml")
    return text.replace(block, "") if block else text
