import os
import signal
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass
class RunResult:
    argv: list[str]
    exit: int
    stdout: str
    stderr: str
    timed_out: bool = False


class Runner(Protocol):
    def run(
        self,
        argv: Sequence[str],
        *,
        stdin: bytes | None = None,
        timeout: float = 60,
        env: Mapping[str, str] | None = None,
        cwd: Path | None = None,
    ) -> RunResult: ...


class SubprocessRunner:
    def run(self, argv, *, stdin=None, timeout=60, env=None, cwd=None) -> RunResult:
        args = list(argv)
        try:
            proc = subprocess.Popen(
                args,
                stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=dict(env) if env is not None else None,
                cwd=cwd,
                start_new_session=True,
            )
        except OSError as e:
            return RunResult(args, 127, "", str(e))
        try:
            out, err = proc.communicate(stdin, timeout=timeout)
            return RunResult(args, proc.returncode, out.decode(errors="replace"), err.decode(errors="replace"))
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            out, err = proc.communicate()
            return RunResult(args, -9, out.decode(errors="replace"), err.decode(errors="replace"), timed_out=True)


class FakeRunner:
    def __init__(self, script: Mapping[tuple[str, ...], RunResult] | None = None):
        self.script = dict(script or {})
        self.calls: list[list[str]] = []

    def run(self, argv, *, stdin=None, timeout=60, env=None, cwd=None) -> RunResult:
        args = list(argv)
        self.calls.append(args)
        best = max((k for k in self.script if tuple(args[: len(k)]) == k), key=len, default=None)
        if best is None:
            return RunResult(args, 127, "", "no scripted result")
        return self.script[best]
