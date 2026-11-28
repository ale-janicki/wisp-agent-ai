from __future__ import annotations

import contextlib
import subprocess
from dataclasses import dataclass

from wisp.compat import kill_process_tree, new_session_kwargs


@dataclass
class Ran:
    status: int | None
    stdout: bytes
    timed_out: bool = False
    started: bool = True


def run_command(argv: list[str], env: dict[str, str] | None = None, timeout: float = 10.0,
                stdin: bytes | None = None) -> Ran:
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, **new_session_kwargs())
    except OSError:
        return Ran(None, b"", started=False)
    try:
        out, _ = proc.communicate(stdin, timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError, PermissionError):
            kill_process_tree(proc.pid)
        with contextlib.suppress(subprocess.TimeoutExpired, OSError):
            proc.communicate(timeout=2)
        return Ran(None, b"", timed_out=True)
    return Ran(proc.returncode, out or b"")
