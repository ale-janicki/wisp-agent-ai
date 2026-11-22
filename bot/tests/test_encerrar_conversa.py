import asyncio
import json
import types

from wisp_bot import bot as _bot, conversa, store, topicos

CONV = "11111111-2222-4333-8444-555555555555"
OUTRA = "66666666-2222-4333-8444-555555555555"
SID = "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb"


def _indice(tmp_path, extra=None):
    path = tmp_path / "conversations.json"
    registros = [
        {"id": CONV.upper(), "sessionId": SID, "title": "topico-um", "updatedAt": "2026-01-01T00:00:00.000Z"},
        {"id": OUTRA.upper(), "sessionId": None, "title": "local", "updatedAt": "2026-01-01T00:00:00.000Z"},
    ] + (extra or [])
    path.write_text(json.dumps(registros))
    return path


def _ler(path):
    return {r["id"].lower(): r for r in json.loads(path.read_text())}


def test_encerrar_conversa_marca_so_a_do_topico(tmp_path):
    indice = _indice(tmp_path)
    assert conversa.encerrar_conversa(indice, CONV, SID, "telegram", quando=1_700_000_000)
    dados = _ler(indice)
    assert dados[CONV]["closedAt"] == "2023-11-14T22:13:20Z" and dados[CONV]["closedFrom"] == "telegram"
    assert "closedAt" not in dados[OUTRA]
    assert dados[CONV]["title"] == "topico-um"


def test_encerrar_conversa_acha_pela_sessao_e_nao_remarca(tmp_path):
    indice = _indice(tmp_path)
    assert conversa.encerrar_conversa(indice, "", SID, "app", quando=1_700_000_000)
    assert not conversa.encerrar_conversa(indice, CONV, SID, "telegram")
    assert _ler(indice)[CONV]["closedFrom"] == "app"


def test_encerrar_conversa_indice_ausente_ou_quebrado(tmp_path):
    assert not conversa.encerrar_conversa(tmp_path / "nada.json", CONV, SID, "app")
    ruim = tmp_path / "ruim.json"
    ruim.write_text("{")
    assert not conversa.encerrar_conversa(ruim, CONV, SID, "app")
    assert ruim.read_text() == "{"


def _cenario(monkeypatch, tmp_path, origem=None):
    indice = _indice(tmp_path)
    transcritos = tmp_path / "conversas"
    transcritos.mkdir()
    jsonl = transcritos / f"{CONV}.jsonl"
    jsonl.write_text('{"kind":"user","text":"oi"}\n')
    st = store.Store(tmp_path / "topics.json")
    key = "-1001:7"
    topic = st.get_or_create(key, name="topico-um", cwd=str(tmp_path))
    st.set_conversation(key, CONV)
    monkeypatch.setattr(_bot, "store", st)
    monkeypatch.setattr(_bot, "_CFG", types.SimpleNamespace(conversations_file=indice))
    monkeypatch.setattr(_bot.topicos, "set_status", lambda *a, **k: None)
    monkeypatch.setattr(_bot.topicos, "push_logo", lambda *a, **k: None)
    monkeypatch.setattr(_bot.vigilia, "soltar", lambda *a, **k: None)

    async def apagar(*a, **k):
        return "apagado"

    async def send(*a, **k):
        return None
    monkeypatch.setattr(_bot, "_apagar_topico", apagar)
    monkeypatch.setattr(_bot, "send", send)
    monkeypatch.setattr(_bot, "topico_local", lambda k: st.get(k))
    return indice, jsonl, key, topic


def test_fechar_do_telegram_marca_e_mantem_o_transcript(monkeypatch, tmp_path):
    indice, jsonl, key, _ = _cenario(monkeypatch, tmp_path)
    asyncio.run(_bot.fechar(None, -1001, 7, key))
    dados = _ler(indice)[CONV]
    assert dados["closedFrom"] == "telegram" and dados["closedAt"]
    assert jsonl.read_text() == '{"kind":"user","text":"oi"}\n'


def test_ctl_encerrar_marca_como_app(monkeypatch, tmp_path):
    indice, jsonl, key, _ = _cenario(monkeypatch, tmp_path)
    asyncio.run(_bot._ctl_encerrar(None, "7"))
    assert _ler(indice)[CONV]["closedFrom"] == "app"
    assert jsonl.exists()


def test_resumo_falho_nao_marca(monkeypatch, tmp_path):
    indice, jsonl, key, topic = _cenario(monkeypatch, tmp_path)
    store.Store.mark_started(_bot.store, key)
    _bot.store.get(key).turns = 1

    async def falha(*a, **k):
        return types.SimpleNamespace(ok=False, text="x", cost_usd=0)
    monkeypatch.setattr(_bot, "claude_run", falha)
    monkeypatch.setattr(_bot.transcripts, "last_engine", lambda s: None)
    monkeypatch.setattr(_bot, "regra_para", lambda *a: "")
    monkeypatch.setattr(_bot, "pedir_permissao", lambda *a: None)
    asyncio.run(_bot.fechar(None, -1001, 7, key))
    assert "closedAt" not in _ler(indice)[CONV]
    assert _bot.store.get(key) is not None


def test_marcar_antigas_so_sessao_de_topico_encerrado_e_nao_viva(tmp_path):
    indice = _indice(tmp_path)
    encerradas = [{"session_id": SID, "session_last": "1700000000"}, {"session_id": "", "session_last": "0"}]
    assert conversa.marcar_antigas(indice, {SID}, encerradas) == 0
    assert conversa.marcar_antigas(indice, set(), encerradas) == 1
    dados = _ler(indice)
    assert dados[CONV]["closedAt"] == "2023-11-14T22:13:20Z" and "closedAt" not in dados[OUTRA]
    assert conversa.marcar_antigas(indice, set(), encerradas) == 0


def test_encerrados_le_so_notas_encerradas(monkeypatch, tmp_path):
    monkeypatch.setattr(topicos, "DIR", tmp_path)
    (tmp_path / "topico-7-a.md").write_text('---\ntopic_key: "-1001:7"\nstatus: encerrado\n---\n')
    (tmp_path / "topico-8-b.md").write_text('---\ntopic_key: "-1001:8"\nstatus: active\n---\n')
    (tmp_path / "sessoes-mac.json").write_text(json.dumps({"-1001:7": {"session_id": SID, "session_last": 5}}))
    achadas = topicos.encerrados()
    assert [a["topic_key"] for a in achadas] == ["-1001:7"] and achadas[0]["session_id"] == SID
