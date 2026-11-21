import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from wisp.fsops import atomic_write

FILE = "modelos.toml"
SECTION = re.compile(r"^\s*\[([^\]]+)\]\s*(#.*)?$")


class ModelosError(Exception):
    pass


@dataclass(frozen=True)
class LocalState:
    ativo: str = ""
    instalados: tuple[str, ...] = field(default_factory=tuple)


def read(folder: Path) -> LocalState:
    path = folder / FILE
    try:
        raw = tomllib.loads(path.read_text("utf-8"))
    except FileNotFoundError:
        return LocalState()
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as e:
        raise ModelosError(f"{FILE}: não consegui ler {path} ({type(e).__name__})") from None
    local = raw.get("local", {})
    ativo, instalados = local.get("ativo", ""), local.get("instalados", [])
    if not isinstance(ativo, str) or not isinstance(instalados, list) or not all(isinstance(t, str) for t in instalados):
        raise ModelosError(f'{FILE}: [local] precisa de ativo = "tag" e instalados = ["tag", ...]')
    return LocalState(ativo, tuple(instalados))


def _block(state: LocalState) -> str:
    listed = ", ".join(f'"{tag}"' for tag in state.instalados)
    return f'[local]\nativo = "{state.ativo}"\ninstalados = [{listed}]\n'


def render(text: str, state: LocalState) -> str:
    kept: list[str] = []
    inside = False
    for line in text.splitlines(keepends=True):
        match = SECTION.match(line)
        if match:
            inside = match.group(1).strip() == "local"
        if not inside:
            kept.append(line)
    body = "".join(kept).rstrip("\n")
    return (body + "\n\n" if body else "") + _block(state)


def write(folder: Path, state: LocalState) -> None:
    path = folder / FILE
    read(folder)
    text = path.read_text("utf-8") if path.exists() else ""
    atomic_write(path, render(text, state))


def with_installed(state: LocalState, tag: str) -> LocalState:
    return LocalState(state.ativo, state.instalados if tag in state.instalados else (*state.instalados, tag))


def with_active(state: LocalState, tag: str) -> LocalState:
    return LocalState(tag, state.instalados)
