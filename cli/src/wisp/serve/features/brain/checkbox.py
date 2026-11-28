import re

BOX = re.compile(r"^[ \t>]*(?:[-*+]|\d+[.)])[ \t]+\[([ xX])\](?:[ \t]|$)")


def normalized(line: str) -> str:
    return line.lstrip(" \t>").strip()


def toggle(text: str, line: int, expected: str | None = None) -> str | None:
    lines = text.split("\n")
    if not 0 <= line < len(lines):
        return None
    current = lines[line]
    if expected is not None and normalized(current) != normalized(expected):
        return None
    match = BOX.match(current)
    if not match:
        return None
    start = match.start(1)
    lines[line] = current[:start] + ("x" if current[start] == " " else " ") + current[start + 1 :]
    return "\n".join(lines)
