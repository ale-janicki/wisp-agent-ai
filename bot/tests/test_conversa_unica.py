import asyncio
import json
import threading
import time
import types

import pytest

from wisp_bot import bot as _bot, compartilhar, session_lock, sessao, store, topicos

SID = "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb"
SID2 = "cccccccc-1111-4222-8333-dddddddddddd"


def test_lock_second_holder_waits_until_first_releases(tmp_path):
    a, b = session_lock.SessionLock(SID, tmp_path), session_lock.SessionLock(SID, tmp_path)
    a.acquire()
    assert b.try_acquire() is False
    got = threading.Event()
    th = threading.Thread(target=lambda: (b.acquire(), got.set()))
    th.start()
    time.sleep(0.2)
    assert not got.is_set()
    a.release()
    assert got.wait(2)
    b.release()
    th.join()


def test_lock_base_dir_override_is_0700_and_per_session(tmp_path):
    base = tmp_path / "locks"
    lk = session_lock.SessionLock(SID, base)
    lk.acquire()
    assert lk.path == base / f"{SID}.lock" and (base.stat().st_mode & 0o777) == 0o700
    other = session_lock.SessionLock(SID2, base)
    assert other.try_acquire() is True
    lk.release(); other.release()


def test_lock_refuses_a_session_id_that_is_a_path(tmp_path):
    with pytest.raises(ValueError):
        session_lock.path_for("../x", tmp_path)


def test_guard_warns_once_when_it_had_to_wait(tmp_path):
    held = session_lock.SessionLock(SID, tmp_path)
    held.acquire()
    avisos = []

    async def on_wait():
        avisos.append(1)

    async def cenario():
        async def solta():
            await asyncio.sleep(0.2)
            held.release()
        t = asyncio.create_task(solta())
        async with session_lock.guard(SID, on_wait, tmp_path):
            assert not session_lock.SessionLock(SID, tmp_path).try_acquire()
        await t
        async with session_lock.guard(SID, on_wait, tmp_path):
            pass
    asyncio.run(cenario())
    assert avisos == [1]


def test_guard_cancelled_during_acquisition_does_not_leak_the_lock(tmp_path):
    async def cenario():
        for held_first in (False, True):
            held = session_lock.SessionLock(SID, tmp_path)
            if held_first:
                held.acquire()
            task = asyncio.create_task(session_lock.guard(SID, None, tmp_path).__aenter__())
            await asyncio.sleep(0)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
            if held_first:
                held.release()
            await asyncio.sleep(0.3)
            other = session_lock.SessionLock(SID, tmp_path)
            assert other.try_acquire() is True
            other.release()
    asyncio.run(cenario())


class FakeBot:
    def __init__(self):
        self.mensagens, self.topicos = [], []

    async def create_forum_topic(self, chat_id, name):
        self.topicos.append(name)
        return types.SimpleNamespace(message_thread_id=40 + len(self.topicos))

    async def send_message(self, chat_id, text, **kw):
        self.mensagens.append((kw.get("message_thread_id"), text))


@pytest.fixture
def mundo(tmp_path, monkeypatch):
    brain = tmp_path / "brain"
    notas = brain / "wisp/topicos"
    notas.mkdir(parents=True)
    work = tmp_path / "work"
    work.mkdir()
    projetos = tmp_path / "claude-projects"
    monkeypatch.setattr(topicos, "DIR", notas)
    monkeypatch.setattr(topicos, "BRAIN", brain)
    monkeypatch.setattr(topicos, "SYNC", None)
    monkeypatch.setattr(topicos, "push_logo", lambda *a, **k: None)
    monkeypatch.setattr(sessao, "PROJETOS", projetos)
    monkeypatch.setattr(compartilhar.Path, "home", classmethod(lambda cls: tmp_path))
    monkeypatch.setattr(_bot, "store", store.Store(tmp_path / "topics.json"))
    monkeypatch.setattr(_bot, "ALLOWED_CHAT_IDS", {"-1001"})
    monkeypatch.setattr(_bot, "DEFAULT_CWD", str(brain))
    return types.SimpleNamespace(tmp=tmp_path, work=work, notas=notas, bot=FakeBot())


def escrever_jsonl(mundo, sid, linhas):
    d = mundo.tmp / ".claude/projects" / compartilhar_slug(str(mundo.work))
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{sid}.jsonl").write_text("\n".join(json.dumps(l) for l in linhas) + "\n")


def compartilhar_slug(cwd):
    import re
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def msg(papel, texto):
    return {"type": papel, "message": {"role": papel, "content": [{"type": "text", "text": texto}]}}


def test_recap_is_last_six_text_messages_cut_to_500(mundo):
    linhas = [msg("user" if i % 2 == 0 else "assistant", f"m{i} " + "x" * 600) for i in range(10)]
    linhas.insert(3, {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "Bash", "input": {}}]}})
    linhas.insert(4, {"type": "user", "isMeta": True, "message": {"role": "user", "content": "meta"}})
    escrever_jsonl(mundo, SID, linhas)
    r = compartilhar.recap(SID, str(mundo.work))
    assert [t.split()[0] for _, t in r] == ["m4", "m5", "m6", "m7", "m8", "m9"]
    assert all(len(t) <= 501 and t.endswith("…") for _, t in r)
    assert compartilhar.recap(SID2, str(mundo.work)) == []


def test_compartilhar_registers_same_session_and_cwd_and_posts_recap(mundo):
    escrever_jsonl(mundo, SID, [msg("user", "oi <b>"), msg("assistant", "ola **tudo** bem")])
    res = asyncio.run(_bot._ctl_compartilhar(mundo.bot, {"session_id": SID, "cwd": str(mundo.work),
                                                         "nome": "Conversa X"}))
    assert res == {"ok": True, "thread_id": 41, "name": "Conversa X", "session_id": SID}
    t = _bot.store.get("-1001:41")
    assert t.session_id == SID and t.cwd == str(mundo.work) and t.started is True and t.name == "Conversa X"
    assert mundo.bot.topicos == ["Conversa X"]
    textos = [m[1] for m in mundo.bot.mensagens]
    assert all(m[0] == 41 for m in mundo.bot.mensagens) and len(textos) == 3
    assert textos[1] == "💻 oi &lt;b&gt;" and "<b>tudo</b>" in textos[2]
    assert list(mundo.notas.glob("topico-41-*.md"))


def test_compartilhar_refuses_a_session_already_in_a_topic(mundo):
    _bot.store.get_or_create("-1001:9", "Ja", str(mundo.work))
    _bot.store.seguir_sessao("-1001:9", SID, True)
    with pytest.raises(ValueError, match="ja esta no Telegram"):
        asyncio.run(_bot._ctl_compartilhar(mundo.bot, {"session_id": SID, "cwd": str(mundo.work), "nome": "Outra"}))
    assert mundo.bot.topicos == []


def test_compartilhar_without_jsonl_leaves_session_not_started(mundo):
    asyncio.run(_bot._ctl_compartilhar(mundo.bot, {"session_id": SID, "cwd": str(mundo.work), "nome": "Vazia"}))
    t = _bot.store.get("-1001:41")
    assert t.session_id == SID and t.started is False


def test_postar_posts_user_then_reply_and_never_runs_claude(mundo, monkeypatch):
    async def proibido(*a, **k):
        raise AssertionError("postar must not run claude")
    monkeypatch.setattr(_bot, "claude_run", proibido)
    monkeypatch.setattr(_bot, "turno", proibido)
    _bot.store.get_or_create("-1001:9", "T", str(mundo.work))
    feitos = {}
    monkeypatch.setattr(_bot.ctl, "gravar_done", lambda id_, res: feitos.update({id_: res}))
    op = {"id": "p1", "op": "postar", "thread": "9", "user": "pergunta <x>", "reply": "**resposta**",
          "at": time.time()}
    asyncio.run(_bot.ctl_executar(types.SimpleNamespace(bot=mundo.bot), op, "local"))
    assert feitos["p1"] == {"ok": True, "thread_id": 9}
    assert mundo.bot.mensagens == [(9, "💻 pergunta &lt;x&gt;"), (9, "<b>resposta</b>")]


def test_postar_without_a_user_line_posts_only_the_reply(mundo, monkeypatch):
    _bot.store.get_or_create("-1001:9", "T", str(mundo.work))
    monkeypatch.setattr(_bot.ctl, "gravar_done", lambda id_, res: None)
    op = {"id": "p2", "op": "postar", "thread": "9", "user": "", "reply": "📱 Continuando aqui.", "at": time.time()}
    asyncio.run(_bot.ctl_executar(types.SimpleNamespace(bot=mundo.bot), op, "local"))
    assert mundo.bot.mensagens == [(9, "📱 Continuando aqui.")]


def escrever_conversas(mundo, registros):
    f = mundo.tmp / "conversations.json"
    f.write_text(json.dumps(registros))
    return f


def test_recentes_filters_shared_sorts_and_caps_at_ten(mundo):
    regs = [{"id": str(i), "sessionId": f"s{i:02d}-aaaaaa", "title": f"C{i}", "updatedAt": 1_700_000_000 + i, "cwd": "/x"}
            for i in range(14)]
    regs.append({"id": "z", "sessionId": SID, "title": "Ja no Telegram", "updatedAt": 1_800_000_000, "cwd": "/x"})
    r = compartilhar.recentes(escrever_conversas(mundo, regs), {SID})
    assert [c["session_id"] for c in r] == [f"s{i:02d}-aaaaaa" for i in range(13, 3, -1)]
    assert compartilhar.relativa(time.time() - 7200) == "há 2 h"


def test_recentes_drops_session_ids_that_are_not_valid(mundo):
    regs = [{"id": "1", "sessionId": "ok-session-id", "title": "A", "updatedAt": 1, "cwd": "/x"},
            {"id": "2", "sessionId": "x" * 65, "title": "B", "updatedAt": 2, "cwd": "/x"},
            {"id": "3", "sessionId": "a;rm -rf", "title": "C", "updatedAt": 3, "cwd": "/x"}]
    assert [c["session_id"] for c in compartilhar.recentes(escrever_conversas(mundo, regs), set())] == ["ok-session-id"]


def test_recentes_missing_or_corrupt_file_is_a_friendly_error(mundo):
    with pytest.raises(ValueError, match="não achei"):
        compartilhar.recentes(mundo.tmp / "nada.json", set())
    f = mundo.tmp / "ruim.json"
    f.write_text("{not json")
    with pytest.raises(ValueError, match="ilegível"):
        compartilhar.recentes(f, set())


def _update(replies):
    chat = types.SimpleNamespace(id=-1001, type="supergroup")
    msg_ = types.SimpleNamespace(message_thread_id=None)

    async def reply_text(texto, reply_markup=None, **kw):
        replies.append((texto, reply_markup))
    msg_.reply_text = reply_text
    return types.SimpleNamespace(effective_user=types.SimpleNamespace(id=_bot.ALLOWED_USER_ID),
                                 effective_chat=chat, effective_message=msg_, get_bot=lambda: None)


def test_cmd_puxar_lists_buttons_and_reports_missing_file(mundo, monkeypatch):
    monkeypatch.setattr(_bot, "ALLOWED_USER_ID", 1)
    f = escrever_conversas(mundo, [{"sessionId": SID, "title": "Primeira", "updatedAt": time.time() - 90, "cwd": "/x"}])
    monkeypatch.setattr(_bot, "_CFG", types.SimpleNamespace(conversations_file=f))
    replies = []
    asyncio.run(_bot.cmd_puxar(_update(replies), None))
    texto, markup = replies[0]
    botao = markup.inline_keyboard[0][0]
    assert botao.callback_data == f"puxar:{SID}" and "Primeira" in botao.text and "min" in botao.text

    sent = []

    async def send(bot, chat, tid, texto):
        sent.append(texto)
    monkeypatch.setattr(_bot, "send", send)
    monkeypatch.setattr(_bot, "_CFG", types.SimpleNamespace(conversations_file=mundo.tmp / "nada.json"))
    asyncio.run(_bot.cmd_puxar(_update([]), None))
    assert "não achei" in sent[0]


def test_puxar_button_shares_the_conversation(mundo, monkeypatch):
    monkeypatch.setattr(_bot, "ALLOWED_USER_ID", 1)
    f = escrever_conversas(mundo, [{"sessionId": SID, "title": "Primeira", "updatedAt": 1, "cwd": str(mundo.work)}])
    monkeypatch.setattr(_bot, "_CFG", types.SimpleNamespace(conversations_file=f))
    respostas = []

    class Q:
        data = f"puxar:{SID}"

        async def answer(self, *a, **k):
            respostas.append(a)

        async def edit_message_text(self, texto):
            respostas.append(texto)
    upd = _update([])
    upd.callback_query = Q()
    asyncio.run(_bot.on_puxar_botao(upd, types.SimpleNamespace(bot=mundo.bot)))
    t = _bot.store.get("-1001:41")
    assert t.session_id == SID and t.cwd == str(mundo.work) and t.name == "Primeira"
    assert any("trouxe" in str(r) for r in respostas)
