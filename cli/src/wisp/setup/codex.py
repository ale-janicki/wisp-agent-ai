import json
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from wisp.config import WispConfig
from wisp.send_gate import SOCKET_ENV
from wisp.engines import read_active
from wisp.fsops import atomic_write
from wisp.harness_merge import END, block_digest, find_block, merge_block
from wisp.paths import WispPaths, resources_root
from wisp.report import Detail
from wisp.setup.folder import wisp_root
from wisp.setup.harness import BRAIN_MCP_NAME, MANIFEST_NAME, MCP_NAME, _block, _file_mode, _load_manifest, _values

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
            if isinstance(servers, dict) and MCP_NAME in servers:
                return PROJECT_DEFINES.format(file=file, name=MCP_NAME)
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


def server_fields(wisp_bin: str) -> list[tuple[str, str]]:
    return [
        ("command", json.dumps(wisp_bin, ensure_ascii=False)),
        ("args", '["mcp", "email"]'),
        ("env_vars", f'["WISP_TELEGRAM_THREAD", "{SOCKET_ENV}"]'),
        ("default_tools_approval_mode", '"approve"'),
        ("startup_timeout_sec", "30"),
        ("tool_timeout_sec", str(APPROVAL_WAIT_SECONDS)),
    ]


def brain_fields(wisp_bin: str) -> list[tuple[str, str]]:
    return [
        ("command", json.dumps(wisp_bin, ensure_ascii=False)),
        ("args", '["mcp", "brain"]'),
        ("env_vars", '["WISP_CONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME"]'),
        ("default_tools_approval_mode", '"approve"'),
        ("startup_timeout_sec", "30"),
        ("tool_timeout_sec", "60"),
    ]


def render_config_block(wisp_bin: str, *, email: bool = True, brain: bool = True) -> str:
    lines = [TOML_BEGIN, "# Managed by Wisp. Edit outside this block; changes inside it are replaced on the next sync."]
    for wanted, name, fields in ((email, MCP_NAME, server_fields(wisp_bin)), (brain, BRAIN_MCP_NAME, brain_fields(wisp_bin))):
        if wanted:
            lines += [f"[mcp_servers.{name}]", *(f"{key} = {value}" for key, value in fields)]
    lines.append(TOML_END)
    return "\n".join(lines) + "\n"


def mcp_overrides(wisp_bin: str, owned: frozenset[str] = frozenset()) -> list[str]:
    out = []
    for name, fields in ((MCP_NAME, server_fields(wisp_bin)), (BRAIN_MCP_NAME, brain_fields(wisp_bin))):
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
    block, problem = render_agents_block(cfg)
    if problem:
        result.details.append(Detail("agente", 0, problem))
    try:
        plans.append((agents_path, AGENTS_KEY, user_agents, _merged(
            user_agents, block, "<!-- wisp:begin -->", "<!-- wisp:end -->", "AGENTS.md", manifest.files.get(AGENTS_KEY))))
        outside = _outside_block(user_config) if user_config is not None else None
        foreign = outside is not None and _owns_server(outside)
        brain_foreign = outside is not None and _owns_server(outside, BRAIN_MCP_NAME)
        if foreign:
            result.details.append(Detail("e-mail", 0, f"já existe outro servidor chamado {MCP_NAME} no Codex; o Wisp não mexeu nele"))
        if brain_foreign:
            result.details.append(Detail("brain", 0, f"já existe outro servidor chamado {BRAIN_MCP_NAME} no Codex; o Wisp não mexeu nele"))
        wisp_bin = str(paths.runtime / "venv/bin/wisp")
        chosen = _config_plan(user_config, wisp_bin, manifest.files.get(CONFIG_KEY), foreign, brain_foreign)
        if chosen is not None:
            plans.append((config_path, CONFIG_KEY, user_config, chosen[0]))
        if (chosen is None and not (foreign and brain_foreign)) or (chosen is not None and chosen[1] and not brain_foreign):
            result.details.append(Detail("brain", 0, INLINE_LEFT_ALONE))
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
    if dry_run:
        return result
    for path, text in pending.items():
        atomic_write(path, text.encode(), mode=_file_mode(path))
    if manifest != _load_manifest(manifest_path):
        atomic_write(manifest_path, json.dumps({"version": manifest.version, "files": manifest.files}, indent=2, sort_keys=True) + "\n")
    return result


def user_owned_servers(paths: WispPaths) -> frozenset[str]:
    try:
        text = _read(codex_home(paths) / "config.toml")
        outside = _outside_block(text) if text is not None else ""
        return frozenset(name for name in (MCP_NAME, BRAIN_MCP_NAME) if _owns_server(outside, name))
    except (OSError, UnicodeDecodeError, ValueError):
        return frozenset()


def _config_plan(
    user: str | None, wisp_bin: str, recorded: str | None, foreign: bool, brain_foreign: bool
) -> tuple[tuple[str, str, str | None], bool] | None:
    options = [(not foreign, not brain_foreign)]
    if options[0] == (True, True):
        options.append((True, False))
    for email, brain in options:
        if not (email or brain):
            continue
        merged = _merged(user, render_config_block(wisp_bin, email=email, brain=brain), TOML_BEGIN, TOML_END, "config.toml", recorded)
        if merged[1] != "conflict":
            try:
                tomllib.loads(merged[0])
            except tomllib.TOMLDecodeError:
                continue
        return merged, brain != options[0][1]
    return None


def _owns_server(outside: str, name: str = MCP_NAME) -> bool:
    servers = tomllib.loads(outside).get("mcp_servers")
    return isinstance(servers, dict) and name in servers


def _outside_block(text: str) -> str:
    block = find_block(text, TOML_BEGIN, TOML_END, "config.toml")
    return text.replace(block, "") if block else text
