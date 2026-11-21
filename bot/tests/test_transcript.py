import asyncio
import json
import multiprocessing
import os
import stat
from pathlib import Path

import pytest

from wisp_bot import bot, claude_runner, config, transcript
from wisp_bot.claude_runner import Result
from wisp_bot.store import Store
from wisp_bot.transcript import Transcripts

CONTRACT = Path(__file__).parents[2] / "cli/tests/fixtures/contract"
SESSION = "11111111-1111-4111-8111-111111111111"
REBUILT = "22222222-2222-4222-8222-222222222222"


def _fixture_lines() -> list[str]:
    return [l for l in (CONTRACT / "conversation-transcript.jsonl").read_text("utf-8").split("\n") if l]


def test_cada_linha_do_fixture_e_a_codificacao_canonica():
    for line in _fixture_lines():
        assert transcript.encode(json.loads(line)) == line


def test_o_escritor_produz_o_fixture_byte_a_byte(tmp_path, monkeypatch):
    stamps = iter(["2026-11-20T12:00:01.000Z", "2026-11-20T12:00:09.250Z", "2026-11-20T12:05:00.000Z",
                   "2026-11-20T12:05:07.000Z", "2026-11-20T12:05:30.000Z", "2026-11-20T12:06:00.000Z"])
    monkeypatch.setattr(transcript, "stamp", lambda: next(stamps))
    store = Transcripts(tmp_path)
    store.user(SESSION, "Oi, tudo bem?\nQuero \"ajuda\" com o café e o link https://exemplo.com/a.", "app")
    store.assistant(SESSION, "Claro! Em que posso ajudar?", "app", "claude", "claude-opus-4-8")
    store.user(SESSION, "E agora pelo celular", "telegram")
    store.assistant(SESSION, "Continuamos aqui.", "telegram", "claude", "claude-opus-4-8")
    store.user(SESSION, "Separa\u2028linha\u0085e\u2029fim", "app")
    store.rebuilt(SESSION, REBUILT, "claude")
    assert [l for l in (tmp_path / f"{SESSION}.jsonl").read_text("utf-8").split("\n") if l] == _fixture_lines()


def test_separadores_unicode_nao_partem_nem_perdem_linhas(tmp_path):
    entries = transcript.read_entries(CONTRACT / "conversation-transcript.jsonl")
    assert len(entries) == len(_fixture_lines())
    assert "Separa\u2028linha\u0085e\u2029fim" in [e.get("text") for e in entries]


def test_pasta_das_conversas_e_privada_e_escrita_curta_completa(tmp_path, monkeypatch):
    pasta = tmp_path / "wisp" / "conversas"
    real = os.write
    monkeypatch.setattr(os, "write", lambda fd, data: real(fd, data[:7]))
    Transcripts(pasta).user(SESSION, "x" * 500, "app")
    assert stat.S_IMODE(pasta.stat().st_mode) == 0o700
    assert [e["text"] for e in transcript.read_entries(pasta / f"{SESSION}.jsonl") if e["kind"] == "user"] == ["x" * 500]


def test_so_mensagem_do_usuario_sem_resposta_nao_conta_como_historia():
    assert transcript.build_context([{"kind": "user", "text": "primeira"}]) is None


def test_o_contexto_reconstruido_e_o_do_fixture(tmp_path):
    copy = tmp_path / f"{SESSION}.jsonl"
    copy.write_text((CONTRACT / "conversation-transcript.jsonl").read_text("utf-8"), "utf-8")
    assert Transcripts(tmp_path).context(SESSION) == (CONTRACT / "conversation-context.txt").read_text("utf-8")


def test_contexto_corta_o_antigo_e_respeita_o_orcamento():
    entries = [{"kind": "user" if i % 2 == 0 else "assistant", "text": f"{i}" + "x" * 5000} for i in range(40)]
    out = transcript.build_context(entries)
    assert len(out) <= transcript.BUDGET_CHARS + 600
    blocks = out.split("\n\n")
    assert "older messages not shown" in blocks[1]
    newest = [b for b in blocks if b.startswith(("User: ", "Assistant: "))][-1]
    assert len(newest) == len("Assistant: ") + transcript.RECENT_CHARS + 1 and newest.endswith("…")
    oldest = [b for b in blocks if b.startswith(("User: ", "Assistant: "))][0]
    assert len(oldest) <= len("Assistant: ") + transcript.OLDER_CHARS + 1


def test_sem_mensagens_nao_ha_contexto():
    assert transcript.build_context([{"kind": "session", "session": "x"}]) is None
    assert transcript.build_context([]) is None


def test_a_sessao_religada_resolve_para_a_mesma_conversa(tmp_path):
    store = Transcripts(tmp_path)
    store.user(SESSION, "oi", "app")
    store.rebuilt(SESSION, REBUILT, "claude")
    assert Transcripts(tmp_path).find(REBUILT) == SESSION
    assert Transcripts(tmp_path).find("33333333-3333-4333-8333-333333333333") is None
    store.user(REBUILT, "segue", "telegram")
    assert [e["text"] for e in store.entries(SESSION) if e["kind"] == "user"] == ["oi", "segue"]
    assert not (tmp_path / f"{REBUILT}.jsonl").exists()


def test_conversa_do_app_com_id_proprio_e_achada_pela_sessao(tmp_path):
    app = "7f4c2b1e-0000-4000-8000-000000000001"
    (tmp_path / f"{app}.jsonl").write_text(transcript.encode(
        {"v": 1, "at": "2026-11-20T12:00:00.000Z", "kind": "session", "session": SESSION, "engine": "claude"}) + "\n")
    store = Transcripts(tmp_path)
    store.user(SESSION, "do celular", "telegram")
    assert store.find(SESSION) == app
    assert not (tmp_path / f"{SESSION}.jsonl").exists()


def _escrever(args):
    folder, n = args
    store = Transcripts(Path(folder))
    for i in range(25):
        store.user(SESSION, f"{n}-{i}-" + "y" * 20000, "telegram")


def test_dois_processos_escrevendo_nunca_misturam_uma_linha(tmp_path):
    ctx = multiprocessing.get_context("fork")
    with ctx.Pool(4) as pool:
        pool.map(_escrever, [(str(tmp_path), n) for n in range(4)])
    raw = (tmp_path / f"{SESSION}.jsonl").read_text("utf-8").splitlines()
    parsed = [json.loads(line) for line in raw]
    assert len([p for p in parsed if p["kind"] == "user"]) == 100
    assert sum(1 for p in parsed if p["kind"] == "session") >= 1


def test_linha_quebrada_no_fim_nao_come_a_proxima(tmp_path):
    path = tmp_path / f"{SESSION}.jsonl"
    path.write_text('{"kind":"user","text":"corta')
    Transcripts(tmp_path).user(SESSION, "inteira", "app")
    entries = transcript.read_entries(path)
    assert [e["text"] for e in entries if e["kind"] == "user"] == ["inteira"]


def test_segredos_e_nada_alem_do_texto_vao_para_o_arquivo(tmp_path):
    store = Transcripts(tmp_path, secrets=["123:TOKEN"])
    store.user(SESSION, "meu token 123:TOKEN", "telegram")
    raw = (tmp_path / f"{SESSION}.jsonl").read_text("utf-8")
    assert "123:TOKEN" not in raw and "[redacted]" in raw
    assert stat.S_IMODE(os.stat(tmp_path / f"{SESSION}.jsonl").st_mode) == 0o600


def test_falha_de_escrita_e_aviso_uma_vez_so(tmp_path):
    blocker = tmp_path / "conversas"
    blocker.write_text("arquivo no lugar da pasta")
    store = Transcripts(blocker)
    store.user(SESSION, "a", "app")
    store.user(SESSION, "b", "app")
    assert "não consegui guardar a conversa" in store.take_notice()
    assert store.take_notice() is None
    store.user(SESSION, "c", "app")
    assert store.take_notice() is None


def test_a_pasta_vem_do_wisp_json(tmp_path):
    env = {"HOME": str(tmp_path)}
    assert config._build({"wisp_dir": "~/Meu Wisp"}, env, strict=False).wisp_dir == tmp_path / "Meu Wisp"
    assert config._build({}, env, strict=False).wisp_dir == tmp_path / "Wisp"


def _claude_falso(tmp_path, script: str) -> str:
    fake = tmp_path / "claude"
    fake.write_text("#!/bin/sh\n" + script)
    fake.chmod(0o755)
    return str(fake)


def test_resume_que_falha_e_marcado_para_reconstruir(tmp_path, monkeypatch):
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", _claude_falso(
        tmp_path, "echo 'No conversation found with session ID: x' >&2\n"
                  "echo '{\"type\":\"result\",\"is_error\":true,\"errors\":[\"No conversation found with session ID: x\"]}'\n"
                  "exit 1\n"))
    monkeypatch.setattr(claude_runner, "guard_settings_path", lambda: tmp_path / "g.json")
    monkeypatch.setattr(claude_runner, "WISP_BIN", str(tmp_path / "claude"))
    res = asyncio.run(claude_runner.run("oi", session_id=SESSION, cwd=str(tmp_path), started=True, timeout=20))
    assert res.resume_failed and not res.ok


def test_o_modelo_que_o_claude_reporta_vai_no_resultado(tmp_path, monkeypatch):
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", _claude_falso(
        tmp_path, "echo '{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"claude-opus-4-8\"}'\n"
                  "echo '{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"s\"}'\n"))
    monkeypatch.setattr(claude_runner, "guard_settings_path", lambda: tmp_path / "g.json")
    monkeypatch.setattr(claude_runner, "WISP_BIN", str(tmp_path / "claude"))
    res = asyncio.run(claude_runner.run("oi", session_id=SESSION, cwd=str(tmp_path), started=False, timeout=20))
    assert res.ok and res.model == "claude-opus-4-8"


class _Roteiro:
    def __init__(self, *resultados):
        self.resultados = list(resultados)
        self.chamadas = []

    async def __call__(self, prompt, **kw):
        self.chamadas.append((prompt, kw["session_id"], kw["started"]))
        return self.resultados.pop(0)


async def _sem_relock(sid):
    raise AssertionError("sem troca de sessao nao ha relock")


def _store(tmp_path):
    store = Store(tmp_path / "topics.json")
    store.get_or_create("1:7", "t", str(tmp_path))
    store.mark_started("1:7")
    return store, store.get("1:7")


def test_resume_perdido_recomeca_sessao_nova_com_a_memoria_do_wisp(tmp_path, monkeypatch):
    store, topic = _store(tmp_path)
    log = Transcripts(tmp_path / "conversas")
    log.user(topic.session_id, "qual a capital da França?", "app")
    log.assistant(topic.session_id, "Paris.", "app", "claude", "claude-opus-4-8")
    roteiro = _Roteiro(Result(False, "x", resume_failed=True), Result(True, "E a da Itália é Roma.", model="m"))
    monkeypatch.setattr(bot, "claude_run", roteiro)
    monkeypatch.setattr(bot, "transcripts", log)
    monkeypatch.setattr(bot, "store", store)
    avisos = []

    async def avisar():
        avisos.append(1)
    movidos = []

    async def relock(sid):
        movidos.append(sid)
    antiga = topic.session_id
    res, novo = asyncio.run(bot.claude_com_memoria("1:7", topic, "e a da Itália?", "e a da Itália?", True, avisar, relock))
    assert movidos == [novo.session_id]
    assert res.ok and len(avisos) == 1
    assert novo.session_id != antiga and not store.get("1:7").started and store.get("1:7").session_id == novo.session_id
    (_, sid1, started1), (prompt2, sid2, started2) = roteiro.chamadas
    assert (sid1, started1) == (antiga, True) and (sid2, started2) == (novo.session_id, False)
    assert "User: qual a capital da França?" in prompt2 and "Assistant: Paris." in prompt2
    assert "e a da Itália?" not in prompt2.split("[end of Wisp conversation memory]")[0]
    assert prompt2.endswith("e a da Itália?")
    assert Transcripts(tmp_path / "conversas").find(novo.session_id) == antiga


def test_sessao_ausente_sem_resume_tambem_comeca_com_a_memoria(tmp_path, monkeypatch):
    store, topic = _store(tmp_path)
    log = Transcripts(tmp_path / "conversas")
    log.user(topic.session_id, "lembra de mim", "app")
    log.assistant(topic.session_id, "lembro", "app", "claude", "m")
    roteiro = _Roteiro(Result(True, "lembro", model="m"))
    monkeypatch.setattr(bot, "claude_run", roteiro)
    monkeypatch.setattr(bot, "transcripts", log)
    monkeypatch.setattr(bot, "store", store)
    avisos = []

    async def avisar():
        avisos.append(1)
    asyncio.run(bot.claude_com_memoria("1:7", topic, "oi", "oi", False, avisar, _sem_relock))
    prompt, sid, started = roteiro.chamadas[0]
    assert "User: lembra de mim" in prompt and not started and avisos == [1]


def test_conversa_antiga_sem_transcript_segue_como_hoje(tmp_path, monkeypatch):
    store, topic = _store(tmp_path)
    roteiro = _Roteiro(Result(True, "ok", model="m"))
    monkeypatch.setattr(bot, "claude_run", roteiro)
    monkeypatch.setattr(bot, "transcripts", Transcripts(tmp_path / "conversas"))
    monkeypatch.setattr(bot, "store", store)

    async def avisar():
        raise AssertionError("sem historico nao ha nota")
    asyncio.run(bot.claude_com_memoria("1:7", topic, "oi", "oi", True, avisar, _sem_relock))
    assert roteiro.chamadas == [("oi", topic.session_id, True)]


def test_resume_perdido_sem_historico_mostra_o_erro_e_nao_troca_a_sessao(tmp_path, monkeypatch):
    store, topic = _store(tmp_path)
    roteiro = _Roteiro(Result(False, "x", resume_failed=True))
    monkeypatch.setattr(bot, "claude_run", roteiro)
    monkeypatch.setattr(bot, "transcripts", Transcripts(tmp_path / "conversas"))
    monkeypatch.setattr(bot, "store", store)

    async def avisar():
        raise AssertionError("sem historico nao ha nota")
    res, same = asyncio.run(bot.claude_com_memoria("1:7", topic, "oi", "oi", True, avisar, _sem_relock))
    assert not res.ok and "não há conversa guardada" in res.text and same.session_id == topic.session_id


def test_primeiro_turno_que_falhou_nao_vira_sessao_perdida(tmp_path, monkeypatch):
    store, topic = _store(tmp_path)
    log = Transcripts(tmp_path / "conversas")
    log.user(topic.session_id, "primeira, sem resposta", "telegram")
    roteiro = _Roteiro(Result(True, "ok", model="m"))
    monkeypatch.setattr(bot, "claude_run", roteiro)
    monkeypatch.setattr(bot, "transcripts", log)
    monkeypatch.setattr(bot, "store", store)

    async def avisar():
        raise AssertionError("nada se perdeu: sem nota")
    asyncio.run(bot.claude_com_memoria("1:7", topic, "de novo", "de novo", False, avisar, _sem_relock))
    assert roteiro.chamadas == [("de novo", topic.session_id, False)]


def test_topico_que_sumiu_na_reconstrucao_mostra_erro_sem_quebrar(tmp_path, monkeypatch):
    store, topic = _store(tmp_path)
    log = Transcripts(tmp_path / "conversas")
    log.user(topic.session_id, "a", "app")
    log.assistant(topic.session_id, "b", "app", "claude", "m")
    monkeypatch.setattr(bot, "claude_run", _Roteiro(Result(False, "x", resume_failed=True)))
    monkeypatch.setattr(bot, "transcripts", log)
    monkeypatch.setattr(store, "renovar_sessao", lambda key: None)
    monkeypatch.setattr(bot, "store", store)

    async def avisar():
        raise AssertionError("sem sessao nova nao ha nota")
    res, same = asyncio.run(bot.claude_com_memoria("1:7", topic, "oi", "oi", True, avisar, _sem_relock))
    assert not res.ok and same is topic


def test_o_lock_muda_para_a_sessao_nova_sem_soltar_a_conversa(tmp_path):
    from wisp_bot import session_lock
    antiga, nova = "aaaaaaaa-1111", "bbbbbbbb-2222"

    async def corre():
        async with session_lock.guard(antiga, base=tmp_path) as held:
            await held.move(nova)
            assert session_lock.SessionLock(antiga, tmp_path).try_acquire()
            outro = session_lock.SessionLock(nova, tmp_path)
            assert not outro.try_acquire()
        livre = session_lock.SessionLock(nova, tmp_path)
        assert livre.try_acquire()
        livre.release()
    asyncio.run(corre())
