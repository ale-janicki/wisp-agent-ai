import asyncio
import stat

from wisp_bot import colheita


def _fake_wisp(tmp_path, corpo):
    f = tmp_path / "wisp"
    f.write_text("#!/bin/sh\n" + corpo + "\n")
    f.chmod(f.stat().st_mode | stat.S_IXUSR)
    return str(f)


def test_contagens():
    assert colheita.contagens(b'{"colhidas": ["a"], "puladas": [{}, {}]}') == (1, 2)
    assert colheita.contagens(b"lixo") is None
    assert colheita.contagens(b"{}") is None


def test_rodar_uma_vez_passa_os_argumentos_e_conta(tmp_path):
    log = tmp_path / "args"
    wisp = _fake_wisp(tmp_path, f'echo "$@" > {log}\necho \'{{"colhidas": [], "puladas": [{{"sid": "-"}}]}}\'')
    assert asyncio.run(colheita.rodar_uma_vez(wisp)) == (0, 1)
    assert log.read_text().strip() == "brain colher --if-due --json"


def test_saida_nao_zero_vira_none(tmp_path):
    assert asyncio.run(colheita.rodar_uma_vez(_fake_wisp(tmp_path, "exit 3"))) is None


def test_timeout_mata_o_grupo(tmp_path):
    wisp = _fake_wisp(tmp_path, "sleep 30")

    async def go():
        try:
            await colheita.rodar_uma_vez(wisp, timeout=0.3)
        except asyncio.TimeoutError:
            return True

    assert asyncio.run(go())


def test_vigiar_cancela_limpo(tmp_path):
    async def go():
        parar = asyncio.Event()
        t = asyncio.create_task(colheita.vigiar(parar, _fake_wisp(tmp_path, "echo '{}'"), intervalo=5, primeira=0))
        await asyncio.sleep(0.3)
        t.cancel()
        try:
            await t
        except asyncio.CancelledError:
            return True

    assert asyncio.run(go())
