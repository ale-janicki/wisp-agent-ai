import json
import os
import time
from datetime import datetime

import pytest

from wisp import arquivos
from wisp.cli import main
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult


def _mdfind(*caminhos, exit=0):
    return FakeRunner({("mdfind",): RunResult(["mdfind"], exit, "\n".join(str(c) for c in caminhos) + "\n", "")})


def _arquivo(pasta, nome, dias=0, conteudo="x"):
    p = pasta / nome
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(conteudo)
    t = time.time() - dias * 86400
    os.utime(p, (t, t))
    return p


def _nomes(achados):
    return [e["nome"] for e in achados]


def test_buscar_ranks_by_recency_and_asks_spotlight_for_name_and_content(fake_home):
    velho = _arquivo(fake_home, "contrato velho.pdf", dias=10)
    novo = _arquivo(fake_home, "contrato novo.pdf", dias=1)
    runner = _mdfind(velho, novo)
    achados = arquivos.buscar(runner, 'con"trato', None, None, None)
    assert _nomes(achados) == ["contrato novo.pdf", "contrato velho.pdf"]
    consulta = runner.calls[0][-1]
    assert runner.calls[0][:3] == ["mdfind", "-onlyin", str(fake_home.resolve())]
    assert 'kMDItemDisplayName == "*con\\"trato*"cd' in consulta and "kMDItemTextContent" in consulta


def test_buscar_caps_at_30(fake_home):
    todos = [_arquivo(fake_home, f"a{i}.txt", dias=i) for i in range(40)]
    assert len(arquivos.buscar(_mdfind(*todos), "a", None, None, None)) == 30


def test_buscar_filters_by_type_and_age(fake_home):
    pdf = _arquivo(fake_home, "a.pdf", dias=1)
    png = _arquivo(fake_home, "b.png", dias=1)
    antigo = _arquivo(fake_home, "c.pdf", dias=40)
    runner = _mdfind(pdf, png, antigo)
    assert _nomes(arquivos.buscar(runner, "x", "pdf", "7d", None)) == ["a.pdf"]
    assert _nomes(arquivos.buscar(runner, "x", "imagem", None, None)) == ["b.png"]
    assert _nomes(arquivos.buscar(runner, "x", ".PDF", "2m", None)) == ["a.pdf", "c.pdf"]


def test_buscar_rejects_a_bad_duration(fake_home):
    with pytest.raises(arquivos.Erro, match="--desde"):
        arquivos.buscar(_mdfind(), "x", None, "ontem", None)


def test_buscar_excludes_library_hidden_and_the_send_deny_list(fake_home):
    ok = _arquivo(fake_home, "Documents/ok.txt")
    lib = _arquivo(fake_home, "Library/Mail/x.txt")
    oculto = _arquivo(fake_home, ".segredo/x.txt")
    chave = _arquivo(fake_home, ".ssh/id_ed25519")
    env = _arquivo(fake_home, "projeto/.env")
    pem = _arquivo(fake_home, "Documents/cert.pem")
    wisp = _arquivo(fake_home, ".config/wisp/wisp.json")
    achados = arquivos.buscar(_mdfind(ok, lib, oculto, chave, env, pem, wisp), "x", None, None, None)
    assert _nomes(achados) == ["ok.txt"]


def test_buscar_denies_through_a_symlink(fake_home):
    (fake_home / ".ssh").mkdir()
    (fake_home / ".ssh" / "config").write_text("x")
    (fake_home / "atalho").symlink_to(fake_home / ".ssh")
    assert arquivos.buscar(_mdfind(fake_home / "atalho" / "config"), "x", None, None, None) == []


def test_buscar_falls_back_to_a_name_search_when_spotlight_finds_nothing(fake_home):
    _arquivo(fake_home, "Documents/Fatura Março.pdf")
    _arquivo(fake_home, "Library/fatura.pdf")
    _arquivo(fake_home, ".oculto/fatura.pdf")
    assert _nomes(arquivos.buscar(_mdfind(), "fatura", None, None, None)) == ["Fatura Março.pdf"]


def test_buscar_falls_back_when_mdfind_fails(fake_home):
    _arquivo(fake_home, "relatorio.txt")
    assert _nomes(arquivos.buscar(_mdfind(exit=1), "relat", None, None, None)) == ["relatorio.txt"]
    assert _nomes(arquivos.buscar(FakeRunner(), "relat", None, None, None)) == ["relatorio.txt"]


def test_fallback_walk_is_bounded_in_depth(fake_home):
    fundo = fake_home
    for i in range(arquivos.MAX_PROFUNDIDADE + 2):
        fundo = fundo / f"d{i}"
    _arquivo(fundo, "fundo.txt")
    assert arquivos.buscar(_mdfind(), "fundo", None, None, None) == []


def test_buscar_in_a_folder_outside_the_home_is_not_hidden_by_the_home_rules(fake_home, tmp_path):
    fora = tmp_path / "fora"
    alvo = _arquivo(fora, "nota.txt")
    assert _nomes(arquivos.buscar(_mdfind(alvo), "nota", None, None, str(fora))) == ["nota.txt"]


def test_buscar_unknown_folder(fake_home):
    with pytest.raises(arquivos.Erro, match="não encontrei a pasta"):
        arquivos.buscar(_mdfind(), "x", None, None, str(fake_home / "nao-existe"))


def test_buscar_cli_prints_lines_json_and_the_empty_message(fake_home, monkeypatch, capsys):
    p = _arquivo(fake_home, "relatorio.txt")
    monkeypatch.setattr(arquivos, "SubprocessRunner", lambda: _mdfind(p))
    assert main(["arquivos", "buscar", "relatorio"]) == 0
    assert capsys.readouterr().out.startswith(f"{p.resolve()}  (")
    assert main(["arquivos", "buscar", "relatorio", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)[0]["nome"] == "relatorio.txt"
    monkeypatch.setattr(arquivos, "SubprocessRunner", lambda: _mdfind())
    assert main(["arquivos", "buscar", "zzz"]) == 0
    assert capsys.readouterr().out == 'Não achei nada para "zzz".\n'
    assert main(["arquivos", "buscar", "x", "--desde", "ontem"]) == 2
    assert "--desde" in capsys.readouterr().err


@pytest.fixture
def downloads(fake_home):
    d = fake_home / "Downloads"
    _arquivo(d, "nota.pdf")
    _arquivo(d, "foto.JPG")
    _arquivo(d, "app novo.dmg", dias=3)
    _arquivo(d, "app velho.dmg", dias=45)
    _arquivo(d, "tudo.zip")
    _arquivo(d, "coisa.xyz")
    _arquivo(d, ".oculto")
    _arquivo(d, ".env")
    (d / "pasta").mkdir()
    return d


def _estado(d):
    return sorted(str(p.relative_to(d)) for p in d.rglob("*"))


def test_organizar_dry_run_proposes_and_touches_nothing(downloads):
    antes = _estado(downloads)
    plano = arquivos.planejar(str(downloads))
    destinos = {os.path.basename(m["de"]): os.path.relpath(m["para"], downloads) for m in plano.mover}
    assert destinos == {"nota.pdf": "Documentos/nota.pdf", "foto.JPG": "Imagens/foto.JPG",
                        "app novo.dmg": "Instaladores/app novo.dmg", "tudo.zip": "Compactados/tudo.zip",
                        "coisa.xyz": "Outros/coisa.xyz"}
    assert [os.path.basename(i["de"]) for i in plano.lixo] == ["app velho.dmg"]
    assert _estado(downloads) == antes


def test_organizar_cli_dry_run_by_default(downloads, capsys):
    antes = _estado(downloads)
    assert main(["arquivos", "organizar", str(downloads)]) == 0
    out = capsys.readouterr().out
    assert "nada foi mexido" in out and "Documentos: 1 arquivo(s): nota.pdf" in out and "app velho.dmg" in out
    assert _estado(downloads) == antes
    assert main(["arquivos", "organizar", str(downloads), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["aplicado"] is False


def test_organizar_refuses_home_library_and_outside_home(fake_home, tmp_path):
    (fake_home / "Library").mkdir()
    for pasta in (fake_home, fake_home / "Library", tmp_path):
        with pytest.raises(arquivos.Erro, match="dentro da sua pasta pessoal"):
            arquivos.planejar(str(pasta))


def test_organizar_aplicar_moves_never_overwrites_and_writes_the_journal(downloads, fake_home):
    _arquivo(downloads, "Documentos/nota.pdf", conteudo="ja existia")
    plano = arquivos.planejar(str(downloads))
    paths = WispPaths.current()
    res = arquivos.aplicar(FakeRunner(), paths, plano, com_lixo=False, agora=datetime(2026, 11, 19, 10, 0, 0))
    assert res == {"ts": "20261119-100000", "movidos": 5, "lixo": 0, "falhas": []}
    assert (downloads / "Documentos/nota.pdf").read_text() == "ja existia"
    assert (downloads / "Documentos/nota 2.pdf").read_text() == "x"
    assert not (downloads / "foto.JPG").exists() and (downloads / "Imagens/foto.JPG").exists()
    assert (downloads / "app velho.dmg").exists() and (downloads / ".env").exists()
    linhas = [json.loads(l) for l in (fake_home / ".local/state/wisp/arquivos/desfazer-20261119-100000.json").read_text().splitlines()]
    assert linhas[0]["version"] == 2
    assert len([l for l in linhas if "de" in l]) == 5
    assert {"criada": str(downloads.resolve() / "Documentos")} not in linhas
    assert {"criada": str(downloads.resolve() / "Imagens")} in linhas


def test_aplicar_picks_a_new_suffix_if_the_target_appeared_after_the_plan(downloads):
    plano = arquivos.planejar(str(downloads))
    _arquivo(downloads, "Imagens/foto.JPG", conteudo="chegou depois")
    arquivos.aplicar(FakeRunner(), WispPaths.current(), plano, False)
    assert (downloads / "Imagens/foto.JPG").read_text() == "chegou depois"
    assert (downloads / "Imagens/foto 2.JPG").read_text() == "x"


def test_the_suffix_keeps_counting_past_existing_copies(fake_home):
    d = fake_home / "Downloads"
    _arquivo(d, "a.pdf")
    _arquivo(d, "Documentos/a.pdf")
    _arquivo(d, "Documentos/a 2.pdf")
    plano = arquivos.planejar(str(d))
    assert [os.path.basename(m["para"]) for m in plano.mover] == ["a 3.pdf"]


def test_old_installers_go_to_the_trash_only_with_the_flag(downloads, monkeypatch):
    plano = arquivos.planejar(str(downloads))
    runner = FakeRunner({(arquivos.TRASH,): RunResult([], 0, "", "")})
    monkeypatch.setattr(arquivos.Path, "exists", lambda self: True if str(self) == arquivos.TRASH else os.path.exists(self))
    assert arquivos.aplicar(runner, WispPaths.current(), plano, com_lixo=False)["lixo"] == 0
    assert runner.calls == []
    assert arquivos.aplicar(runner, WispPaths.current(), plano, com_lixo=True)["lixo"] == 1
    assert runner.calls == [[arquivos.TRASH, str((downloads / "app velho.dmg").resolve())]]
    assert (downloads / "app velho.dmg").exists()


def test_trash_falls_back_to_finder_when_the_binary_is_missing(monkeypatch):
    monkeypatch.setattr(arquivos, "TRASH", "/nao/existe/trash")
    runner = FakeRunner({("osascript",): RunResult([], 0, "", "")})
    assert arquivos._para_o_lixo(runner, "/a/b.dmg") is True
    assert runner.calls[0][0] == "osascript" and runner.calls[0][-1] == "/a/b.dmg"


def test_desfazer_reverts_the_last_run_and_removes_the_folders_it_created(downloads):
    antes = _estado(downloads)
    paths = WispPaths.current()
    arquivos.aplicar(FakeRunner(), paths, arquivos.planejar(str(downloads)), False, agora=datetime(2026, 11, 19, 10, 0, 0))
    res = arquivos.desfazer(paths, None)
    assert res == {"ts": "20261119-100000", "voltaram": 5, "nao_restaurados": []}
    assert _estado(downloads) == antes
    with pytest.raises(arquivos.Erro, match="nada para desfazer"):
        arquivos.desfazer(paths, None)


def test_desfazer_by_timestamp_skips_what_changed_since(downloads):
    paths = WispPaths.current()
    arquivos.aplicar(FakeRunner(), paths, arquivos.planejar(str(downloads)), False, agora=datetime(2026, 11, 19, 10, 0, 0))
    _arquivo(downloads, "nota.pdf", conteudo="novo no lugar")
    (downloads / "Imagens/foto.JPG").unlink()
    res = arquivos.desfazer(paths, "20261119-100000")
    assert res["voltaram"] == 3 and sorted(f["arquivo"] for f in res["nao_restaurados"]) == ["foto.JPG", "nota.pdf"]
    assert (downloads / "nota.pdf").read_text() == "novo no lugar"
    assert (downloads / "Documentos/nota.pdf").exists()


def test_desfazer_unknown_timestamp(downloads):
    with pytest.raises(arquivos.Erro, match="com o código 999"):
        arquivos.desfazer(WispPaths.current(), "999")


def test_organizar_cli_apply_and_undo_end_to_end(downloads, capsys):
    antes = _estado(downloads)
    assert main(["arquivos", "organizar", str(downloads), "--aplicar"]) == 0
    out = capsys.readouterr().out
    assert out.startswith("Movi 5 arquivo(s)") and "arquivos desfazer " in out
    assert main(["arquivos", "desfazer"]) == 0
    assert "5 arquivo(s) voltaram" in capsys.readouterr().out
    assert _estado(downloads) == antes
    assert main(["arquivos", "desfazer"]) == 2
    assert "nada para desfazer" in capsys.readouterr().err


def _aplicar(d, **kw):
    return arquivos.aplicar(FakeRunner(), WispPaths.current(), arquivos.planejar(str(d)), False, **kw)


def test_two_runs_in_the_same_second_get_their_own_journals_and_undo_takes_the_last(downloads):
    agora = datetime(2026, 11, 19, 10, 0, 0)
    primeiro = _aplicar(downloads, agora=agora)
    _arquivo(downloads, "outra.pdf")
    segundo = _aplicar(downloads, agora=agora)
    assert (primeiro["ts"], segundo["ts"]) == ("20261119-100000", "20261119-100000-2")
    assert arquivos.desfazer(WispPaths.current(), None)["ts"] == "20261119-100000-2"
    assert (downloads / "outra.pdf").exists() and (downloads / "Documentos/nota.pdf").exists()


def test_a_failed_move_is_reported_and_the_journal_keeps_the_ones_that_worked(downloads, fake_home, monkeypatch):
    real = arquivos._mover_sem_sobrescrever

    def falha_numa(origem, destino):
        if origem.name == "foto.JPG":
            raise PermissionError(13, "Permission denied", str(destino))
        real(origem, destino)
    monkeypatch.setattr(arquivos, "_mover_sem_sobrescrever", falha_numa)
    res = _aplicar(downloads, agora=datetime(2026, 11, 19, 10, 0, 0))
    assert res["movidos"] == 4 and res["falhas"] == [{"arquivo": "foto.JPG", "motivo": "Permission denied"}]
    assert (downloads / "foto.JPG").exists()
    linhas = (fake_home / ".local/state/wisp/arquivos/desfazer-20261119-100000.json").read_text().splitlines()
    assert len([l for l in linhas if '"de"' in l]) == 4
    assert arquivos.desfazer(WispPaths.current(), None)["voltaram"] == 4


def test_a_crash_midway_leaves_a_journal_that_undoes_what_moved(downloads, fake_home, monkeypatch):
    real = arquivos._mover_sem_sobrescrever
    chamadas = []

    def morre_na_terceira(origem, destino):
        chamadas.append(origem)
        if len(chamadas) == 3:
            raise KeyboardInterrupt
        real(origem, destino)
    monkeypatch.setattr(arquivos, "_mover_sem_sobrescrever", morre_na_terceira)
    antes = _estado(downloads)
    with pytest.raises(KeyboardInterrupt):
        _aplicar(downloads, agora=datetime(2026, 11, 19, 10, 0, 0))
    monkeypatch.setattr(arquivos, "_mover_sem_sobrescrever", real)
    assert arquivos.desfazer(WispPaths.current(), None)["voltaram"] == 2
    assert _estado(downloads) == antes


def test_a_run_that_moves_nothing_leaves_no_journal(fake_home):
    d = fake_home / "Downloads"
    d.mkdir()
    assert _aplicar(d)["ts"] is None
    assert list((fake_home / ".local/state/wisp/arquivos").iterdir()) == []


def test_the_move_never_overwrites_even_when_the_target_appears_at_the_last_moment(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    a.write_text("novo")
    b.write_text("velho")
    with pytest.raises(FileExistsError):
        arquivos._mover_sem_sobrescrever(a, b)
    assert b.read_text() == "velho" and a.read_text() == "novo"


def test_a_dangling_symlink_counts_as_occupied(fake_home):
    d = fake_home / "Downloads"
    _arquivo(d, "a.pdf")
    (d / "Documentos").mkdir()
    (d / "Documentos/a.pdf").symlink_to(d / "nada")
    assert [os.path.basename(m["para"]) for m in arquivos.planejar(str(d)).mover] == ["a 2.pdf"]


def test_a_group_folder_that_is_a_symlink_or_a_file_or_points_outside_is_refused(fake_home, tmp_path):
    d = fake_home / "Downloads"
    _arquivo(d, "a.pdf")
    _arquivo(d, "b.png")
    _arquivo(d, "c.mp4")
    fora = tmp_path / "fora"
    fora.mkdir()
    (d / "Documentos").symlink_to(fora)
    (d / "Imagens").write_text("sou um arquivo")
    plano = arquivos.planejar(str(d))
    assert sorted(os.path.basename(m["de"]) for m in plano.mover) == ["Imagens", "c.mp4"]
    assert any("Documentos" in a and "atalho" in a for a in plano.avisos)
    assert any("Imagens" in a and "já existe um arquivo" in a for a in plano.avisos)
    assert list(fora.iterdir()) == []


def test_aplicar_rechecks_the_group_folder_after_the_plan(fake_home, tmp_path):
    d = fake_home / "Downloads"
    _arquivo(d, "a.pdf")
    plano = arquivos.planejar(str(d))
    fora = tmp_path / "fora"
    fora.mkdir()
    (d / "Documentos").symlink_to(fora)
    res = arquivos.aplicar(FakeRunner(), WispPaths.current(), plano, False)
    assert res["movidos"] == 0 and res["falhas"][0]["arquivo"] == "a.pdf"
    assert (d / "a.pdf").exists() and list(fora.iterdir()) == []


def test_desfazer_does_not_overwrite_and_says_which_files_stayed(downloads, capsys):
    _aplicar(downloads, agora=datetime(2026, 11, 19, 10, 0, 0))
    _arquivo(downloads, "nota.pdf", conteudo="novo")
    (downloads / "foto.JPG").symlink_to(downloads / "nada")
    assert main(["arquivos", "desfazer"]) == 0
    out = capsys.readouterr().out
    assert "3 arquivo(s) voltaram" in out and "Não voltaram 2" in out and "nota.pdf" in out and "foto.JPG" in out
    assert (downloads / "nota.pdf").read_text() == "novo" and (downloads / "Documentos/nota.pdf").exists()


@pytest.mark.parametrize("conteudo", ["", "isto nao e json\n", '{"version": 2}\n{"de": "/a"}\n', '{"version": 1}\n', "[1]\n"])
def test_a_corrupt_journal_is_one_clear_line_and_touches_nothing(fake_home, capsys, conteudo):
    pasta = fake_home / ".local/state/wisp/arquivos"
    pasta.mkdir(parents=True)
    (pasta / "desfazer-20261119-100000.json").write_text(conteudo)
    assert main(["arquivos", "desfazer"]) == 2
    err = capsys.readouterr().err
    assert "danificado" in err and "Traceback" not in err
    assert (pasta / "desfazer-20261119-100000.json").exists()


@pytest.mark.parametrize("marca", [".git", "package.json", "pyproject.toml", "Makefile", "App.xcodeproj"])
def test_project_folders_are_refused(fake_home, marca):
    d = fake_home / "meu-app"
    _arquivo(d, "a.pdf")
    (d / marca).mkdir() if marca in (".git", "App.xcodeproj") else (d / marca).write_text("x")
    with pytest.raises(arquivos.Erro, match=f"parece um projeto \\(tem {marca}\\)"):
        arquivos.planejar(str(d))


def test_the_plan_text_says_unknown_types_go_to_outros(downloads):
    assert "Tipos que não reconheço vão para Outros." in arquivos._texto_plano(arquivos.planejar(str(downloads)))
