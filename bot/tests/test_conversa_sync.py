import asyncio
import json

import pytest

from wisp_bot import conversa, sessao, unir
from wisp_bot.store import Store
from wisp_bot.transcript import Transcripts, encode

KEY = "-1001:0"
S1 = "c7bee14a-bf07-4539-b2d5-6914aebb03e5"
S2 = "64627ba7-fbb3-469a-b901-2800feac5aa0"
APP_GERAL_OLD = "8F55FBFB-9572-4767-8A4A-5102B86281A3"
APP_GERAL_NEW = "62A355B9-ED36-4E9B-8125-D36308E7CBF9"


@pytest.fixture
def env(tmp_path):
    store = Store(tmp_path / "topics.json")
    transcripts = Transcripts(tmp_path / "conversas")
    return store, transcripts, tmp_path


def entry(at, kind, text, surface="app", **extra):
    base = {"v": 1, "at": at, "kind": kind, "surface": surface, "text": text}
    if kind == "assistant":
        base.update(engine="claude", model="m")
    return {**base, **extra}


def seed(transcripts, conversation, entries):
    transcripts.path(conversation).parent.mkdir(parents=True, exist_ok=True)
    transcripts.path(conversation).write_text("".join(encode(e) + "\n" for e in entries), "utf-8")


def sender():
    sent = []

    async def enviar(texto):
        sent.append(texto)
    return sent, enviar


def test_a_topic_is_born_with_a_conversation_id_and_a_reset_keeps_it(env):
    store, _, _ = env
    topic = store.get_or_create(KEY, "Geral", "/tmp")
    conversation, session = topic.conversation, topic.session_id
    assert conversation and conversation != session
    store.reset(KEY)
    again = store.get(KEY)
    assert again.conversation == conversation and again.session_id != session


def test_an_old_store_without_the_field_loads_and_is_backfilled_from_the_transcript(env):
    store, transcripts, tmp = env
    (tmp / "old.json").write_text(json.dumps({KEY: {"key": KEY, "name": "Geral", "session_id": S1, "cwd": "/tmp"}}))
    legacy = Store(tmp / "old.json")
    assert legacy.get(KEY).conversation == ""
    seed(transcripts, "app-born", [{"v": 1, "at": "2026-11-20T00:00:00.000Z", "kind": "session", "session": S1,
                                    "engine": "claude", "reason": "new"}])
    assert conversa.garantir(legacy, transcripts, KEY) == "app-born"
    assert legacy.get(KEY).conversation == "app-born"
    assert legacy.get(KEY).meta[conversa.CURSOR]
    fresh = Store(tmp / "old.json")
    assert fresh.get(KEY).conversation == "app-born"


def test_the_geral_reset_keeps_one_conversation_and_the_new_session_is_only_a_link(env):
    store, transcripts, _ = env
    topic = store.get_or_create(KEY, "Geral", "/tmp")
    conversation = conversa.garantir(store, transcripts, KEY)
    transcripts.user(topic.session_id, "antes", "telegram")
    transcripts.assistant(topic.session_id, "resposta antes", "telegram", "claude", "m")
    store.reset(KEY)
    renewed = store.get(KEY)
    assert conversa.garantir(store, transcripts, KEY, "reset") == conversation
    assert transcripts.find(renewed.session_id) == conversation
    assert transcripts.context(renewed.session_id) is None
    transcripts.user(renewed.session_id, "depois", "telegram")
    transcripts.assistant(renewed.session_id, "resposta depois", "telegram", "claude", "m")
    assert list(transcripts.folder.glob("*.jsonl")) == [transcripts.path(conversation)]
    texts = [e["text"] for e in transcripts.entries(renewed.session_id) if e["kind"] in ("user", "assistant")]
    assert texts == ["antes", "resposta antes", "depois", "resposta depois"]
    memory = transcripts.context(renewed.session_id)
    assert "depois" in memory and "antes" not in memory.replace("resposta antes", "")


def test_a_rebuild_on_one_side_links_the_new_session_to_the_same_conversation(env):
    store, transcripts, _ = env
    topic = store.get_or_create(KEY, "Geral", "/tmp")
    conversation = conversa.garantir(store, transcripts, KEY)
    transcripts.user(topic.session_id, "oi", "app")
    transcripts.assistant(topic.session_id, "ola", "app", "claude", "m")
    old = topic.session_id
    new = store.renovar_sessao(KEY)
    transcripts.rebuilt(old, new.session_id, "claude")
    assert transcripts.find(new.session_id) == transcripts.find(old) == conversation
    assert conversa.garantir(store, transcripts, KEY) == conversation
    assert len(list(transcripts.folder.glob("*.jsonl"))) == 1


def seeded_topic(env):
    store, transcripts, _ = env
    store.get_or_create(KEY, "Geral", "/tmp")
    conversation = conversa.garantir(store, transcripts, KEY)
    store.set_meta(KEY, **{conversa.CURSOR: "2026-11-21T10:00:00.000Z"})
    return store, transcripts, conversation


def test_turns_made_while_telegram_was_down_are_posted_in_order_marked_as_from_the_app(env):
    store, transcripts, conversation = seeded_topic(env)
    seed(transcripts, conversation, [
        entry("2026-11-21T09:00:00.000Z", "user", "ja postada"),
        entry("2026-11-21T10:05:00.000Z", "user", "primeira"),
        entry("2026-11-21T10:05:09.000Z", "assistant", "resposta 1"),
        entry("2026-11-21T10:06:00.000Z", "user", "do telegram", surface="telegram"),
        entry("2026-11-21T10:30:00.000Z", "user", "segunda"),
        entry("2026-11-21T10:30:09.000Z", "assistant", "resposta 2"),
    ])
    sent, enviar = sender()
    assert asyncio.run(conversa.alcancar(store, transcripts, KEY, enviar)) == 2
    assert sent == [conversa.CABECALHO, "💻 primeira", "resposta 1", "💻 segunda", "resposta 2"]
    assert store.get(KEY).meta[conversa.CURSOR] == "2026-11-21T10:30:09.000Z"
    again, enviar2 = sender()
    assert asyncio.run(conversa.alcancar(store, transcripts, KEY, enviar2)) == 0 and again == []


def test_a_live_single_turn_is_posted_whole_without_the_offline_header(env):
    store, transcripts, conversation = seeded_topic(env)
    long = "x" * 3000
    seed(transcripts, conversation, [
        entry("2026-11-21T10:05:00.000Z", "user", "oi"),
        entry("2026-11-21T10:05:09.000Z", "assistant", long),
    ])
    sent, enviar = sender()
    asyncio.run(conversa.alcancar(store, transcripts, KEY, enviar, agora=1795000000.0 - 10 * 86400 + 0))
    assert sent[0] == "💻 oi" and sent[1] == long and conversa.CABECALHO not in sent


def test_a_long_backlog_is_compacted_and_a_failed_send_resumes_without_repeating(env):
    store, transcripts, conversation = seeded_topic(env)
    entries = []
    for n in range(8):
        entries.append(entry(f"2026-11-21T11:0{n}:00.000Z", "user", f"pergunta {n}"))
        entries.append(entry(f"2026-11-21T11:0{n}:30.000Z", "assistant", f"resposta {n} " + "y" * 2000))
    seed(transcripts, conversation, entries)
    sent = []
    calls = {"n": 0}

    async def flaky(texto):
        calls["n"] += 1
        if calls["n"] == 9:
            raise OSError("telegram fora")
        sent.append(texto)
    with pytest.raises(OSError):
        asyncio.run(conversa.alcancar(store, transcripts, KEY, flaky))
    assert sent[0] == conversa.CABECALHO and "3 trocas" in sent[1]
    assert all(len(t) <= conversa.RESUMO_CHARS + 20 for t in sent if t.startswith("resposta"))
    cursor = store.get(KEY).meta[conversa.CURSOR]
    assert cursor == "2026-11-21T11:05:30.000Z"
    rest, enviar = sender()
    assert asyncio.run(conversa.alcancar(store, transcripts, KEY, enviar, agora=0)) == 2
    assert [t for t in rest if t.startswith("💻")] == ["💻 pergunta 6", "💻 pergunta 7"]
    assert not any("pergunta 5" in t for t in rest)


def test_without_a_cursor_the_first_look_marks_now_and_replays_nothing(env):
    store, transcripts, _ = env
    store.get_or_create(KEY, "Geral", "/tmp")
    topic = store.get(KEY)
    store.set_conversation(KEY, "c1")
    seed(transcripts, "c1", [entry("2020-01-01T00:00:00.000Z", "user", "antigo")])
    sent, enviar = sender()
    assert asyncio.run(conversa.alcancar(store, transcripts, KEY, enviar)) == 0 and sent == []
    assert store.get(KEY).meta[conversa.CURSOR] > "2026"
    assert topic.key == KEY


def split_data(tmp, monkeypatch):
    projetos = tmp / "projects"
    pasta = projetos / "-brain"
    pasta.mkdir(parents=True)
    monkeypatch.setattr(sessao, "PROJETOS", projetos)

    def sessao_jsonl(sid, linhas):
        (pasta / f"{sid}.jsonl").write_text("".join(json.dumps(
            {"type": papel, "timestamp": ts, "message": {"content": texto, "model": "m"}}) + "\n"
            for papel, ts, texto in linhas), "utf-8")
    sessao_jsonl(S1, [("user", "2026-11-19T10:00:00.000Z", "geral antiga"),
                      ("assistant", "2026-11-19T10:00:05.000Z", "resposta antiga")])
    sessao_jsonl(S2, [("user", "2026-11-21T17:40:00.000Z", "geral nova"),
                      ("assistant", "2026-11-21T17:40:05.000Z", "resposta nova")])
    records = [
        {"id": APP_GERAL_NEW, "sessionId": S2, "title": "Geral", "updatedAt": "2026-11-21T18:13:56.749Z",
         "cwd": "/tmp", "lastPreview": "resposta nova"},
        {"id": APP_GERAL_OLD, "sessionId": S1, "title": "Geral", "updatedAt": "2026-11-20T03:00:14.159Z",
         "cwd": "/tmp", "lastPreview": "resposta antiga"},
        {"id": "6419E52F-0EBA-4724-97A1-31FF4D2C9C5F", "sessionId": "2704d540-efb9-4326-a43e-32f407b06df5",
         "title": "financas", "updatedAt": "2026-11-20T14:03:20.095Z"},
    ]
    indice = tmp / "conversations.json"
    indice.write_text(json.dumps(records))
    topicos = {KEY: {"key": KEY, "name": "Geral", "session_id": S2, "cwd": "/tmp", "started": True, "turns": 9,
                     "meta": {}},
               "-1001:4013": {"key": "-1001:4013", "name": "financas", "session_id": "2704d540-efb9-4326-a43e-32f407b06df5",
                              "cwd": "/tmp", "started": True, "turns": 81, "meta": {}}}
    (tmp / "topics.json").write_text(json.dumps(topicos))
    return indice, topicos, records


def test_the_merge_plan_rejoins_the_split_geral_and_touches_nothing(env, monkeypatch):
    _, transcripts, tmp = env
    indice, topicos, records = split_data(tmp, monkeypatch)
    before = (indice.read_text(), (tmp / "topics.json").read_text())
    grupos = unir.plano(records, topicos, transcripts)
    geral = next(g for g in grupos if g.topico == KEY)
    assert geral.conversa == APP_GERAL_NEW.lower()
    assert [r["id"] for r in geral.perdedores] == [APP_GERAL_OLD]
    assert geral.sessoes == [S1, S2]
    assert set(geral.importar) == {S1, S2}
    assert all(not g.perdedores for g in grupos if g is not geral)
    assert "Geral é uma conversa só" in "\n".join(unir.descrever(grupos, topicos, transcripts))
    assert (indice.read_text(), (tmp / "topics.json").read_text()) == before
    assert not (tmp / "conversas").exists()


def test_the_merge_keeps_everything_writes_a_backup_and_a_log(env, monkeypatch):
    _, transcripts, tmp = env
    indice, topicos, records = split_data(tmp, monkeypatch)
    grupos = unir.plano(records, topicos, transcripts)
    pasta = unir.aplicar(grupos, indice, tmp / "topics.json", transcripts, tmp, agora=1795300000)
    assert {p.name for p in pasta.iterdir()} >= {"conversations.json", "topics.json", "unir.log"}
    assert json.loads((pasta / "conversations.json").read_text()) == records
    left = json.loads(indice.read_text())
    assert [r["id"] for r in left if r["title"] == "Geral"] == [APP_GERAL_NEW]
    assert len(left) == 2
    saved = json.loads((tmp / "topics.json").read_text())
    assert saved[KEY]["conversation"] == APP_GERAL_NEW.lower()
    assert saved["-1001:4013"]["conversation"] == "6419e52f-0eba-4724-97a1-31ff4d2c9c5f"
    fresh = Transcripts(tmp / "conversas")
    assert fresh.find(S1) == fresh.find(S2) == APP_GERAL_NEW.lower()
    texts = [e["text"] for e in fresh.entries(S2) if e["kind"] in ("user", "assistant")]
    assert texts == ["geral antiga", "resposta antiga", "geral nova", "resposta nova"]
    assert not (tmp / "conversas" / "6419e52f-0eba-4724-97a1-31ff4d2c9c5f.jsonl").exists()
    assert "juntada" in (pasta / "unir.log").read_text()
    assert unir.plano(left, saved, fresh) == []


def test_the_merge_joins_two_records_that_share_a_transcript_by_session_links(env, monkeypatch):
    store, transcripts, tmp = env
    seed(transcripts, "aaaaaaaa-0000-4000-8000-000000000001", [
        {"v": 1, "at": "2026-11-18T10:00:00.000Z", "kind": "session", "session": "s-one", "engine": "claude", "reason": "new"},
        entry("2026-11-18T10:00:01.000Z", "user", "um"),
        {"v": 1, "at": "2026-11-18T11:00:00.000Z", "kind": "session", "session": "s-two", "engine": "claude", "reason": "rebuilt"},
    ])
    records = [
        {"id": "AAAAAAAA-0000-4000-8000-000000000001", "sessionId": "s-one", "title": "x", "updatedAt": "2026-11-18T10:00:01.000Z"},
        {"id": "BBBBBBBB-0000-4000-8000-000000000002", "sessionId": "s-two", "title": "x", "updatedAt": "2026-11-18T11:00:09.000Z"},
    ]
    grupos = unir.plano(records, {}, transcripts)
    assert len(grupos) == 1 and grupos[0].conversa == "bbbbbbbb-0000-4000-8000-000000000002"
    assert grupos[0].arquivos == ["aaaaaaaa-0000-4000-8000-000000000001"]


def test_a_postar_request_with_a_conversation_posts_the_pending_turns_not_the_raw_text(env, monkeypatch):
    from wisp_bot import bot as _bot
    store, transcripts, conversation = seeded_topic(env)
    seed(transcripts, conversation, [
        entry("2026-11-21T10:05:00.000Z", "user", "offline"),
        entry("2026-11-21T10:05:09.000Z", "assistant", "resposta offline"),
        entry("2026-11-21T10:40:00.000Z", "user", "agora"),
        entry("2026-11-21T10:40:09.000Z", "assistant", "resposta agora"),
    ])
    sent = []

    async def fake_send(bot, chat, thread_id, text):
        sent.append(text)
    monkeypatch.setattr(_bot, "store", store)
    monkeypatch.setattr(_bot, "transcripts", transcripts)
    monkeypatch.setattr(_bot, "send", fake_send)
    monkeypatch.setattr(_bot, "_key_da_thread", lambda thread: KEY)
    res = asyncio.run(_bot._ctl_postar(object(), {"thread": "0", "user": "agora", "reply": "resposta agora",
                                                  "conversation": conversation}))
    assert res["ok"] is True
    assert sent == [conversa.CABECALHO, "💻 offline", "resposta offline", "💻 agora", "resposta agora"]


def test_sharing_a_conversation_keys_the_topic_on_the_apps_id(env, monkeypatch, tmp_path):
    from types import SimpleNamespace
    from wisp_bot import bot as _bot
    store, transcripts, tmp = env
    sent = []

    async def fake_send(bot, chat, thread_id, text):
        sent.append(text)

    class FakeBot:
        async def create_forum_topic(self, chat_id, name):
            return SimpleNamespace(message_thread_id=77)
    for name, value in (("store", store), ("transcripts", transcripts), ("send", fake_send),
                        ("_chat_principal", lambda: -1001)):
        monkeypatch.setattr(_bot, name, value)
    monkeypatch.setattr(_bot.topicos, "garantir", lambda *a, **k: None)
    monkeypatch.setattr(_bot.topicos, "set_campos", lambda *a, **k: None)
    monkeypatch.setattr(_bot.topicos, "gravar_ponteiro", lambda *a, **k: None)
    monkeypatch.setattr(_bot.topicos, "push_logo", lambda *a, **k: None)
    mine = "11111111-2222-4333-8444-555555555555"
    res = asyncio.run(_bot.compartilhar_conversa(FakeBot(), S1, str(tmp), "minha", mine))
    topic = store.get("-1001:77")
    assert res["thread_id"] == 77 and topic.conversation == mine and topic.session_id == S1
    assert transcripts.find(S1) == mine and topic.meta[conversa.CURSOR]
    with pytest.raises(ValueError):
        asyncio.run(_bot.compartilhar_conversa(FakeBot(), S2, str(tmp), "outra", mine))


def test_the_cursor_exists_from_the_moment_a_topic_or_its_conversation_is_created(env):
    store, _, _ = env
    assert store.get_or_create(KEY, "Geral", "/tmp").meta[conversa.CURSOR]
    legacy = Store(env[2] / "legacy.json")
    legacy._data[KEY] = type(store.get(KEY))(key=KEY, name="g", session_id=S1, cwd="/tmp")
    legacy.set_conversation(KEY, "abc")
    assert legacy.get(KEY).meta[conversa.CURSOR]


def test_a_flush_keeps_a_conversation_written_to_the_file_by_another_process(env):
    store, _, tmp = env
    store.get_or_create(KEY, "Geral", "/tmp")
    on_disk = json.loads(store.path.read_text())
    on_disk[KEY]["conversation"] = "from-the-merge"
    store.path.write_text(json.dumps(on_disk))
    store.set_meta(KEY, x=1)
    assert store.get(KEY).conversation == "from-the-merge"
    assert json.loads(store.path.read_text())[KEY]["conversation"] == "from-the-merge"
    other = Store(store.path)
    assert other.get(KEY).conversation == "from-the-merge"


def test_the_apply_holds_the_store_lock_so_a_bot_flush_waits(env, monkeypatch):
    import threading
    from wisp_bot import store as store_mod
    store, transcripts, tmp = env
    store.get_or_create(KEY, "Geral", "/tmp")
    indice, topicos, records = split_data(tmp, monkeypatch)
    order = []
    seen = threading.Event()
    real = unir._aplicar

    def slow(*args, **kwargs):
        seen.set()
        threading.Event().wait(0.4)
        order.append("apply-done")
        return real(*args, **kwargs)
    monkeypatch.setattr(unir, "_aplicar", slow)
    grupos = unir.plano(records, topicos, transcripts)
    t = threading.Thread(target=lambda: unir.aplicar(grupos, indice, store.path, transcripts, tmp))
    t.start()
    seen.wait(2)
    store.set_meta(KEY, y=2)
    order.append("flush-done")
    t.join()
    assert order == ["apply-done", "flush-done"]
    assert store_mod.file_lock


def test_a_failed_reply_send_keeps_the_cursor_before_the_turn_and_the_retry_sends_both_lines(env):
    store, transcripts, conversation = seeded_topic(env)
    seed(transcripts, conversation, [
        entry("2026-11-21T10:05:00.000Z", "user", "pergunta"),
        entry("2026-11-21T10:05:09.000Z", "assistant", "resposta"),
    ])
    sent = []
    falhou = []

    async def flaky(texto):
        if texto == "resposta" and not falhou:
            falhou.append(1)
            raise OSError("fora")
        sent.append(texto)
    with pytest.raises(OSError):
        asyncio.run(conversa.alcancar(store, transcripts, KEY, flaky, agora=1795000000.0))
    assert store.get(KEY).meta[conversa.CURSOR] == "2026-11-21T10:00:00.000Z"
    again, enviar = sender()
    asyncio.run(conversa.alcancar(store, transcripts, KEY, enviar, agora=1795000000.0))
    assert again == ["💻 pergunta", "resposta"]
    assert store.get(KEY).meta[conversa.CURSOR] == "2026-11-21T10:05:09.000Z"


def test_a_user_line_without_its_reply_waits_and_a_failed_turn_is_skipped(env):
    store, transcripts, conversation = seeded_topic(env)
    seed(transcripts, conversation, [
        entry("2026-11-21T10:05:00.000Z", "user", "falhou"),
        entry("2026-11-21T10:06:00.000Z", "user", "ok"),
        entry("2026-11-21T10:06:09.000Z", "assistant", "resposta ok"),
        entry("2026-11-21T10:07:00.000Z", "user", "ainda respondendo"),
    ])
    sent, enviar = sender()
    assert asyncio.run(conversa.alcancar(store, transcripts, KEY, enviar, agora=1795000000.0)) == 1
    assert sent == ["💻 ok", "resposta ok"]
    assert store.get(KEY).meta[conversa.CURSOR] == "2026-11-21T10:06:09.000Z"
    seed(transcripts, conversation, transcripts.conversation_entries(conversation)
         + [entry("2026-11-21T10:07:09.000Z", "assistant", "pronto")])
    more, enviar2 = sender()
    asyncio.run(conversa.alcancar(store, transcripts, KEY, enviar2, agora=1795000000.0))
    assert more == ["💻 ainda respondendo", "pronto"]


def postar_env(env, monkeypatch):
    from wisp_bot import bot as _bot
    store, transcripts, conversation = seeded_topic(env)
    sent = []

    async def fake_send(bot, chat, thread_id, text):
        sent.append(text)
    monkeypatch.setattr(_bot, "store", store)
    monkeypatch.setattr(_bot, "transcripts", transcripts)
    monkeypatch.setattr(_bot, "send", fake_send)
    monkeypatch.setattr(_bot, "_key_da_thread", lambda thread: KEY)
    return _bot, transcripts, conversation, sent


def test_a_mirror_is_never_dropped_when_the_transcript_has_nothing_for_it(env, monkeypatch):
    _bot, transcripts, conversation, sent = postar_env(env, monkeypatch)
    op = {"thread": "0", "user": "oi", "reply": "resposta", "conversation": conversation}
    asyncio.run(_bot._ctl_postar(object(), op))
    assert sent == ["💻 oi", "resposta"]


def test_a_mirror_the_catch_up_already_posted_is_not_posted_twice(env, monkeypatch):
    _bot, transcripts, conversation, sent = postar_env(env, monkeypatch)
    seed(transcripts, conversation, [entry("2026-11-21T10:05:00.000Z", "user", "oi"),
                                     entry("2026-11-21T10:05:09.000Z", "assistant", "resposta")])
    op = {"thread": "0", "user": "oi", "reply": "resposta", "conversation": conversation,
          "turn_at": "2026-11-21T10:05:09.000Z"}
    asyncio.run(_bot._ctl_postar(object(), op))
    asyncio.run(_bot._ctl_postar(object(), op))
    assert sent.count("💻 oi") == 1 and sent.count("resposta") == 1


def test_a_repeated_reply_text_is_still_posted_when_its_own_turn_is_not_in_the_transcript(env, monkeypatch):
    _bot, transcripts, conversation, sent = postar_env(env, monkeypatch)
    seed(transcripts, conversation, [entry("2026-11-21T10:05:00.000Z", "user", "faz"),
                                     entry("2026-11-21T10:05:09.000Z", "assistant", "Feito.")])
    first = {"thread": "0", "user": "faz", "reply": "Feito.", "conversation": conversation,
             "turn_at": "2026-11-21T10:05:09.000Z"}
    asyncio.run(_bot._ctl_postar(object(), first))
    before = list(sent)
    again = {"thread": "0", "user": "faz de novo", "reply": "Feito.", "conversation": conversation,
             "turn_at": "2026-11-21T11:00:09.000Z"}
    asyncio.run(_bot._ctl_postar(object(), again))
    assert sent[len(before):] == ["💻 faz de novo", "Feito."]
    assert conversa.coberto(transcripts.conversation_entries(conversation), "2026-11-21T12:00:00.000Z", "Feito.",
                            "2026-11-21T10:05:09.000Z")
    assert not conversa.coberto(transcripts.conversation_entries(conversation), "2026-11-21T12:00:00.000Z", "Feito.",
                                "2026-11-21T11:00:09.000Z")
    assert not conversa.coberto(transcripts.conversation_entries(conversation), "2026-11-21T12:00:00.000Z", "Feito.", "")


def test_a_mirror_for_another_conversation_id_posts_the_payload(env, monkeypatch):
    _bot, transcripts, conversation, sent = postar_env(env, monkeypatch)
    seed(transcripts, conversation, [entry("2026-11-21T10:05:00.000Z", "user", "outra"),
                                     entry("2026-11-21T10:05:09.000Z", "assistant", "nao deste")])
    op = {"thread": "0", "user": "oi", "reply": "payload", "conversation": "11111111-2222-4333-8444-555555555555"}
    asyncio.run(_bot._ctl_postar(object(), op))
    assert sent == ["💻 oi", "payload"]


def test_a_session_that_cannot_be_imported_keeps_its_record_and_is_listed(env, monkeypatch):
    _, transcripts, tmp = env
    indice, topicos, records = split_data(tmp, monkeypatch)
    (sessao.PROJETOS / "-brain" / f"{S1}.jsonl").unlink()
    grupos = unir.plano(records, topicos, transcripts)
    geral = next(g for g in grupos if g.topico == KEY)
    assert geral.nao_importaveis == [S1] and [r["id"] for r in geral.mantidos] == [APP_GERAL_OLD]
    assert geral.importar == [S2]
    text = "\n".join(unir.descrever(grupos, topicos, transcripts))
    assert "não importável" in text and "mantém no índice" in text
    unir.aplicar(grupos, indice, tmp / "topics.json", transcripts, tmp, agora=1795300000)
    left = {r["id"] for r in json.loads(indice.read_text())}
    assert APP_GERAL_OLD in left and APP_GERAL_NEW in left
    fresh = Transcripts(tmp / "conversas")
    assert fresh.find(S1) == APP_GERAL_NEW.lower()
    (sessao.PROJETOS / "-brain" / f"{S1}.jsonl").write_text(json.dumps(
        {"type": "user", "timestamp": "2026-11-19T10:00:00.000Z", "message": {"content": "voltou"}}) + "\n")
    again = unir.plano(json.loads(indice.read_text()), json.loads((tmp / "topics.json").read_text()), fresh)
    assert again[0].importar == [S1] and not again[0].nao_importaveis


def test_a_legacy_topic_gets_the_same_id_on_both_sides(env):
    store, transcripts, tmp = env
    store.get_or_create(KEY, "Geral", "/tmp")
    store._data[KEY].conversation = ""
    store._data[KEY].session_id = S2
    indice = tmp / "conversations.json"
    indice.write_text(json.dumps([{"id": APP_GERAL_NEW, "sessionId": S2, "title": "Geral", "updatedAt": "x"}]))
    assert conversa.legado(S2, transcripts, indice) == APP_GERAL_NEW.lower()
    assert conversa.garantir(store, transcripts, KEY, indice=indice) == APP_GERAL_NEW.lower()
    assert conversa.legado(S1, transcripts, indice) == S1
    assert conversa.legado(S1.upper(), transcripts, indice) == S1


def test_the_merge_refuses_while_the_bot_process_runs(env, monkeypatch, capsys):
    from argparse import Namespace
    topic, tmp, indice = unir_cli(env, monkeypatch)
    monkeypatch.setattr(topic, "bot_vivo", lambda: True)
    monkeypatch.setattr(topic.unir, "aplicar", lambda *a: pytest.fail("must not apply"))
    assert topic.cmd_unir(Namespace(aplicar=True, forcar=False)) == 1
    assert "pare o serviço" in capsys.readouterr().err


def test_a_kept_record_does_not_come_back_as_a_loser_and_a_second_run_takes_no_backup(env, monkeypatch, capsys):
    from argparse import Namespace
    from types import SimpleNamespace
    from wisp import topic
    _, transcripts, tmp = env
    indice, topicos, records = split_data(tmp, monkeypatch)
    (sessao.PROJETOS / "-brain" / f"{S1}.jsonl").unlink()
    grupos = unir.plano(records, topicos, transcripts)
    unir.aplicar(grupos, indice, tmp / "topics.json", transcripts, tmp, agora=1795300000)
    fresh = Transcripts(tmp / "conversas")
    reasons = [e["reason"] for e in fresh.entries(S1) if e.get("kind") == "session" and e.get("session") == S1]
    assert reasons == ["pending-import"]
    saved = json.loads((tmp / "topics.json").read_text())
    assert unir.plano(json.loads(indice.read_text()), saved, fresh) == []
    backups = sorted(p.name for p in (tmp / "backup-conversas").iterdir())
    monkeypatch.setattr(topic, "app_index", lambda: indice)
    monkeypatch.setattr(topic, "cfg", lambda: SimpleNamespace(wisp_dir=tmp))
    monkeypatch.setattr(topic.store, "STORE", tmp / "topics.json")
    assert topic.cmd_unir(Namespace(aplicar=True, forcar=True)) == 0
    assert "nada para juntar" in capsys.readouterr().out
    assert sorted(p.name for p in (tmp / "backup-conversas").iterdir()) == backups


def two_topic_data(tmp, monkeypatch):
    split_data(tmp, monkeypatch)
    ca = "aaaaaaaa-0000-4000-8000-00000000000a"
    cb = "bbbbbbbb-0000-4000-8000-00000000000b"
    sa, sb = "11111111-0000-4000-8000-00000000000a", "22222222-0000-4000-8000-00000000000b"
    records = [
        {"id": ca.upper(), "sessionId": sa, "title": "Geral", "updatedAt": "2026-11-21T10:00:00.000Z"},
        {"id": cb.upper(), "sessionId": sb, "title": "Geral", "updatedAt": "2026-11-21T11:00:00.000Z"},
    ]
    topicos = {
        "1:0": {"key": "1:0", "name": "Geral", "session_id": sb, "conversation": cb, "meta": {}},
        "1:5": {"key": "1:5", "name": "outro", "session_id": sa, "conversation": ca, "meta": {}},
    }
    return records, topicos, ca, cb, sa, sb


def test_a_geral_titled_record_bound_to_another_topic_is_not_merged_into_the_geral(env, monkeypatch):
    _, transcripts, tmp = env
    records, topicos, ca, cb, sa, sb = two_topic_data(tmp, monkeypatch)
    seed(transcripts, ca, [{"v": 1, "at": "2026-11-21T09:00:00.000Z", "kind": "session", "session": sa,
                            "engine": "claude", "reason": "new"}, entry("2026-11-21T09:00:01.000Z", "user", "do A")])
    assert unir.plano(records, topicos, transcripts) == []
    assert transcripts.path(ca).exists()


def test_a_group_that_spans_two_topics_is_refused_and_never_applied(env, monkeypatch):
    _, transcripts, tmp = env
    records, topicos, ca, cb, sa, sb = two_topic_data(tmp, monkeypatch)
    topicos["1:5"]["conversation"] = cb
    grupos = unir.plano(records, topicos, transcripts)
    assert grupos and all(g.recusado for g in grupos)
    assert sorted(grupos[0].topicos) == ["1:0", "1:5"]
    assert "recusado" in "\n".join(unir.descrever(grupos, topicos, transcripts))
    indice = tmp / "idx.json"
    indice.write_text(json.dumps(records))
    (tmp / "topics.json").write_text(json.dumps(topicos))
    before = indice.read_text()
    unir.aplicar(grupos, indice, tmp / "topics.json", transcripts, tmp, agora=1795300000)
    assert indice.read_text() == before
    assert json.loads((tmp / "topics.json").read_text()) == topicos


def test_a_stale_plan_is_refused_without_writing_anything(env, monkeypatch):
    _, transcripts, tmp = env
    indice, topicos, records = split_data(tmp, monkeypatch)
    grupos = unir.plano(records, topicos, transcripts)
    changed = json.loads(indice.read_text())
    changed[0]["title"] = "Geral"
    changed.append({"id": "CCCCCCCC-0000-4000-8000-00000000000c", "sessionId": "33333333-0000-4000-8000-00000000000c",
                    "title": "Geral", "updatedAt": "2026-11-21T19:00:00.000Z"})
    indice.write_text(json.dumps(changed))
    with pytest.raises(unir.PlanoMudou):
        unir.aplicar(grupos, indice, tmp / "topics.json", transcripts, tmp, agora=1795300000)
    assert not (tmp / "backup-conversas").exists()
    assert json.loads(indice.read_text()) == changed


def test_losing_transcripts_are_deleted_only_after_the_index_and_store_are_written(env, monkeypatch):
    _, transcripts, tmp = env
    a, b = "aaaaaaaa-0000-4000-8000-000000000001", "bbbbbbbb-0000-4000-8000-000000000002"
    seed(transcripts, a, [
        {"v": 1, "at": "2026-11-18T10:00:00.000Z", "kind": "session", "session": "s-one", "engine": "claude", "reason": "new"},
        entry("2026-11-18T10:00:01.000Z", "user", "um"),
        {"v": 1, "at": "2026-11-18T11:00:00.000Z", "kind": "session", "session": "s-two", "engine": "claude", "reason": "rebuilt"},
    ])
    records = [
        {"id": a.upper(), "sessionId": "s-one", "title": "x", "updatedAt": "2026-11-18T10:00:01.000Z"},
        {"id": b.upper(), "sessionId": "s-two", "title": "x", "updatedAt": "2026-11-18T11:00:09.000Z"},
    ]
    indice = tmp / "idx.json"
    indice.write_text(json.dumps(records))
    (tmp / "topics.json").write_text("{}")
    grupos = unir.plano(records, {}, transcripts)
    real = unir._gravar

    def broken(path, texto):
        if path == indice:
            raise OSError("disco cheio")
        real(path, texto)
    monkeypatch.setattr(unir, "_gravar", broken)
    with pytest.raises(OSError):
        unir.aplicar(grupos, indice, tmp / "topics.json", transcripts, tmp, agora=1795300000)
    assert transcripts.path(a).exists()
    assert json.loads(indice.read_text()) == records
    monkeypatch.setattr(unir, "_gravar", real)
    unir.aplicar(unir.plano(records, {}, transcripts), indice, tmp / "topics.json", transcripts, tmp, agora=1795300001)
    assert not transcripts.path(a).exists() and transcripts.path(b).exists()


def unir_cli(env, monkeypatch):
    from types import SimpleNamespace
    from wisp import topic
    _, transcripts, tmp = env
    indice, topicos, records = split_data(tmp, monkeypatch)
    monkeypatch.setattr(topic, "app_index", lambda: indice)
    monkeypatch.setattr(topic, "cfg", lambda: SimpleNamespace(wisp_dir=tmp))
    monkeypatch.setattr(topic.store, "STORE", tmp / "topics.json")
    monkeypatch.setattr(topic, "bot_vivo", lambda: False)
    monkeypatch.setattr(topic.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=1))
    monkeypatch.delenv(topic.CONFIRMA_ENV, raising=False)
    monkeypatch.setattr(topic.sys, "stdin", SimpleNamespace(isatty=lambda: False))
    return topic, tmp, indice


def test_apply_without_a_tty_needs_the_token_the_plan_run_printed(env, monkeypatch, capsys):
    from argparse import Namespace
    topic, tmp, indice = unir_cli(env, monkeypatch)
    assert topic.cmd_unir(Namespace(aplicar=False, forcar=False)) == 0
    pid = capsys.readouterr().out.split("id do plano: ")[1].split()[0]
    before = indice.read_text()
    assert topic.cmd_unir(Namespace(aplicar=True, forcar=False)) == 1
    assert "confirmação" in capsys.readouterr().err
    monkeypatch.setenv(topic.CONFIRMA_ENV, "outro")
    assert topic.cmd_unir(Namespace(aplicar=True, forcar=False)) == 1
    assert indice.read_text() == before and not (tmp / "backup-conversas").exists()
    monkeypatch.setenv(topic.CONFIRMA_ENV, pid)
    assert topic.cmd_unir(Namespace(aplicar=True, forcar=False)) == 0
    assert "juntado" in capsys.readouterr().out
    assert len(json.loads(indice.read_text())) == 2


def test_apply_on_a_tty_asks_for_the_plan_id(env, monkeypatch, capsys):
    from argparse import Namespace
    from types import SimpleNamespace
    topic, tmp, indice = unir_cli(env, monkeypatch)
    topic.cmd_unir(Namespace(aplicar=False, forcar=False))
    pid = capsys.readouterr().out.split("id do plano: ")[1].split()[0]
    monkeypatch.setattr(topic.sys, "stdin", SimpleNamespace(isatty=lambda: True))
    monkeypatch.setattr("builtins.input", lambda prompt="": "errado")
    assert topic.cmd_unir(Namespace(aplicar=True, forcar=False)) == 1
    monkeypatch.setattr("builtins.input", lambda prompt="": pid)
    assert topic.cmd_unir(Namespace(aplicar=True, forcar=False)) == 0


def test_the_unir_apply_and_force_flags_always_ask_in_every_shipped_settings():
    import json as _json
    from pathlib import Path
    from wisp_bot import claude_runner
    rules = ["Bash(*topic unir*--aplicar*)", "Bash(*topic unir*--forcar*)"]
    root = Path(__file__).parents[2]
    shipped = _json.loads((root / "harness/settings.json").read_text())["permissions"]
    assert all(r in shipped["ask"] for r in rules)
    assert all(r in claude_runner.guard_settings("/x/wisp")["permissions"]["ask"] for r in rules)
    fixture = _json.loads((root / "cli/tests/fixtures/contract/guard-settings.json").read_text())
    assert all(r in fixture["permissions"]["ask"] for r in rules)
    swift = (root / "core/Sources/WispCore/Agent/EngineGuards.swift").read_text()
    assert all(r in swift for r in rules)
