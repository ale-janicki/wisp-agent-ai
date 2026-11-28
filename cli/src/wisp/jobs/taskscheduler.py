import csv
import io
import math
import os
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from xml.sax.saxutils import escape

from wisp.fsops import atomic_write, ensure_dir
from wisp.jobs import JobSpec, JobState
from wisp.paths import WispPaths
from wisp.report import Detail
from wisp.runner import Runner

SCHTASKS = "schtasks.exe"
NAMESPACE = "http://schemas.microsoft.com/windows/2004/02/mit/task"
RUNNING = 267009
NEVER_RUN = 267011
NOT_FAILURES = frozenset({0, 267008, 267009, 267010, 267011, 267012})
RUNNING_WORDS = frozenset({"running", "em execução", "executando"})
DISABLED_WORDS = frozenset({"disabled", "desabilitado", "desativado"})
_LABEL_COLUMN, _STATUS_COLUMN, _RESULT_COLUMN = 1, 3, 6
_DECLARATION = re.compile(r"^\s*<\?xml[^>]*\?>")
_LOG_REDIRECT = re.compile(r'>>\s*"([^"]+)"')
_WEEKDAYS = {"Sunday": "dom", "Monday": "seg", "Tuesday": "ter", "Wednesday": "qua", "Thursday": "qui", "Friday": "sex", "Saturday": "sáb"}
_DURATION = re.compile(r"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$")


@dataclass(frozen=True)
class QueryRow:
    label: str
    status: str
    last_result: int


@dataclass(frozen=True)
class TaskInfo:
    label: str
    state: JobState
    enabled: bool
    schedule: str
    logs: list[str] = field(default_factory=list)
    last_result: int = 0


def _cmd_word(value: str) -> str:
    if any(ch in value for ch in '%"\r\n'):
        raise ValueError(f"o Agendador de Tarefas não aceita este valor: {value!r}")
    return value


def _quoted(value: str) -> str:
    return f'"{_cmd_word(value)}"'


def _program_word(value: str) -> str:
    _cmd_word(value)
    return f'"{value}"' if re.search(r"[\s&|<>^()]", value) or not value else value


def command_line(spec: JobSpec) -> tuple[str, str]:
    sets = [f'set "{_cmd_word(key)}={_cmd_word(value)}"' for key, value in spec.env.items()]
    program = " ".join([_quoted(spec.program[0]), *(_program_word(arg) for arg in spec.program[1:])])
    body = " && ".join([*sets, f'{program} >> {_quoted(str(spec.log_path))} 2>&1'])
    return "cmd.exe", f'/d /s /c "{body}"'


def render_xml(spec: JobSpec, user: str | None) -> str:
    command, arguments = command_line(spec)
    minutes = max(1, math.ceil(spec.throttle_s / 60))
    trigger = ""
    if spec.run_at_load or spec.keep_alive:
        who = f"<UserId>{escape(user)}</UserId>" if user else ""
        trigger = f"<LogonTrigger><Enabled>true</Enabled>{who}</LogonTrigger>"
    restart = f"<RestartOnFailure><Interval>PT{minutes}M</Interval><Count>999</Count></RestartOnFailure>" if spec.keep_alive else ""
    return (
        '<?xml version="1.0" encoding="UTF-16"?>\n'
        f'<Task version="1.4" xmlns="{NAMESPACE}">'
        f"<RegistrationInfo><Description>{escape(spec.label)}</Description></RegistrationInfo>"
        f"<Triggers>{trigger}</Triggers>"
        '<Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>'
        "<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"
        "<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>"
        "<AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable>"
        "<AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden>"
        f"<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>{restart}</Settings>"
        f'<Actions Context="Author"><Exec><Command>{escape(command)}</Command><Arguments>{escape(arguments)}</Arguments></Exec></Actions>'
        "</Task>"
    )


def parse_query_csv(text: str) -> list[QueryRow]:
    rows: list[QueryRow] = []
    seen: set[str] = set()
    for cells in csv.reader(io.StringIO(text)):
        if len(cells) <= _RESULT_COLUMN or not cells[_LABEL_COLUMN].startswith("\\"):
            continue
        label = cells[_LABEL_COLUMN].rsplit("\\", 1)[-1]
        if not label or label in seen:
            continue
        seen.add(label)
        try:
            last = int(cells[_RESULT_COLUMN].strip())
        except ValueError:
            last = 0
        rows.append(QueryRow(label, cells[_STATUS_COLUMN].strip(), last))
    return rows


def _state(row: QueryRow) -> JobState:
    if row.last_result == RUNNING or row.status.lower() in RUNNING_WORDS:
        return JobState.RUNNING
    return JobState.INSTALLED if row.last_result in NOT_FAILURES else JobState.FAILED


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _duration(text: str) -> int | None:
    match = _DURATION.match(text.strip())
    if not match or not any(match.groups()):
        return None
    hours, minutes, seconds = (int(part or 0) for part in match.groups())
    return hours * 3600 + minutes * 60 + seconds


def _every(seconds: int) -> str:
    if seconds < 60:
        return f"a cada {seconds} s"
    if seconds % 3600 == 0:
        return f"a cada {seconds // 3600} h"
    if seconds % 60 == 0:
        return f"a cada {seconds // 60} min"
    return f"a cada {seconds // 60} min {seconds % 60} s"


def _trigger_text(trigger: ET.Element) -> str:
    kind = _local(trigger.tag)
    fields = {_local(el.tag): el for el in trigger.iter()}
    if kind == "LogonTrigger" or kind == "BootTrigger":
        return "ao ligar"
    interval = fields.get("Interval")
    seconds = _duration(interval.text or "") if interval is not None else None
    if seconds:
        return _every(seconds)
    start = fields.get("StartBoundary")
    when = (start.text or "")[11:16] if start is not None and len(start.text or "") >= 16 else "00:00"
    if "DaysOfWeek" in fields:
        days = [_WEEKDAYS.get(_local(day.tag), _local(day.tag)) for day in fields["DaysOfWeek"]]
        return f"toda {'/'.join(days)} {when}" if days else f"todo dia {when}"
    return f"todo dia {when}"


def describe_schedule(xml: str) -> tuple[str, bool, list[str]]:
    try:
        root = ET.fromstring(_DECLARATION.sub("", xml, count=1))
    except ET.ParseError:
        return "sob demanda", True, []
    nodes = {_local(el.tag): el for el in root.iter()}
    settings = nodes.get("Settings")
    enabled = True
    if settings is not None:
        flag = next((child for child in settings if _local(child.tag) == "Enabled"), None)
        enabled = flag is None or (flag.text or "").strip().lower() != "false"
    triggers = [child for el in root.iter() if _local(el.tag) == "Triggers" for child in el]
    if any(_local(el.tag) == "RestartOnFailure" for el in root.iter()) and any(_local(t.tag) == "LogonTrigger" for t in triggers):
        schedule = "sempre ligado"
    elif not triggers:
        schedule = "sob demanda"
    elif len(triggers) > 1:
        schedule = f"{len(triggers)} horários"
    else:
        schedule = _trigger_text(triggers[0])
    arguments = " ".join((el.text or "") for el in root.iter() if _local(el.tag) == "Arguments")
    logs = list(dict.fromkeys(_LOG_REDIRECT.findall(arguments)))
    return schedule, enabled, logs


class TaskSchedulerJobs:
    def __init__(self, paths: WispPaths, runner: Runner, user: str | None = None):
        self._xml_dir = paths.state / "tasks"
        self._runner = runner
        self._user = user if user is not None else _current_user()

    def _schtasks(self, *args: str, timeout: float = 30) -> Detail:
        argv = [SCHTASKS, *args]
        result = self._runner.run(argv, timeout=timeout)
        return Detail.capture(" ".join(argv), result.exit, result.stdout, result.stderr)

    def install(self, spec: JobSpec, *, load: bool = True) -> list[Detail]:
        xml = render_xml(spec, self._user)
        ensure_dir(spec.log_path.parent)
        ensure_dir(self._xml_dir)
        path = self._xml_dir / f"{spec.label}.xml"
        atomic_write(path, b"\xff\xfe" + xml.encode("utf-16-le"))
        details = [self._schtasks("/End", "/TN", spec.label)] if load else []
        details.append(self._schtasks("/Create", "/TN", spec.label, "/XML", str(path), "/F"))
        if load:
            details.append(self._schtasks("/Run", "/TN", spec.label))
        return details

    def remove(self, label: str) -> list[Detail]:
        details = [self._schtasks("/End", "/TN", label), self._schtasks("/Delete", "/TN", label, "/F")]
        (self._xml_dir / f"{label}.xml").unlink(missing_ok=True)
        return details

    def _row(self, label: str) -> QueryRow | None:
        result = self._runner.run([SCHTASKS, "/Query", "/TN", label, "/V", "/FO", "CSV", "/NH"], timeout=30)
        rows = parse_query_csv(result.stdout) if result.exit == 0 else []
        return rows[0] if rows else None

    def state(self, label: str) -> JobState:
        row = self._row(label)
        return JobState.NOT_INSTALLED if row is None else _state(row)

    def list_tasks(self, prefixes: list[str], labels: tuple[str, ...] = ()) -> list[TaskInfo]:
        wanted = tuple(p for p in prefixes if p)
        if not wanted and not labels:
            return []
        result = self._runner.run([SCHTASKS, "/Query", "/FO", "CSV", "/V", "/NH"], timeout=60)
        rows = [row for row in parse_query_csv(result.stdout)
                if result.exit == 0 and ((wanted and row.label.startswith(wanted)) or row.label in labels)]
        tasks = []
        for row in sorted(rows, key=lambda r: r.label):
            detail = self._runner.run([SCHTASKS, "/Query", "/TN", row.label, "/XML"], timeout=30)
            schedule, enabled, logs = describe_schedule(detail.stdout) if detail.exit == 0 else ("sob demanda", True, [])
            tasks.append(TaskInfo(row.label, _state(row), enabled and row.status.lower() not in DISABLED_WORDS, schedule, logs, row.last_result))
        return tasks

    def set_enabled(self, label: str, on: bool, *, run: bool) -> list[Detail]:
        if not on:
            return [self._schtasks("/End", "/TN", label), self._schtasks("/Change", "/TN", label, "/DISABLE")]
        details = [self._schtasks("/Change", "/TN", label, "/ENABLE")]
        if run:
            details.append(self._schtasks("/Run", "/TN", label))
        return details


def _current_user() -> str | None:
    name = os.environ.get("USERNAME")
    domain = os.environ.get("USERDOMAIN")
    return f"{domain}\\{name}" if name and domain else name
