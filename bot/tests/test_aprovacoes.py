import asyncio
import json
import time
from types import SimpleNamespace

import pytest

from wisp_bot import aprovacoes

VALIDADE = aprovacoes.VALIDADE_S
ID = "a" * 32
ID2 = "b" * 32
OWNER = 1


class FakeBot:
    def __init__(self):
        self.enviadas, self.editadas = [], []

    async def send_message(self, chat_id, text, **kw):
        self.enviadas.append((chat_id, text, kw))
        return SimpleNamespace(message_id=100 + len(self.enviadas))

    async def edit_message_text(self, text, **kw):
        self.editadas.append((text, kw))


class FakeQuery:
    def __init__(self, data, user_id):
        self.data, self.from_user = data, SimpleNamespace(id=user_id)
        self.message = SimpleNamespace(text="resumo")
        self.respostas, self.editadas = [], []

    async def answer(self, text=None, **kw):
        self.respostas.append(text)

    async def edit_message_text(self, text, **kw):
        self.editadas.append(text)


@pytest.fixture
def d(tmp_path):
    p = tmp_path / "approvals"
    p.mkdir()
    return p


def pedido(d, id=ID, detail="corpo", thread=None, summary="Enviar email"):
    (d / f"{id}.json").write_text(json.dumps(
        {"id": id, "tool": "send_email", "summary": summary, "detail": detail, "created": time.time(), "thread": thread}))


def novo(d, **kw):
    bot = FakeBot()
    return bot, aprovacoes.Aprovacoes(bot, -1001, OWNER, d, **kw)


def run(c):
    return asyncio.run(c)


def test_posts_once_per_request(d):
    pedido(d, thread=7)
    bot, a = novo(d)
    run(a.varrer())
    run(a.varrer())
    assert len(bot.enviadas) == 1
    chat, _, kw = bot.enviadas[0]
    assert chat == -1001 and kw["message_thread_id"] == 7 and kw["parse_mode"] == "HTML"
    botoes = kw["reply_markup"].inline_keyboard[0]
    assert [b.text for b in botoes] == ["Permitir", "Negar"]
    assert botoes[0].callback_data == f"aprov:{ID}:allow" and botoes[1].callback_data == f"aprov:{ID}:deny"
    assert len(botoes[0].callback_data.encode()) <= 64


def test_owner_press_decides(d):
    pedido(d)
    bot, a = novo(d)
    run(a.varrer())
    q = FakeQuery(f"aprov:{ID}:allow", OWNER)
    run(a.pressionou(SimpleNamespace(callback_query=q)))
    assert (d / f"{ID}.decision").read_text() == "allow"
    assert "permitido" in q.editadas[0]
    q2 = FakeQuery(f"aprov:{ID}:deny", OWNER)
    run(a.pressionou(SimpleNamespace(callback_query=q2)))
    assert (d / f"{ID}.decision").read_text() == "allow" and "já respondido" in q2.editadas[0]


def test_stranger_press_ignored(d):
    pedido(d)
    _, a = novo(d)
    q = FakeQuery(f"aprov:{ID}:allow", 999)
    run(a.pressionou(SimpleNamespace(callback_query=q)))
    assert not (d / f"{ID}.decision").exists()
    assert q.respostas == ["só o dono do Wisp pode responder"] and q.editadas == []


def test_message_updated_when_answered_elsewhere(d):
    pedido_em(d, ID, 1000.0)
    pedido_em(d, ID2, 1000.0)
    relogio = [1010.0]
    bot, a = novo(d, agora=lambda: relogio[0])
    run(a.varrer())
    (d / f"{ID}.json").unlink()                     # o app respondeu e a ferramenta limpou: sumiu antes dos 600 s
    run(a.varrer())
    assert [t for t, _ in bot.editadas] == [bot.enviadas[0][1] + "\n\n<i>respondido no app</i>"]
    relogio[0] = 1000.0 + 601                       # ID2 passou dos 600 s: some da lista e expira
    run(a.varrer())
    assert "expirou" in bot.editadas[1][0]
    assert a.postados == {}


def test_stale_and_non_numeric_created_are_hidden(d):
    pedido_em(d, ID, 1000.0)
    pedido_em(d, ID2, "ontem")
    pedido_em(d, "c" * 32, 1500.0)
    assert [r["id"] for r in aprovacoes.pendentes(d, agora=lambda: 1000.0 + 601)] == ["c" * 32]


def test_long_detail_cut(d):
    pedido(d, detail="<x>" + "a" * 5000, summary="<b>&")
    bot, a = novo(d)
    run(a.varrer())
    corpo = bot.enviadas[0][1]
    assert corpo.endswith("… (veja inteiro no app)") and "&lt;x&gt;" in corpo and "&lt;b&gt;&amp;" in corpo
    assert corpo.count("a") <= 3500


def test_missing_or_symlinked_dir_has_no_requests(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    assert aprovacoes.diretorio() is None and aprovacoes.pendentes() == []
    assert not (tmp_path / "wisp").exists()
    real = tmp_path / "real"
    real.mkdir()
    (tmp_path / "wisp").mkdir()
    (tmp_path / "wisp" / "approvals").symlink_to(real)
    assert aprovacoes.diretorio() is None


def test_decidir_rejects_bad_gone_decided(d):
    assert not aprovacoes.decidir("../x", True, d) and not aprovacoes.decidir(ID, True, d)
    pedido(d)
    assert aprovacoes.decidir(ID, False, d) and not aprovacoes.decidir(ID, True, d)
    assert (d / f"{ID}.decision").read_text() == "deny"


def pedido_em(d, id, created, thread=None):
    (d / f"{id}.json").write_text(json.dumps(
        {"id": id, "tool": "t", "summary": "s", "detail": "d", "created": created, "thread": thread}))


def test_missing_thread_falls_back_to_general_and_next_still_posts(d):
    pedido_em(d, ID, time.time() - 2, thread=9)
    pedido_em(d, ID2, time.time() - 1)
    bot, a = novo(d)
    orig = bot.send_message

    async def send(chat_id, text, **kw):
        if kw.get("message_thread_id") == 9:
            raise RuntimeError("Message thread not found")
        return await orig(chat_id, text, **kw)

    bot.send_message = send
    run(a.varrer())
    assert len(bot.enviadas) == 2 and a.postados[ID][1] is None and ID2 in a.postados


def test_raising_send_does_not_stop_next(d):
    pedido_em(d, ID, time.time() - 2)
    pedido_em(d, ID2, time.time() - 1)
    bot, a = novo(d)
    orig = bot.send_message

    async def send(chat_id, text, **kw):
        if not bot.enviadas and not getattr(bot, "falhou", False):
            bot.falhou = True
            raise RuntimeError("boom")
        return await orig(chat_id, text, **kw)

    bot.send_message = send
    run(a.varrer())
    assert ID not in a.postados and ID2 in a.postados
    run(a.varrer())                                   # A is retried next scan
    assert ID in a.postados


def test_restart_does_not_repost_and_can_edit(d, tmp_path):
    pedido(d)
    est = tmp_path / "aprovacoes.json"
    bot, a = novo(d, estado=est)
    run(a.varrer())
    bot2, b = novo(d, estado=est)
    run(b.varrer())
    assert len(bot.enviadas) == 1 and bot2.enviadas == []
    assert json.loads(est.read_text())[ID][4] == b.postados[ID][4] > 0
    (d / f"{ID}.json").unlink()
    run(b.varrer())
    assert "respondido no app" in bot2.editadas[0][0] and json.loads(est.read_text()) == {}


def test_standby_scan_does_nothing(d):
    pedido(d)
    bot, a = novo(d, ativo=lambda: False)
    run(a.varrer())
    assert bot.enviadas == []


def test_summary_bounded(d):
    pedido(d, summary="x" * 400)
    bot, a = novo(d)
    run(a.varrer())
    assert "x" * 300 + "…" in bot.enviadas[0][1] and "x" * 301 not in bot.enviadas[0][1]


def test_press_on_gone_request(d):
    _, a = novo(d)
    q = FakeQuery(f"aprov:{ID}:allow", OWNER)
    run(a.pressionou(SimpleNamespace(callback_query=q)))
    assert q.respostas == ["expirou ou já respondido"]


def test_old_state_without_created_still_loads(d, tmp_path):
    est = tmp_path / "aprovacoes.json"
    est.write_text(json.dumps({ID: [-1001, None, 7, "corpo"]}))
    bot, a = novo(d, estado=est)
    assert a.postados[ID] == (-1001, None, 7, "corpo", 0.0)
    run(a.varrer())
    assert "expirou" in bot.editadas[0][0]


def _tumulo(d, id, outcome, idade=0.0, **extra):
    import os
    f = d / f"{id}.done"
    f.write_text(json.dumps({"id": id, "outcome": outcome, **extra}))
    if idade:
        t = time.time() - idade
        os.utime(f, (t, t))
    return f


@pytest.mark.parametrize("outcome,rotulo", [
    ("allow", "permitido no app"), ("deny", "negado"),
    ("cancelled", "cancelado (a conversa parou)"), ("expired", "expirou"),
])
def test_label_follows_the_tombstone_and_it_is_deleted(d, outcome, rotulo):
    pedido(d)
    bot, a = novo(d)
    run(a.varrer())
    (d / f"{ID}.json").unlink()
    f = _tumulo(d, ID, outcome)
    run(a.varrer())
    assert bot.editadas[0][0] == bot.enviadas[0][1] + f"\n\n<i>{rotulo}</i>"
    assert not f.exists() and a.postados == {}


def test_without_tombstone_the_time_fallback_stays(d):
    pedido(d)
    bot, a = novo(d)
    run(a.varrer())
    (d / f"{ID}.json").unlink()
    run(a.varrer())
    assert "respondido no app" in bot.editadas[0][0]


def test_tombstone_of_another_id_or_garbage_is_ignored(d):
    pedido(d)
    bot, a = novo(d)
    run(a.varrer())
    (d / f"{ID}.json").unlink()
    _tumulo(d, ID, "bogus")
    run(a.varrer())
    assert "respondido no app" in bot.editadas[0][0]
    assert not (d / f"{ID}.done").exists()


def test_stale_tombstone_is_cleaned(d):
    velho = _tumulo(d, ID2, "allow", idade=VALIDADE + 1)
    novo_ = _tumulo(d, "c" * 32, "deny", idade=10)
    bot, a = novo(d)
    run(a.varrer())
    assert not velho.exists() and novo_.exists()


def test_decided_but_not_yet_withdrawn_is_not_labelled_yet(d):
    pedido(d)
    bot, a = novo(d)
    run(a.varrer())
    (d / f"{ID}.decision").write_text("allow")          # a ferramenta ainda nao escreveu o .done
    run(a.varrer())
    assert bot.editadas == [] and ID in a.postados
    f = _tumulo(d, ID, "allow")
    (d / f"{ID}.json").unlink()
    (d / f"{ID}.decision").unlink()
    run(a.varrer())
    assert bot.editadas[0][0] == bot.enviadas[0][1] + "\n\n<i>permitido no app</i>"
    assert not f.exists() and a.postados == {}


def test_failed_tombstone_label(d):
    pedido(d)
    bot, a = novo(d)
    run(a.varrer())
    (d / f"{ID}.json").unlink()
    _tumulo(d, ID, "failed")
    run(a.varrer())
    assert "<i>permitido, mas o envio falhou</i>" in bot.editadas[0][0]


@pytest.mark.parametrize("desfecho", ["expired", "cancelled"])
def test_decidir_after_the_tool_gave_up_is_refused(d, desfecho):
    pedido(d)
    _tumulo(d, ID, desfecho)
    assert not aprovacoes.decidir(ID, True, d)
    assert not (d / f"{ID}.decision").exists()


def test_decidir_while_the_tool_picks_it_up_still_counts(d):
    pedido(d)
    _tumulo(d, ID, "allow")
    assert aprovacoes.decidir(ID, True, d)


def test_press_after_expiry_never_says_permitido(d):
    bot, ap = novo(d)
    pedido(d)
    run(ap.varrer())
    _tumulo(d, ID, "expired")
    q = FakeQuery(f"aprov:{ID}:allow", OWNER)
    run(ap.pressionou(SimpleNamespace(callback_query=q)))
    assert q.respostas == ["já respondido"]
    assert "permitido" not in q.editadas[0]
