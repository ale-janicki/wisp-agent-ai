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
    """The bot modules read their paths at import: point them at this test's home."""
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
    """Plays the bot: answers every request that lands in the ctl queue."""
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
        "wisp topic falar --sem-pull --origem Wisp {anexos} -- {thread} {text}",
        "wisp topic encerrar --sem-pull {thread}",
        "wisp topic assumir --json --thread {thread}",
    ]
    values = {"cwd": "/tmp/o'brien dir", "name": "-ideia 'x' $(rm)", "thread": "12", "text": "--oi; \"a b\""}
    parser = build_parser()
    for t in templates:
        filled = t.replace("{anexos}", "--anexo '/tmp/a b.png'")
        for k, v in values.items():
            filled = filled.replace("{" + k + "}", shlex.quote(v))
        args = parser.parse_args(shlex.split(filled)[1:])
        assert args.command == "topic" and callable(args.f)
    falar = parser.parse_args(shlex.split(templates[3].replace("{anexos}", "").replace("{thread}", "'12'").replace("{text}", shlex.quote("--oi")))[1:])
    assert (falar.thread, falar.texto, falar.origem, falar.sem_pull) == ("12", "--oi", "Wisp", True)


def test_status_down_when_no_heartbeat(env, capsys):
    assert main(["topic", "status", "--json"]) == 0
    d = json.loads(capsys.readouterr().out)
    assert d["up"] is False and d["reader"] is None and d["state"] is None and d["age_s"] is None


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
    assert d["up"] is False and d["reader"] is None and d["claim"] is None


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


def test_falar_writes_ctl_and_waits_done(env, capsys):
    seen: list = []
    stop = fake_bot({"ok": True, "thread_id": 12}, seen)
    try:
        assert main(["topic", "falar", "--sem-pull", "--origem", "Wisp", "--", "12", "oi tudo bem"]) == 0
    finally:
        stop.set()
    assert capsys.readouterr().out.strip() == "enviado ao tópico 12; o turno roda no Telegram"
    assert [(p["op"], p["thread"], p["texto"], p["origem"]) for p in seen] == [("falar", "12", "oi tudo bem", "Wisp")]


def test_falar_geral_passes_thread_zero(env):
    seen: list = []
    stop = fake_bot({"ok": True, "thread_id": 0}, seen)
    try:
        assert main(["topic", "falar", "--sem-pull", "--", "0", "oi"]) == 0
    finally:
        stop.set()
    assert seen[0]["thread"] == "0" and "message_thread_id" not in seen[0]


def test_falar_times_out_with_sentence(env, capsys, monkeypatch):
    monkeypatch.setattr(topic, "FALAR_S", 0.2)
    assert main(["topic", "falar", "--sem-pull", "--", "12", "oi"]) == 1
    err = capsys.readouterr().err
    assert err.startswith("o bot não respondeu") and "wisp topic:" not in err and len(err.strip().splitlines()) == 1
    assert ctl.pendentes() == []


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
    assert "nenhum host le o Telegram" in capsys.readouterr().err


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


def test_assumir_solo_is_immediate(env, capsys):
    assert main(["topic", "assumir", "--json", "--thread", "5"]) == 0
    assert json.loads(capsys.readouterr().out) == {"ok": True, "reader": "mac", "waited_s": 0}


def test_puxar_solo_is_one_sentence_on_stderr(env, capsys):
    assert main(["topic", "puxar", "5"]) == 1
    cap = capsys.readouterr()
    assert cap.err.strip() == topic.SO_UMA_MAQUINA
    out = cap.out.strip().splitlines()
    assert out == []


def test_puxar_pair_reports_unknown_topic(env, capsys, monkeypatch):
    monkeypatch.setattr(hosting, "MODO", "pair")
    assert main(["topic", "puxar", "--sem-pull", "99"]) == 2
    assert "nenhum tópico bate" in capsys.readouterr().err


def test_puxar_pair_releases_and_prints_resume(env, capsys, monkeypatch, fake_home):
    state, _, _ = env
    beat(state)
    monkeypatch.setattr(hosting, "MODO", "pair")
    monkeypatch.delenv("WISP_TOPIC_THREAD", raising=False)
    monkeypatch.setenv("CLAUDECODE", "1")
    work = fake_home / "work"
    work.mkdir()
    topicos.garantir(f"{CHAT}:5", "Ideias", str(work))
    jsonl = sessao.caminho(SID, str(work))
    jsonl.parent.mkdir(parents=True)
    jsonl.write_text(json.dumps({"type": "user", "message": {"content": "Mensagem do usuario:\noi"}}) + "\n")
    stop = fake_bot({"ok": True, "session_id": SID, "cwd": str(work), "session_host": "mac", "started": True}, [])
    try:
        assert main(["topic", "puxar", "--sem-pull", "Ideias"]) == 0
    finally:
        stop.set()
    out = capsys.readouterr().out
    assert f"claude --resume {SID}" in out and f"cd {work}" in out and "Você: oi" in out


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
    stop = fake_bot({"ok": False, "erro": "falhou\n  linha dois\t\ttres"}, [])
    try:
        assert main(["topic", "falar", "--sem-pull", "--", "12", "oi"]) == 1
    finally:
        stop.set()
    assert capsys.readouterr().err == "falhou linha dois tres\n"


def test_encerrar_fails_at_once_when_bot_is_down(env, capsys, monkeypatch):
    monkeypatch.setattr(topic, "ENCERRAR_S", 60.0)
    t0 = time.monotonic()
    assert main(["topic", "encerrar", "--sem-pull", "5"]) == 1
    assert time.monotonic() - t0 < 2
    err = capsys.readouterr().err
    assert err == topic.SEM_BOT_NO_PC + "\n" and ctl.pendentes() == []


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


def test_falar_anexo_sends_absolute_paths_and_allows_empty_text(env):
    seen: list = []
    stop = fake_bot({"ok": True, "thread_id": 12}, seen)
    try:
        assert main(["topic", "falar", "--sem-pull", "--anexo", "/a/b.png", "--anexo", "rel.txt", "--", "12", ""]) == 0
    finally:
        stop.set()
    assert seen[0]["anexos"] == ["/a/b.png", str(Path("rel.txt").absolute())] and seen[0]["texto"] == ""


def test_falar_without_anexo_has_no_anexos_key(env):
    seen: list = []
    stop = fake_bot({"ok": True, "thread_id": 12}, seen)
    try:
        assert main(["topic", "falar", "--sem-pull", "--", "12", "oi"]) == 0
    finally:
        stop.set()
    assert "anexos" not in seen[0]
