from __future__ import annotations

import json
import unicodedata
from typing import Any

ASK_TOOLS = ("mcp__wisp-email__email_send", "mcp__wisp-mac__mac_send")
SUMMARY_LIMIT = 120
_HIDDEN = {"Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp"}
_INVISIBLE_LETTERS = {0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x17B4, 0x17B5, 0x180B, 0x180C, 0x180D, 0x180E, 0x034F}


def escaped(text: str) -> str:
    out = []
    for char in text:
        hidden = unicodedata.category(char) in _HIDDEN or ord(char) in _INVISIBLE_LETTERS
        out.append(f"\\u{{{ord(char):04x}}}" if hidden and char not in "\n\t" else char)
    return "".join(out)


def _flat(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    return " ".join(value.split()) or None


def _is_blank(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str):
        return not value.strip()
    return isinstance(value, (list, dict)) and not value


def _first_string_key(tool_input: dict) -> str | None:
    return next((k for k in sorted(tool_input) if isinstance(tool_input[k], str) and tool_input[k].split()), None)


def _shown_key(tool_input: dict, key: str) -> str | None:
    value = tool_input.get(key)
    return key if isinstance(value, str) and value.split() else None


def _hides_content(tool_input: dict, shown: str | None) -> bool:
    return any(k != shown and not _is_blank(v) for k, v in tool_input.items())


def chains_commands(command: str) -> bool:
    for i, char in enumerate(command):
        following = command[i + 1] if i + 1 < len(command) else None
        previous = command[i - 1] if i > 0 else None
        if char in ";|`":
            return True
        if char in "$<>" and following == "(":
            return True
        if char == "&" and previous not in (">", "<") and following != ">":
            return True
    return False


def requires_expansion(tool: str, tool_input: dict, truncated: bool) -> bool:
    if truncated:
        return True
    if tool in ("Bash", "PowerShell"):
        command = tool_input.get("command")
        return isinstance(command, str) and ("\n" in command.strip() or chains_commands(command))
    if tool in ("Read", "Glob", "Grep", "WebFetch", "WebSearch"):
        return False
    if tool in ("Edit", "MultiEdit", "Write"):
        return _hides_content(tool_input, _shown_key(tool_input, "file_path"))
    if tool == "NotebookEdit":
        return _hides_content(tool_input, _shown_key(tool_input, "notebook_path"))
    return _hides_content(tool_input, _first_string_key(tool_input))


def phrase(tool: str, tool_input: dict, home: str) -> str:
    def string(key: str) -> str | None:
        return _flat(tool_input.get(key))

    def path(key: str) -> str | None:
        value = string(key)
        if value is None:
            return None
        if value == home:
            return "~"
        return "~" + value[len(home):] if value.startswith((home + "/", home + "\\")) else value

    def say(verb: str, value: str | None, fallback: str) -> str:
        return f"{verb} {value}" if value else fallback

    if tool in ("Bash", "PowerShell"):
        return say("rodar", string("command"), "rodar um comando")
    if tool in ("Edit", "MultiEdit"):
        return say("editar", path("file_path"), "editar um arquivo")
    if tool == "Write":
        return say("escrever", path("file_path"), "escrever um arquivo")
    if tool == "NotebookEdit":
        return say("editar", path("notebook_path"), "editar um notebook")
    if tool == "Read":
        return say("ler", path("file_path"), "ler um arquivo")
    if tool in ("Glob", "Grep"):
        return say("buscar", string("pattern"), "buscar arquivos")
    if tool == "WebFetch":
        return say("abrir", string("url"), "abrir uma página")
    if tool == "WebSearch":
        return say("pesquisar", string("query"), "pesquisar na web")
    key = _first_string_key(tool_input)
    first = _flat(tool_input[key]) if key else None
    return f"usar {tool}: {first}" if first else f"usar {tool}"


def clip_summary(text: str) -> str:
    return text if len(text) <= SUMMARY_LIMIT else text[:SUMMARY_LIMIT - 1] + "…"


def detail(tool: str, tool_input: dict, description: str | None) -> str:
    parts = [description] if description else []
    if tool in ("Bash", "PowerShell") and isinstance(tool_input.get("command"), str):
        parts.append(tool_input["command"])
    else:
        try:
            parts.append(json.dumps(tool_input, indent=2, sort_keys=True, ensure_ascii=False))
        except (TypeError, ValueError):
            pass
    return "\n\n".join(parts)


def rule_text(rule: dict) -> str:
    tool = rule.get("toolName") if isinstance(rule.get("toolName"), str) else ""
    content = rule.get("ruleContent")
    return f"{tool}({content})" if isinstance(content, str) and content else tool


RULE_LIMIT = 200
DESTINATIONS = {
    "userSettings": "configurações do usuário (todos os projetos)",
    "projectSettings": "configurações do projeto (arquivo compartilhado)",
    "localSettings": "configurações locais do projeto",
}


def rebuild_persist(suggestions: Any) -> tuple[list[dict], list[str], list[str], bool]:
    kept: list[dict] = []
    shown: list[str] = []
    where: list[str] = []
    hidden = False
    for item in suggestions if isinstance(suggestions, list) else []:
        if not (isinstance(item, dict) and item.get("type") == "addRules" and item.get("behavior") == "allow"
                and item.get("destination") in DESTINATIONS):
            continue
        rules = []
        for rule in item.get("rules") if isinstance(item.get("rules"), list) else []:
            tool = rule.get("toolName") if isinstance(rule, dict) else None
            content = rule.get("ruleContent") if isinstance(rule, dict) else None
            if not isinstance(tool, str) or not tool or not (content is None or isinstance(content, str)):
                continue
            clean = {"toolName": tool, **({"ruleContent": content} if content else {})}
            text = rule_text(clean)
            safe = escaped(text)
            hidden = hidden or safe != text or len(text) > RULE_LIMIT
            rules.append(clean)
            shown.append(safe)
            where.append(DESTINATIONS[item["destination"]])
        if rules:
            kept.append({"type": "addRules", "behavior": "allow", "destination": item["destination"], "rules": rules})
    return kept, shown, where, hidden
