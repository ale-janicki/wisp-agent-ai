import os
import json
import shlex
import threading
import time
from pathlib import Path

import pytest
from wisp_bot import ctl, hosting, sessao, store, topicos
from wisp_bot.config import BotConfig

from wisp import topic
from wisp.cli import build_parser, main

CONTRACT = Path(__file__).parent / "fixtures" / "contract"
SID = "11111111-2222-3333-4444-555555555555"
CHAT = "-1001"


@pytest.fixture
def env(fake_home, monkeypatch):
    state = fake_home / "state"
    brain = fake_home / "brain"
    notes = brain / "wisp/topicos"
    notes.mkdir(parents=True)
    state.mkdir()
    monkeypatch.setattr(hosting, "DIR", state)
    monkeypatch.setattr(hosting, "STATE", state / "host-state.json")
    monkeypatch.setattr(hosting, "MODO", "solo")
    monkeypatch.setattr(hosting, "HOST", "mac")
    monkeypatch.setattr(ctl, "DIR", state / "ctl")
    monkeypatch.setattr(ctl, "DONE", state / "ctl" / "done")
    monkeypatch.setattr(store, "STORE", state / "topics.json")
    monkeypatch.setattr(topicos, "DIR", notes)
    monkeypatch.setattr(topicos, "BRAIN", brain)
    monkeypatch.setattr(topicos, "SYNC", None)
    monkeypatch.setattr(sessao, "PROJETOS", fake_home / ".claude" / "projects")
    monkeypatch.setattr(topic, "cfg", lambda: BotConfig(
        token="", chat_ids={CHAT}, user_id=1, brain=brain, topics_dir=notes, topics_rel="wisp/topicos",
        state_dir=state, claude_bin=None, persona="Wisp", hosting="solo", brain_sync_cmd=None, alert_cmd=None,
        pair=None, system_topics={7: "Journals"}))
    return state, brain, notes


def beat(state: Path, estado: str = "active", ago: int = 0) -> None:
    (state / "host-state.json").write_text(json.dumps({"state": estado, "ts": int(time.time()) - ago}))


def add_topic(thread: int, name: str, cwd: Path) -> None:
    key = f"{CHAT}:{thread}"
    t = store.Store(store.STORE)
    t.get_or_create(key, name, str(cwd))
    t.adotar_sessao(key, SID[:-1] + str(thread % 10))


def fake_bot(answer: dict, seen: list):
    stop = threading.Event()

    def loop():
        while not stop.is_set():
            for p in ctl.pendentes():
                ctl.consumir(p)
                seen.append(p)
                ctl.gravar_done(p["id"], answer)
            time.sleep(0.05)
    th = threading.Thread(target=loop, daemon=True)
    th.start()
    return stop


def test_profile_templates_parse():
    templates = [
        "wisp topic status --json",
        "wisp topic listar --json",
        "wisp topic novo --cwd {cwd} -- {name}",
        "wisp topic compartilhar --session={thread} --cwd={cwd} --nome={name} --json",
        "wisp topic postar --json",
        "wisp topic enviar --thread={thread} --legenda={text} /tmp/a.png",
        "wisp topic encerrar --sem-pull {thread}",
    ]
    values = {"cwd": "/tmp/o'brien dir", "name": "-ideia 'x' $(rm)", "thread": "12", "text": "--oi; \"a b\""}
    parser = build_parser()
    for t in templates:
        filled = t
        for k, v in values.items():
            filled = filled.replace("{" + k + "}", shlex.quote(v))
        args = parser.parse_args(shlex.split(filled)[1:])
        assert args.command == "topic" and callable(args.f)


def test_status_down_when_no_heartbeat(env, capsys):
    assert main(["topic", "status", "--json"]) == 0
    d = json.loads(capsys.readouterr().out)
    assert d["up"] is False and d["reader"] == "mac" and d["state"] is None and d["age_s"] is None


def test_status_up_with_fresh_host_state(env, capsys):
    beat(env[0])
    assert main(["topic", "status", "--json"]) == 0
    d = json.loads(capsys.readouterr().out)
    assert d["up"] is True and d["host"] == "mac" and d["reader"] == "mac" and d["state"] == "active"
    assert d["claim"] == "mac" and 0 <= d["age_s"] <= 2
    assert set(d) == {"up", "host", "state", "age_s", "reader", "claim"}


def test_status_stale_heartbeat_is_down(env, capsys):
    beat(env[0], ago=300)
    main(["topic", "status", "--json"])
    d = json.loads(capsys.readouterr().out)
    assert d["up"] is False and d["reader"] == "mac" and d["claim"] == "mac"


def test_listar_reads_notes_and_store(env, capsys, fake_home):
    state, brain, notes = env
    beat(state)
    work = fake_home / "work"
    work.mkdir()
    for thread, name in ((0, "Geral"), (5, "Ideias"), (7, "Journals")):
        topicos.garantir(f"{CHAT}:{thread}", name, str(work))
    add_topic(5, "Ideias", work)
    add_topic(9, "Sem nota", work)
    assert main(["topic", "listar", "--json", "--sem-pull"]) == 0
    rows = {r["thread"]: r for r in json.loads(capsys.readouterr().out)}
    assert set(rows) == {0, 5, 7, 9}
    assert rows[5]["name"] == "Ideias" and rows[5]["cwd"] == str(work) and rows[5]["host"] == "mac"
    assert rows[5]["turns"] >= 1 and rows[5]["session_id"]
    assert rows[0]["fixed"] is True and rows[7]["fixed"] is True
    assert rows[5]["fixed"] is False and rows[9]["fixed"] is False


def test_listar_hides_non_active_and_mirrors(env, capsys, fake_home):
    state, _, notes = env
    beat(state)
    work = fake_home / "work"
    work.mkdir()
    topicos.garantir(f"{CHAT}:5", "Fechado", str(work))
    topicos.set_status(f"{CHAT}:5", "encerrado")
    assert main(["topic", "listar", "--json"]) == 0
    assert {r["thread"] for r in json.loads(capsys.readouterr().out)} == {0, 7}


def test_encerrar_waits_done(env, capsys):
    beat(env[0])
    stop = fake_bot({"ok": True, "nome": "Ideias"}, [])
    try:
        assert main(["topic", "encerrar", "--sem-pull", "5"]) == 0
    finally:
        stop.set()
    assert capsys.readouterr().out.strip() == "encerrado: Ideias"


def test_novo_rejects_missing_cwd(env, capsys, fake_home):
    assert main(["topic", "novo", "--cwd", str(fake_home / "nope"), "--", "Ideias"]) == 2
    assert "cwd não existe" in capsys.readouterr().err


def test_novo_needs_a_reader(env, capsys):
    assert main(["topic", "novo", "--", "Ideias"]) == 1
    assert "o bot do Telegram não está rodando" in capsys.readouterr().err


def test_novo_creates_and_prints_json(env, capsys):
    state, brain, _ = env
    beat(state)

    stop = threading.Event()

    def bot():
        while not stop.is_set():
            for p in ctl.pendentes():
                ctl.consumir(p)
                if p["op"] == "vincular":
                    t = store.Store(store.STORE)
                    t.get_or_create(f"{CHAT}:21", p["nome"], p["cwd"])
                    t.adotar_sessao(f"{CHAT}:21", SID)
                    ctl.gravar_done(p["id"], {"ok": True, "thread_id": 21, "chat": CHAT})
                else:
                    ctl.gravar_done(p["id"], {"ok": True})
            time.sleep(0.05)
    threading.Thread(target=bot, daemon=True).start()
    try:
        assert main(["topic", "novo", "--", "Ideias"]) == 0
    finally:
        stop.set()
    d = json.loads(capsys.readouterr().out)
    assert d == {"thread": 21, "session_id": SID, "cwd": str(brain), "name": "Ideias"}


def test_system_topics_come_from_config(env, capsys):
    state, _, _ = env
    beat(state)
    add_topic(7, "x", Path.home())
    main(["topic", "listar", "--json"])
    rows = {r["thread"]: r for r in json.loads(capsys.readouterr().out)}
    assert rows[7]["fixed"] is True


def test_contract_fixtures_written(env, fake_home):
    CONTRACT.mkdir(parents=True, exist_ok=True)
    estado = {"up": True, "host": "mac", "state": "active", "age_s": 2, "reader": "mac", "claim": "mac"}
    lista = [
        {"thread": 0, "name": "Geral", "session_id": SID, "cwd": "/Users/_x/brain", "started": True, "turns": 4,
         "last_used": 1763400000.5, "host": "mac", "session_host": "mac", "fixed": True},
        {"thread": 12, "name": "Ideias", "session_id": SID, "cwd": "/Users/_x/brain", "started": True, "turns": 2,
         "last_used": 1763399000.0, "host": "mac", "session_host": "mac", "fixed": False},
    ]
    files = {
        "topic-status.json": topic.status_json(estado),
        "topic-list.json": topic.listar_json(lista),
        "topic-new.json": topic.novo_json(21, SID, "/Users/_x/brain", "Ideias"),
        "topic-claim.json": topic.claim_json({"ok": True, "reader": "mac", "waited_s": 0}),
    }
    for name, text in files.items():
        (CONTRACT / name).write_text(text + "\n")
    assert json.loads((CONTRACT / "topic-status.json").read_text()).keys() == \
        {"up", "host", "state", "age_s", "reader", "claim"}
    assert json.loads((CONTRACT / "topic-list.json").read_text())[0]["fixed"] is True
    assert json.loads((CONTRACT / "topic-new.json").read_text()).keys() == {"thread", "session_id", "cwd", "name"}
    assert json.loads((CONTRACT / "topic-claim.json").read_text()) == {"ok": True, "reader": "mac", "waited_s": 0}


def test_error_has_no_prefix_and_bot_error_is_one_line(env, capsys):
    beat(env[0])
    stop = fake_bot({"ok": False, "erro": "falhou\n  linha dois\t\ttres"}, [])
    try:
        assert main(["topic", "encerrar", "--sem-pull", "12"]) == 1
    finally:
        stop.set()
    assert capsys.readouterr().err == "falhou linha dois tres\n"


def test_encerrar_fails_at_once_when_bot_is_down(env, capsys, monkeypatch):
    monkeypatch.setattr(topic, "ENCERRAR_S", 60.0)
    t0 = time.monotonic()
    assert main(["topic", "encerrar", "--sem-pull", "5"]) == 1
    assert time.monotonic() - t0 < 2
    err = capsys.readouterr().err
    assert err == topic.SEM_BOT + "\n" and ctl.pendentes() == []


def test_listar_always_has_geral_and_system_topics(env, capsys):
    beat(env[0])
    assert main(["topic", "listar", "--json", "--sem-pull"]) == 0
    rows = {r["thread"]: r for r in json.loads(capsys.readouterr().out)}
    assert set(rows) == {0, 7}
    assert rows[0]["name"] == "Geral" and rows[7]["name"] == "Journals"
    assert rows[0]["fixed"] is True and rows[7]["fixed"] is True


def test_listar_without_telegram_has_no_fixed_rows(env, capsys, monkeypatch):
    real = topic.cfg()
    from dataclasses import replace
    monkeypatch.setattr(topic, "cfg", lambda: replace(real, chat_ids=set(), system_topics={}))
    assert main(["topic", "listar", "--json", "--sem-pull"]) == 0
    assert json.loads(capsys.readouterr().out) == []


def test_compartilhar_sends_session_and_prints_contract_json(env, capsys, fake_home):
    beat(env[0])
    seen: list = []
    stop = fake_bot({"ok": True, "thread_id": 31, "name": "Conversa X", "session_id": SID}, seen)
    try:
        assert main(["topic", "compartilhar", "--session", SID, "--cwd", str(fake_home), "--nome", "Conversa X",
                     "--json"]) == 0
    finally:
        stop.set()
    assert json.loads(capsys.readouterr().out) == {"thread": 31, "name": "Conversa X", "session_id": SID}
    assert [(p["op"], p["session_id"], p["nome"]) for p in seen] == [("compartilhar", SID, "Conversa X")]


def test_compartilhar_accepts_a_name_starting_with_a_dash(env, capsys, fake_home):
    beat(env[0])
    seen: list = []
    stop = fake_bot({"ok": True, "thread_id": 32, "name": "-teste", "session_id": SID}, seen)
    try:
        assert main(["topic", "compartilhar", f"--session={SID}", f"--cwd={fake_home}", "--nome=-teste", "--json"]) == 0
    finally:
        stop.set()
    assert json.loads(capsys.readouterr().out)["name"] == "-teste"
    assert [p["nome"] for p in seen] == ["-teste"]


def test_compartilhar_bot_refusal_is_one_line_on_stderr(env, capsys, fake_home):
    beat(env[0])
    stop = fake_bot({"ok": False, "erro": "essa conversa ja esta no Telegram (topico 5)"}, [])
    try:
        assert main(["topic", "compartilhar", "--session", SID, "--cwd", str(fake_home), "--nome", "X"]) == 1
    finally:
        stop.set()
    assert capsys.readouterr().err == "essa conversa ja esta no Telegram (topico 5)\n"


def test_compartilhar_needs_the_bot_up(env, capsys, fake_home):
    assert main(["topic", "compartilhar", "--session", SID, "--cwd", str(fake_home), "--nome", "X"]) == 1
    assert capsys.readouterr().err == topic.SEM_BOT + "\n" and ctl.pendentes() == []


def test_postar_reads_stdin_and_queues_a_postar_op(env, capsys, monkeypatch):
    import io
    beat(env[0])
    seen: list = []
    stop = fake_bot({"ok": True, "thread_id": 12}, seen)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"thread": 12, "user": "oi", "reply": "ola"})))
    try:
        assert main(["topic", "postar", "--json"]) == 0
    finally:
        stop.set()
    assert json.loads(capsys.readouterr().out) == {"ok": True}
    assert [(p["op"], p["thread"], p["user"], p["reply"]) for p in seen] == [("postar", "12", "oi", "ola")]


def test_postar_rejects_bad_stdin(env, capsys, monkeypatch):
    import io
    monkeypatch.setattr("sys.stdin", io.StringIO('{"thread": 1}'))
    assert main(["topic", "postar", "--json"]) == 2
    assert "stdin" in capsys.readouterr().err


def test_enviar_makes_paths_absolute_and_queues_an_enviar_op(env, capsys, tmp_path, monkeypatch):
    beat(env[0])
    monkeypatch.chdir(tmp_path)
    seen: list = []
    stop = fake_bot({"ok": True, "enviados": 2}, seen)
    try:
        assert main(["topic", "enviar", "--thread=12", "--legenda=olha", "a.png", "/tmp/b.pdf", "--json"]) == 0
    finally:
        stop.set()
    assert json.loads(capsys.readouterr().out) == {"ok": True, "enviados": 2}
    p = seen[0]
    assert (p["op"], p["thread"], p["legenda"]) == ("enviar", 12, "olha")
    assert p["arquivos"] == [os.path.abspath("a.png"), "/tmp/b.pdf"]


def test_enviar_answers_pendente_instead_of_waiting_past_the_agent_timeout(env, capsys, monkeypatch):
    beat(env[0])
    assert topic.ENVIAR_S < 120
    monkeypatch.setattr(topic, "ENVIAR_S", 0.2)
    assert main(["topic", "enviar", "--thread=3", "/tmp/x"]) == 0
    out, err = capsys.readouterr()
    d = json.loads(out)
    assert d["ok"] is True and d["pendente"] is True and d["id"]
    assert "envio em andamento, não reenvie" in err
    assert [p["op"] for p in ctl.pendentes()] == ["enviar"]


def test_enviar_prints_the_bot_sentence_and_exits_1(env, capsys):
    beat(env[0])
    stop = fake_bot({"ok": False, "erro": "arquivo recusado: x passa de 50 MB"}, [])
    try:
        assert main(["topic", "enviar", "--thread=3", "/tmp/x"]) == 1
    finally:
        stop.set()
    assert capsys.readouterr().err == "arquivo recusado: x passa de 50 MB\n"


def test_enviar_needs_thread_and_a_file(env):
    with pytest.raises(SystemExit):
        main(["topic", "enviar", "/tmp/x"])
    with pytest.raises(SystemExit):
        main(["topic", "enviar", "--thread=3"])


def test_postar_forwards_arquivos(env, monkeypatch):
    import io
    beat(env[0])
    seen: list = []
    stop = fake_bot({"ok": True, "thread_id": 12}, seen)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"thread": 12, "user": "oi", "reply": "ola",
                                                            "arquivos": ["/tmp/a.png"]})))
    try:
        assert main(["topic", "postar", "--json"]) == 0
    finally:
        stop.set()
    assert seen[0]["arquivos"] == ["/tmp/a.png"]
