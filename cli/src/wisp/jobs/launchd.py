import plistlib
import re

from wisp.fsops import atomic_write, ensure_dir
from wisp.jobs import JobSpec, JobState, NotSupportedHere
from wisp.paths import WispPaths
from wisp.report import Detail
from wisp.runner import Runner

_TOP_LEVEL_FIELD = re.compile(r"^\t([^\t=][^=]*?) = (.*)$")


class LaunchdJobs:
    def __init__(self, paths: WispPaths, runner: Runner, uid: int):
        if paths.launch_agents is None:
            raise NotSupportedHere("this system has no LaunchAgents folder")
        self._agents = paths.launch_agents
        self._runner = runner
        self._domain = f"gui/{uid}"

    @staticmethod
    def render_plist(spec: JobSpec) -> bytes:
        return plistlib.dumps(
            {
                "Label": spec.label,
                "ProgramArguments": spec.program,
                "EnvironmentVariables": spec.env,
                "KeepAlive": spec.keep_alive,
                "RunAtLoad": spec.run_at_load,
                "ThrottleInterval": spec.throttle_s,
                "StandardOutPath": str(spec.log_path),
                "StandardErrorPath": str(spec.log_path),
            }
        )

    def _plist(self, label: str):
        return self._agents / f"{label}.plist"

    def _launchctl(self, *args: str) -> Detail:
        argv = ["launchctl", *args]
        result = self._runner.run(argv, timeout=30)
        return Detail.capture(" ".join(argv), result.exit, result.stdout, result.stderr)

    def install(self, spec: JobSpec, *, load: bool = True) -> list[Detail]:
        ensure_dir(spec.log_path.parent)
        plist = self._plist(spec.label)
        atomic_write(plist, self.render_plist(spec))
        if not load:
            return []
        return [
            self._launchctl("bootout", f"{self._domain}/{spec.label}"),
            self._launchctl("bootstrap", self._domain, str(plist)),
        ]

    def remove(self, label: str) -> list[Detail]:
        details = [self._launchctl("bootout", f"{self._domain}/{label}")]
        self._plist(label).unlink(missing_ok=True)
        return details

    def state(self, label: str) -> JobState:
        result = self._runner.run(["launchctl", "print", f"{self._domain}/{label}"], timeout=30)
        installed = JobState.INSTALLED if self._plist(label).exists() else JobState.NOT_INSTALLED
        if result.exit != 0:
            return installed
        fields = {}
        for line in result.stdout.splitlines():
            match = _TOP_LEVEL_FIELD.match(line)
            if match:
                fields[match.group(1)] = match.group(2).strip()
        if fields.get("state") == "running":
            return JobState.RUNNING
        exit_code = fields.get("last exit code", "").split(":")[0].strip()
        if exit_code.lstrip("-").isdigit() and int(exit_code) != 0:
            return JobState.FAILED
        return JobState.INSTALLED
