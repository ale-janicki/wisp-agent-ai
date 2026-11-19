import json
from pathlib import Path

import pytest

from wisp_bot import bot as _bot


@pytest.fixture
def casa(tmp_path, monkeypatch):
    home = tmp_path.resolve()
    monkeypatch.setenv("HOME", str(home))
    (home / ".ssh").mkdir()
    (home / ".ssh" / "id_ed25519").write_text("k")
    (home / ".config" / "wisp").mkdir(parents=True)
    (home / ".config" / "wisp" / "wisp.json").write_text("{}")
    (home / "ok.txt").write_text("ok")
    return home


def test_arquivo_comum_passa(casa):
    assert [p for p, _ in _bot.arquivos_validos([str(casa / "ok.txt")])] == [casa / "ok.txt"]


@pytest.mark.parametrize("rel", [".ssh/id_ed25519", ".SSH/id_ed25519", ".Ssh/id_ed25519",
                                 ".Config/wisp/wisp.json", ".config/WISP/wisp.json", ".CONFIG/Wisp/wisp.json"])
def test_negados_ignora_maiusculas(casa, rel):
    with pytest.raises(ValueError, match="protegida"):
        _bot.arquivos_validos([str(casa / rel)])


def test_negado_por_symlink(casa):
    (casa / "atalho").symlink_to(casa / ".ssh")
    with pytest.raises(ValueError, match="protegida"):
        _bot.arquivos_validos([str(casa / "atalho" / "id_ed25519")])


CONTRATO = json.loads((Path(__file__).resolve().parents[2] / "cli/tests/fixtures/contract/send-denylist.json").read_text())


def test_listas_iguais_ao_contrato():
    assert list(_bot.NEGADOS_NOMES) == CONTRATO["names"]
    assert list(_bot.NEGADOS_GLOBS) == CONTRATO["globs"]
    assert list(_bot.NEGADOS_PASTAS) == CONTRATO["dirs"]
    assert _bot.NEGADOS_MARCADOR == CONTRATO["content_marker"].encode()
    assert _bot.NEGADOS_BYTES == CONTRATO["content_bytes"]


ARQUIVOS = CONTRATO["names"] + [g.replace("*", "x") for g in CONTRATO["globs"]]


@pytest.mark.parametrize("nome", ARQUIVOS)
def test_nome_negado_em_qualquer_pasta(casa, nome):
    (casa / "docs").mkdir()
    for variante in (nome, nome.upper(), nome.title()):
        alvo = casa / "docs" / variante
        alvo.write_text("s")
        with pytest.raises(ValueError, match="protegida"):
            _bot.arquivos_validos([str(alvo)])


@pytest.mark.parametrize("nome", ARQUIVOS)
def test_symlink_para_arquivo_negado(casa, nome):
    (casa / "cofre").mkdir()
    (casa / "cofre" / nome).write_text("s")
    (casa / "foto.txt").symlink_to(casa / "cofre" / nome)
    with pytest.raises(ValueError, match="protegida"):
        _bot.arquivos_validos([str(casa / "foto.txt")])


@pytest.mark.parametrize("pasta", CONTRATO["dirs"])
def test_pasta_negada_ignora_maiusculas(casa, pasta):
    alvo = casa / pasta
    alvo.mkdir(parents=True, exist_ok=True)
    (alvo / "dado.txt").write_text("s")
    for variante in (pasta, pasta.upper(), pasta.title()):
        with pytest.raises(ValueError, match="protegida"):
            _bot.arquivos_validos([str(casa / variante / "dado.txt")])


@pytest.mark.parametrize("nome", ["envio.txt", "my.env.txt", "chave.keyx", "pem.txt", "x_id_rsa.txt"])
def test_nomes_parecidos_passam(casa, nome):
    (casa / nome).write_text("ok")
    assert [p for p, _ in _bot.arquivos_validos([str(casa / nome)])] == [casa / nome]


def test_deck_key_zip_passa(casa):
    (casa / "deck.key").write_bytes(b"PK\x03\x04" + b"junk" * 100)
    assert [p for p, _ in _bot.arquivos_validos([str(casa / "deck.key")])] == [casa / "deck.key"]


@pytest.mark.parametrize("nome,cabeca", [("notes.txt", b"-----BEGIN " + b"OPENSSH PRIVATE KEY-----\nabc"),
                                         ("server.key", b"-----BEGIN " + b"RSA PRIVATE KEY-----\nabc")])
def test_chave_privada_por_conteudo_recusada(casa, nome, cabeca):
    (casa / nome).write_bytes(cabeca)
    with pytest.raises(ValueError, match="chave privada"):
        _bot.arquivos_validos([str(casa / nome)])


def test_marcador_alem_do_limite_passa(casa):
    marcador = CONTRATO["content_marker"].encode()
    (casa / "longo.txt").write_bytes(b"a" * (CONTRATO["content_bytes"] - len(marcador) + 1) + marcador)
    assert [p for p, _ in _bot.arquivos_validos([str(casa / "longo.txt")])] == [casa / "longo.txt"]


def test_marcador_no_limite_recusado(casa):
    marcador = CONTRATO["content_marker"].encode()
    (casa / "limite.txt").write_bytes(b"a" * (CONTRATO["content_bytes"] - len(marcador)) + marcador)
    with pytest.raises(ValueError, match="chave privada"):
        _bot.arquivos_validos([str(casa / "limite.txt")])


def test_arquivo_ilegivel_recusado(casa):
    alvo = casa / "fechado.txt"
    alvo.write_text("ok")
    alvo.chmod(0)
    try:
        with pytest.raises(ValueError, match="nao pode ser lido"):
            _bot.arquivos_validos([str(alvo)])
    finally:
        alvo.chmod(0o600)


def test_arquivo_vazio_passa(casa):
    (casa / "vazio.txt").write_bytes(b"")
    assert [p for p, _ in _bot.arquivos_validos([str(casa / "vazio.txt")])] == [casa / "vazio.txt"]
