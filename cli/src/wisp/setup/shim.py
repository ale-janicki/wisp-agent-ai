import shlex
import sys
from pathlib import Path

from wisp.fsops import atomic_write
from wisp.paths import WispPaths, exe, venv_bin
from wisp.report import StepReport

MARKER = "# wisp-shim v1"


def _target(paths: WispPaths) -> Path:
    return paths.bin / ("wisp.cmd" if sys.platform == "win32" else "wisp")


def _content(paths: WispPaths) -> str:
    wisp = venv_bin(paths.runtime / "venv") / exe("wisp")
    if sys.platform == "win32":
        return f'@echo off\r\nrem {MARKER}\r\n"{wisp}" %*\r\n'
    return f'#!/bin/sh\n{MARKER}\nexec {shlex.quote(str(wisp))} "$@"\n'


def _ours(shim: Path) -> bool:
    try:
        return not shim.is_symlink() and MARKER in shim.read_text().splitlines()[:3]
    except (OSError, UnicodeDecodeError):
        return False


def setup_shim(paths: WispPaths) -> StepReport:
    shim = _target(paths)
    content = _content(paths)
    if shim.is_symlink() or (shim.exists() and not _ours(shim)):
        return StepReport("shim", "failed", "já existe um comando wisp que não é do Wisp; ele foi mantido", data={"path": str(shim)})
    if shim.exists() and shim.read_text() == content and (sys.platform == "win32" or shim.stat().st_mode & 0o777 == 0o755):
        return StepReport("shim", "skipped", "o comando wisp já está instalado", data={"path": str(shim)})
    atomic_write(shim, content, mode=0o755)
    return StepReport("shim", "done", "comando wisp instalado", data={"path": str(shim)})
