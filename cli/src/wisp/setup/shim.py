import shlex
from pathlib import Path

from wisp.fsops import atomic_write
from wisp.paths import WispPaths
from wisp.report import StepReport

MARKER = "# wisp-shim v1"


def _content(paths: WispPaths) -> str:
    return f'#!/bin/sh\n{MARKER}\nexec {shlex.quote(str(paths.runtime / "venv/bin/wisp"))} "$@"\n'


def _ours(shim: Path) -> bool:
    try:
        return not shim.is_symlink() and MARKER in shim.read_text().splitlines()[:3]
    except (OSError, UnicodeDecodeError):
        return False


def setup_shim(paths: WispPaths) -> StepReport:
    shim = paths.bin / "wisp"
    content = _content(paths)
    if shim.is_symlink() or (shim.exists() and not _ours(shim)):
        return StepReport("shim", "failed", "já existe um comando wisp que não é do Wisp; ele foi mantido", data={"path": str(shim)})
    if shim.exists() and shim.read_text() == content and shim.stat().st_mode & 0o777 == 0o755:
        return StepReport("shim", "skipped", "o comando wisp já está instalado", data={"path": str(shim)})
    atomic_write(shim, content, mode=0o755)
    return StepReport("shim", "done", "comando wisp instalado", data={"path": str(shim)})
