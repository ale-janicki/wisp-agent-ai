import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from wisp import brain_colher
from wisp.brain_colher import Candidate, MAX_CHARS, read_slice, run, trim
from wisp.config import TelegramConfig, WispConfig
from wisp.runner import RunResult, SubprocessRunner

FIXTURE = Path(__file__).parent / "fixtures" / "brain_colher" / "transcript.jsonl"
CWD = "/work/proj"
SID = "11111111-aaaa-bbbb-cccc-000000000001"
OTHER = "22222222-aaaa-bbbb-cccc-000000000002"


class StubRunner:
    def __init__(self, exit=0, timed_out=False):
        self.calls = []
        self.exit = exit
        self.timed_out = timed_out

    def run(self, argv, *, stdin=None, timeout=60, env=None, cwd=None):
        self.calls.append({"argv": list(argv), "stdin": stdin, "timeout": timeout, "cwd": cwd, "env": env})
        return RunResult(list(argv), self.exit, "", "boom" if self.exit else "", timed_out=self.timed_out)


@pytest.fixture
def world(fake_home):
    brain = fake_home / "brain"
    brain.mkdir()
    cfg = WispConfig(
        brain=str(brain),
        claude_bin="/bin/echo",
        telegram=TelegramConfig(chat_id=1, user_id=1, token_file="t", state_dir=str(fake_home / "botstate")),
    )
    return fake_home, brain, cfg


def put_transcript(home, sid=SID, cwd=CWD, age=3600):
    path = brain_colher.transcript_path(sid, cwd)
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(FIXTURE, path)
    stamp = time.time() - age
    os.utime(path, (stamp, stamp))
    return path


def put_app(home, *records):
    path = home / "Library/Application Support/Wisp/conversations.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(list(records)))


def app_record(sid=SID, cwd=CWD, title="Atlas"):
    return {"id": "x", "sessionId": sid, "cwd": cwd, "title": title}


def motivos(report):
    return {p["sid"]: p["motivo"] for p in report["puladas"]}


def test_slice_counts_only_real_user_messages():
    piece = read_slice(FIXTURE, 0)
    assert piece.user_messages == 3
    assert "tool_result" not in piece.text and "segredo" not in piece.text
    assert "contexto do bot" not in piece.text and "Image:" not in piece.text and "command-name" not in piece.text
    assert piece.text.startswith("User: Prefiro respostas curtas")
    assert "Assistant: Registrado: Atlas usa Postgres." in piece.text
    assert "thinking" not in piece.text
    assert piece.end == FIXTURE.stat().st_size


def test_slice_ignores_partial_last_line(tmp_path):
    path = tmp_path / "t.jsonl"
    path.write_bytes(FIXTURE.read_bytes() + b'{"type":"user","message":{"cont')
    piece = read_slice(path, 0)
    assert piece.end == FIXTURE.stat().st_size
    assert piece.user_messages == 3


def test_slice_from_offset_sends_only_the_new_part():
    full = FIXTURE.read_bytes()
    cut = full.index(b"Decidimos")
    cut = full.rfind(b"\n", 0, cut) + 1
    piece = read_slice(FIXTURE, cut)
    assert piece.user_messages == 2
    assert "Prefiro" not in piece.text


def test_trim_keeps_the_tail():
    text = "a" * 70_000 + "FIM"
    out = trim(text)
    assert len(out) == MAX_CHARS and out.endswith("FIM")


def test_eligible_session_is_harvested_and_ledger_advances(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    runner = StubRunner()
    report = run(cfg, runner)
    assert report["colhidas"] == [SID] and report["puladas"] == []
    call = runner.calls[0]
    assert call["cwd"] == brain
    assert call["timeout"] == 600
    assert call["argv"][0] == "/bin/echo"
    argv = call["argv"]
    assert argv[argv.index("--tools") + 1] == "Read,Write,Edit,Glob,Grep"
    assert "--add-dir" not in argv
    assert b"User: Decidimos usar Postgres" in call["stdin"]
    ledger = json.loads((home / ".local/state/wisp/brain/colhidos.json").read_text())
    assert ledger[SID]["offset"] == FIXTURE.stat().st_size
    settings = json.loads((home / ".local/state/wisp/brain/guard-settings.json").read_text())
    assert len(settings["hooks"]["PreToolUse"][0]["hooks"]) == 3
    scope = settings["hooks"]["PreToolUse"][1]
    assert scope["matcher"] == "Read|Write|Edit|MultiEdit|NotebookEdit|Glob|Grep"
    assert scope["hooks"][0]["command"].endswith("hook guard-brain-scope")
    assert call["env"]["WISP_BRAIN_SCOPE"] == str(brain.resolve())
    assert call["env"]["WISP_RECALL_OFF"] == "1"


def test_second_run_has_nothing_new(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    run(cfg, StubRunner())
    runner = StubRunner()
    report = run(cfg, runner)
    assert runner.calls == []
    assert report["colhidas"] == []
    assert motivos(report)[SID] == "so 0 mensagens novas"


def test_only_new_part_after_offset_is_sent(world):
    home, brain, cfg = world
    put_app(home, app_record())
    path = put_transcript(home)
    run(cfg, StubRunner())
    extra = "".join(
        json.dumps({"type": "user", "message": {"role": "user", "content": f"novo fato {i}"}}) + "\n" for i in range(3)
    )
    with path.open("a") as handle:
        handle.write(extra)
    stamp = time.time() - 3600
    os.utime(path, (stamp, stamp))
    runner = StubRunner()
    report = run(cfg, runner)
    assert report["colhidas"] == [SID]
    assert b"novo fato 2" in runner.calls[0]["stdin"] and b"Postgres" not in runner.calls[0]["stdin"]


def test_recent_transcript_is_skipped(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home, age=60)
    runner = StubRunner()
    report = run(cfg, runner)
    assert runner.calls == [] and "30 min" in motivos(report)[SID]


def test_too_few_user_messages_is_skipped(world):
    home, brain, cfg = world
    put_app(home, app_record())
    path = put_transcript(home)
    lines = FIXTURE.read_text().splitlines()[:5]
    path.write_text("\n".join(lines) + "\n")
    stamp = time.time() - 3600
    os.utime(path, (stamp, stamp))
    runner = StubRunner()
    report = run(cfg, runner)
    assert runner.calls == [] and motivos(report)[SID] == "so 1 mensagens novas"


def test_dedupes_app_and_bot_by_session_id(world):
    home, brain, cfg = world
    put_app(home, app_record())
    state = home / "botstate"
    state.mkdir()
    (state / "topics.json").write_text(json.dumps({
        "1:0": {"name": "Geral", "session_id": SID, "cwd": CWD},
        "1:5": {"name": "Outro", "session_id": OTHER, "cwd": CWD},
    }))
    put_transcript(home)
    put_transcript(home, sid=OTHER)
    runner = StubRunner()
    report = run(cfg, runner)
    assert sorted(report["colhidas"]) == sorted([SID, OTHER])
    assert len(runner.calls) == 2


def test_closed_topic_is_skipped(world):
    home, brain, cfg = world
    topics = brain / "wisp/topicos"
    topics.mkdir(parents=True)
    (topics / "topico-9-feito.md").write_text('---\ntopic_key: "1:9"\nstatus: encerrado\n---\ncorpo\n')
    (topics / "sessoes-mac.json").write_text(json.dumps({"1:9": {"session_id": SID}}))
    put_app(home, app_record())
    put_transcript(home)
    runner = StubRunner()
    report = run(cfg, runner)
    assert runner.calls == [] and motivos(report)[SID] == "topico encerrado"


def test_session_lock_held_is_skipped(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    held = brain_colher.try_lock(home / ".local/state/wisp/locks" / f"{SID}.lock")
    assert held is not None
    try:
        runner = StubRunner()
        report = run(cfg, runner)
    finally:
        os.close(held)
    assert runner.calls == [] and motivos(report)[SID] == "sessao em uso"


def test_failure_does_not_advance_ledger_and_does_not_stop_others(world):
    home, brain, cfg = world
    put_app(home, app_record(), app_record(sid=OTHER))
    put_transcript(home)
    put_transcript(home, sid=OTHER)

    class FailFirst(StubRunner):
        def run(self, argv, **kw):
            super().run(argv, **kw)
            self.exit = 1 if len(self.calls) == 1 else 0
            return RunResult(list(argv), self.exit, "", "boom")

    runner = FailFirst()
    report = run(cfg, runner)
    assert len(runner.calls) == 2
    (failed,) = motivos(report)
    (harvested,) = report["colhidas"]
    assert {failed, harvested} == {SID, OTHER}
    assert "claude exited 1" in motivos(report)[failed]
    ledger = json.loads((home / ".local/state/wisp/brain/colhidos.json").read_text())
    assert failed not in ledger and harvested in ledger


def test_timeout_does_not_advance_ledger(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    report = run(cfg, StubRunner(exit=-9, timed_out=True))
    assert "600s" in motivos(report)[SID]
    assert not (home / ".local/state/wisp/brain/colhidos.json").exists()


def test_brain_learn_false_disables(world):
    home, brain, cfg = world
    config = home / ".config/wisp/wisp.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"brain_learn": False}))
    put_app(home, app_record())
    put_transcript(home)
    runner = StubRunner()
    report = run(cfg, runner)
    assert runner.calls == [] and report["colhidas"] == []
    assert motivos(report)["-"] == "brain_learn desligado"


def test_dry_run_lists_without_calling_model_or_writing(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    runner = StubRunner()
    report = run(cfg, runner, dry_run=True)
    assert runner.calls == []
    assert report["colhidas"][0]["sid"] == SID and report["colhidas"][0]["mensagens"] == 3
    assert not (home / ".local/state/wisp/brain/colhidos.json").exists()
    assert not (home / ".local/state/wisp/brain/ultima-execucao").exists()


def test_if_due_skips_when_ran_recently(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    now = time.time()
    run(cfg, StubRunner(), now=now, dry_run=False)
    runner = StubRunner()
    report = run(cfg, runner, now=now + 60, if_due=True)
    assert runner.calls == [] and motivos(report)["-"] == "rodou ha menos de 10 min"
    put_transcript(home, sid=OTHER)
    put_app(home, app_record(), app_record(sid=OTHER))
    report = run(cfg, runner, now=now + 700, if_due=True)
    assert report["colhidas"] == [OTHER]


def test_global_lock_held_exits_quietly(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    held = brain_colher.try_lock(home / ".local/state/wisp/brain/colher.lock")
    try:
        runner = StubRunner()
        report = run(cfg, runner)
    finally:
        os.close(held)
    assert runner.calls == [] and motivos(report)["-"] == "outra colheita em andamento"


def test_offset_larger_than_file_restarts_from_zero(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    ledger = home / ".local/state/wisp/brain/colhidos.json"
    ledger.parent.mkdir(parents=True)
    ledger.write_text(json.dumps({SID: {"offset": 10**9, "at": 1}}))
    report = run(cfg, StubRunner())
    assert report["colhidas"] == [SID]


def test_main_json_output(world, capsys):
    home, brain, cfg = world
    config = home / ".config/wisp/wisp.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"brain": str(brain)}))
    put_app(home, app_record())
    put_transcript(home)
    assert brain_colher.main(["--dry-run", "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["colhidas"][0]["sid"] == SID and out["puladas"] == []


def test_run_harvests_at_most_the_cap_newest_first(world):
    home, brain, cfg = world
    sids = [f"{n}1111111-aaaa-bbbb-cccc-000000000001" for n in range(brain_colher.MAX_PER_RUN + 2)]
    put_app(home, *(app_record(sid=sid) for sid in sids))
    for age, sid in enumerate(sids):
        put_transcript(home, sid=sid, age=3600 + age * 100)
    runner = StubRunner()
    report = run(cfg, runner)
    assert report["colhidas"] == sids[: brain_colher.MAX_PER_RUN]
    assert len(runner.calls) == brain_colher.MAX_PER_RUN
    assert run(cfg, StubRunner(), now=time.time() + 700)["colhidas"] == sids[brain_colher.MAX_PER_RUN :]


def git_repo(brain, *, broken=False):
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
    subprocess.run(["git", "init", "-q", str(brain)], check=True, env=env)
    if broken:
        (brain / ".git" / "index.lock").write_text("")


def write_note(brain, text="x"):
    (brain / "nota.md").write_text(text)


class WritingRunner(StubRunner):
    def run(self, argv, **kw):
        if argv and argv[0] == "git":
            return SubprocessRunner().run(argv, **kw)
        write_note(kw["cwd"])
        return super().run(argv, **kw)


def ledger_file(home):
    return home / ".local/state/wisp/brain/colhidos.json"


def test_ledger_not_saved_when_git_commit_fails(world):
    home, brain, cfg = world
    git_repo(brain, broken=True)
    put_app(home, app_record())
    put_transcript(home)
    report = run(cfg, WritingRunner())
    assert report["colhidas"] == [SID]
    assert not ledger_file(home).exists()


def test_ledger_saved_when_git_commit_succeeds(world):
    home, brain, cfg = world
    git_repo(brain)
    put_app(home, app_record())
    put_transcript(home)
    run(cfg, WritingRunner())
    assert SID in json.loads(ledger_file(home).read_text())
    log = subprocess.run(["git", "-C", str(brain), "log", "--oneline"], capture_output=True, text=True).stdout
    assert "save the brain" in log


def test_ledger_saved_for_earlier_sessions_when_a_later_one_raises(world):
    home, brain, cfg = world
    put_app(home, app_record(), app_record(sid=OTHER))
    put_transcript(home, age=3600)
    put_transcript(home, sid=OTHER, age=7200)

    class BoomSecond(StubRunner):
        def run(self, argv, **kw):
            if self.calls:
                raise RuntimeError("boom")
            return super().run(argv, **kw)

    with pytest.raises(RuntimeError):
        run(cfg, BoomSecond())
    ledger = json.loads(ledger_file(home).read_text())
    assert SID in ledger and OTHER not in ledger


def test_failures_do_not_consume_the_cap_so_older_sessions_get_harvested(world):
    home, brain, cfg = world
    newest = [f"{n}1111111-aaaa-bbbb-cccc-000000000001" for n in range(brain_colher.MAX_PER_RUN)]
    put_app(home, *(app_record(sid=sid) for sid in [*newest, OTHER]))
    for age, sid in enumerate([*newest, OTHER]):
        put_transcript(home, sid=sid, age=3600 + age * 100)

    class FailNewest(StubRunner):
        def run(self, argv, **kw):
            super().run(argv, **kw)
            failing = len(self.calls) <= len(newest)
            return RunResult(list(argv), 1 if failing else 0, "", "boom")

    report = run(cfg, FailNewest())
    assert report["colhidas"] == [OTHER]
    assert OTHER in json.loads(ledger_file(home).read_text())


def test_attempts_per_run_are_bounded(world):
    home, brain, cfg = world
    sids = [f"{n:02d}111111-aaaa-bbbb-cccc-000000000001" for n in range(brain_colher.MAX_ATTEMPTS_PER_RUN + 5)]
    put_app(home, *(app_record(sid=sid) for sid in sids))
    for age, sid in enumerate(sids):
        put_transcript(home, sid=sid, age=3600 + age * 100)
    runner = StubRunner(exit=1)
    report = run(cfg, runner)
    assert len(runner.calls) == brain_colher.MAX_ATTEMPTS_PER_RUN
    assert report["colhidas"] == []
def test_harvest_prompt_and_header_carry_the_lessons_contract(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    runner = StubRunner()
    run(cfg, runner)
    argv = runner.calls[0]["argv"]
    prompt = argv[argv.index("--append-system-prompt") + 1]
    assert "wisp/aprendizados.md" in prompt
    assert runner.calls[0]["stdin"].decode().startswith("Today: ")


def test_harvest_dedupes_and_caps_the_lessons_the_model_wrote(world):
    home, brain, cfg = world
    put_app(home, app_record())
    put_transcript(home)
    path = brain / "wisp" / "aprendizados.md"
    path.parent.mkdir()
    path.write_text("# O que o Wisp aprendeu\n\n- Responda curto · 2026-11-19 · a\n- responda curto · 2026-11-19 · b\n")
    run(cfg, StubRunner())
    assert path.read_text().count("- ") == 1
