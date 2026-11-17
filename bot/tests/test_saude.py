"""Testes do canario de saude: decisao com arquivo real e checks injetados."""
import asyncio
import os

from wisp_bot import saude


class FakeBot:
    def __init__(self, falha=False):
        self.msgs, self.falha = [], falha

    async def enviar(self, texto):
        if self.falha:
            raise OSError("rede fora")
        self.msgs.append(texto)


def _rodar(erro, bot, arquivo):
    parar = asyncio.Event()
    asyncio.run(saude.decidir(erro, bot.enviar, parar, arquivo))
    return parar


def test_passando_zera_contador(tmp_path):
    f = tmp_path / "saude.json"
    bot = FakeBot()
    _rodar("boom", bot, f)
    assert saude.ler(f)["falhas_seguidas"] == 1
    parar = _rodar(None, bot, f)
    assert saude.ler(f)["falhas_seguidas"] == 0
    assert not parar.is_set()


def test_primeira_falha_desliga_sem_alerta(tmp_path):
    f, bot = tmp_path / "saude.json", FakeBot()
    parar = _rodar("boom", bot, f)
    assert parar.is_set() and bot.msgs == []
    assert saude.ler(f)["ultimo_erro"] == "boom"


def test_segunda_falha_seguida_alerta_uma_vez_e_fica_de_pe(tmp_path):
    f, bot = tmp_path / "saude.json", FakeBot()
    _rodar("boom", bot, f)
    parar = _rodar("boom", bot, f)
    assert not parar.is_set() and len(bot.msgs) == 1
    assert "mesmo depois de reiniciar: boom" in bot.msgs[0]
    assert saude.ler(f)["alertado"] is True


def test_ja_alertado_nao_alerta_nem_desliga(tmp_path):
    f, bot = tmp_path / "saude.json", FakeBot()
    for _ in range(4):
        parar = _rodar("boom", bot, f)
    assert len(bot.msgs) == 1 and not parar.is_set()
    assert saude.ler(f)["falhas_seguidas"] == 4


def test_passar_zera_e_reabilita_o_alerta(tmp_path):
    f, bot = tmp_path / "saude.json", FakeBot()
    for _ in range(2):
        _rodar("boom", bot, f)
    _rodar(None, bot, f)
    d = saude.ler(f)
    assert d["falhas_seguidas"] == 0 and d["alertado"] is False
    for _ in range(2):
        _rodar("boom", bot, f)
    assert len(bot.msgs) == 2


def test_alerta_com_rede_fora_nao_quebra_e_ainda_reinicia(tmp_path):
    f, bot = tmp_path / "saude.json", FakeBot(falha=True)
    _rodar("boom", bot, f)
    parar = _rodar("boom", bot, f)
    assert parar.is_set() and saude.ler(f)["alertado"] is False


def test_alerta_pendurado_estoura_em_10s_e_reinicia(tmp_path, monkeypatch):
    monkeypatch.setattr(saude, "ALERTA_S", 0.05)
    f = tmp_path / "saude.json"

    async def pendurado(texto):
        await asyncio.sleep(30)

    _rodar("boom", FakeBot(), f)
    parar = asyncio.Event()
    asyncio.run(saude.decidir("boom", pendurado, parar, f))
    assert parar.is_set()


def test_claude_uma_falha_nao_reinicia_duas_seguidas_sim(tmp_path):
    f, bot = tmp_path / "saude.json", FakeBot()
    erro = "claude: --version saiu 124"
    assert not _rodar(erro, bot, f).is_set()
    assert saude.ler(f)["claude_falhas"] == 1
    assert _rodar(erro, bot, f).is_set()


def test_claude_passando_no_meio_zera_a_contagem(tmp_path):
    f, bot = tmp_path / "saude.json", FakeBot()
    erro = "claude: --version saiu 1"
    _rodar(erro, bot, f)
    _rodar(None, bot, f)
    assert saude.ler(f)["claude_falhas"] == 0
    assert not _rodar(erro, bot, f).is_set()


def test_interprete_trocado_reinicia_mas_so_a_cada_30min(tmp_path):
    f, bot = tmp_path / "saude.json", FakeBot()
    erro = "interprete: /x sumiu"
    assert _rodar(erro, bot, f).is_set() and bot.msgs == []
    parar = _rodar(erro, bot, f)           # reinicio recente: avisa e fica de pe
    assert not parar.is_set() and len(bot.msgs) == 1
    assert not _rodar(erro, bot, f).is_set() and len(bot.msgs) == 1
    d = saude.ler(f)
    d["ts_interp"] -= saude.REINICIO_INTERPRETE_S + 5
    saude._gravar(d, f)
    assert _rodar(erro, bot, f).is_set()


def test_caminhos_intactos_passam(tmp_path):
    alvo = tmp_path / "py-3.14.1"
    alvo.mkdir()
    link = tmp_path / "cpython-3.14"
    link.symlink_to(alvo)
    assert saude.verificar_caminhos({str(link): os.path.realpath(link)}) is None


def test_caminho_removido_falha(tmp_path):
    alvo = tmp_path / "lib"
    alvo.mkdir()
    reg = {str(alvo): os.path.realpath(alvo)}
    alvo.rmdir()
    assert "sumiu" in saude.verificar_caminhos(reg)


def test_symlink_reapontado_falha(tmp_path):
    velho, novo = tmp_path / "py-3.14.1", tmp_path / "py-3.14.2"
    velho.mkdir()
    novo.mkdir()
    link = tmp_path / "cpython-3.14"
    link.symlink_to(velho)
    reg = {str(link): os.path.realpath(link)}
    link.unlink()
    link.symlink_to(novo)
    erro = saude.verificar_caminhos(reg)
    assert erro and "agora aponta" in erro and str(link) in erro


def test_retry_absorve_falha_unica():
    chamadas = []

    async def instavel():
        chamadas.append(1)
        return "blip" if len(chamadas) == 1 else None

    assert asyncio.run(saude.checar_com_retry((instavel,), retry_s=0)) is None
    assert len(chamadas) == 2


def test_retry_confirma_falha_persistente():
    async def ruim():
        return "morto"

    assert asyncio.run(saude.checar_com_retry((ruim,), retry_s=0)) == "morto"


def test_checks_reais_passam_neste_processo():
    assert asyncio.run(saude.checar_interprete()) is None
