import asyncio
import json
from types import SimpleNamespace

import pytest

from wisp_bot import aprovacoes, claude_runner

OWNER = 1
EMAIL = {"subtype": "can_use_tool", "tool_name": "mcp__wisp-email__email_send",
         "input": {"to": ["ana@exemplo.com"], "subject": "oi", "body": "corpo"}}


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
        self.respostas = []

    async def answer(self, text=None, **kw):
        self.respostas.append(text)


def botao(bot, indice):
    return bot.enviadas[0][2]["reply_markup"].inline_keyboard[0][indice].callback_data


async def com_cartao(ap, bot, req=EMAIL, thread=7):
    tarefa = asyncio.ensure_future(ap.pedir(-1001, thread, req))
    for _ in range(100):
        if bot.enviadas:
            break
        await asyncio.sleep(0)
    return tarefa


def test_the_card_shows_the_whole_request_and_allow_answers_none():
    async def go():
        bot = FakeBot()
        ap = aprovacoes.Aprovacoes(bot, OWNER)
        tarefa = await com_cartao(ap, bot)
        chat, corpo, kw = bot.enviadas[0]
        assert chat == -1001 and kw["message_thread_id"] == 7
        assert "mcp__wisp-email__email_send" in corpo and "ana@exemplo.com" in corpo and "corpo" in corpo
        assert [b.text for b in kw["reply_markup"].inline_keyboard[0]] == ["Permitir", "Negar"]
        q = FakeQuery(botao(bot, 0), OWNER)
        await ap.pressionou(SimpleNamespace(callback_query=q))
        assert await tarefa is None and q.respostas == ["permitido"]
        assert "permitido" in bot.editadas[0][0] and bot.editadas[0][1]["reply_markup"] is None
    asyncio.run(go())


def test_deny_answers_the_text_claude_reads():
    async def go():
        bot = FakeBot()
        ap = aprovacoes.Aprovacoes(bot, OWNER)
        tarefa = await com_cartao(ap, bot)
        await ap.pressionou(SimpleNamespace(callback_query=FakeQuery(botao(bot, 1), OWNER)))
        assert await tarefa == aprovacoes.NEGADO_NO_TELEGRAM
    asyncio.run(go())


def test_only_the_owner_answers_and_the_card_stays_open():
    async def go():
        bot = FakeBot()
        ap = aprovacoes.Aprovacoes(bot, OWNER)
        tarefa = await com_cartao(ap, bot)
        intruso = FakeQuery(botao(bot, 0), OWNER + 1)
        await ap.pressionou(SimpleNamespace(callback_query=intruso))
        assert intruso.respostas == ["só o dono do Wisp pode responder"] and not tarefa.done()
        await ap.pressionou(SimpleNamespace(callback_query=FakeQuery(botao(bot, 1), OWNER)))
        assert await tarefa == aprovacoes.NEGADO_NO_TELEGRAM
    asyncio.run(go())


def test_a_second_press_or_an_unknown_card_is_expired():
    async def go():
        bot = FakeBot()
        ap = aprovacoes.Aprovacoes(bot, OWNER)
        tarefa = await com_cartao(ap, bot)
        data = botao(bot, 0)
        await ap.pressionou(SimpleNamespace(callback_query=FakeQuery(data, OWNER)))
        await tarefa
        de_novo = FakeQuery(data, OWNER)
        await ap.pressionou(SimpleNamespace(callback_query=de_novo))
        assert de_novo.respostas == ["expirou ou já respondido"]
        for lixo in ("aprov:x:allow", "aprov:x", "outro:x:allow", ""):
            q = FakeQuery(lixo, OWNER)
            await ap.pressionou(SimpleNamespace(callback_query=q))
            assert q.respostas in (["expirou ou já respondido"], [None])
    asyncio.run(go())


def test_no_answer_in_time_denies():
    async def go():
        bot = FakeBot()
        ap = aprovacoes.Aprovacoes(bot, OWNER, validade=0.05)
        assert await ap.pedir(-1001, None, EMAIL) == aprovacoes.EXPIROU
        assert "expirou" in bot.editadas[0][0]
    asyncio.run(go())


def test_a_card_that_does_not_fit_has_no_allow_button_and_is_denied_now():
    async def go():
        bot = FakeBot()
        ap = aprovacoes.Aprovacoes(bot, OWNER)
        longo = {**EMAIL, "input": {**EMAIL["input"], "body": "x" * 5000}}
        assert await ap.pedir(-1001, None, longo) == aprovacoes.LONGO_DEMAIS
        _, corpo, kw = bot.enviadas[0]
        assert "reply_markup" not in kw and "aprove pelo app" in corpo and len(corpo) < 4096
        assert "não cabe" in bot.editadas[0][0]
    asyncio.run(go())


def test_cancelling_the_request_closes_the_card():
    async def go():
        bot = FakeBot()
        ap = aprovacoes.Aprovacoes(bot, OWNER)
        tarefa = await com_cartao(ap, bot)
        tarefa.cancel()
        with pytest.raises(asyncio.CancelledError):
            await tarefa
        assert "cancelado" in bot.editadas[0][0]
    asyncio.run(go())


def test_bash_shows_the_command_itself():
    pedido = aprovacoes.descrever({"tool_name": "Bash", "input": {"command": "touch probe1"}})
    assert pedido["detail"] == "touch probe1"


FAKE_CLAUDE = """#!{python}
import json, sys
user = json.loads(sys.stdin.readline())
print(json.dumps({{"type": "control_request", "request_id": "r1", "request": {request}}}), flush=True)
answer = json.loads(sys.stdin.readline())
print(json.dumps({{"type": "result", "is_error": False, "session_id": "s",
                  "result": json.dumps({{"user": user, "answer": answer}})}}), flush=True)
sys.stdin.read()
"""


def _rodar(tmp_path, monkeypatch, on_permission, request=EMAIL):
    fake = tmp_path / "claude"
    fake.write_text(FAKE_CLAUDE.format(python=__import__("sys").executable, request=json.dumps(request)))
    fake.chmod(0o755)
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(fake))
    monkeypatch.setattr(claude_runner, "guard_settings_path", lambda: tmp_path / "g.json")
    monkeypatch.setattr(claude_runner, "WISP_BIN", str(fake))
    res = asyncio.run(claude_runner.run("mande um e-mail", session_id="11111111-1111-1111-1111-111111111111",
                                        cwd=str(tmp_path), started=False, timeout=20, on_permission=on_permission))
    assert res.ok, res.text
    return json.loads(res.text)


def test_runner_sends_the_user_message_as_stream_json_and_allows(tmp_path, monkeypatch):
    vistos = []

    async def permitir(req):
        vistos.append(req)
        return None

    dados = _rodar(tmp_path, monkeypatch, permitir)
    assert dados["user"] == {"type": "user", "message": {"role": "user", "content": "mande um e-mail"}}
    assert vistos == [EMAIL]
    assert dados["answer"] == {"type": "control_response", "response": {
        "subtype": "success", "request_id": "r1",
        "response": {"behavior": "allow", "updatedInput": EMAIL["input"]}}}


def test_runner_denies_with_the_text_the_handler_gave(tmp_path, monkeypatch):
    async def negar(req):
        return "não"

    dados = _rodar(tmp_path, monkeypatch, negar)
    assert dados["answer"]["response"]["response"] == {"behavior": "deny", "message": "não"}


def test_runner_denies_when_nobody_can_answer_or_the_handler_breaks(tmp_path, monkeypatch):
    sem = _rodar(tmp_path, monkeypatch, None)["answer"]["response"]["response"]
    assert sem == {"behavior": "deny", "message": claude_runner.SEM_CANAL}

    async def quebra(req):
        raise RuntimeError("telegram caiu")

    assert _rodar(tmp_path, monkeypatch, quebra)["answer"]["response"]["response"]["behavior"] == "deny"


def test_runner_asks_claude_for_the_permission_channel_and_the_ask_rule(tmp_path, monkeypatch):
    args = tmp_path / "args"
    fake = tmp_path / "claude"
    fake.write_text(f'#!/bin/sh\necho "$@" > {args}\ncat >/dev/null &\n'
                    'echo \'{"type":"result","is_error":false,"result":"ok","session_id":"s"}\'\nwait\n')
    fake.chmod(0o755)
    settings = tmp_path / "g.json"
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(fake))
    monkeypatch.setattr(claude_runner, "guard_settings_path", lambda: settings)
    asyncio.run(claude_runner.run("oi", session_id="11111111-1111-1111-1111-111111111111",
                                  cwd=str(tmp_path), started=False, timeout=20))
    linha = args.read_text()
    assert "--input-format stream-json" in linha and "--permission-prompt-tool stdio" in linha
    assert "mcp__wisp-email__email_send" in json.loads(settings.read_text())["permissions"]["ask"]
