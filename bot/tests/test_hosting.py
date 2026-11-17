"""PC fora da LAN (Host is down) conta como leitura valida de 'down'; timeout/recusa seguem ilegiveis."""
import asyncio
import time
import types

import pytest

from wisp_bot import hosting


@pytest.mark.parametrize("err,esperado", [
    ("ssh: connect to host 192.168.0.71 port 22: Host is down", True),
    ("ssh: connect to host 192.168.0.71 port 22: No route to host", True),
    ("ssh: connect to host 192.168.0.71 port 22: Operation timed out", False),
    ("ssh: connect to host 192.168.0.71 port 22: Connection refused", False),
    ("Permission denied (publickey).", False),
    ("", False),
])
def test_ssh_host_inalcancavel(err, esperado):
    assert hosting.ssh_host_inalcancavel(err) is esperado


@pytest.mark.parametrize("rc_ssh,windows,esperado", [
    (hosting.RC_LAN_INALCANCAVEL, False, "down"),   # host down + Windows mudo
    (124, False, None),                             # timeout + Windows mudo
    (255, False, None),                             # recusa/auth
    (hosting.RC_LAN_INALCANCAVEL, True, "down"),    # Windows responde: caminho RC_PC_WINDOWS
])
def test_estado_do_pc_lan(monkeypatch, rc_ssh, windows, esperado):
    monkeypatch.setattr(hosting, "mac_na_lan_do_pc", lambda: True)
    async def off(): return False
    async def ssh(script): return rc_ssh, ""
    async def win(): return windows
    monkeypatch.setattr(hosting, "_pc_offline_no_tailscale", off)
    monkeypatch.setattr(hosting, "_pc_ssh", ssh)
    monkeypatch.setattr(hosting, "_pc_windows_no_ar", win)
    assert asyncio.run(hosting.estado_do_pc()) == esperado


@pytest.mark.parametrize("err,rc_esperado", [
    ("ssh: connect to host x port 22: Host is down", hosting.RC_LAN_INALCANCAVEL),
    ("ssh: connect to host x port 22: Operation timed out", 255),
])
def test_pc_ssh_traduz_stderr(monkeypatch, err, rc_esperado):
    async def sh_err(*cmd, **kw): return 255, "", err
    monkeypatch.setattr(hosting, "_sh_err", sh_err)
    monkeypatch.setattr(hosting, "pc_argv", lambda *a, **k: ["ssh"])
    assert asyncio.run(hosting._pc_ssh("true")) == (rc_esperado, "")


def test_lan_down_conta_falta_e_ativa_mac():
    f = 0
    for _ in range(hosting.MISSES):
        acao, f = hosting.decidir_mac("down", f, False)
    assert acao == "ativar"


def _fora_ou_dentro(monkeypatch, cfg, ip_local):
    async def off(): return False
    async def ssh(script): return hosting.RC_LAN_INALCANCAVEL, ""
    async def win(): return False
    monkeypatch.setattr(hosting, "_pc_offline_no_tailscale", off)
    monkeypatch.setattr(hosting, "_pc_ssh", ssh)
    monkeypatch.setattr(hosting, "_pc_windows_no_ar", win)
    monkeypatch.setattr(hosting, "_pc_cfg", lambda: cfg)
    monkeypatch.setattr(hosting, "_ip_local_para", lambda ip: ip_local)
    return asyncio.run(hosting.estado_do_pc())


def test_mesma_lan():
    assert hosting.mesma_lan("192.168.0.75", "192.168.0.71") is True
    assert hosting.mesma_lan("192.168.16.75", "192.168.0.71") is False
    assert hosting.mesma_lan("10.0.0.2", "192.168.0.71") is False
    assert hosting.mesma_lan(None, "192.168.0.71") is False
    assert hosting.mesma_lan("192.168.0.75", "pc.local") is False


def test_host_down_mac_fora_da_lan_e_ilegivel(monkeypatch):
    assert _fora_ou_dentro(monkeypatch, {"PC_LAN_IP": "192.168.0.71"}, "10.1.2.3") is None
    assert _fora_ou_dentro(monkeypatch, {"PC_LAN_IP": "192.168.0.71"}, None) is None


def test_host_down_mac_na_lan_e_down(monkeypatch):
    assert _fora_ou_dentro(monkeypatch, {"PC_LAN_IP": "192.168.0.71"}, "192.168.0.75") == "down"


def test_host_down_pc_host_hostname_e_ilegivel(monkeypatch):
    cfg = {"PC_HOST": "pc.local", "PC_LAN_IP": "192.168.0.71"}
    assert _fora_ou_dentro(monkeypatch, cfg, "192.168.0.75") is None


# ---- estado "off": o PC avisa que desligou de proposito ----

def _saida_estado(estado, ts, agora=1000):
    return f'{{"host": "pc", "state": "{estado}", "ts": {ts}}}\n\n{agora}\n'


def test_interpretar_off_fresco_e_velho_e_off():
    assert hosting.interpretar_estado_pc(0, _saida_estado("off", 995)) == "off"
    assert hosting.interpretar_estado_pc(0, _saida_estado("off", 1000 - hosting.FRESCO_S - 500)) == "off"


def test_interpretar_demais_estados_inalterados():
    assert hosting.interpretar_estado_pc(0, _saida_estado("active", 995)) == "active"
    assert hosting.interpretar_estado_pc(0, _saida_estado("grace", 995)) == "grace"
    assert hosting.interpretar_estado_pc(0, _saida_estado("standby", 995)) == "down"
    assert hosting.interpretar_estado_pc(0, _saida_estado("active", 900)) == "down"


@pytest.mark.parametrize("faltas,ativo,bloqueado,esperado", [
    (0, False, False, ("manter", 1)),      # 1a leitura off: so conta
    (1, False, False, ("ativar", 2)),      # 2a leitura off seguida: ativa
    (5, False, False, ("ativar", 6)),
    (1, False, True, ("manter", 2)),       # conflito vence
    (1, True, False, ("manter", 2)),       # ja ativo
    (0, True, False, ("manter", 1)),
])
def test_decidir_mac_off_ativa_so_na_segunda_leitura(faltas, ativo, bloqueado, esperado):
    assert hosting.decidir_mac("off", faltas, ativo, bloqueado) == esperado


def test_decidir_mac_off_seguido_de_ilegivel_zera():
    _, f = hosting.decidir_mac("off", 0, False)
    assert hosting.decidir_mac(None, f, False) == ("manter", 0)
    assert hosting.decidir_mac("off", 0, False)[0] == "manter"


def test_decidir_mac_offline_continua_na_hora():
    assert hosting.decidir_mac("offline", 0, False)[0] == "ativar"


@pytest.mark.parametrize("linha,esperado", [
    ('{"host": "pc", "state": "off", "ts": 1}', True),
    ('{"host": "pc", "state": "off", "ts": 1}\n', True),
    ('{"host": "pc", "state": "active", "ts": 1}', False),
    ('{"host": "pc", "state": "grace", "ts": 1}', False),
    ('{}', False),
    ('', False),
    ('\n', False),
    ('lixo off', False),
    ('"off"', False),
    ('[1, 2]', False),
])
def test_linha_diz_off(linha, esperado):
    assert hosting.linha_diz_off(linha) is esperado


class _FakeStdin:
    def __init__(self): self.dados = b""
    def write(self, b): self.dados += b
    async def drain(self): pass
    def close(self): pass


class _FakeStdout:
    def __init__(self, linhas, bloqueia):
        self.linhas, self.bloqueia = list(linhas), bloqueia
    async def readline(self):
        if self.linhas:
            return self.linhas.pop(0)
        if self.bloqueia:
            await asyncio.Event().wait()
        return b""


class _FakeStderr:
    def __init__(self, dados): self.dados = dados
    async def read(self, n=-1):
        pedaco, self.dados = self.dados[:n if n > 0 else None], self.dados[n:] if n > 0 else b""
        return pedaco


class _FakeProc:
    def __init__(self, linhas, bloqueia, stderr=b""):
        self.stdin, self.stdout = _FakeStdin(), _FakeStdout(linhas, bloqueia)
        self.stderr = _FakeStderr(stderr)
        self.returncode, self.morto = None, False
    def kill(self):
        self.morto, self.returncode = True, -9
    async def wait(self):
        return self.returncode


def _vigia(monkeypatch, linhas, bloqueia, stderr=b""):
    monkeypatch.setattr(hosting, "HOST", "mac")
    monkeypatch.setattr(hosting, "RECONECTA_VIGIA_S", 0.01)
    argvs, procs = [], []
    monkeypatch.setattr(hosting, "pc_argv", lambda *a, **k: argvs.append((a, k)) or ["ssh", "pc"])

    async def criar(*cmd, **kw):
        p = _FakeProc(linhas, bloqueia, stderr)
        procs.append(p)
        return p

    monkeypatch.setattr(hosting.asyncio, "create_subprocess_exec", criar)
    return hosting.Hosting(object(), None, None), argvs, procs


def test_vigia_linha_off_acorda_o_loop_e_script_vai_pelo_stdin(monkeypatch):
    async def cenario():
        h, argvs, procs = _vigia(monkeypatch, [b'{"state": "active"}\n', b'{"state": "off"}\n'], True)
        t = asyncio.ensure_future(h._vigiar_pc())
        await asyncio.wait_for(h._off.wait(), 2)
        assert h._vigia_ligada
        t.cancel()
        await asyncio.gather(t, return_exceptions=True)
        return h, argvs, procs
    h, argvs, procs = asyncio.run(cenario())
    assert b"host-state.json" in procs[0].stdin.dados and procs[0].morto and not h._vigia_ligada
    assert argvs[0] == ((), {"extra": hosting.OPCOES_VIGIA})


def test_vigia_eof_nao_vira_off_e_reconecta(monkeypatch):
    async def cenario():
        h, argvs, procs = _vigia(monkeypatch, [b'{"state": "active"}\n'], False)
        t = asyncio.ensure_future(h._vigiar_pc())
        for _ in range(200):
            if len(procs) >= 3:
                break
            await asyncio.sleep(0.01)
        t.cancel()
        await asyncio.gather(t, return_exceptions=True)
        return h, procs
    h, procs = asyncio.run(cenario())
    assert len(procs) >= 3 and not h._off.is_set() and all(p.morto for p in procs)


def test_vigia_mac_ativo_mata_o_ssh_e_volta_no_standby(monkeypatch):
    async def cenario():
        h, argvs, procs = _vigia(monkeypatch, [b'{"state": "active"}\n'], True)
        t = asyncio.ensure_future(h._vigiar_pc())
        for _ in range(200):
            if procs and h._vigia_ligada:
                break
            await asyncio.sleep(0.01)
        h.estado = "active"
        h._mudanca.set()
        for _ in range(200):
            if procs[0].morto:
                break
            await asyncio.sleep(0.01)
        morto, n = procs[0].morto, len(procs)
        await asyncio.sleep(0.1)
        assert len(procs) == n                      # ativo: nao reconecta
        h.estado = "standby"
        h._mudanca.set()
        for _ in range(200):
            if len(procs) > n:
                break
            await asyncio.sleep(0.01)
        t.cancel()
        await asyncio.gather(t, return_exceptions=True)
        return morto, n, len(procs)
    morto, n, depois = asyncio.run(cenario())
    assert morto and depois > n


def test_vigia_nao_roda_no_pc(monkeypatch):
    async def cenario():
        h, argvs, procs = _vigia(monkeypatch, [], True)
        monkeypatch.setattr(hosting, "HOST", "pc")
        await asyncio.wait_for(h._vigiar_pc(), 1)
        return procs
    assert asyncio.run(cenario()) == []


def test_pc_argv_real_extra_antes_do_destino(monkeypatch):
    monkeypatch.setattr(hosting, "_pc_cfg", lambda: {"PC_HOST": "1.2.3.4", "PC_USER_LINUX": "u"})
    monkeypatch.setattr(hosting, "PC_KEY", hosting.DIR / "nao-existe-chave")
    base = hosting.pc_argv()
    com = hosting.pc_argv(extra=hosting.OPCOES_VIGIA)
    assert com[0] == "ssh" and com[1:5] == hosting.OPCOES_VIGIA
    assert com[5:] == base[1:]                         # o resto, na mesma ordem
    assert com[-2:] == ["u@1.2.3.4", "bash -s"]        # destino, depois o comando remoto por ultimo
    assert "ServerAliveInterval=5" not in base


def test_esperar_ciclo_sem_vigia_e_o_sleep_de_sempre(monkeypatch):
    chamadas = []

    async def dorme(t): chamadas.append(t)
    monkeypatch.setattr(hosting.asyncio, "sleep", dorme)
    h = hosting.Hosting(object(), None, None)
    asyncio.run(h._esperar_ciclo(15))
    assert chamadas == [15]


def test_esperar_ciclo_com_vigia_off_interrompe_e_sem_off_espera_o_prazo(monkeypatch):
    async def cenario():
        h = hosting.Hosting(object(), None, None)
        h._vigia_ligada = True
        t0 = time.monotonic()
        await h._esperar_ciclo(0.1)                    # sem off: vence o prazo
        prazo = time.monotonic() - t0
        h._off.set()
        t0 = time.monotonic()
        await h._esperar_ciclo(30)                     # com off: volta na hora
        return prazo, time.monotonic() - t0
    prazo, com_off = asyncio.run(asyncio.wait_for(cenario(), 5))
    assert prazo >= 0.09 and com_off < 1


def _mac_com_leituras(monkeypatch, leituras, off_antes=False, grace=None, fechou=False, bloqueado=False,
                      eventos=None, sondas=(False, False), atraso=0.0, mudo=False, roteadores=(True, True), lans=(True,), ativo=False,
                      lido_extra=None):
    """Roda _rodar_mac com estado_do_pc roteirizado e relogio falso; devolve (ativacoes, esperas, h, lidas, cedidos).
    `sondas`: o que cada pc_responde devolve; `atraso`: segundos entre o sinal e o ciclo. Para ao esgotar as leituras. `eventos` registra a ordem: ("espera", t), "sonda", "le", ("ativar", relogio), ("motivo", m)."""
    monkeypatch.setattr(hosting, "HOST", "mac")
    eventos = [] if eventos is None else eventos
    checagens, publicados = [], []               # (mac, claim_idade) de cada leitura; (estado, extra) de cada gravar_estado
    monkeypatch.setattr(hosting, "gravar_estado", lambda e, extra=None: publicados.append((e, extra)))
    relogio = [1000.0]
    monkeypatch.setattr(hosting, "time", types.SimpleNamespace(monotonic=lambda: relogio[0], time=time.time))
    restantes = list(leituras)
    lidas = []

    async def le(mac=None, claim_idade=None, lido=None):
        lidas.append(1)
        eventos.append("le")
        checagens.append((mac, claim_idade))
        if lido is not None and lido_extra:
            lido.update(lido_extra)
        return restantes.pop(0)

    async def dorme(t):
        eventos.append(("espera", t))
        relogio[0] += t

    pendentes = list(sondas)

    async def sonda():
        eventos.append("sonda")
        return pendentes.pop(0)

    rotas, redes = list(roteadores), list(lans)

    async def roteador():
        eventos.append("roteador")
        return rotas.pop(0)

    def lan():
        eventos.append("lan")
        return redes.pop(0)
    monkeypatch.setattr(hosting, "roteador_responde", roteador)
    monkeypatch.setattr(hosting, "mac_na_lan_do_pc", lan)
    monkeypatch.setattr(hosting.asyncio, "sleep", dorme)
    monkeypatch.setattr(hosting, "estado_do_pc", le)
    monkeypatch.setattr(hosting, "pc_responde", sonda)
    cedidos = []

    async def ceder(): cedidos.append(1)
    monkeypatch.setattr(hosting, "ceder_ao_pc", ceder)
    ativacoes, esperas = [], []

    class App:
        class updater:
            @staticmethod
            async def start_polling(**kw):
                ativacoes.append(kw)
                eventos.append(("ativar", relogio[0]))

            @staticmethod
            async def stop(): pass

    async def on(_): pass
    async def antes(): pass
    async def ativou(m): eventos.append(("motivo", m))

    async def cenario():
        h = hosting.Hosting(App, ativou, on, antes_de_ceder=antes)
        async def vigia_parado(): await asyncio.Event().wait()
        h._vigiar_pc = vigia_parado
        if ativo:
            h.estado = "active"
        if off_antes:
            h._off.set()
        if fechou or mudo:
            h._sinal = (relogio[0] - atraso, "mudo" if mudo else "fechou")
            h._off.set()
        if bloqueado:
            h.bloqueado_ate = relogio[0] + 100

        async def espera(t):
            esperas.append(t)
            if not restantes:
                raise asyncio.CancelledError
        h._esperar_ciclo = espera
        with pytest.raises(asyncio.CancelledError):
            await h._rodar_mac()
        h.checagens_teste, h.publicados_teste = checagens, publicados
        return h
    h = asyncio.run(cenario())
    return ativacoes, esperas, h, lidas, cedidos


@pytest.mark.parametrize("lido", ["active", "grace"])
def test_off_velho_com_leitura_viva_nao_ativa_e_cede(monkeypatch, lido):
    ativacoes, esperas, h, lidas, cedidos = _mac_com_leituras(monkeypatch, [lido], off_antes=True)
    assert ativacoes == [] and len(lidas) == 1 and not h._off.is_set()   # sempre le de verdade
    assert (len(cedidos) == 1) == (lido == "grace")


def test_off_e_depois_grace_nao_ativa(monkeypatch):
    ativacoes, esperas, h, _, cedidos = _mac_com_leituras(monkeypatch, ["off", "grace"])
    assert ativacoes == [] and cedidos == [1]


def test_off_e_depois_ilegivel_nao_ativa(monkeypatch):
    ativacoes, esperas, h, _, _ = _mac_com_leituras(monkeypatch, ["off", None, "off"])
    assert ativacoes == []


def test_off_off_ativa_e_reagenda_com_off_recheck(monkeypatch):
    ativacoes, esperas, h, _, _ = _mac_com_leituras(monkeypatch, ["off", "off"])
    assert len(ativacoes) == 1 and h.ativo
    assert esperas == [hosting.OFF_RECHECK_S, hosting.CHECK_ACTIVE_S]
    assert hosting.OFF_RECHECK_S < hosting.CHECK_STANDBY_S


def test_leitura_down_segue_com_check_standby(monkeypatch):
    _, esperas, _, _, _ = _mac_com_leituras(monkeypatch, ["down"])
    assert esperas == [hosting.CHECK_STANDBY_S]


# ---- o PC fechou a sessao (SIGTERM no desligamento): segundo sinal da vigia ----

@pytest.mark.parametrize("err,esperado", [
    ("Connection to 192.168.0.71 closed by remote host.\n", True),
    ("Connection to 192.168.0.71 closed by remote host.", True),
    ("Warning: x\nConnection to pc-test closed by remote host.\n", True),
    ("Connection closed by remote host", False),
    ("kex_exchange_identification: Connection closed by remote host", False),
    ("Connection closed by 192.168.0.71 port 22", False),
    ("Timeout, server x not responding.", False),
    ("Connection reset by peer", False),
    ("Broken pipe", False),
    ("", False),
])
def test_pc_fechou_a_sessao(err, esperado):
    assert hosting.pc_fechou_a_sessao(err) is esperado


FECHOU = b"Connection to 192.168.0.71 closed by remote host.\n"


async def _rodar_vigia_ate_eof(h, procs, n=1):
    t = asyncio.ensure_future(h._vigiar_pc())
    for _ in range(200):
        if len(procs) >= n:
            await asyncio.sleep(0.05)
            break
        await asyncio.sleep(0.01)
    t.cancel()
    await asyncio.gather(t, return_exceptions=True)


@pytest.mark.parametrize("linhas,stderr,esperado", [
    ([b'{"state": "active"}\n'], FECHOU, True),
    ([], FECHOU, False),                                          # nunca conectou de verdade
    ([b'{"state": "active"}\n'], b"", False),                    # EOF mudo
    ([b'{"state": "active"}\n'], b"Timeout, server x not responding.\n", False),
    ([b'{"state": "active"}\n'], b"Connection closed by 1.2.3.4 port 22\n", False),
])
def test_vigia_sinal_de_sessao_fechada(monkeypatch, linhas, stderr, esperado):
    async def cenario():
        monkeypatch.setattr(hosting, "mac_na_lan_do_pc", lambda: False)   # o Timeout so vira sinal "mudo" na LAN
        h, _, procs = _vigia(monkeypatch, linhas, False, stderr)
        await _rodar_vigia_ate_eof(h, procs)
        return h
    h = asyncio.run(cenario())
    assert (h._sinal is not None) is esperado and h._off.is_set() is esperado
    assert h._sinal is None or h._sinal[1] == "fechou"


def test_vigia_mac_matou_o_ssh_nao_gera_sinal(monkeypatch):
    async def cenario():
        h, _, procs = _vigia(monkeypatch, [b'{"state": "active"}\n'], True, FECHOU)
        t = asyncio.ensure_future(h._vigiar_pc())
        for _ in range(200):
            if h._vigia_ligada:
                break
            await asyncio.sleep(0.01)
        h.estado = "active"
        h._mudanca.set()
        for _ in range(200):
            if procs[0].morto:
                break
            await asyncio.sleep(0.01)
        t.cancel()
        await asyncio.gather(t, return_exceptions=True)
        return h
    h = asyncio.run(cenario())
    assert h._sinal is None and not h._off.is_set()


def test_vigia_cancel_nao_gera_sinal(monkeypatch):
    async def cenario():
        h, _, procs = _vigia(monkeypatch, [b'{"state": "active"}\n'], True, FECHOU)
        t = asyncio.ensure_future(h._vigiar_pc())
        for _ in range(200):
            if h._vigia_ligada:
                break
            await asyncio.sleep(0.01)
        t.cancel()
        await asyncio.gather(t, return_exceptions=True)
        return h
    h = asyncio.run(cenario())
    assert h._sinal is None


def test_vigia_stderr_grande_nao_trava(monkeypatch):
    async def cenario():
        h, _, procs = _vigia(monkeypatch, [b'{"state": "active"}\n'], False, b"x" * 500_000 + FECHOU)
        await asyncio.wait_for(_rodar_vigia_ate_eof(h, procs), 5)
        return h
    asyncio.run(cenario())          # nao travar e nao levantar


def test_fechou_duas_sondas_mudas_ativa_sem_ler_o_estado_em_fechou_ativa_s(monkeypatch):
    eventos = []
    ativacoes, esperas, h, lidas, _ = _mac_com_leituras(monkeypatch, [], fechou=True, eventos=eventos)
    assert len(ativacoes) == 1 and h.ativo and h.pc_estado == "fechou" and lidas == []
    assert eventos[:6] == [("espera", hosting.FECHOU_SONDA1_S), "sonda",
                           ("espera", hosting.FECHOU_SONDA2_S - hosting.FECHOU_SONDA1_S), "sonda",
                           ("espera", hosting.FECHOU_ATIVA_S - hosting.FECHOU_SONDA2_S),
                           ("ativar", 1000.0 + hosting.FECHOU_ATIVA_S)]
    assert ("motivo", "PC fechou a conexao") in eventos
    assert h._sinal is None and not h._off.is_set()


def test_fechou_primeira_sonda_responde_so_uma_sonda_e_ciclo_normal(monkeypatch):
    eventos = []
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, ["active"], fechou=True, eventos=eventos,
                                                  sondas=(True,))
    assert eventos.count("sonda") == 1 and ativacoes == [] and len(lidas) == 1 and h.pc_estado == "active"


def test_fechou_segunda_sonda_responde_ciclo_normal_e_none_nao_ativa(monkeypatch):
    eventos = []
    # None zera as faltas: o "off" seguinte e so a primeira leitura off
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, [None, "off"], fechou=True, eventos=eventos,
                                                  sondas=(False, True))
    assert eventos.count("sonda") == 2 and ativacoes == [] and len(lidas) == 2


def test_fechou_grace_apos_sonda_respondida_cede(monkeypatch):
    ativacoes, _, h, _, cedidos = _mac_com_leituras(monkeypatch, ["grace"], fechou=True, sondas=(True,))
    assert ativacoes == [] and cedidos == [1]


def test_fechou_bloqueado_nao_ativa(monkeypatch):
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, [], fechou=True, bloqueado=True)
    assert ativacoes == [] and lidas == []


def test_fechou_sinal_atrasado_encolhe_as_esperas_mas_roda_as_duas_sondas(monkeypatch):
    eventos = []
    ativacoes, _, h, _, _ = _mac_com_leituras(monkeypatch, [], fechou=True, eventos=eventos,
                                              atraso=hosting.FECHOU_ATIVA_S + 5)
    assert eventos[:3] == ["sonda", "sonda", ("ativar", 1000.0)] and len(ativacoes) == 1


@pytest.mark.parametrize("rc,err,esperado", [
    (0, "", True),
    (255, "ssh: connect to host 1.2.3.4 port 22: Connection refused", False),
    (255, "ssh: connect to host 1.2.3.4 port 22: Connection timed out", False),
    (255, "Connection reset by 1.2.3.4 port 22", False),
    (255, "kex_exchange_identification: Connection closed by remote host", False),
    (255, "", False),
    (124, "", False),
])
def test_pc_responde(monkeypatch, rc, err, esperado):
    chamadas = []

    async def sh_err(*cmd, **kw):
        chamadas.append((cmd, kw))
        return rc, "", err
    monkeypatch.setattr(hosting, "_sh_err", sh_err)
    monkeypatch.setattr(hosting, "pc_argv", lambda *a, **k: ["ssh", "pc", a[0]])
    assert asyncio.run(hosting.pc_responde()) is esperado
    assert chamadas[0][1] == {"timeout": hosting.FECHOU_SONDA_TIMEOUT_S} and chamadas[0][0][-1] == "true"


def test_pc_responde_sem_argv_e_verdadeiro(monkeypatch):
    monkeypatch.setattr(hosting, "pc_argv", lambda *a, **k: None)
    assert asyncio.run(hosting.pc_responde()) is True


def test_sem_sinal_nao_ha_espera_extra(monkeypatch):
    eventos = []
    _mac_com_leituras(monkeypatch, ["down"], eventos=eventos)
    assert eventos[0] == "le"


def test_decidir_mac_fechou():
    assert hosting.decidir_mac("fechou", 0, False)[0] == "ativar"
    assert hosting.decidir_mac("fechou", 0, True)[0] == "manter"
    assert hosting.decidir_mac("fechou", 0, False, bloqueado=True)[0] == "manter"


# ---- o PC morreu sem avisar: o ssh da vigia estoura (ServerAlive) ----

@pytest.mark.parametrize("err,esperado", [
    ("Timeout, server 192.168.0.71 not responding.\n", True),
    ("Timeout, server pc-test not responding.", True),
    ("Warning: x\nTimeout, server 1.2.3.4 not responding.\n", True),
    ("Connection to 192.168.0.71 closed by remote host.", False),
    ("Connection closed by remote host", False),
    ("kex_exchange_identification: Connection closed by remote host", False),
    ("Connection closed by 192.168.0.71 port 22", False),
    ("Connection reset by peer", False),
    ("Broken pipe", False),
    ("", False),
])
def test_pc_calou(err, esperado):
    assert hosting.pc_calou(err) is esperado


MUDO = b"Timeout, server 192.168.0.71 not responding.\n"


@pytest.mark.parametrize("linhas,stderr,lan,tipo", [
    ([b'{"state": "active"}\n'], MUDO, True, "mudo"),
    ([], MUDO, True, None),                                   # nunca conectou
    ([b'{"state": "active"}\n'], MUDO, False, None),         # Mac fora da LAN do PC
    ([b'{"state": "active"}\n'], b"", True, None),
    ([b'{"state": "active"}\n'], FECHOU, True, "fechou"),    # fechou pelo PC segue igual
])
def test_vigia_sinal_mudo_ou_fechou(monkeypatch, linhas, stderr, lan, tipo):
    async def cenario():
        monkeypatch.setattr(hosting, "mac_na_lan_do_pc", lambda: lan)
        h, _, procs = _vigia(monkeypatch, linhas, False, stderr)
        await _rodar_vigia_ate_eof(h, procs)
        return h
    h = asyncio.run(cenario())
    assert (h._sinal[1] if h._sinal else None) == tipo and h._off.is_set() is (tipo is not None)


@pytest.mark.parametrize("modo", ["mac_ativou", "cancel"])
def test_vigia_mudo_iniciado_pelo_mac_nao_gera_sinal(monkeypatch, modo):
    async def cenario():
        monkeypatch.setattr(hosting, "mac_na_lan_do_pc", lambda: True)
        h, _, procs = _vigia(monkeypatch, [b'{"state": "active"}\n'], True, MUDO)
        t = asyncio.ensure_future(h._vigiar_pc())
        for _ in range(200):
            if h._vigia_ligada:
                break
            await asyncio.sleep(0.01)
        if modo == "mac_ativou":
            h.estado = "active"
            h._mudanca.set()
            for _ in range(200):
                if procs[0].morto:
                    break
                await asyncio.sleep(0.01)
        t.cancel()
        await asyncio.gather(t, return_exceptions=True)
        return h
    assert asyncio.run(cenario())._sinal is None


def _roteador(monkeypatch, route_rc, route_out, ping_rc):
    chamadas = []

    async def sh(*cmd, **kw):
        chamadas.append((cmd, kw))
        return (route_rc, route_out) if cmd[0] == "route" else (ping_rc, "")
    monkeypatch.setattr(hosting, "_sh", sh)
    return asyncio.run(hosting.roteador_responde()), chamadas


@pytest.mark.parametrize("route_rc,route_out,ping_rc,esperado", [
    (0, "   route to: default\n    gateway: 192.168.0.1\n", 0, True),
    (0, "   gateway: 192.168.0.1\n", 2, False),               # ping falhou
    (0, "   gateway: 192.168.0.1\n", 124, False),             # ping estourou
    (0, "   route to: default\n", 0, False),                   # sem gateway
    (0, "   gateway: fe80::1%en0\n", 0, False),                # IPv6
    (0, "   gateway: link#14\n", 0, False),
    (124, "", 0, False),                                       # route estourou
    (1, "   gateway: 192.168.0.1\n", 0, False),
])
def test_roteador_responde(monkeypatch, route_rc, route_out, ping_rc, esperado):
    r, chamadas = _roteador(monkeypatch, route_rc, route_out, ping_rc)
    assert r is esperado
    if esperado:
        assert chamadas[1][0] == ("ping", "-c", "1", "-t", "1", "192.168.0.1") and chamadas[1][1] == {"timeout": 2}
    else:
        assert not any(c[0][0] == "ping" for c in chamadas) or ping_rc != 0


def test_mudo_roteador_e_pc_calados_ativa_sem_ler_na_ordem(monkeypatch):
    eventos = []
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, [], mudo=True, eventos=eventos)
    assert len(ativacoes) == 1 and lidas == [] and h.pc_estado == "mudo"
    ordem = [e for e in eventos if not (isinstance(e, tuple) and e[0] == "motivo")]
    assert ordem[:7] == ["roteador", "sonda", ("espera", hosting.MUDO_SONDA2_S), "sonda", "lan", "roteador",
                         ("ativar", 1000.0 + hosting.MUDO_SONDA2_S)]
    assert ("motivo", "PC parou de responder") in eventos and h._sinal is None


def test_mudo_roteador_fora_no_inicio_nao_sonda_nem_ativa(monkeypatch):
    eventos = []
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, [None], mudo=True, eventos=eventos,
                                                  roteadores=(False,))
    assert eventos[0] == "roteador" and "sonda" not in eventos and ativacoes == [] and len(lidas) == 1


@pytest.mark.parametrize("sondas", [(True,), (False, True)])
def test_mudo_pc_que_responde_descarta_o_sinal_e_ciclo_normal(monkeypatch, sondas):
    eventos = []
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, ["active"], mudo=True, eventos=eventos,
                                                  sondas=sondas)
    assert ativacoes == [] and eventos.count("sonda") == len(sondas) and len(lidas) == 1
    assert "lan" not in eventos


def test_mudo_roteador_some_na_reconferencia_nao_ativa(monkeypatch):
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, [None], mudo=True, roteadores=(True, False))
    assert ativacoes == [] and len(lidas) == 1


def test_mudo_fora_da_lan_na_reconferencia_nao_ativa(monkeypatch):
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, [None], mudo=True, lans=(False,))
    assert ativacoes == [] and len(lidas) == 1


def test_mudo_bloqueado_nao_ativa(monkeypatch):
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, [], mudo=True, bloqueado=True)
    assert ativacoes == [] and lidas == []


def test_mudo_ignorado_se_o_mac_ja_le(monkeypatch):
    eventos = []
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, ["down"], mudo=True, eventos=eventos, ativo=True)
    assert "roteador" not in eventos and "sonda" not in eventos and len(lidas) == 1 and h._sinal is None


def test_mudo_descartado_e_leitura_none_deixa_faltas_zeradas(monkeypatch):
    # sinal descartado (PC respondeu), leitura None zera as faltas, "off" seguinte e so a primeira
    ativacoes, _, h, lidas, _ = _mac_com_leituras(monkeypatch, [None, "off"], mudo=True, sondas=(True,))
    assert ativacoes == [] and len(lidas) == 2


def test_decidir_mac_mudo():
    assert hosting.decidir_mac("mudo", 0, False)[0] == "ativar"
    assert hosting.decidir_mac("mudo", 0, True)[0] == "manter"
    assert hosting.decidir_mac("mudo", 0, False, bloqueado=True)[0] == "manter"


# ---- desativar reentrante: 409 em voo + "o PC voltou" no mesmo instante ----

class _UpdaterFalso:
    """stop() espera um portao e levanta RuntimeError se o updater ja nao roda (como o do python-telegram-bot)."""
    def __init__(self):
        self.rodando, self.paradas, self.portao = True, 0, asyncio.Event()

    async def stop(self):
        self.paradas += 1
        await self.portao.wait()
        if not self.rodando:
            raise RuntimeError("This Updater is not running!")
        self.rodando = False


def _hosting_ativo(monkeypatch, updater):
    monkeypatch.setattr(hosting, "HOST", "mac")
    monkeypatch.setattr(hosting, "gravar_estado", lambda e, extra=None: None)
    chamadas = []

    class App:
        pass
    App.updater = updater

    async def on_desativar(m): chamadas.append(m)
    async def on_ativar(m): pass
    h = hosting.Hosting(App, on_ativar, on_desativar)
    h.estado = "active"
    return h, chamadas


def test_desativar_concorrente_para_uma_vez_so(monkeypatch, caplog):
    caplog.set_level("INFO", logger="wisp.hosting")

    async def cenario():
        up = _UpdaterFalso()
        h, chamadas = _hosting_ativo(monkeypatch, up)
        a = asyncio.ensure_future(h.desativar("409"))
        b = asyncio.ensure_future(h.desativar("o PC voltou"))
        await asyncio.sleep(0.05)
        up.portao.set()
        await asyncio.gather(a, b)
        return h, up, chamadas
    h, up, chamadas = asyncio.run(asyncio.wait_for(cenario(), 5))
    assert up.paradas == 1 and h.estado == "standby" and chamadas == ["409"]
    assert sum("soltando em" in r.getMessage() for r in caplog.records) == 1


def test_409_em_voo_e_ceder_do_loop_nao_derrubam_o_hosting(monkeypatch):
    async def cenario():
        up = _UpdaterFalso()
        h, chamadas = _hosting_ativo(monkeypatch, up)

        async def le(mac=None, **_): return "active"
        monkeypatch.setattr(hosting, "estado_do_pc", le)
        async def vigia_parado(): await asyncio.Event().wait()
        h._vigiar_pc = vigia_parado
        h.conflito()                                   # desativar em voo, preso no stop()
        antes = h.bloqueado_ate
        await asyncio.sleep(0.05)

        async def espera(t):
            up.portao.set()
            raise asyncio.CancelledError               # um ciclo so
        h._esperar_ciclo = espera
        with pytest.raises(asyncio.CancelledError):    # RuntimeError aqui = hosting morreu
            await asyncio.wait_for(h._rodar_mac(), 2)  # preso no stop() = TimeoutError (falha), nao trava a suite
        await asyncio.wait_for(h._cessao, 2)
        return h, up, antes
    h, up, antes = asyncio.run(asyncio.wait_for(cenario(), 5))
    assert up.paradas == 1 and h.estado == "standby" and h.bloqueado_ate == antes > 0


def test_desativar_com_stop_que_falha_limpa_a_trava(monkeypatch):
    async def cenario():
        up = _UpdaterFalso()
        up.rodando = False                             # stop() vai levantar
        up.portao.set()
        h, _ = _hosting_ativo(monkeypatch, up)
        with pytest.raises(RuntimeError):
            await h.desativar("x")
        return h
    h = asyncio.run(cenario())
    assert h._soltando is False and h.estado == "active"


# ---- leitor segue o ultimo claim do Wisp (17/11): Mac <-> PC pelo claim, sem "o PC ganha" ----

import json as _json
import os as _os
import subprocess as _subprocess


def _estado_com_claim(estado, claim, ts=995, agora=1000):
    st = {"host": "pc", "state": estado, "ts": ts}
    if claim:
        st["claim"] = {"host": claim, "ts": 1}
    return _json.dumps(st) + f"\n\n{agora}\n"


def test_interpretar_standby_com_claim_do_mac_e_cedeu():
    assert hosting.interpretar_estado_pc(0, _estado_com_claim("standby", "mac")) == "cedeu"
    assert hosting.interpretar_estado_pc(0, _estado_com_claim("standby", None)) == "down"
    assert hosting.interpretar_estado_pc(0, _estado_com_claim("standby", "pc")) == "down"
    assert hosting.interpretar_estado_pc(0, _estado_com_claim("standby", "mac", ts=900)) == "down"   # velho = sem bot
    assert hosting.interpretar_estado_pc(0, _estado_com_claim("active", "mac")) == "active"          # ainda num turno
    assert hosting.interpretar_estado_pc(0, _estado_com_claim("grace", "pc")) == "grace"


@pytest.mark.parametrize("ativo,bloqueado,esperado", [
    (False, False, "ativar"),          # o PC soltou: o Mac le na primeira checagem
    (False, True, "manter"),           # 409 recente segue valendo
    (True, False, "manter"),
])
def test_decidir_mac_cedeu(ativo, bloqueado, esperado):
    assert hosting.decidir_mac("cedeu", 0, ativo, bloqueado)[0] == esperado


def test_mac_ativa_na_primeira_leitura_cedeu(monkeypatch):
    eventos = []
    ativacoes, esperas, h, lidas, cedidos = _mac_com_leituras(monkeypatch, ["cedeu"], eventos=eventos)
    assert len(ativacoes) == 1 and h.ativo and cedidos == [] and len(lidas) == 1
    assert ("motivo", "o PC soltou (claim do Mac)") in eventos


def test_mac_pc_ilegivel_nunca_ativa_mesmo_com_claim(monkeypatch):
    ativacoes, _, h, _, _ = _mac_com_leituras(monkeypatch, [None, None, None, None])
    assert ativacoes == [] and not h.ativo


def test_mac_ativo_e_pc_reiniciado_com_claim_do_mac_segue_lendo(monkeypatch):
    ativacoes, esperas, h, _, cedidos = _mac_com_leituras(monkeypatch, ["cedeu", "cedeu"], ativo=True)
    assert h.ativo and ativacoes == [] and cedidos == [] and esperas == [hosting.CHECK_ACTIVE_S] * 2


def test_mac_ativo_e_claim_do_pc_cede_pelo_grace(monkeypatch):
    ativacoes, _, h, _, cedidos = _mac_com_leituras(monkeypatch, ["grace"], ativo=True)
    assert not h.ativo and cedidos == [1]


@pytest.mark.parametrize("linha,esperado", [
    ('{"state": "standby", "claim": {"host": "mac", "ts": 1}}', True),
    ('{"state": "standby", "claim": {"host": "pc", "ts": 1}}', False),
    ('{"state": "standby"}', False),
    ('{"state": "active", "claim": {"host": "mac", "ts": 1}}', False),
    ('lixo', False),
])
def test_linha_diz_cedeu(linha, esperado):
    assert hosting.linha_diz_cedeu(linha) is esperado


def test_vigia_linha_cedeu_acorda_o_loop(monkeypatch):
    async def cenario():
        h, _, _ = _vigia(monkeypatch, [b'{"state": "active"}\n',
                                       b'{"state": "standby", "claim": {"host": "mac", "ts": 1}}\n'], True)
        t = asyncio.ensure_future(h._vigiar_pc())
        await asyncio.wait_for(h._off.wait(), 2)
        t.cancel()
        await asyncio.gather(t, return_exceptions=True)
    asyncio.run(cenario())


def _bash(script, home):
    env = {"HOME": str(home), "PATH": _os.environ["PATH"]}
    return _subprocess.run(["bash", "-s"], input=script.encode(), capture_output=True, env=env, timeout=10)


def test_script_estado_pc_grava_mac_visto_e_a_saida_nao_muda(tmp_path):
    d = tmp_path / hosting.DIR_REMOTO_REL
    d.mkdir(parents=True)
    (d / "host-state.json").write_text(_json.dumps({"host": "pc", "state": "standby", "ts": int(time.time()),
                                                    "claim": {"host": "mac", "ts": 1}}))
    r = _bash(hosting.script_estado_pc("active"), tmp_path)
    assert r.returncode == 0
    assert hosting.interpretar_estado_pc(0, r.stdout.decode()) == "cedeu"
    mtime, st = hosting.ler_mac_visto(d / "mac-seen.json")
    assert st == "active" and abs(mtime - time.time()) < 5
    (d / "mac-seen.json").unlink()
    r = _bash(hosting.script_estado_pc(), tmp_path)           # a CLI so le: nao finge ser o bot do Mac
    assert r.returncode == 0 and not (d / "mac-seen.json").exists()


def test_estado_do_pc_manda_o_estado_do_mac(monkeypatch):
    scripts = []
    async def off(): return False
    async def ssh(script):
        scripts.append(script)
        return 0, _estado_com_claim("standby", "mac", ts=int(time.time()), agora=int(time.time()))
    monkeypatch.setattr(hosting, "_pc_offline_no_tailscale", off)
    monkeypatch.setattr(hosting, "_pc_ssh", ssh)
    assert asyncio.run(hosting.estado_do_pc(mac="standby")) == "cedeu"
    assert '"state": "standby"' in scripts[0] and "mac-seen.json" in scripts[0]


def test_script_claim_grava_com_relogio_do_pc(tmp_path):
    r = _bash(hosting.script_claim("mac"), tmp_path)
    assert r.returncode == 0
    c = hosting.ler_claim(tmp_path / hosting.DIR_REMOTO_REL / "reader-claim.json")
    assert c["host"] == "mac" and abs(c["ts"] - time.time()) < 5
    with pytest.raises(ValueError):
        hosting.script_claim("x; rm -rf ~")


def test_ler_claim_rejeita_lixo(tmp_path):
    p = tmp_path / "c.json"
    assert hosting.ler_claim(p) == {}
    p.write_text('{"host": "windows"}')
    assert hosting.ler_claim(p) == {}
    p.write_text("lixo")
    assert hosting.ler_claim(p) == {}
    hosting.gravar_claim("pc", p)
    assert hosting.ler_claim(p)["host"] == "pc"


def test_gravar_estado_no_pc_leva_o_claim_e_no_mac_nao(monkeypatch, tmp_path):
    monkeypatch.setattr(hosting, "DIR", tmp_path)
    monkeypatch.setattr(hosting, "STATE", tmp_path / "host-state.json")
    monkeypatch.setattr(hosting, "CLAIM", tmp_path / "reader-claim.json")
    hosting.gravar_claim("mac")
    monkeypatch.setattr(hosting, "HOST", "pc")
    hosting.gravar_estado("standby")
    assert hosting.ler_estado_local()["claim"]["host"] == "mac"
    monkeypatch.setattr(hosting, "HOST", "mac")
    hosting.gravar_estado("active")
    assert "claim" not in hosting.ler_estado_local()


@pytest.mark.parametrize("claim,ativo,ocupado,idade,mac_ativo,parado,esperado", [
    (None, False, False, 0, False, 0, "ler"),          # sem claim: o PC le como sempre (grace)
    ("pc", False, False, 999, False, 0, "ler"),
    ("pc", True, False, 999, False, 0, "manter"),
    ("mac", True, True, 5, False, 0, "esperar"),       # turno rodando: nunca solta no meio
    ("mac", True, False, 5, False, 0, "soltar"),
    ("mac", False, False, 5, True, 0, "manter"),       # o Mac le
    ("mac", False, False, 5, False, 30, "manter"),     # o Mac ainda esta ativando
    ("mac", False, False, 5, False, 61, "retomar"),    # o Mac vive mas nao le: o claim volta
    ("mac", False, False, 91, False, 0, "tomar"),      # o Mac sumiu (dormiu/desligou)
    ("mac", True, True, 91, False, 0, "tomar"),
])
def test_decidir_pc(claim, ativo, ocupado, idade, mac_ativo, parado, esperado):
    assert hosting.decidir_pc(claim, ativo, ocupado, idade, mac_ativo, parado) == esperado


class _PC:
    """O laco do PC com relogio falso e arquivos num tmp: o claim, a checagem do Mac, o host-state e o peer-yielded."""

    def __init__(self, monkeypatch, tmp_path, claim=None, ativo=False, ocupado=False):
        self.relogio = [1_800_000_000.0]
        monkeypatch.setattr(hosting, "HOST", "pc")
        monkeypatch.setattr(hosting, "time", types.SimpleNamespace(time=lambda: self.relogio[0],
                                                                  monotonic=lambda: self.relogio[0]))
        for nome, arq in (("DIR", ""), ("STATE", "host-state.json"), ("CLAIM", "reader-claim.json"),
                          ("MAC_VISTO", "mac-seen.json"), ("YIELDED", "peer-yielded")):
            monkeypatch.setattr(hosting, nome, tmp_path / arq if arq else tmp_path)
        self.tmp, self.ativacoes, self.paradas, self.soltas, self.ocupado = tmp_path, [], [], [], [ocupado]
        self.ao_dormir = None
        self.ocupa_ao_parar = False                   # um update ja lido vira handler logo depois do updater.stop
        self.religar_falha = 0                        # quantas chamadas de start_polling ainda levantam
        pc = self

        async def dorme(t):
            pc.relogio[0] += t
            if pc.ao_dormir:
                pc.ao_dormir()
        monkeypatch.setattr(hosting.asyncio, "sleep", dorme)

        class Updater:
            @staticmethod
            async def start_polling(**kw):
                if pc.religar_falha:
                    pc.religar_falha -= 1
                    raise OSError("rede")
                pc.ativacoes.append(pc.relogio[0])
            @staticmethod
            async def stop():
                pc.paradas.append(pc.relogio[0])
                if pc.ocupa_ao_parar:
                    pc.ocupado[0] = True

        class App:
            updater = Updater

        async def nada(_): pass
        async def soltar(): pc.soltas.append(pc.relogio[0])
        self.h = hosting.Hosting(App, nada, nada, ocupado=lambda: pc.ocupado[0], antes_de_soltar=soltar)
        if claim:
            hosting.gravar_claim(claim)
        if ativo:
            self.h.estado, self.h._precisa_grace = "active", False
        self.boot = self.relogio[0]

    def mac_checou(self, estado="standby"):
        p = self.tmp / "mac-seen.json"
        p.write_text(_json.dumps({"state": estado}))
        _os.utime(p, (self.relogio[0], self.relogio[0]))

    def passos(self, n=1, passo=1.0):
        async def roda():
            for _ in range(n):
                await self.h._passo_pc(self.boot)
                self.relogio[0] += passo
        asyncio.run(roda())

    def publicado(self):
        st = hosting.ler_estado_local()
        return hosting.interpretar_estado_pc(0, _json.dumps(st) + f"\n{int(self.relogio[0])}\n")


def test_pc_lendo_e_claim_do_mac_espera_o_turno_e_depois_solta(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="pc", ativo=True, ocupado=True)
    pc.mac_checou()
    hosting.gravar_claim("mac")                       # o Wisp do Mac pediu (ssh Mac->PC)
    pc.passos(3)
    assert pc.h.ativo and pc.paradas == [] and pc.soltas == []       # turno rodando: segue lendo
    assert pc.publicado() == "active"
    pc.ocupado[0] = False                             # o turno acabou
    pc.mac_checou()
    pc.passos(1)
    assert not pc.h.ativo and len(pc.paradas) == 1 and len(pc.soltas) == 1
    assert pc.publicado() == "cedeu"                  # o que o Mac le na checagem seguinte
    pc.mac_checou("active")
    pc.passos(30)
    assert not pc.h.ativo and pc.ativacoes == [] and hosting.ler_claim()["host"] == "mac"


def test_pc_turno_que_chega_durante_o_push_segura_a_soltura(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac", ativo=True)
    pc.mac_checou()

    async def soltar(): pc.ocupado[0] = True          # mensagem do celular chegou enquanto empurrava as notas
    pc.h.antes_de_soltar = soltar
    pc.passos(1)
    assert pc.h.ativo and pc.paradas == []


def test_pc_religar_falha_com_trabalho_chegando_nao_publica_standby_e_insiste(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac", ativo=True)
    pc.mac_checou()
    pc.religar_falha = 1
    pc.ocupa_ao_parar = True                          # chega trabalho durante o hand-off
    pc.passos(1)                                      # para o updater, ve ocupado, religar levanta
    assert pc.h.ativo and pc.publicado() == "active"  # nunca standby/cedeu: o Mac nao pode ler agora
    assert pc.ativacoes == [] and len(pc.paradas) == 1
    pc.mac_checou()
    pc.passos(1)                                      # proximo passo: religar de novo
    assert len(pc.ativacoes) == 1 and pc.h.ativo and pc.publicado() == "active"
    assert pc.h._sem_leitura is False and len(pc.paradas) == 1   # nao parou de novo


def test_pc_religar_falha_varias_vezes_segue_ativo_ate_conseguir(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac", ativo=True)
    pc.mac_checou()
    pc.religar_falha = 3
    pc.ocupa_ao_parar = True
    for _ in range(3):
        pc.passos(1)
        assert pc.h.ativo and pc.publicado() == "active" and pc.ativacoes == []
    pc.passos(1)
    assert len(pc.ativacoes) == 1 and pc.publicado() == "active"


def test_pc_em_standby_pelo_mac_e_claim_do_pc_volta_pelo_grace(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac")
    pc.h._precisa_grace = True
    pc.mac_checou("active")
    pc.passos(2)
    assert not pc.h.ativo and pc.publicado() == "cedeu"
    hosting.gravar_claim("pc")                        # o Wisp do PC pediu

    def mac_cede():                                   # o Mac ve o grace e grava peer-yielded
        if hosting.ler_estado_local().get("state") == "grace":
            (tmp_path / "peer-yielded").touch()
    pc.ao_dormir = mac_cede
    pc.passos(1)
    assert pc.h.ativo and len(pc.ativacoes) == 1
    assert pc.ativacoes[0] - pc.relogio[0] < 5        # nao esperou o grace inteiro


def test_pc_reboot_mantem_o_claim_do_mac(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac")
    p = tmp_path / "mac-seen.json"
    p.write_text('{"state": "active"}')
    _os.utime(p, (pc.relogio[0] - 600, pc.relogio[0] - 600))   # o PC ficou 10 min desligado
    pc.passos(int(hosting.GRACE_S) + 10)
    assert not pc.h.ativo and pc.ativacoes == [] and pc.publicado() == "cedeu"
    pc.mac_checou("active")                           # o Mac segue checando: o PC nunca le
    pc.passos(int(hosting.MAC_FRESCO_S))
    pc.mac_checou("active")
    pc.passos(int(hosting.MAC_FRESCO_S))
    assert pc.ativacoes == [] and hosting.ler_claim()["host"] == "mac"


def test_pc_mac_sumiu_o_claim_volta_e_le_sem_grace(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac")
    pc.mac_checou("active")
    pc.passos(int(hosting.MAC_FRESCO_S) + 2)          # o Mac fechou a tampa: nenhuma checagem mais
    assert pc.h.ativo and len(pc.ativacoes) == 1 and hosting.ler_claim()["host"] == "pc"
    pc.mac_checou("standby")                          # o Mac acorda: o claim ja e do PC, nada de flapping
    pc.passos(30)
    assert pc.h.ativo and pc.paradas == []


def test_pc_mac_vivo_sem_ler_retoma_pelo_grace(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac")
    pc.h._precisa_grace = True
    for _ in range(int(hosting.MAC_ESPERA_S) + 5):    # o Mac checa (409 recente) mas nao le
        pc.mac_checou("standby")
        pc.passos(1)
        if pc.h.ativo:
            break
    assert pc.h.ativo and hosting.ler_claim()["host"] == "pc"


def test_pc_grace_abortado_pelo_claim_do_mac(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path)
    pc.mac_checou("active")
    n = [0]

    def wisp_do_mac():
        n[0] += 1
        if n[0] == 3:
            hosting.gravar_claim("mac")
    pc.ao_dormir = wisp_do_mac
    pc.passos(1)
    assert not pc.h.ativo and pc.ativacoes == []
    pc.ao_dormir = None
    pc.mac_checou("active")
    pc.passos(5)
    assert not pc.h.ativo and pc.publicado() == "cedeu"


def test_pc_sem_claim_le_depois_do_grace_como_antes(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path)
    pc.passos(1)
    assert pc.h.ativo and len(pc.ativacoes) == 1
    assert pc.ativacoes[0] - pc.boot >= hosting.GRACE_S


def test_pc_ativacao_falhou_insiste_a_cada_batida(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path)
    tentativas = []

    class Updater:
        @staticmethod
        async def start_polling(**kw):
            tentativas.append(pc.relogio[0])
            raise RuntimeError("rede fora")
    pc.h.app = types.SimpleNamespace(updater=Updater)
    pc.passos(12)
    assert not pc.h.ativo and hosting.ler_estado_local()["state"] == "grace"
    assert 2 <= len(tentativas) <= 4                  # o grace, depois a cada BATIDA_S (nao a cada segundo)


def test_409_no_pc_nao_cede_mesmo_com_claim_do_mac(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac", ativo=True, ocupado=True)
    pc.h.conflito()
    assert pc.h.ativo and pc.h._cessao is None


# ---- fix round 1 (17/11): achados da revisao do A3 ----

from wisp_bot import topicos as _topicos


def _sync_falso(tmp_path, marca, corpo):
    exe = tmp_path / "brain-sync"
    exe.write_text(f"#!/bin/bash\n{corpo}\n: {marca}\n")
    exe.chmod(0o755)
    return str(exe)


def _sobra(marca):
    return _subprocess.run(["pgrep", "-f", marca], capture_output=True, text=True).stdout.strip()


def test_sync_no_estouro_mata_o_grupo_inteiro(monkeypatch, tmp_path):
    marca = f"wisp-sync-{time.time_ns()}"
    filho = tmp_path / f"{marca}-git"
    filho.write_text("#!/bin/bash\nsleep 30\n")
    filho.chmod(0o755)
    monkeypatch.setattr(_topicos, "SYNC", [_sync_falso(tmp_path, marca, f"{filho} &\nwait")])
    t0 = time.monotonic()
    assert asyncio.run(_topicos.push_agora(0.5)) is False
    assert time.monotonic() - t0 < 5
    time.sleep(0.2)
    assert _sobra(marca) == ""                         # o "git" filho do brain-sync nao sobrevive


def test_sync_cancelado_mata_o_grupo_inteiro(monkeypatch, tmp_path):
    marca = f"wisp-sync-c-{time.time_ns()}"
    filho = tmp_path / f"{marca}-git"
    filho.write_text("#!/bin/bash\nsleep 30\n")
    filho.chmod(0o755)
    monkeypatch.setattr(_topicos, "SYNC", [_sync_falso(tmp_path, marca, f"{filho} &\nwait")])

    async def cenario():
        t = asyncio.ensure_future(_topicos.push_agora(30))
        await asyncio.sleep(0.3)
        t.cancel()
        await asyncio.gather(t, return_exceptions=True)
    asyncio.run(cenario())
    time.sleep(0.2)
    assert _sobra(marca) == ""


from wisp_bot import sessao as _sessao
import base64 as _base64
import threading as _threading


def _pc_que_serve(tmp_path, monkeypatch, conteudo: bytes, pausa: float = 0.02):
    """pc_argv = um bash local que serve `conteudo` como o script do buscar_do_pc, devagar (linha a linha)."""
    import hashlib
    b64 = _base64.encodebytes(conteudo).decode().split()
    corpo = "".join(f"echo {l}; sleep {pausa}\n" for l in b64)
    exe = tmp_path / "pc-falso"
    exe.write_text(f"#!/bin/bash\ncat > /dev/null\n{corpo}echo SHA:{hashlib.sha256(conteudo).hexdigest()}\n")
    exe.chmod(0o755)
    monkeypatch.setattr(_sessao.hosting, "pc_argv", lambda *a, **k: [str(exe)])
    monkeypatch.setattr(_sessao, "PROJETOS", tmp_path / "projects")


def test_buscar_do_pc_dois_ao_mesmo_tempo_nao_embaralham(tmp_path, monkeypatch):
    conteudo = b"".join(b'{"linha": %d, "texto": "%s"}\n' % (i, b"x" * 40) for i in range(60))
    _pc_que_serve(tmp_path, monkeypatch, conteudo)
    erros = []

    def busca():
        try:
            _sessao.buscar_do_pc(SID_FIX, str(tmp_path / "cwd"))
        except Exception as e:
            erros.append(e)
    ts = [_threading.Thread(target=busca) for _ in range(2)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(30)
    assert erros == []
    assert _sessao.caminho(SID_FIX, str(tmp_path / "cwd")).read_bytes() == conteudo
    assert list((tmp_path / "projects").glob("*/*.tmp")) == []


SID_FIX = "aaaaaaaa-2222-4333-8444-555555555555"


def test_buscar_do_pc_no_estouro_mata_o_grupo(tmp_path, monkeypatch):
    marca = f"wisp-buscar-{time.time_ns()}"
    filho = tmp_path / f"{marca}-ssh"
    filho.write_text("#!/bin/bash\nsleep 30\n")
    filho.chmod(0o755)
    exe = tmp_path / "pc-lento"
    exe.write_text(f"#!/bin/bash\ncat > /dev/null\n{filho} &\nwait\n")
    exe.chmod(0o755)
    monkeypatch.setattr(_sessao.hosting, "pc_argv", lambda *a, **k: [str(exe)])
    monkeypatch.setattr(_sessao, "PROJETOS", tmp_path / "projects")
    t0 = time.monotonic()
    with pytest.raises(RuntimeError):
        _sessao.buscar_do_pc(SID_FIX, str(tmp_path / "cwd"), timeout_s=0.5)
    assert time.monotonic() - t0 < 5
    time.sleep(0.2)
    assert _sobra(marca) == ""


def test_pc_trabalho_que_chega_depois_do_stop_religa_e_nunca_publica_cedeu(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac", ativo=True)
    pc.mac_checou()
    publicados = []
    real = hosting.gravar_estado
    monkeypatch.setattr(hosting, "gravar_estado", lambda e, extra=None: (publicados.append(e), real(e, extra)))

    class Updater:
        @staticmethod
        async def start_polling(**kw): pc.ativacoes.append(pc.relogio[0])
        @staticmethod
        async def stop():
            pc.paradas.append(pc.relogio[0])
            pc.ocupado[0] = True                       # um update ja lido virou turno (anexo, pedido da fila)
    pc.h.app = types.SimpleNamespace(updater=Updater)
    pc.passos(1)
    assert pc.h.ativo and len(pc.paradas) == 1 and len(pc.ativacoes) == 1   # parou, viu o turno, religou
    assert "standby" not in publicados and pc.publicado() == "active"


def test_pc_soltando_espera_a_fila_de_updates_esvaziar(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac", ativo=True)
    pc.mac_checou()
    fila = asyncio.Queue()

    class Updater:
        @staticmethod
        async def start_polling(**kw): pc.ativacoes.append(pc.relogio[0])
        @staticmethod
        async def stop():
            fila.put_nowait("update")                 # o ultimo getUpdates trouxe uma mensagem
    pc.h.app = types.SimpleNamespace(updater=Updater, update_queue=fila)

    def handler():                                    # o PTB tira da fila e o handler conta o turno
        if not fila.empty():
            fila.get_nowait()
            pc.ocupado[0] = True
    pc.ao_dormir = handler
    pc.passos(1)
    assert pc.h.ativo and len(pc.ativacoes) == 1


def test_pc_nao_solta_para_mac_bloqueado_e_retoma_se_ja_soltou(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac", ativo=True)
    pc.mac_checou("bloqueado")                        # o Mac levou 409 ha pouco: nao pode ler
    pc.passos(5)
    assert pc.h.ativo and pc.paradas == [] and hosting.ler_claim()["host"] == "mac"
    (tmp_path / "b").mkdir()
    pc2 = _PC(monkeypatch, tmp_path / "b", claim="mac")
    pc2.h._precisa_grace = True
    pc2.mac_checou("bloqueado")
    pc2.passos(1)
    assert pc2.h.ativo and hosting.ler_claim()["host"] == "pc"   # PC em standby: o claim volta e le ja


def test_script_estado_pc_grava_mac_bloqueado(tmp_path):
    d = tmp_path / hosting.DIR_REMOTO_REL
    d.mkdir(parents=True)
    assert _bash(hosting.script_estado_pc("bloqueado"), tmp_path).returncode == 0
    assert hosting.ler_mac_visto(d / "mac-seen.json")[1] == "bloqueado"


def test_mac_bloqueado_manda_bloqueado_na_checagem_e_publica_o_fim(monkeypatch):
    _, _, h, _, _ = _mac_com_leituras(monkeypatch, ["down"], bloqueado=True)
    assert h.checagens_teste == [("bloqueado", None)]           # o PC fica sabendo que o Mac nao pode ler
    estado, extra = h.publicados_teste[-1]
    assert estado == "standby" and extra["bloqueado_ate"] > time.time()   # a CLI recusa na hora
    _, _, h, _, _ = _mac_com_leituras(monkeypatch, ["down"])
    assert h.checagens_teste == [("standby", None)]


def test_pc_tomar_nao_atropela_claim_novo_do_mac(monkeypatch, tmp_path):
    pc = _PC(monkeypatch, tmp_path, claim="mac")
    pc.mac_checou("active")
    pc.relogio[0] += hosting.MAC_FRESCO_S + 5          # o Mac sumiu...
    real = hosting.ler_mac_visto
    n = [0]

    def visto(path=None):                             # ...e o Wisp do Mac grava um claim novo no meio da volta
        n[0] += 1
        r = real(path)
        if n[0] == 1:
            pc.relogio[0] += 1
            hosting.gravar_claim("mac")
        return r
    monkeypatch.setattr(hosting, "ler_mac_visto", visto)
    asyncio.run(pc.h._passo_pc(pc.boot))
    assert hosting.ler_claim()["host"] == "mac" and not pc.h.ativo


def test_claim_lido_so_de_host_state_fresco():
    assert hosting.claim_lido(0, _estado_com_claim("standby", "mac")) == "mac"
    assert hosting.claim_lido(0, _estado_com_claim("active", None)) == "none"
    assert hosting.claim_lido(0, _estado_com_claim("standby", "pc", ts=900)) is None
    assert hosting.claim_lido(255, "") is None


def test_script_entregar_claim_respeita_claim_mais_novo_do_pc(tmp_path):
    d = tmp_path / hosting.DIR_REMOTO_REL
    d.mkdir(parents=True)
    f = d / "reader-claim.json"
    f.write_text(_json.dumps({"host": "pc", "ts": int(time.time()) - 600}))
    assert _bash(hosting.script_entregar_claim(60), tmp_path).returncode == 0
    c = hosting.ler_claim(f)
    assert c["host"] == "mac" and abs(c["ts"] - (time.time() - 60)) < 5      # datado de quando o Wisp pediu
    f.write_text(_json.dumps({"host": "pc", "ts": int(time.time()) - 10}))   # o Wisp do PC pediu depois
    _bash(hosting.script_entregar_claim(60), tmp_path)
    assert hosting.ler_claim(f)["host"] == "pc"
    f.unlink()
    _bash(hosting.script_entregar_claim(0), tmp_path)
    assert hosting.ler_claim(f)["host"] == "mac"


def test_mac_entrega_o_claim_pendente_e_nao_cede_ao_grace_lido_antes(monkeypatch, tmp_path):
    monkeypatch.setattr(hosting, "CLAIM_PENDENTE", tmp_path / "claim-pendente.json")
    _, _, h, _, cedidos = _mac_com_leituras(monkeypatch, ["grace"], ativo=True)
    assert cedidos == [1] and not h.ativo              # sem claim pendente: cede ao grace como sempre
    hosting.gravar_claim_pendente()
    _, _, h, _, cedidos = _mac_com_leituras(monkeypatch, ["grace"], ativo=True,
                                            lido_extra={"claim": "pc", "entregue": True})
    assert cedidos == [] and h.ativo                   # o PC bootou no grace; o claim do Wisp acabou de chegar la
    assert h.checagens_teste[0][1] is not None
    assert hosting.idade_claim_pendente() is None      # entregue: sai do Mac


def test_mac_publica_o_claim_lido_do_pc(monkeypatch):
    _, _, h, _, _ = _mac_com_leituras(monkeypatch, ["cedeu"], lido_extra={"claim": "mac"})
    assert h.publicados_teste[-1][1]["claim_pc"] == "mac"


from wisp_bot import bot as _bot

SID_BOT = "bbbbbbbb-2222-4333-8444-555555555555"


def test_turno_rodando_conta_anexo_na_janela(monkeypatch):
    monkeypatch.setattr(_bot, "_anexos_pendentes", {})
    monkeypatch.setattr(_bot, "_turnos_mac", {})
    monkeypatch.setattr(_bot, "_locks", {})
    assert _bot._turno_rodando() is False
    _bot._anexos_pendentes["-1:9"] = {"itens": ["- a.jpg"]}
    assert _bot._turno_rodando() is True              # o turno nasce em 3 s: o PC nao pode soltar agora


def test_turno_rodando_conta_pedido_da_fila_e_handler_em_curso(monkeypatch):
    monkeypatch.setattr(_bot, "_anexos_pendentes", {})
    monkeypatch.setattr(_bot, "_turnos_mac", {})
    monkeypatch.setattr(_bot, "_locks", {})

    async def cenario():
        solta = asyncio.Event()

        async def pedido(): await solta.wait()
        t = _bot._disparar(pedido())
        assert _bot._turno_rodando() is True          # contado ja no disparo, antes de a task rodar
        solta.set()
        await t
        await asyncio.sleep(0)
        assert _bot._turno_rodando() is False

        entrou, sai = asyncio.Event(), asyncio.Event()

        async def handler(update, ctx):
            entrou.set()
            await sai.wait()
        h = asyncio.ensure_future(_bot._contado(handler)(None, None))
        await entrou.wait()
        assert _bot._turno_rodando() is True          # update ja lido, handler ainda antes do turno
        sai.set()
        await h
        assert _bot._turno_rodando() is False
    asyncio.run(cenario())


def _zerar_bot(monkeypatch):
    monkeypatch.setattr(_bot, "_anexos_pendentes", {})
    monkeypatch.setattr(_bot, "_turnos_mac", {})
    monkeypatch.setattr(_bot, "_locks", {})
    monkeypatch.setattr(_bot, "_em_curso", 0)


def test_abrir_topico_conta_o_primeiro_turno_desde_o_disparo(monkeypatch):
    _zerar_bot(monkeypatch)
    soltar, vistos = asyncio.Event(), []

    class Bot:
        async def create_forum_topic(self, chat_id, name): return types.SimpleNamespace(message_thread_id=7)

    async def send(*a, **k): pass

    async def turno(*a, **k):
        await soltar.wait()
    monkeypatch.setattr(_bot, "send", send)
    monkeypatch.setattr(_bot, "turno", turno)
    monkeypatch.setattr(_bot.store, "get_or_create", lambda *a, **k: None)
    monkeypatch.setattr(_bot.topicos, "garantir", lambda *a, **k: None)
    monkeypatch.setattr(_bot.topicos, "push_logo", lambda: None)

    async def cenario():
        await _bot.abrir_topico(Bot(), -1, "x", "/tmp", "faz algo")
        vistos.append(_bot._turno_rodando())          # a task ainda nem rodou
        soltar.set()
        for _ in range(5):
            await asyncio.sleep(0)
        vistos.append(_bot._turno_rodando())
    asyncio.run(cenario())
    assert vistos == [True, False]


def test_encerrar_conta_o_fechar_desde_o_disparo(monkeypatch):
    _zerar_bot(monkeypatch)
    soltar, vistos = asyncio.Event(), []

    async def fechar(*a, **k):
        await soltar.wait()

    async def reply(*a, **k): pass
    monkeypatch.setattr(_bot, "fechar", fechar)
    monkeypatch.setattr(_bot, "reply", reply)
    monkeypatch.setattr(_bot, "topic_key", lambda u: ("-1:9", 9))
    monkeypatch.setattr(_bot, "topico_local", lambda k: types.SimpleNamespace(started=False, turns=0))
    upd = types.SimpleNamespace(effective_chat=types.SimpleNamespace(id=-1))

    async def cenario():
        await _bot.encerrar(upd, types.SimpleNamespace(bot=None))
        vistos.append(_bot._turno_rodando())
        soltar.set()
        for _ in range(5):
            await asyncio.sleep(0)
        vistos.append(_bot._turno_rodando())
    asyncio.run(cenario())
    assert vistos == [True, False]


def _ctl_trazer(monkeypatch, segurar_lock: bool):
    monkeypatch.setattr(_bot, "HOST", "mac")
    monkeypatch.setattr(_bot, "_locks", {})
    monkeypatch.setattr(_bot, "_key_da_thread", lambda thread: f"-1:{thread}")
    vistos, feitos = [], {}

    def trazer(sid, cwd, prazo):
        vistos.append((sid, prazo, _bot.lock_for("-1:9").locked()))
        return "trazida"
    monkeypatch.setattr(_bot.sessao, "trazer_se_maior", trazer)
    monkeypatch.setattr(_bot.ctl, "gravar_done", lambda id_, res: feitos.update({id_: res}))

    async def cenario():
        lk = _bot.lock_for("-1:9")
        if segurar_lock:
            await lk.acquire()
        await _bot.ctl_executar(types.SimpleNamespace(bot=None), {"id": "abc", "op": "trazer", "thread": 9,
                                                                  "session_id": SID_BOT, "cwd": "/nao/existe",
                                                                  "prazo": 30, "at": time.time()}, "local")
    asyncio.run(cenario())
    return vistos, feitos["abc"]


def test_ctl_trazer_puxa_sob_o_lock_do_topico(monkeypatch):
    vistos, res = _ctl_trazer(monkeypatch, False)
    assert res == {"ok": True, "session": "trazida"}
    assert vistos == [(SID_BOT, 30, True)]            # o pull roda com o lock do topico seguro


def test_ctl_trazer_com_turno_no_topico_nao_puxa_junto(monkeypatch):
    vistos, res = _ctl_trazer(monkeypatch, True)
    assert res == {"ok": True, "session": "local"} and vistos == []   # o turno em curso ja alinha a sessao


def test_ctl_falar_no_geral_posta_sem_message_thread_id(monkeypatch):
    """Geral e a thread 0 na chave, mas o Telegram recusa message_thread_id=0: vai None, como no on_message."""
    monkeypatch.setattr(_bot, "_key_da_thread", lambda thread: f"-1:{thread}")
    enviados, turnos, feitos = [], [], {}

    async def send(bot, chat, tid, texto):
        enviados.append(tid)

    async def turno(bot, chat, tid, key, texto, contexto=""):
        turnos.append((tid, key))
    monkeypatch.setattr(_bot, "send", send)
    monkeypatch.setattr(_bot, "turno", turno)
    monkeypatch.setattr(_bot.ctl, "gravar_done", lambda id_, res: feitos.update({id_: res}))

    async def cenario():
        await _bot.ctl_executar(types.SimpleNamespace(bot=None), {"id": "g", "op": "falar", "thread": "0",
                                                                  "texto": "oi", "at": time.time()}, "local")
        await asyncio.sleep(0)
    asyncio.run(cenario())
    assert feitos["g"] == {"ok": True, "thread_id": 0}
    assert enviados == [None] and turnos == [(None, "-1:0")]
