"""Parsing com saida real do pmset/ioreg (capturada neste Mac); lock com caffeinate real."""
import subprocess, sys
import pytest

from wisp_bot import vigilia

# capturas reais (23/10/2026); a de DarkWake e o formato do pmset sem a capacidade Graphics
FULL = "Current System Capabilities are: CPU Graphics Audio Network \nCurrent Power State: 4\n"
DARK = "Current System Capabilities are: CPU Audio Network \nCurrent Power State: 2\n"
PS_BAT = ("Now drawing from 'Battery Power'\n"
          " -InternalBattery-0 (id=1)\t60%; discharging; 6:06 remaining present: true\n")
PS_AC = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t60%; charging; present: true\n"
IO_ABERTA = '  |   "AppleClamshellCausesSleep" = No\n  |   "AppleClamshellState" = No\n'
IO_FECHADA = '  |   "AppleClamshellCausesSleep" = Yes\n  |   "AppleClamshellState" = Yes\n'


def test_parse_acordado():
    assert vigilia.parse_acordado(FULL) and not vigilia.parse_acordado(DARK)


def test_parse_tampa_e_tomada():
    assert vigilia.parse_tampa_fechada(IO_FECHADA) and not vigilia.parse_tampa_fechada(IO_ABERTA)
    assert vigilia.parse_na_tomada(PS_AC) and not vigilia.parse_na_tomada(PS_BAT)


def test_pode_segurar():
    assert not vigilia.pode_segurar({"acordado": True, "tampa_fechada": True, "tomada": False})
    assert vigilia.pode_segurar({"acordado": True, "tampa_fechada": True, "tomada": True})
    assert vigilia.pode_segurar({"acordado": True, "tampa_fechada": False, "tomada": False})


@pytest.mark.skipif(sys.platform != "darwin", reason="caffeinate so no Mac")
def test_segurar_e_soltar_reais():
    vigilia.segurar("t:1")
    pid = vigilia._caf["t:1"].pid
    vigilia.segurar("t:1")                          # idempotente
    assert vigilia._caf["t:1"].pid == pid

    def tem():
        out = subprocess.run(["pmset", "-g", "assertions"], capture_output=True, text=True).stdout
        return any(f"pid {pid}(caffeinate)" in l for l in out.splitlines())
    import time
    time.sleep(0.5)
    assert tem()
    vigilia.soltar("t:1")
    time.sleep(0.5)
    assert not tem()


@pytest.mark.skipif(sys.platform != "darwin", reason="caffeinate so no Mac")
def test_timer_so_apos_o_ultimo_turno_e_nova_mensagem_cancela():
    import asyncio

    async def roda():
        # mesmo contrato de sessao.contar_turno/soltar_turno (sessao importa telegram: fora do pytest do sistema)
        cont = {"t:timer": 2}                       # turno A rodando + turno B na fila
        k = "t:timer"

        def soltar_turno(c, key):
            c[key] -= 1
            return c[key] <= 0
        vigilia.segurar(k)
        if soltar_turno(cont, k):            # A termina com B pendente: nao agenda
            vigilia.agendar_soltura(k, 0.2)
        await asyncio.sleep(0.4)
        assert k in vigilia._caf and vigilia._caf[k].poll() is None
        if soltar_turno(cont, k):            # B e o ultimo: agenda
            vigilia.agendar_soltura(k, 0.2)
        assert k in vigilia._timers
        vigilia.segurar(k)                          # nova mensagem antes do fim cancela
        await asyncio.sleep(0.4)
        assert k in vigilia._caf and k not in vigilia._timers
        vigilia.agendar_soltura(k, 0.1)
        await asyncio.sleep(0.4)
        assert k not in vigilia._caf and k not in vigilia._timers

    asyncio.run(roda())


@pytest.mark.skipif(sys.platform != "darwin", reason="pmset so no Mac")
def test_estado_e_acordar_nao_bloqueiam_o_loop():
    import asyncio

    async def roda():
        ticks = 0

        async def bate():
            nonlocal ticks
            while True:
                await asyncio.sleep(0.01)
                ticks += 1
        t = asyncio.create_task(bate())
        est = await vigilia.estado()
        assert set(est) == {"acordado", "tampa_fechada", "tomada"}
        await vigilia.acordar()
        await asyncio.sleep(0.05)
        t.cancel()
        assert ticks > 0

    asyncio.run(roda())
