import json
import os
import shutil
import time
from pathlib import Path

import pytest

from wisp import brain_colher
from wisp.brain_colher import Candidate, MAX_CHARS, read_slice, run, trim
from wisp.config import TelegramConfig, WispConfig
from wisp.runner import RunResult

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
    assert report["colhidas"] == [OTHER]
    assert "claude exited 1" in motivos(report)[SID]
    ledger = json.loads((home / ".local/state/wisp/brain/colhidos.json").read_text())
    assert SID not in ledger and OTHER in ledger


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
