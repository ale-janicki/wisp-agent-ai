"""Watchdog do getUpdates, log de erro de polling e decisao de dono da leitura (relogio injetado, sem rede)."""
import asyncio
import json
import logging
import threading

import httpx
import pytest
from telegram.error import Conflict, NetworkError

from wisp_bot import hosting, polling


class Relogio:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def test_watchdog_vence_sem_getupdates_concluido():
    r = Relogio()
    wd = polling.PollingWatchdog(limite_s=300, relogio=r)
    r.t += 299
    assert not wd.vencido(True)
    r.t += 2
    assert wd.vencido(True)


def test_watchdog_getupdates_concluido_zera_a_contagem():
    r = Relogio()
    wd = polling.PollingWatchdog(limite_s=300, relogio=r)
    r.t += 250
    wd.ok()
    r.t += 250
    assert not wd.vencido(True)


def test_watchdog_standby_nunca_vence_e_conta_so_apos_ativar():
    r = Relogio()
    wd = polling.PollingWatchdog(limite_s=300, relogio=r)
    r.t += 5000
    assert not wd.vencido(False)
    r.t += 10
    assert not wd.vencido(True)
    r.t += 301
    assert wd.vencido(True)


def test_vigiar_sai_com_codigo_nao_zero_quando_vence(caplog):
    r = Relogio()
    wd = polling.PollingWatchdog(limite_s=300, relogio=r)
    r.t += 301
    saiu = threading.Event()
    codigos = []

    def sair(c):
        codigos.append(c)
        saiu.set()

    with caplog.at_level(logging.CRITICAL, logger="wisp.polling"):
        polling.vigiar(lambda: True, wd=wd, sair=sair, intervalo_s=0.01)
        assert saiu.wait(2)
    assert codigos == [polling.WATCHDOG_EXIT] and polling.WATCHDOG_EXIT != 0
    assert any("WATCHDOG" in m for m in caplog.messages)


def test_timeout_de_leitura_maior_que_long_poll_e_finito():
    assert polling.POLL_READ_TIMEOUT_S > 0
    bot = polling.criar_bot("123:abc")
    assert bot._request[0].read_timeout == polling.POLL_READ_TIMEOUT_S
    assert bot._request[0].read_timeout + polling.POLL_TIMEOUT_S > polling.POLL_TIMEOUT_S


def test_erro_de_dns_vira_uma_linha_por_janela(caplog):
    r = Relogio()
    conflitos = []
    cb = polling.ErroPolling(lambda: conflitos.append(1), relogio=r)
    dns = NetworkError("httpx.ConnectError: [Errno 8] nodename nor servname provided")
    with caplog.at_level(logging.INFO, logger="wisp.polling"):
        for _ in range(50):
            cb(dns)
            r.t += 5
        assert len(caplog.records) == 1
        r.t += polling.REDE_LOG_S
        cb(dns)
    assert len(caplog.records) == 2 and "suprimidos" in caplog.records[1].getMessage()
    assert not conflitos


def test_erro_que_nao_e_rede_mantem_traceback(caplog):
    cb = polling.ErroPolling(lambda: None)
    with caplog.at_level(logging.INFO, logger="wisp.polling"):
        cb(ValueError("outra coisa"))
    assert caplog.records[0].levelno == logging.ERROR and caplog.records[0].exc_info


def test_conflict_chama_o_dono_da_decisao():
    chamadas = []
    polling.ErroPolling(lambda: chamadas.append(1))(Conflict("terminated by other getUpdates request"))
    assert chamadas == [1]


NOW = 1_800_000_000


def _saida(estado, ts):
    return json.dumps({"host": "pc", "state": estado, "ts": ts}) + f"\n{NOW}\n"


def test_estado_do_pc_leituras_validas():
    assert hosting.interpretar_estado_pc(0, _saida("active", NOW - 3)) == "active"
    assert hosting.interpretar_estado_pc(0, _saida("grace", NOW - 3)) == "grace"
    assert hosting.interpretar_estado_pc(0, _saida("standby", NOW - 3)) == "down"
    assert hosting.interpretar_estado_pc(0, _saida("active", NOW - 31)) == "down"
    assert hosting.interpretar_estado_pc(0, f"\n{NOW}\n") == "down"
    assert hosting.interpretar_estado_pc(hosting.RC_PC_WINDOWS, "") == "down"


@pytest.mark.parametrize("rc,out", [
    (255, ""), (124, ""), (2, ""), (1, _saida("active", NOW)),
    (0, ""), (0, "{quebrado\n" + str(NOW)), (0, "[1]\n" + str(NOW)), (0, _saida("active", NOW).replace(str(NOW) + "\n", "x\n")),
])
def test_estado_do_pc_ilegivel_e_none(rc, out):
    assert hosting.interpretar_estado_pc(rc, out) is None


def test_decidir_mac_ilegivel_nunca_ativa_e_zera_faltas():
    assert hosting.decidir_mac(None, 0, False) == ("manter", 0)
    assert hosting.decidir_mac(None, hosting.MISSES - 1, False) == ("manter", 0)
    assert hosting.decidir_mac(None, 99, False) == ("manter", 0)


def test_decidir_mac_pc_fora_ativa_so_apos_misses_leituras_validas():
    f, acao = 0, None
    for i in range(hosting.MISSES):
        acao, f = hosting.decidir_mac("down", f, False)
        assert acao == ("ativar" if i == hosting.MISSES - 1 else "manter")
    acao, f = hosting.decidir_mac("down", hosting.MISSES - 1, False)
    acao2, f2 = hosting.decidir_mac(None, f, False)
    assert acao == "ativar" and (acao2, f2) == ("manter", 0)


def test_decidir_mac_tailscale_offline_ativa_na_hora_e_pc_vivo_cede():
    assert hosting.decidir_mac("offline", 0, False)[0] == "ativar"
    assert hosting.decidir_mac("active", 5, True) == ("ceder", 0)
    assert hosting.decidir_mac("grace", 5, False) == ("ceder", 0)


def test_decidir_mac_bloqueio_apos_409_impede_ativar():
    assert hosting.decidir_mac("offline", 0, False, bloqueado=True)[0] == "manter"
    assert hosting.decidir_mac("down", 9, False, bloqueado=True)[0] == "manter"


def test_loop_do_mac_com_estado_ilegivel_nao_le(monkeypatch):
    monkeypatch.setattr(hosting, "HOST", "mac")
    monkeypatch.setattr(hosting, "gravar_estado", lambda e, extra=None: None)
    monkeypatch.setattr(hosting, "estado_do_pc", lambda mac=None, **_: _async(None))
    voltas = []

    async def dorme(_):
        voltas.append(1)
        if len(voltas) >= hosting.MISSES * 4:
            raise asyncio.CancelledError

    monkeypatch.setattr(hosting.asyncio, "sleep", dorme)
    ativacoes = []

    class App:
        class updater:
            @staticmethod
            async def start_polling(**kw):
                ativacoes.append(kw)

    h = hosting.Hosting(App, None, None)
    with pytest.raises(asyncio.CancelledError):
        asyncio.run(h._rodar_mac())
    assert ativacoes == [] and not h.ativo


def test_409_no_mac_solta_a_leitura_e_bloqueia(monkeypatch):
    monkeypatch.setattr(hosting, "HOST", "mac")
    monkeypatch.setattr(hosting, "gravar_estado", lambda e, extra=None: None)
    parou = []

    class App:
        class updater:
            @staticmethod
            async def stop():
                parou.append(1)

    async def cenario():
        async def on(_):
            pass
        h = hosting.Hosting(App, on, on)
        h.estado = "active"
        h.conflito()
        await h._cessao
        return h

    h = asyncio.run(cenario())
    assert parou == [1] and not h.ativo and h.bloqueado_ate > 0


async def _async(v):
    return v


def test_getupdates_com_409_alimenta_o_watchdog_e_falha_de_rede_nao(monkeypatch):
    r = Relogio()
    monkeypatch.setattr(polling, "WATCHDOG", polling.PollingWatchdog(limite_s=300, relogio=r))
    bot = polling.criar_bot("123:abc")

    def falha(exc):
        async def _g(self, *a, **k):
            raise exc
        return _g

    async def chama():
        try:
            await bot.get_updates()
        except Exception:
            pass

    from telegram.ext import ExtBot
    monkeypatch.setattr(ExtBot, "get_updates", falha(NetworkError("dns")))
    r.t += 200
    asyncio.run(chama())
    assert polling.WATCHDOG.parado_ha() == 200
    monkeypatch.setattr(ExtBot, "get_updates", falha(Conflict("other getUpdates")))
    asyncio.run(chama())
    assert polling.WATCHDOG.parado_ha() == 0

    async def propaga():
        with pytest.raises(Conflict):
            await bot.get_updates()
    asyncio.run(propaga())


def _hosting_com_alerta():
    chamadas = []

    async def alerta(*args):
        chamadas.append(args)
        return True
    return hosting.Hosting(object(), None, None, alerta=alerta), chamadas


def test_alerta_red_so_apos_10_min_ilegivel_e_uma_vez_e_resolve_ao_voltar():
    async def cenario():
        h, chamadas = _hosting_com_alerta()
        h._avisar_ilegivel(None, 0.0)
        h._avisar_ilegivel(None, hosting.ALERTA_ILEGIVEL_S - 1)
        await asyncio.sleep(0)
        assert chamadas == []
        h._avisar_ilegivel(None, hosting.ALERTA_ILEGIVEL_S + 1)
        h._avisar_ilegivel(None, hosting.ALERTA_ILEGIVEL_S + 60)
        await asyncio.sleep(0)
        assert len(chamadas) == 1
        a = chamadas[0]
        assert a[:7] == ("add", "--nivel", "red", "--chave", "bot-ninguem-lendo", "--frente", "bot")
        h._avisar_ilegivel("down", hosting.ALERTA_ILEGIVEL_S + 90)
        await asyncio.sleep(0)
        assert chamadas[1] == ("resolve", "bot-ninguem-lendo") and len(chamadas) == 2
        h._avisar_ilegivel("down", hosting.ALERTA_ILEGIVEL_S + 120)
        await asyncio.sleep(0)
        assert len(chamadas) == 2
    asyncio.run(cenario())


def test_leitura_valida_no_meio_zera_a_contagem_do_alerta():
    async def cenario():
        h, chamadas = _hosting_com_alerta()
        h._avisar_ilegivel(None, 0.0)
        h._avisar_ilegivel("down", 400.0)
        h._avisar_ilegivel(None, 500.0)
        h._avisar_ilegivel(None, 500.0 + hosting.ALERTA_ILEGIVEL_S - 1)
        await asyncio.sleep(0)
        assert chamadas == []
    asyncio.run(cenario())


def test_cessao_por_409_que_falha_e_logada(monkeypatch, caplog):
    monkeypatch.setattr(hosting, "HOST", "mac")
    monkeypatch.setattr(hosting, "gravar_estado", lambda e, extra=None: None)

    class App:
        class updater:
            @staticmethod
            async def stop():
                raise RuntimeError("stop quebrou")

    async def cenario():
        async def on(_):
            pass
        h = hosting.Hosting(App, on, on)
        h.estado = "active"
        h.conflito()
        try:
            await h._cessao
        except RuntimeError:
            pass
        await asyncio.sleep(0)

    with caplog.at_level(logging.ERROR, logger="wisp.hosting"):
        asyncio.run(cenario())
    assert any("cessao por 409 falhou" in m and "stop quebrou" in m for m in caplog.messages)


@pytest.mark.parametrize("sistema,esperado", [("Linux", "pc"), ("Darwin", "mac")])
def test_detectar_host_por_sistema(monkeypatch, sistema, esperado):
    monkeypatch.delenv("WISP_HOST", raising=False)
    monkeypatch.setattr(hosting.platform, "system", lambda: sistema)
    assert hosting.detectar_host() == esperado


def test_detectar_host_env_vence(monkeypatch):
    monkeypatch.setenv("WISP_HOST", "mac")
    monkeypatch.setattr(hosting.platform, "system", lambda: "Linux")
    assert hosting.detectar_host() == "mac"


@pytest.mark.parametrize("rc_linux,windows_no_ar,esperado", [
    (255, True, "down"),      # PC no Windows: sem bot, o Mac assume
    (255, False, None),       # os dois mudos: ilegivel, nunca ativa
    (124, False, None),
])
def test_estado_do_pc_windows_no_ar(monkeypatch, rc_linux, windows_no_ar, esperado):
    async def off(): return False
    async def ssh(script): return rc_linux, ""
    async def win(): return windows_no_ar
    monkeypatch.setattr(hosting, "_pc_offline_no_tailscale", off)
    monkeypatch.setattr(hosting, "_pc_ssh", ssh)
    monkeypatch.setattr(hosting, "_pc_windows_no_ar", win)
    assert asyncio.run(hosting.estado_do_pc()) == esperado


def test_estado_do_pc_linux_ok_nao_sonda_windows(monkeypatch):
    async def off(): return False
    async def ssh(script): return 0, _saida("active", NOW - 2)
    async def win(): raise AssertionError("nao deveria sondar o Windows")
    monkeypatch.setattr(hosting, "_pc_offline_no_tailscale", off)
    monkeypatch.setattr(hosting, "_pc_ssh", ssh)
    monkeypatch.setattr(hosting, "_pc_windows_no_ar", win)
    assert asyncio.run(hosting.estado_do_pc()) == "active"


def _ts(online, estado="Running", nome="pc-node"):
    return json.dumps({"BackendState": estado, "Peer": {
        "a": {"HostName": "DESKTOP-X", "Online": True},
        "b": {"HostName": nome, "Online": online}}})


def test_node_offline_no_status():
    assert hosting.node_offline_no_status(_ts(False), "pc-node") is True
    assert hosting.node_offline_no_status(_ts(True), "pc-node") is False
    assert hosting.node_offline_no_status(_ts(False, nome="outro"), "pc-node") is False   # node ausente
    assert hosting.node_offline_no_status(_ts(False, estado="Stopped"), "pc-node") is False  # Mac sem Tailscale
    assert hosting.node_offline_no_status("{quebrado", "pc-node") is False


def test_estado_do_pc_node_offline_vira_offline_sem_ssh(monkeypatch):
    async def sh(*cmd, **kw): return 0, _ts(False)
    async def ssh(script): raise AssertionError("nao deveria tocar o ssh")
    monkeypatch.setattr(hosting, "_sh", sh)
    monkeypatch.setattr(hosting, "_pc_ssh", ssh)
    monkeypatch.setattr(hosting, "_pc_cfg", lambda: {})        # PC_HOST vazio
    monkeypatch.setattr(hosting.os.path, "exists", lambda p: True)
    assert asyncio.run(hosting.estado_do_pc()) == "offline"
    assert hosting.decidir_mac("offline", 0, False) == ("ativar", 1)
