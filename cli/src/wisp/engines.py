import re
import tomllib
from pathlib import Path

from wisp.fsops import atomic_write

ENGINES = ("claude", "codex")
DEFAULT_ENGINE = "claude"
TABLE_HEADER = re.compile(r"^[ \t]*\[", re.MULTILINE)
ACTIVE_LINE = re.compile(r'^(?P<head>[ \t]*ativo[ \t]*=[ \t]*)"[^"\n]*"', re.MULTILINE)


def modelos_path(wisp_dir: Path) -> Path:
    return wisp_dir / "modelos.toml"


def read_active(wisp_dir: Path) -> str:
    try:
        value = tomllib.loads(modelos_path(wisp_dir).read_text("utf-8")).get("ativo")
    except (OSError, ValueError):
        return DEFAULT_ENGINE
    return value if isinstance(value, str) and value else DEFAULT_ENGINE


def write_active(wisp_dir: Path, engine: str) -> None:
    path = modelos_path(wisp_dir)
    try:
        text = path.read_text("utf-8")
    except FileNotFoundError:
        text = ""
    table = TABLE_HEADER.search(text)
    top, rest = (text[: table.start()], text[table.start() :]) if table else (text, "")
    if ACTIVE_LINE.search(top):
        top = ACTIVE_LINE.sub(lambda m: f'{m.group("head")}"{engine}"', top, count=1)
    else:
        top = f'ativo = "{engine}"\n' + top
    atomic_write(path, top + rest)
