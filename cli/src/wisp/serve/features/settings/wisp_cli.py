import json
import sys
from collections.abc import Callable, Sequence

from wisp.runner import Runner, RunResult, SubprocessRunner

COULD_NOT_RUN = "Não consegui rodar o wisp."
TIMED_OUT = "O wisp demorou demais."
NO_ANSWER = "O wisp não respondeu."

runner_factory: Callable[[], Runner] = SubprocessRunner


def run_wisp(args: Sequence[str], *, stdin: bytes | None = None, timeout: float = 60) -> RunResult:
    return runner_factory().run([sys.executable, "-m", "wisp", *args], stdin=stdin, timeout=timeout)


def last_json(text: str) -> dict | None:
    for line in reversed(text.strip().splitlines()):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return None


def failed(summary: str, step: str = "") -> dict:
    return {"step": step, "status": "failed", "summary": summary, "details": [], "data": {}}


def report_of(result: RunResult, step: str = "") -> dict:
    if result.timed_out:
        return failed(TIMED_OUT, step)
    if result.exit == 127:
        return failed(COULD_NOT_RUN, step)
    report = last_json(result.stdout)
    if report is None or "status" not in report:
        return failed(NO_ANSWER, step)
    return report


def run_report(args: Sequence[str], *, step: str = "", stdin: bytes | None = None, timeout: float = 60) -> dict:
    return report_of(run_wisp(args, stdin=stdin, timeout=timeout), step)
