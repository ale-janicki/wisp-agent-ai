import xml.etree.ElementTree as ET
from dataclasses import replace
from pathlib import PureWindowsPath

import pytest

from wisp.jobs import JobSpec, JobState, manager_for
from wisp.jobs.taskscheduler import (
    NEVER_RUN, RUNNING, TaskInfo, TaskSchedulerJobs, describe_schedule, parse_query_csv, render_xml,
)
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult

NS = {"t": "http://schemas.microsoft.com/windows/2004/02/mit/task"}
LABEL = "ai.wisp.bot"
USER = r"PC\ana"


def _spec(home, **kw):
    base = dict(label=LABEL, program=[r"C:\wisp\venv\Scripts\wisp-bot.exe", "--flag", "a b"],
                env={"WISP_CONFIG": r"C:\cfg\wisp.json", "PATH": r"C:\bin;C:\win"}, log_path=home / "logs" / "bot.log")
    return JobSpec(**{**base, **kw})


def _ok(argv=(), out="", exit=0):
    return RunResult(list(argv), exit, out, "")


def _manager(home, script=None):
    windows = WispPaths.for_os("Windows", home, {"APPDATA": str(home / "AppData/Roaming"), "LOCALAPPDATA": str(home / "AppData/Local")})
    paths = replace(windows, state=home / "AppData/Local/wisp/state")
    runner = FakeRunner(script)
    return TaskSchedulerJobs(paths, runner, user=USER), runner, paths


def _csv(label, status="Ready", last="0"):
    cols = ["PC", f"\\{label}", "N/A", status, "Interactive only", "30/11/1999 00:00:00", last, "ana", "cmd.exe /d /s /c x",
            "N/A", "N/A", "Enabled"]
    return ",".join(f'"{c}"' for c in cols) + "\n"


def test_xml_is_a_user_level_task_with_logon_trigger_and_restart(fake_home):
    root = ET.fromstring(render_xml(_spec(fake_home), USER).split("?>", 1)[1])
    assert root.find("t:Principals/t:Principal/t:RunLevel", NS).text == "LeastPrivilege"
    assert root.find("t:Principals/t:Principal/t:LogonType", NS).text == "InteractiveToken"
    assert root.find("t:Triggers/t:LogonTrigger/t:UserId", NS).text == USER
    assert root.find("t:Settings/t:RestartOnFailure/t:Interval", NS).text == "PT1M"
    assert root.find("t:Settings/t:ExecutionTimeLimit", NS).text == "PT0S"
    assert root.find("t:Settings/t:MultipleInstancesPolicy", NS).text == "IgnoreNew"
    assert root.find("t:Settings/t:DisallowStartIfOnBatteries", NS).text == "false"
    assert root.find("t:RegistrationInfo/t:Description", NS).text == LABEL


def test_xml_runs_cmd_with_env_program_and_log_redirect(fake_home):
    spec = _spec(fake_home)
    root = ET.fromstring(render_xml(spec, USER).split("?>", 1)[1])
    assert root.find("t:Actions/t:Exec/t:Command", NS).text == "cmd.exe"
    args = root.find("t:Actions/t:Exec/t:Arguments", NS).text
    assert args.startswith('/d /s /c "')
    assert 'set "WISP_CONFIG=C:\\cfg\\wisp.json"' in args
    assert '"C:\\wisp\\venv\\Scripts\\wisp-bot.exe" --flag "a b"' in args
    assert args.endswith(f'>> "{spec.log_path}" 2>&1"')


def test_xml_without_keep_alive_or_load_has_no_trigger_and_no_restart(fake_home):
    root = ET.fromstring(render_xml(_spec(fake_home, keep_alive=False, run_at_load=False), USER).split("?>", 1)[1])
    assert root.find("t:Triggers/t:LogonTrigger", NS) is None
    assert root.find("t:Settings/t:RestartOnFailure", NS) is None


def test_xml_throttle_rounds_up_to_whole_minutes(fake_home):
    root = ET.fromstring(render_xml(_spec(fake_home, throttle_s=61), USER).split("?>", 1)[1])
    assert root.find("t:Settings/t:RestartOnFailure/t:Interval", NS).text == "PT2M"


def test_xml_escapes_markup_in_values(fake_home):
    xml = render_xml(_spec(fake_home, env={"A": "x<y&z"}), USER)
    ET.fromstring(xml.split("?>", 1)[1])
    assert "x&lt;y&amp;z" in xml


@pytest.mark.parametrize("bad", ['50%', 'say "hi"', "two\nlines"])
def test_values_cmd_would_reinterpret_are_refused(fake_home, bad):
    with pytest.raises(ValueError):
        render_xml(_spec(fake_home, env={"A": bad}), USER)
    with pytest.raises(ValueError):
        render_xml(_spec(fake_home, program=["x.exe", bad]), USER)


def test_install_writes_utf16_xml_and_registers_then_runs(fake_home):
    manager, runner, paths = _manager(fake_home)
    details = manager.install(_spec(fake_home))
    xml = (paths.state / "tasks" / f"{LABEL}.xml")
    raw = xml.read_bytes()
    assert raw[:2] == b"\xff\xfe"
    assert 'encoding="UTF-16"' in raw.decode("utf-16")
    assert runner.calls == [
        ["schtasks.exe", "/End", "/TN", LABEL],
        ["schtasks.exe", "/Create", "/TN", LABEL, "/XML", str(xml), "/F"],
        ["schtasks.exe", "/Run", "/TN", LABEL],
    ]
    assert [d.command for d in details][1].startswith("schtasks.exe /Create")


def test_install_without_load_only_creates(fake_home):
    manager, runner, _ = _manager(fake_home)
    manager.install(_spec(fake_home), load=False)
    assert [c[1] for c in runner.calls] == ["/Create"]


def test_remove_ends_deletes_and_drops_the_xml(fake_home):
    manager, runner, paths = _manager(fake_home)
    manager.install(_spec(fake_home), load=False)
    manager.remove(LABEL)
    assert runner.calls[-2:] == [["schtasks.exe", "/End", "/TN", LABEL], ["schtasks.exe", "/Delete", "/TN", LABEL, "/F"]]
    assert not (paths.state / "tasks" / f"{LABEL}.xml").exists()


def test_parse_query_csv_reads_fixed_columns_not_localised_headers():
    rows = parse_query_csv(_csv("a.b") + _csv("c.d", status="Em execução", last="267009") + "\n")
    assert [(r.label, r.status, r.last_result) for r in rows] == [("a.b", "Ready", 0), ("c.d", "Em execução", 267009)]


def test_parse_query_csv_skips_repeated_trigger_rows_and_folders():
    rows = parse_query_csv(_csv("a.b") + ",".join(['""'] * 12) + "\n" + _csv("a.b"))
    assert [r.label for r in rows] == ["a.b"]


@pytest.mark.parametrize(
    ("status", "last", "expected"),
    [("Ready", "0", JobState.INSTALLED), ("Running", str(RUNNING), JobState.RUNNING), ("Em execução", str(RUNNING), JobState.RUNNING),
     ("Ready", "1", JobState.FAILED), ("Ready", "-2147020576", JobState.FAILED), ("Ready", str(NEVER_RUN), JobState.INSTALLED)],
)
def test_state_from_query(fake_home, status, last, expected):
    manager, runner, _ = _manager(fake_home, {("schtasks.exe", "/Query"): _ok(out=_csv(LABEL, status, last))})
    assert manager.state(LABEL) == expected
    assert runner.calls[0][:4] == ["schtasks.exe", "/Query", "/TN", LABEL]


def test_state_missing_task_is_not_installed(fake_home):
    manager, _, _ = _manager(fake_home, {("schtasks.exe", "/Query"): _ok(exit=1)})
    assert manager.state(LABEL) == JobState.NOT_INSTALLED


def test_manager_for_windows_gets_task_scheduler(fake_home):
    paths = WispPaths.for_os("Windows", fake_home, {})
    assert isinstance(manager_for("Windows", paths, FakeRunner(), 0), TaskSchedulerJobs)


def test_list_matches_prefixes_and_reads_each_task_xml(fake_home):
    ours = render_xml(_spec(fake_home), USER).replace('"UTF-16"', '"UTF-8"')
    manager, runner, _ = _manager(fake_home, {
        ("schtasks.exe", "/Query", "/FO"): _ok(out=_csv("ai.wisp.bot", "Running", str(RUNNING)) + _csv("Microsoft.Other") + _csv("ai.wisp.news", "Disabled")),
        ("schtasks.exe", "/Query", "/TN"): _ok(out=ours),
    })
    jobs = manager.list_tasks(["ai.wisp."])
    assert [j.label for j in jobs] == ["ai.wisp.bot", "ai.wisp.news"]
    assert jobs[0].state == JobState.RUNNING and jobs[0].enabled
    assert jobs[0].schedule == "sempre ligado"
    assert jobs[0].logs == [str(_spec(fake_home).log_path)]
    assert not jobs[1].enabled
    assert manager.list_tasks([""]) == [] and manager.list_tasks([]) == []


def test_list_also_returns_exact_registry_labels_outside_the_prefixes(fake_home):
    manager, _, _ = _manager(fake_home, {
        ("schtasks.exe", "/Query", "/FO"): _ok(out=_csv("ai.wisp.bot") + _csv("other.thing") + _csv("other.thing2")),
        ("schtasks.exe", "/Query", "/TN"): _ok(exit=1),
    })
    assert [j.label for j in manager.list_tasks(["ai.wisp."], ("other.thing",))] == ["ai.wisp.bot", "other.thing"]
    assert [j.label for j in manager.list_tasks([], ("other.thing",))] == ["other.thing"]


def test_set_enabled_disables_after_ending_and_enables_before_running(fake_home):
    manager, runner, _ = _manager(fake_home)
    manager.set_enabled(LABEL, False, run=False)
    assert runner.calls == [["schtasks.exe", "/End", "/TN", LABEL], ["schtasks.exe", "/Change", "/TN", LABEL, "/DISABLE"]]
    runner.calls.clear()
    manager.set_enabled(LABEL, True, run=True)
    assert runner.calls == [["schtasks.exe", "/Change", "/TN", LABEL, "/ENABLE"], ["schtasks.exe", "/Run", "/TN", LABEL]]


def _task_xml(triggers, restart=False):
    settings = "<RestartOnFailure><Interval>PT1M</Interval><Count>9</Count></RestartOnFailure>" if restart else ""
    return ('<?xml version="1.0" encoding="UTF-16"?><Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
            f"<Triggers>{triggers}</Triggers><Settings>{settings}</Settings></Task>")


@pytest.mark.parametrize(
    ("triggers", "restart", "expected"),
    [("<LogonTrigger/>", True, "sempre ligado"), ("<LogonTrigger/>", False, "ao ligar"), ("", False, "sob demanda"),
     ("<TimeTrigger><Repetition><Interval>PT15M</Interval></Repetition></TimeTrigger>", False, "a cada 15 min"),
     ("<TimeTrigger><Repetition><Interval>PT2H</Interval></Repetition></TimeTrigger>", False, "a cada 2 h"),
     ("<TimeTrigger><Repetition><Interval>PT90S</Interval></Repetition></TimeTrigger>", False, "a cada 1 min 30 s"),
     ("<CalendarTrigger><StartBoundary>2025-01-01T07:05:00</StartBoundary><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>", False, "todo dia 07:05"),
     ("<CalendarTrigger><StartBoundary>2025-01-01T09:00:00</StartBoundary><ScheduleByWeek><DaysOfWeek><Monday/></DaysOfWeek></ScheduleByWeek></CalendarTrigger>", False, "toda seg 09:00"),
     ("<LogonTrigger/><TimeTrigger><StartBoundary>2025-01-01T09:00:00</StartBoundary></TimeTrigger>", False, "2 horários")],
)
def test_describe_schedule(triggers, restart, expected):
    assert describe_schedule(_task_xml(triggers, restart))[0] == expected


def test_describe_schedule_unreadable_xml_is_on_demand():
    assert describe_schedule("not xml") == ("sob demanda", True, [])


def test_taskinfo_is_a_plain_record():
    assert TaskInfo("a", JobState.INSTALLED, True, "sob demanda", []).label == "a"
    assert PureWindowsPath(r"C:\x").name == "x"
