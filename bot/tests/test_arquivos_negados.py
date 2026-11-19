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
