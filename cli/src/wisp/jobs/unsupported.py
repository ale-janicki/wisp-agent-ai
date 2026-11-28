from wisp.jobs import JobSpec, JobState, NotSupportedHere
from wisp.report import Detail


class _Unsupported:
    name = ""

    def install(self, spec: JobSpec, *, load: bool = True) -> list[Detail]:
        raise NotSupportedHere(f"{self.name} jobs are not implemented yet")

    def remove(self, label: str) -> list[Detail]:
        raise NotSupportedHere(f"{self.name} jobs are not implemented yet")

    def state(self, label: str) -> JobState:
        raise NotSupportedHere(f"{self.name} jobs are not implemented yet")


class SystemdUserJobs(_Unsupported):
    name = "systemd"

