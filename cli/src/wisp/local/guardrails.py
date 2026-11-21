import json
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

FILE = "guardrails.toml"
TIERS = ("pequeno", "medio", "grande")
TIER_LABELS = {"pequeno": "Pequeno", "medio": "Médio", "grande": "Grande"}
ALWAYS_IRREVERSIBLE = frozenset({"email_send", "run_shell"})
READ_ONLY = frozenset({"read_file", "list_files", "email_list", "email_read", "email_search"})
DEFAULT_REPEAT_LIMIT = 3
TIER_KEYS = {"max_steps", "tools", "approve"}
TOP_KEYS = set(TIERS) | {"irreversible", "loop"}

MODES = ("default", "auto", "bypassPermissions")


class GuardrailsError(Exception):
    pass


@dataclass(frozen=True)
class Tier:
    name: str
    max_steps: int
    tools: frozenset[str]
    approve: frozenset[str]

    @property
    def label(self) -> str:
        return TIER_LABELS[self.name]


@dataclass(frozen=True)
class Guardrails:
    tiers: dict[str, Tier]
    irreversible: frozenset[str]
    repeat_limit: int = DEFAULT_REPEAT_LIMIT

    def tier(self, name: str) -> Tier:
        return self.tiers[name]


def _fail(message: str) -> GuardrailsError:
    return GuardrailsError(f"{FILE}: {message}")


def _names(section: str, key: str, value: object) -> frozenset[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise _fail(f"[{section}] {key} deve ser uma lista de nomes entre aspas (achei {json.dumps(value, ensure_ascii=False)})")
    return frozenset(value)


def _tier(name: str, raw: object) -> Tier:
    if not isinstance(raw, dict):
        raise _fail(f"falta a seção [{name}]")
    unknown = sorted(set(raw) - TIER_KEYS)
    if unknown:
        raise _fail(f"[{name}] tem a chave desconhecida {unknown[0]!r}; as chaves são max_steps, tools e approve")
    steps = raw.get("max_steps")
    if isinstance(steps, bool) or not isinstance(steps, int) or steps < 0:
        raise _fail(f"[{name}] max_steps deve ser um número inteiro maior ou igual a 0, onde 0 é sem limite (achei {json.dumps(steps)})")
    tools = _names(name, "tools", raw.get("tools"))
    approve = _names(name, "approve", raw.get("approve", []))
    if not approve <= tools:
        raise _fail(f"[{name}] approve lista {sorted(approve - tools)[0]!r}, que não está em tools")
    return Tier(name, steps, tools, approve)


def parse(text: str) -> Guardrails:
    try:
        raw = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise _fail(f"não consegui ler o arquivo ({e})") from None
    unknown = sorted(set(raw) - TOP_KEYS)
    if unknown:
        raise _fail(f"seção desconhecida [{unknown[0]}]; as seções são {', '.join('[' + k + ']' for k in sorted(TOP_KEYS))}")
    tiers = {name: _tier(name, raw.get(name)) for name in TIERS}
    extra = raw.get("irreversible", {})
    if not isinstance(extra, dict) or set(extra) - {"tools"}:
        raise _fail("[irreversible] só aceita a chave tools")
    irreversible = ALWAYS_IRREVERSIBLE | _names("irreversible", "tools", extra.get("tools", []))
    loop = raw.get("loop", {})
    if not isinstance(loop, dict) or set(loop) - {"repeat_limit"}:
        raise _fail("[loop] só aceita a chave repeat_limit")
    limit = loop.get("repeat_limit", DEFAULT_REPEAT_LIMIT)
    if isinstance(limit, bool) or not isinstance(limit, int) or limit < 2:
        raise _fail(f"[loop] repeat_limit deve ser um número inteiro maior ou igual a 2 (achei {json.dumps(limit)})")
    return Guardrails(tiers, irreversible, limit)


def load(folder: Path) -> Guardrails:
    path = folder / FILE
    try:
        text = path.read_text("utf-8")
    except FileNotFoundError:
        raise _fail(f"não achei o arquivo em {path}; rode `wisp setup folder` para recriá-lo") from None
    except (OSError, UnicodeDecodeError) as e:
        raise _fail(f"não consegui ler {path} ({type(e).__name__})") from None
    return parse(text)


def needs_card(rails: Guardrails, tier: Tier, mode: str, tool: str) -> bool:
    if tool in rails.irreversible or tool in tier.approve:
        return True
    return mode == "default" and tool not in READ_ONLY


def call_key(name: str, arguments: dict) -> str:
    return f"{name}\0{json.dumps(arguments, sort_keys=True, ensure_ascii=False, default=str)}"


@dataclass
class TurnGuard:
    tier: Tier
    repeat_limit: int
    steps: int = 0
    seen: dict[str, int] = field(default_factory=dict)
    refused: list[str] = field(default_factory=list)
    last_repeated: str = ""

    def count_step(self) -> None:
        self.steps += 1

    @property
    def capped(self) -> bool:
        return self.tier.max_steps > 0 and self.steps >= self.tier.max_steps

    def allowed(self, tool: str) -> bool:
        return tool in self.tier.tools

    def refuse(self, tool: str) -> None:
        if tool not in self.refused:
            self.refused.append(tool)

    def repeated(self, name: str, arguments: dict) -> bool:
        key = call_key(name, arguments)
        self.seen[key] = self.seen.get(key, 0) + 1
        return self.seen[key] >= self.repeat_limit
