import asyncio

from wisp_bot import bot as _bot


def test_pedido_igual_em_10_min_nao_posta_de_novo(tmp_path, monkeypatch):
    f = tmp_path / "a.txt"
    f.write_text("x")
    postados = []

    async def postar(bot, chat, tid, itens, legenda):
        postados.append((tid, [str(p) for p, _ in itens], legenda))

    monkeypatch.setattr(_bot, "_key_da_thread", lambda t: "1:5")
    monkeypatch.setattr(_bot, "_thread_de", lambda k: 5)
    monkeypatch.setattr(_bot, "_postar_arquivos", postar)
    monkeypatch.setattr(_bot, "_enviados_recentes", {})
    op = {"thread": 5, "arquivos": [str(f)], "legenda": "oi"}
    assert asyncio.run(_bot._ctl_enviar(None, op))["enviados"] == 1
    assert asyncio.run(_bot._ctl_enviar(None, dict(op))) == {"ok": True, "enviados": 0, "repetido": True}
    assert len(postados) == 1
    assert asyncio.run(_bot._ctl_enviar(None, {**op, "legenda": "outra"}))["enviados"] == 1
    assert len(postados) == 2


def test_depois_da_janela_ou_de_uma_falha_pode_reenviar(tmp_path, monkeypatch):
    f = tmp_path / "a.txt"
    f.write_text("x")
    estado = {"falha": True, "n": 0}

    async def postar(*a):
        estado["n"] += 1
        if estado["falha"]:
            raise RuntimeError("rede")

    monkeypatch.setattr(_bot, "_key_da_thread", lambda t: "1:5")
    monkeypatch.setattr(_bot, "_thread_de", lambda k: 5)
    monkeypatch.setattr(_bot, "_postar_arquivos", postar)
    monkeypatch.setattr(_bot, "_enviados_recentes", {})
    op = {"thread": 5, "arquivos": [str(f)]}
    try:
        asyncio.run(_bot._ctl_enviar(None, op))
    except RuntimeError:
        pass
    estado["falha"] = False
    assert asyncio.run(_bot._ctl_enviar(None, op))["enviados"] == 1
    monkeypatch.setattr(_bot.time, "monotonic", lambda: 10**9)
    assert asyncio.run(_bot._ctl_enviar(None, op))["enviados"] == 1
    assert estado["n"] == 3
