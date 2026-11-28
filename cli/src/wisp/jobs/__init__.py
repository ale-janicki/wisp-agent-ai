from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Protocol

from wisp.paths import WispPaths
from wisp.report import Detail
from wisp.runner import Runner


class NotSupportedHere(Exception):
    pass


@dataclass(frozen=True)
class JobSpec:
    label: str
    program: list[str]
    env: dict[str, str]
    log_path: Path
    keep_alive: bool = True
    run_at_load: bool = True
    throttle_s: int = 10


class JobState(Enum):
    NOT_INSTALLED = "not_installed"
    INSTALLED = "installed"
    RUNNING = "running"
    FAILED = "failed"


class JobManager(Protocol):
    def install(self, spec: JobSpec, *, load: bool = True) -> list[Detail]: ...
    def remove(self, label: str) -> list[Detail]: ...
    def state(self, label: str) -> JobState: ...


def manager_for(system: str, paths: WispPaths, runner: Runner, uid: int) -> JobManager:
    from wisp.jobs.launchd import LaunchdJobs
    from wisp.jobs.taskscheduler import TaskSchedulerJobs
    from wisp.jobs.unsupported import SystemdUserJobs

    if system == "Darwin":
        return LaunchdJobs(paths, runner, uid)
    return TaskSchedulerJobs(paths, runner) if system == "Windows" else SystemdUserJobs()
