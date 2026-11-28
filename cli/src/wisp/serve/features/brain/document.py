from __future__ import annotations

from dataclasses import dataclass

PLAIN_STARTS = "[{&*!|>%@`'\"#-?:,"


@dataclass
class _Entry:
    key: str
    start: int
    end: int
    value: str | list[str]
    kind: str
    inline: bool


def _is_fence(line: str, opening: bool) -> bool:
    trimmed = line.strip()
    return trimmed == "---" or (not opening and trimmed == "...")


def _unquote(value: str) -> str:
    text = value.strip()
    if len(text) >= 2 and text[0] in "\"'" and text[-1] == text[0]:
        text = text[1:-1]
    return text


def _split_inline(inner: str) -> list[str]:
    parts, current, quote = [], "", None
    for char in inner:
        if quote:
            current += char
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
            current += char
        elif char == ",":
            parts.append(current)
            current = ""
        else:
            current += char
    parts.append(current)
    return [item for item in (_unquote(p) for p in parts) if item]


def _render(value: str) -> str:
    plain = value == "" or value[0] not in PLAIN_STARTS
    if plain and ": " not in value and " #" not in value and value == value.strip():
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Document:
    def __init__(self, text: str):
        self.opening, self.closing, self.closing_end = "---", "---", "\n"
        self.front: list[str] | None = None
        lines = text.split("\n")
        end = next((i for i in range(1, len(lines)) if _is_fence(lines[i], False)), None) if len(lines) > 1 and _is_fence(lines[0], True) else None
        if end is None:
            self.body = text
            return
        self.opening, self.closing = lines[0], lines[end]
        self.front = lines[1:end]
        last = end == len(lines) - 1
        self.closing_end = "" if last else "\n"
        self.body = "" if last else "\n".join(lines[end + 1 :])

    @property
    def text(self) -> str:
        if self.front is None:
            return self.body
        joined = "\n".join(self.front) + ("\n" if self.front else "")
        return self.opening + "\n" + joined + self.closing + self.closing_end + self.body

    def _entries(self) -> list[_Entry]:
        front = self.front or []
        found, i = [], 0
        while i < len(front):
            line = front[i]
            if not line or line[0] in " \t-#" or ":" not in line:
                i += 1
                continue
            colon = line.index(":")
            key, rest = line[:colon].strip(), line[colon + 1 :].strip()
            end = i + 1
            while end < len(front) and self._continues(front[end], rest == ""):
                end += 1
            value, kind = self._value(rest, front[i + 1 : end])
            found.append(_Entry(key, i, end, value, kind, rest.startswith("[")))
            i = end
        return found

    @staticmethod
    def _continues(line: str, empty_value: bool) -> bool:
        if not line:
            return True
        return line[0] in " \t" or (empty_value and line[0] == "-")

    @staticmethod
    def _value(rest: str, extra: list[str]) -> tuple[str | list[str], str]:
        content = [e for e in extra if e.strip()]
        if rest.startswith("[") and rest.endswith("]") and not content:
            return _split_inline(rest[1:-1]), "list"
        if not rest:
            if not content:
                return "", "text"
            items = [c.strip() for c in content]
            if all(i.startswith("-") for i in items):
                return [v for v in (_unquote(i[1:]) for i in items) if v], "list"
            return "\n".join(content), "complex"
        if content:
            return "\n".join([rest, *content]), "complex"
        return _unquote(rest), "text"

    def properties(self) -> list[dict]:
        return [{"key": e.key, "value": e.value, "kind": e.kind} for e in self._entries()]

    def set(self, key: str, value: str | list[str], complex_: bool = False) -> None:
        lines = list(self.front or [])
        carriage = "\r" if self.front and self.front[0].endswith("\r") else ""
        existing = next((e for e in self._entries() if e.key == key), None)
        block = not existing.inline if existing else True
        if complex_ and isinstance(value, str):
            rendered = [f"{key}:", *value.split("\n")]
        elif isinstance(value, str):
            rendered = [f"{key}:" if value == "" else f"{key}: {_render(value)}"]
        elif not value:
            rendered = [f"{key}: []"]
        elif not block:
            rendered = [f"{key}: [" + ", ".join(_render(v) for v in value) + "]"]
        else:
            indent = "  "
            if existing:
                dash = next((ln for ln in lines[existing.start + 1 : existing.end] if ln.strip().startswith("-")), None)
                if dash is not None:
                    indent = dash[: len(dash) - len(dash.lstrip(" \t"))]
            rendered = [f"{key}:", *(f"{indent}- {_render(v)}" for v in value)]
        if carriage:
            rendered = [r if r.endswith("\r") else r + carriage for r in rendered]
        if existing:
            lines[existing.start : existing.end] = rendered
        else:
            lines.extend(rendered)
        self.front = lines

    def remove(self, key: str) -> None:
        existing = next((e for e in self._entries() if e.key == key), None)
        if existing and self.front is not None:
            del self.front[existing.start : existing.end]
