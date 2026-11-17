"""Modo celular (/me-avisa): o celular resolve as perguntas. Fim de turno que faz o topico assumir a sessao,
turno com --resume no cwd e guarda contra dois escritores.
Nada fala com o Telegram nem com o claude: o post e o comando sao capturados."""
import asyncio
import json
import os
import time
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from wisp_bot import bot, claude_runner, topicos, vigia
from wisp_bot.store import Store

SID, OUTRA = "11111111-2222-4333-8444-555555555555", "99999999-2222-4333-8444-555555555555"
CHAT, THREAD = 1, 77
KEY = f"{CHAT}:{THREAD}"


def linha(ts: datetime, tipo: str, conteudo, **extra) -> str:
    return json.dumps({"type": tipo, "timestamp": ts.isoformat().replace("+00:00", "Z"),
                       "message": {"role": tipo, "content": conteudo, **extra}})


def prompt(ts):
    return linha(ts, "user", "faz a coisa")


def fim(ts, texto="Pronto. Quer A ou B?"):
    return linha(ts, "assistant", [{"type": "text", "text": texto}], stop_reason="end_turn")


def tool(ts, nome="Bash", id_="t1"):
    return linha(ts, "assistant", [{"type": "tool_use", "name": nome, "id": id_, "input": {}}], stop_reason="tool_use")


# ---- (a) hook ----


# ---- mundo: jsonl real em tmp, store, registro, posts capturados ----

class Mundo:
    def __init__(self, tmp_path, monkeypatch):
        self.cwd = tmp_path / "repo"
        self.cwd.mkdir()
        self.jsonl = tmp_path / "projetos" / vigia.slug(str(self.cwd)) / f"{SID}.jsonl"
        self.jsonl.parent.mkdir(parents=True)
        self.posts: list[str] = []
        self.agora = datetime.now(timezone.utc)
        monkeypatch.setattr(vigia, "PROJETOS", tmp_path / "projetos")
        monkeypatch.setattr(vigia, "ARQUIVO", tmp_path / "vigias.json")
        monkeypatch.setattr(bot, "store", Store(tmp_path / "topics.json"))
        monkeypatch.setattr(topicos, "DIR", tmp_path / "brain" / "topicos")
        monkeypatch.setattr(topicos, "BRAIN", tmp_path / "brain")
        monkeypatch.setattr(bot, "vigilia", SimpleNamespace(segurar=lambda *a: None, soltar=lambda *a: None,
                                                            esperar_poder=_nada, agendar_soltura=lambda *a: None,
                                                            SEGURA_GERAL_S=0, SEGURA_TOPICO_S=0))
        monkeypatch.setattr(topicos, "push_logo", lambda *a, **k: None)
        monkeypatch.setattr(topicos, "gravar_ponteiro", self._ponteiro)
        self.ponteiros: list[tuple] = []
        bot.store.get_or_create(KEY, "mirror", str(self.cwd), meta={"espelho": SID})

        async def postar(app, rec, texto):
            self.posts.append(texto)
        monkeypatch.setattr(bot, "_vigia_postar", postar)
        vigia.registrar({"session_id": SID, "cwd": str(self.cwd), "thread": THREAD, "chat": CHAT, "nome": "mirror",
                         "host": bot.HOST, "desde": (self.agora - timedelta(hours=1)).timestamp(),
                         "estado": "rodando", "avisado": "rodando", "motivo": "", "modo": "celular"})

    def _ponteiro(self, *a):
        self.ponteiros.append(a)

    def escrever(self, *linhas: str) -> None:
        with open(self.jsonl, "a") as f:
            f.write("\n".join(linhas) + "\n")

    def envelhecer(self, s: int) -> None:
        t = time.time() - s
        os.utime(self.jsonl, (t, t))

    def tick(self) -> None:
        asyncio.run(bot._vigia_um(None, SID, vigia.ler()[SID]))


async def _nada(*a, **k):
    return None


@pytest.fixture
def mundo(tmp_path, monkeypatch):
    return Mundo(tmp_path, monkeypatch)


# ---- (b) fim de turno -> post com o texto + topico assume a sessao ----

def test_b_fim_de_turno_posta_o_texto_e_o_topico_adota_a_sessao(mundo):
    mundo.escrever(prompt(mundo.agora - timedelta(minutes=10)), fim(mundo.agora - timedelta(minutes=5)))
    mundo.tick()
    assert mundo.posts[0].startswith("✅ terminou") and "Quer A ou B?" in mundo.posts[0]
    assert "<code>terminal</code>" in mundo.posts[1] and "mesma conversa" in mundo.posts[1]
    t = bot.store.get(KEY)
    assert (t.session_id, t.cwd, t.started) == (SID, str(mundo.cwd), True)
    assert "espelho" not in t.meta and t.meta["celular"] == SID
    assert vigia.ler()[SID]["modo"] == "adotada"                    # o topico e o dono; o registro so vigia o terminal
    assert bot._escrita_bot(KEY) >= mundo.jsonl.stat().st_mtime     # linha de base: o que ja estava no jsonl
    assert mundo.ponteiros and mundo.ponteiros[0][2] == SID         # a nota aponta a sessao: puxar a acha


def test_b_sem_modo_celular_o_espelho_continua_como_antes(mundo):
    vigia.atualizar(SID, modo=None)
    mundo.escrever(prompt(mundo.agora - timedelta(minutes=10)), fim(mundo.agora - timedelta(minutes=5)))
    mundo.tick()
    assert len(mundo.posts) == 1 and SID in vigia.ler()
    assert bot.store.get(KEY).meta.get("espelho") == SID


def test_b_turno_ainda_rodando_nao_adota(mundo):
    mundo.escrever(prompt(mundo.agora - timedelta(minutes=10)), tool(mundo.agora - timedelta(minutes=1)))
    mundo.tick()
    assert mundo.posts == [] and bot.store.get(KEY).meta.get("espelho") == SID


def test_abertura_traz_o_que_roda_o_ultimo_texto_e_a_pergunta_aberta(mundo):
    ask = linha(mundo.agora, "assistant", [{"type": "tool_use", "name": "AskUserQuestion", "id": "q1", "input": {
        "questions": [{"question": "Qual banco?", "options": [{"label": "PG"}, {"label": "SQLite"}]}]}}],
        stop_reason="tool_use")
    mundo.escrever(prompt(mundo.agora - timedelta(minutes=2)),
                   linha(mundo.agora - timedelta(minutes=1), "assistant", [{"type": "text", "text": "Analisei."}]), ask)
    texto, pid = vigia.abertura_celular(SID, str(mundo.cwd))
    assert pid == "q1" and "Analisei." in texto and "Qual banco?" in texto and "PG · SQLite" in texto
    assert vigia.PERGUNTA_TERMINAL in texto and "turno em andamento" in texto


# ---- (c) mensagem no topico adotado = turno com --resume sid no cwd ----

def adotar(mundo):
    mundo.escrever(prompt(mundo.agora - timedelta(minutes=10)), fim(mundo.agora - timedelta(minutes=5)))
    mundo.envelhecer(300)
    mundo.tick()


def test_c_mensagem_apos_adocao_roda_turno_com_resume_no_cwd(mundo, monkeypatch):
    adotar(mundo)
    chamadas = []

    async def claude_falso(prompt, **kw):
        chamadas.append(kw)
        return claude_runner.Result(True, "feito", cost_usd=0.0)
    monkeypatch.setattr(bot, "claude_run", claude_falso)
    monkeypatch.setattr(bot, "send", lambda *a, **k: _nada())
    asyncio.run(bot.turno(SimpleNamespace(), SimpleNamespace(id=CHAT), THREAD, KEY, "segue com a opcao A"))
    assert chamadas[0]["session_id"] == SID and chamadas[0]["started"] is True
    assert chamadas[0]["cwd"] == str(mundo.cwd)


def test_c_o_runner_monta_claude_resume_sid_no_cwd(tmp_path, monkeypatch):
    visto = {}

    async def exec_falso(*cmd, **kw):
        visto["cmd"], visto["cwd"] = list(cmd), kw["cwd"]
        raise FileNotFoundError
    monkeypatch.setattr(claude_runner.asyncio, "create_subprocess_exec", exec_falso)
    r = asyncio.run(claude_runner.run("oi", session_id=SID, cwd=str(tmp_path), started=True))
    i = visto["cmd"].index("--resume")
    assert visto["cmd"][i + 1] == SID and "--session-id" not in visto["cmd"] and visto["cwd"] == str(tmp_path)
    assert not r.ok


# ---- (d) terminal no meio do turno: a mensagem espera ----

def test_d_terminal_no_meio_do_turno_segura_a_mensagem_ate_o_end_turn(mundo, monkeypatch):
    adotar(mundo)
    mundo.escrever(prompt(mundo.agora), tool(mundo.agora + timedelta(seconds=1)))      # o usuario voltou ao terminal
    monkeypatch.setattr(bot, "TERMINAL_POLL_S", 0.01)
    avisos, chamadas = [], []

    async def enviar(b, chat, tid, texto):
        avisos.append(texto)
    monkeypatch.setattr(bot, "send", enviar)

    async def claude_falso(prompt, **kw):
        chamadas.append(avisos[:])                    # o aviso ja tem que ter saido antes do turno
        return claude_runner.Result(True, "feito", cost_usd=0.0)
    monkeypatch.setattr(bot, "claude_run", claude_falso)

    async def cenario():
        tarefa = asyncio.create_task(bot.turno(SimpleNamespace(), SimpleNamespace(id=CHAT), THREAD, KEY, "oi"))
        await asyncio.sleep(0.1)
        assert chamadas == [] and not tarefa.done()                                   # segurada
        mundo.escrever(fim(mundo.agora + timedelta(seconds=5), "terminal acabou"))    # end_turn do terminal
        mundo.envelhecer(120)                                                          # e nada escrito ha 60 s+
        await asyncio.wait_for(tarefa, 5)
    asyncio.run(cenario())
    assert avisos.count(bot.TERMINAL_RODANDO_AVISO) == 1 and len(chamadas) >= 1
    assert chamadas[0][0] == bot.TERMINAL_RODANDO_AVISO


def test_d_escrita_do_proprio_bot_nao_conta_como_terminal(mundo):
    adotar(mundo)
    mundo.escrever(fim(mundo.agora, "resposta do bot"))                               # mtime = agora
    assert vigia.terminal_ativo(SID, str(mundo.cwd)) is True                          # desconhecido: assume terminal
    assert vigia.terminal_ativo(SID, str(mundo.cwd), escrita_bot=time.time()) is False


def test_d_terminal_parado_sem_end_turn_nao_trava_para_sempre(mundo):
    mundo.escrever(prompt(mundo.agora - timedelta(hours=2)), tool(mundo.agora - timedelta(hours=2)))
    mundo.envelhecer(3600)
    assert vigia.terminal_ativo(SID, str(mundo.cwd)) is False


# ---- (e) puxar devolve a sessao ao terminal ----


# ---- round 2 ----


def test_d_turno_do_bot_interrompido_nao_e_terminal_ativo(mundo):
    mundo.escrever(prompt(mundo.agora), tool(mundo.agora))                            # /stop no meio do turno do bot
    bot_ts = mundo.jsonl.stat().st_mtime
    assert vigia.terminal_ativo(SID, str(mundo.cwd)) is True                          # sem saber quem escreveu: terminal
    assert vigia.terminal_ativo(SID, str(mundo.cwd), escrita_bot=bot_ts) is False     # ultima escrita e do bot
    assert vigia.terminal_ativo(SID, str(mundo.cwd), escrita_bot=bot_ts - 30) is True  # terminal escreveu depois


def test_d_escrita_do_bot_sobrevive_a_restart(mundo, monkeypatch):
    adotar(mundo)
    monkeypatch.setattr(bot, "claude_run", lambda *a, **k: _res())
    monkeypatch.setattr(bot, "send", lambda *a, **k: _nada())
    antes = time.time()
    asyncio.run(bot.turno(SimpleNamespace(), SimpleNamespace(id=CHAT), THREAD, KEY, "oi"))
    reaberto = Store(bot.store.path)                                                  # processo novo, le do disco
    assert float(reaberto.get(KEY).meta["escrita_bot"]) >= antes


async def _res():
    return claude_runner.Result(True, "feito", cost_usd=0.0)


def test_d_terminal_que_comeca_com_o_lock_tomado_segura_a_mensagem_na_fila(mundo, monkeypatch):
    adotar(mundo)
    monkeypatch.setattr(bot, "TERMINAL_POLL_S", 0.01)
    monkeypatch.setattr(bot, "send", lambda *a, **k: _nada())
    liberar, rodando = asyncio.Event(), []

    async def claude_falso(prompt, **kw):
        if prompt.startswith("[regra"):                                                # reforco do "Onde esta", nao e turno
            return claude_runner.Result(True, "ok", cost_usd=0.0)
        rodando.append(prompt)
        if len(rodando) == 1:
            await liberar.wait()
        return claude_runner.Result(True, "feito", cost_usd=0.0)
    monkeypatch.setattr(bot, "claude_run", claude_falso)

    async def cenario():
        a = asyncio.create_task(bot.turno(SimpleNamespace(), SimpleNamespace(id=CHAT), THREAD, KEY, "A"))
        await asyncio.sleep(0.1)                                                       # A segura o lock
        b = asyncio.create_task(bot.turno(SimpleNamespace(), SimpleNamespace(id=CHAT), THREAD, KEY, "B"))
        await asyncio.sleep(0.1)
        mundo.escrever(prompt(mundo.agora), tool(mundo.agora + timedelta(seconds=1)))  # terminal volta a rodar
        t = time.time() + 30
        os.utime(mundo.jsonl, (t, t))                                                  # depois da escrita do bot
        liberar.set()
        await asyncio.wait_for(a, 5)
        await asyncio.sleep(0.2)
        assert len(rodando) == 1 and not b.done()                                      # B espera o terminal, dentro do lock
        mundo.escrever(fim(mundo.agora + timedelta(seconds=5), "terminal acabou"))
        mundo.envelhecer(120)
        await asyncio.wait_for(b, 5)
    asyncio.run(cenario())
    assert len(rodando) == 2


def test_adotada_avisa_uma_vez_que_o_terminal_voltou_e_espelha_o_fim(mundo):
    adotar(mundo)
    mundo.posts.clear()
    mundo.tick()
    assert mundo.posts == []                                                          # nada novo: calado
    mundo.escrever(prompt(mundo.agora - timedelta(seconds=250)), tool(mundo.agora - timedelta(seconds=240)))   # tarefa em 2o plano reinvocou
    mundo.tick(); mundo.tick()
    assert mundo.posts == [bot.TERMINAL_VOLTOU]                                       # uma vez so
    mundo.escrever(fim(mundo.agora - timedelta(seconds=200), "rodei sozinho"))
    mundo.envelhecer(100)
    mundo.tick(); mundo.tick()
    assert len(mundo.posts) == 2 and mundo.posts[1].startswith("✅ terminou") and "rodei sozinho" in mundo.posts[1]


def test_adotada_ignora_a_escrita_do_proprio_bot(mundo, monkeypatch):
    adotar(mundo)
    mundo.posts.clear()
    mundo.escrever(prompt(mundo.agora), fim(mundo.agora, "resposta do bot"))
    bot.store.set_meta(KEY, escrita_bot=time.time())                                  # o turno do bot acabou de gravar
    mundo.tick()
    assert mundo.posts == []


def test_adocao_que_falha_no_meio_tenta_de_novo_no_proximo_tick(mundo):
    mundo.escrever(prompt(mundo.agora - timedelta(minutes=10)), fim(mundo.agora - timedelta(minutes=5)))
    mundo.envelhecer(300)
    chamadas = []

    async def postar(app, rec, texto):
        chamadas.append(texto)
        if texto.startswith("📱 a sessão"):
            raise RuntimeError("telegram caiu")
        mundo.posts.append(texto)
    bot._vigia_postar = postar
    with pytest.raises(RuntimeError):
        mundo.tick()
    assert vigia.ler()[SID]["modo"] == "celular"                                      # a flag so vira no ultimo passo
    chamadas.clear()
    chamadas_ok = []

    async def postar_ok(app, rec, texto):
        chamadas_ok.append(texto)
    bot._vigia_postar = postar_ok
    mundo.tick()
    assert vigia.ler()[SID]["modo"] == "adotada" and bot.store.get(KEY).meta["celular"] == SID
    assert len(chamadas_ok) == 1 and chamadas_ok[0].startswith("📱 a sessão")            # "terminou" nao repete


def test_adocao_com_cwd_ausente_nao_adota_e_avisa(mundo):
    mundo.escrever(prompt(mundo.agora - timedelta(minutes=10)), fim(mundo.agora - timedelta(minutes=5)))
    mundo.envelhecer(300)
    vigia.atualizar(SID, cwd=str(mundo.cwd / "nao-existe"))
    mundo.tick()
    assert any("cwd ausente neste host" in p for p in mundo.posts)
    assert "celular" not in bot.store.get(KEY).meta and bot.store.get(KEY).meta.get("espelho") == SID
    assert vigia.ler()[SID]["modo"] is None


# ---- guard: marca sincrona ----


# ---- vigia-pedido: falso positivo (meta) x pedido de verdade ----


