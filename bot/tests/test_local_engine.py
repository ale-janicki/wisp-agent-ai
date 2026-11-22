import asyncio
import re
import json
import shutil
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from wisp_bot import aprovacoes, bot, engine, local_runner, modelo
from wisp_bot.config import CURRENT as CFG
from wisp_bot.transcript import Transcripts, switched_note

ROOT = Path(__file__).parents[2]
FIXTURES = ROOT / "cli/tests/fixtures"
WISP_FOLDER = ROOT / "cli/src/wisp/wisp_folder"
sys.path.insert(0, str(ROOT / "cli/tests"))
from local_fakes import FakeLLM, call, reply  # noqa: E402


def without_day(text):
    return re.sub(r"\n\n\[Hoje é \d{4}-\d{2}-\d{2}\.\]$", "", text)


@pytest.fixture
def wisp(monkeypatch, tmp_path):
    folder = CFG.wisp_dir
    shutil.rmtree(folder, ignore_errors=True)
    (folder / "conversas").mkdir(parents=True)
    for name in ("guardrails.toml", "modelos.toml"):
        shutil.copy(WISP_FOLDER / name, folder / name)
    (folder / "notas.txt").write_text("conteúdo das notas")
    (folder / "modelos.toml").write_text(
        'ativo = "local"\n\n[local]\nativo = "qwen3:8b"\ninstalados = ["qwen3:8b"]\n')
    log = tmp_path / "mail.log"
    monkeypatch.setenv("FAKE_MAIL_LOG", str(log))
    monkeypatch.setattr(local_runner, "launch", lambda: [sys.executable, str(FIXTURES / "fake_wisp_local.py")])
    monkeypatch.setattr(local_runner, "permission_mode", lambda: "default")
    monkeypatch.setattr(engine, "_status_cache", {})
    transcripts = Transcripts(folder / "conversas")
    monkeypatch.setattr(bot, "transcripts", transcripts)
    yield SimpleNamespace(folder=folder, log=log, transcripts=transcripts)
    shutil.rmtree(folder, ignore_errors=True)


def point(wisp, url):
    (wisp.folder / "modelos.toml").write_text(
        f'ativo = "local"\n\n[local]\nativo = "qwen3:8b"\ninstalados = []\nbackend = "openai"\nurl = "{url}"\n')


TOPIC = SimpleNamespace(session_id="11111111-1111-4111-8111-111111111111")


class Decider:
    def __init__(self, answer=None):
        self.answer, self.requests = answer, []

    async def __call__(self, req):
        self.requests.append(req)
        return self.answer


def turn(wisp, fake, text, *, decider=None, trocou=False, notices=None, monkeypatch=None):
    async def warn():
        notices.append("avisou")

    async def go():
        res, _ = await bot.local_com_memoria(
            TOPIC, engine.get("local"), text, text, warn, trocou, cwd=str(wisp.folder), model="claude-x", timeout=60,
            extra_prompt="", disallowed="", env={"WISP_TELEGRAM_THREAD": "7"}, on_permission=decider)
        if res.ok:
            wisp.transcripts.assistant(TOPIC.session_id, res.text, "telegram", res.engine, res.model)
        return res

    return asyncio.run(go())


def entries(wisp):
    return [json.loads(l) for l in (wisp.folder / "conversas" / f"{TOPIC.session_id}.jsonl").read_text().splitlines()]


def test_a_text_turn_runs_the_local_engine_and_records_the_transcript(wisp, monkeypatch):
    with FakeLLM([reply("Olá!")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        res = turn(wisp, fake, "oi")
    assert res.ok and res.text == "Olá!" and res.engine == "local" and res.model == "qwen3:8b"
    kinds = [(e["kind"], e.get("engine"), e.get("model"), e.get("text")) for e in entries(wisp)]
    assert kinds[1:] == [("user", None, None, "oi"), ("assistant", "local", "qwen3:8b", "Olá!")]
    assert [without_day(m["content"]) for m in fake.chats()[0]["messages"] if m["role"] == "user"] == ["oi"]


def test_the_next_turn_carries_the_conversation_from_the_transcript(wisp, monkeypatch):
    with FakeLLM([reply("um"), reply("dois")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        turn(wisp, fake, "primeira")
        turn(wisp, fake, "segunda")
    sent = [(m["role"], without_day(m["content"])) for m in fake.chats()[1]["messages"] if m["role"] != "system"]
    assert sent == [("user", "primeira"), ("assistant", "um"), ("user", "segunda")]


def test_a_carded_tool_asks_the_host_and_runs_only_when_allowed(wisp, monkeypatch):
    target = wisp.folder / "novo.txt"
    plant = reply("", [call("write_file", path=str(target), content="x")])
    with FakeLLM([plant, reply("feito")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        allow = Decider(None)
        res = turn(wisp, fake, "escreve", decider=allow)
    assert res.ok and target.read_text() == "x"
    assert allow.requests[0]["tool_name"] == "write_file" and allow.requests[0]["engine"] == "local"
    target.unlink()
    with FakeLLM([plant, reply("não deu")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        deny = Decider("O usuário negou esta ação no Telegram.")
        res = turn(wisp, fake, "escreve de novo", decider=deny)
    assert res.ok and not target.exists() and len(deny.requests) == 1
    assert any("negou" in m["content"] for m in fake.chats()[1]["messages"] if m["role"] == "tool")


def test_with_no_way_to_ask_a_carded_tool_is_denied(wisp, monkeypatch):
    target = wisp.folder / "novo.txt"
    with FakeLLM([reply("", [call("write_file", path=str(target), content="x")]), reply("ok")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        res = turn(wisp, fake, "escreve", decider=None)
    assert res.ok and not target.exists()


class FakeBot:
    def __init__(self):
        self.enviadas = []

    async def send_message(self, chat_id, text, **kw):
        self.enviadas.append((chat_id, text, kw))
        return SimpleNamespace(message_id=1)

    async def edit_message_text(self, text, **kw):
        pass


class FakeQuery:
    def __init__(self, data):
        self.data, self.from_user = data, SimpleNamespace(id=1)

    async def answer(self, text=None, **kw):
        pass


def test_the_telegram_card_for_the_local_engine_names_it_and_its_button_unblocks_the_tool(wisp, monkeypatch):
    target = wisp.folder / "cartao.txt"
    plant = reply("", [call("write_file", path=str(target), content="y")])

    async def go():
        bot_api = FakeBot()
        cards = aprovacoes.Aprovacoes(bot_api, 1)

        async def ask(req):
            return await cards.pedir(-1001, 7, req)

        async def press():
            while not bot_api.enviadas:
                await asyncio.sleep(0.01)
            data = bot_api.enviadas[0][2]["reply_markup"].inline_keyboard[0][0].callback_data
            await cards.pressionou(SimpleNamespace(callback_query=FakeQuery(data)))

        async def run():
            res, _ = await bot.local_com_memoria(
                TOPIC, engine.get("local"), "escreve", "escreve", lambda: None, False, cwd=str(wisp.folder), model=None,
                timeout=60, extra_prompt="", disallowed="", env={}, on_permission=ask)
            return res

        res, _ = await asyncio.gather(run(), press())
        return res, bot_api.enviadas[0][1]

    with FakeLLM([plant, reply("feito")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        res, card = asyncio.run(go())
    assert res.ok and target.read_text() == "y" and "A IA local quer usar write_file" in card


def test_email_send_keeps_the_single_use_ticket_flow_when_the_bot_is_the_host(wisp, monkeypatch):
    send = reply("", [call("email_send", to=["a@b.c"], subject="Oi", body="texto")])
    with FakeLLM([send, reply("enviei")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        allow = Decider(None)
        res = turn(wisp, fake, "manda", decider=allow)
    assert res.ok and wisp.log.read_text() == "['a@b.c']|Oi|texto\n"
    assert allow.requests[0]["tool_name"] == "email_send" and allow.requests[0]["input"]["to"] == ["a@b.c"]
    wisp.log.unlink()
    with FakeLLM([send, reply("não enviei")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        res = turn(wisp, fake, "manda de novo", decider=Decider("negado"))
    assert res.ok and not wisp.log.exists()


def test_switching_from_claude_to_local_rebuilds_the_context_from_the_transcript(wisp, monkeypatch):
    wisp.transcripts.user(TOPIC.session_id, "qual a capital da França?", "telegram")
    wisp.transcripts.assistant(TOPIC.session_id, "Paris.", "telegram", "claude", "claude-x")
    notices = []
    with FakeLLM([reply("Sim, Paris.")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        res = turn(wisp, fake, "e a população?", trocou=True, notices=notices)
    sent = [(m["role"], without_day(m["content"])) for m in fake.chats()[0]["messages"] if m["role"] != "system"]
    assert res.ok and notices == ["avisou"] and sent == [
        ("user", "qual a capital da França?"), ("assistant", "Paris."), ("user", "e a população?")]
    assert wisp.transcripts.last_engine(TOPIC.session_id) == "local"
    assert switched_note("local") == "<i>↻ agora quem responde é a IA local; ele retomou pela conversa guardada no Wisp.</i>"


def test_switching_from_local_back_to_claude_sees_the_local_reply(wisp, monkeypatch):
    with FakeLLM([reply("resposta local")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        turn(wisp, fake, "pergunta")
    context = wisp.transcripts.context(TOPIC.session_id)
    assert wisp.transcripts.last_engine(TOPIC.session_id) == "local"
    assert "User: pergunta" in context and "Assistant: resposta local" in context


def test_a_failed_local_turn_reports_the_server_and_records_no_reply(wisp, monkeypatch):
    point(wisp, "http://127.0.0.1:1")
    res = turn(wisp, None, "oi")
    assert not res.ok and "servidor" in res.text
    assert [e["kind"] for e in entries(wisp)][-1] == "user"


def fake_wisp(tmp_path, body):
    script = tmp_path / "wisp"
    script.write_text(f"#!/bin/sh\n{body}\n")
    script.chmod(0o755)
    return [str(script)]


def test_the_active_local_engine_is_used_when_ready(wisp, monkeypatch, tmp_path):
    monkeypatch.setattr(local_runner, "launch", lambda: fake_wisp(tmp_path, 'echo \'{"type":"ready","ready":true}\''))
    eng, note = asyncio.run(engine.resolve(wisp.folder))
    assert eng.name == "local" and note is None


@pytest.mark.parametrize("missing", ["o mlx-lm não está instalado neste Wisp; atualize o Wisp", "o modelo qwen3:8b não está baixado", "nenhum modelo local está ativo"])
def test_a_local_engine_that_is_not_ready_falls_back_to_claude_and_says_why(wisp, monkeypatch, tmp_path, missing):
    payload = json.dumps({"type": "ready", "ready": False, "missing": missing}, ensure_ascii=False)
    monkeypatch.setattr(local_runner, "launch", lambda: fake_wisp(tmp_path, f"echo '{payload}'"))
    eng, note = asyncio.run(engine.resolve(wisp.folder))
    assert eng.name == "claude" and missing in note and "esta resposta veio do Claude" in note and "Ajustes &gt; Modelo" in note


def test_a_readiness_check_that_cannot_run_or_hangs_falls_back(wisp, monkeypatch, tmp_path):
    monkeypatch.setattr(local_runner, "launch", lambda: [str(tmp_path / "missing")])
    assert asyncio.run(local_runner.readiness()) == (False, "não achei o comando do Wisp")
    import subprocess, uuid
    marker = f"sleep 30.{uuid.uuid4().int % 10**9:09d}"
    monkeypatch.setattr(local_runner, "launch", lambda: fake_wisp(tmp_path, marker))
    assert asyncio.run(local_runner.readiness(timeout=0.3)) == (False, "o servidor local não respondeu a tempo")
    assert subprocess.run(["pgrep", "-f", marker], capture_output=True).returncode != 0


def test_claude_and_codex_selection_is_unchanged(wisp, monkeypatch):
    (wisp.folder / "modelos.toml").write_text('ativo = "claude"\n')
    assert asyncio.run(engine.resolve(wisp.folder))[0].name == "claude"
    (wisp.folder / "modelos.toml").write_text('ativo = "nada"\n')
    assert asyncio.run(engine.resolve(wisp.folder))[0].name == "claude"


def test_the_modelo_command_switches_through_the_cli_writer_and_shows_the_recommendation(wisp, monkeypatch, tmp_path):
    log = tmp_path / "args"
    advice = json.dumps({"best": {"name": "Qwen3 8B", "reason": "cabe com folga em 16 GB; ~17 palavras/s (estimativa)"},
                         "fastest": None, "notes": ["nenhum modelo que use ferramentas direito cabe"]}, ensure_ascii=False)
    body = (f'echo "$@" >> {log}\ncase "$1" in config) echo \'{{"status":"done"}}\';; '
            f"local) echo '{advice}';; esac")
    monkeypatch.setattr(modelo, "launch", lambda: fake_wisp(tmp_path, body))
    monkeypatch.setattr(local_runner, "launch", lambda: fake_wisp(tmp_path, 'echo \'{"type":"ready","ready":false,"missing":"o modelo qwen3:8b não está baixado"}\''))
    sent = []

    async def reply_(update, text, thread_id=None):
        sent.append(text)

    monkeypatch.setattr(bot, "reply", reply_)
    monkeypatch.setattr(bot, "authorized", lambda update: True)
    monkeypatch.setattr(bot, "topic_key", lambda update: ("k", 7))
    asyncio.run(bot.cmd_modelo(None, SimpleNamespace(args=[])))
    assert "Pensar antes de responder:</b> não" in sent[0]
    assert "Motor ativo:</b> IA local" in sent[0] and "qwen3:8b" in sent[0] and "Melhor para este Mac:</b> Qwen3 8B" in sent[0]
    assert "/modelo local" in sent[0]
    asyncio.run(bot.cmd_modelo(None, SimpleNamespace(args=["local"])))
    assert "config set engine local --json" in log.read_text() and "motor agora: IA local" in sent[1]
    assert "ainda não está pronta (o modelo qwen3:8b não está baixado)" in sent[1]
    asyncio.run(bot.cmd_modelo(None, SimpleNamespace(args=["gpt"])))
    assert "motor desconhecido" in sent[2] and "config set engine gpt" not in log.read_text()


def test_the_modelo_command_reports_a_switch_that_failed(wisp, monkeypatch, tmp_path):
    monkeypatch.setattr(modelo, "launch", lambda: fake_wisp(tmp_path, 'echo \'{"status":"failed","summary":"o harness não sincronizou"}\''))
    sent = []

    async def reply_(update, text, thread_id=None):
        sent.append(text)

    monkeypatch.setattr(bot, "reply", reply_)
    monkeypatch.setattr(bot, "authorized", lambda update: True)
    monkeypatch.setattr(bot, "topic_key", lambda update: ("k", None))
    asyncio.run(bot.cmd_modelo(None, SimpleNamespace(args=["codex"])))
    assert "não consegui trocar o motor: o harness não sincronizou" in sent[0]


def test_the_command_is_registered_and_in_the_menu():
    assert "modelo" in dict(bot.PROPRIOS) and "modelo" in bot.MENU


def test_a_message_that_starts_with_a_dash_is_not_taken_for_an_option(wisp, monkeypatch):
    with FakeLLM([reply("ok")], tags={"qwen3:8b": 5}) as fake:
        point(wisp, fake.url)
        res = turn(wisp, fake, "-5 graus é frio?")
    assert res.ok and without_day(fake.chats()[0]["messages"][-1]["content"]) == "-5 graus é frio?"


def test_the_modelo_summary_shows_the_thinking_setting(wisp):
    assert modelo.thinking(wisp.folder) is False
    (wisp.folder / "modelos.toml").write_text('ativo = "local"\n\n[local]\nativo = "qwen3:8b"\npensar = true\n')
    assert modelo.thinking(wisp.folder) is True
    (wisp.folder / "modelos.toml").write_text("ativo = [")
    assert modelo.thinking(wisp.folder) is False
