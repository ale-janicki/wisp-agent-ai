import pytest

from wisp import mac
from wisp.cli import main
from wisp.mac import Falha
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult

OK = RunResult([], 0, "", "")
NEGADO = RunResult([], 1, "", "execution error: Not authorized to send Apple events to System Events. (-1743)")
BATT = """Now drawing from 'Battery Power'
 -InternalBattery-0 (id=35651683)\t74%; discharging; 8:29 remaining present: true
"""


def test_volume_sets_the_level_and_unmutes():
    runner = FakeRunner({("osascript",): OK})
    assert mac.volume(runner, "40") == "Volume do Mac em 40."
    assert runner.calls == [["osascript", "-e", "set volume output volume 40", "-e", "set volume output muted false"]]


def test_volume_mute():
    runner = FakeRunner({("osascript",): OK})
    assert "mudo" in mac.volume(runner, "mudo")
    assert runner.calls == [["osascript", "-e", "set volume output muted true"]]


@pytest.mark.parametrize("valor", ["101", "-1", "alto", "4.5", ""])
def test_volume_rejects_bad_values_without_calling_the_mac(valor):
    runner = FakeRunner()
    with pytest.raises(Falha, match="0 a 100"):
        mac.volume(runner, valor)
    assert runner.calls == []


def test_notificar_passes_the_text_as_an_argument_never_inside_the_script():
    runner = FakeRunner({("osascript",): OK})
    mac.notificar(runner, 'oi "mundo" \\ fim')
    assert runner.calls[0][-2:] == ["--", 'oi "mundo" \\ fim']
    assert "oi" not in "".join(runner.calls[0][:-1])


def test_osascript_uses_a_30s_timeout():
    seen = {}

    class R(FakeRunner):
        def run(self, argv, *, timeout=60, **kw):
            seen["timeout"] = timeout
            return OK
    mac.notificar(R(), "x")
    assert seen["timeout"] == 30


def test_permission_denied_is_one_clear_line():
    with pytest.raises(Falha, match="Automação"):
        mac.volume(FakeRunner({("osascript",): NEGADO}), "10")


def test_osascript_timeout_and_other_errors_are_clear():
    with pytest.raises(Falha, match="demorou demais"):
        mac.notificar(FakeRunner({("osascript",): RunResult([], -9, "", "", timed_out=True)}), "x")
    with pytest.raises(Falha, match="não conseguiu"):
        mac.notificar(FakeRunner({("osascript",): RunResult([], 1, "", "boom")}), "x")


@pytest.fixture
def apps(tmp_path, monkeypatch):
    pasta = tmp_path / "Applications"
    (pasta / "Safari.app").mkdir(parents=True)
    monkeypatch.setattr(mac, "PASTAS_APPS", (str(pasta),))
    return pasta


def test_abrir_picks_url_safe_file_or_installed_app(tmp_path, apps):
    arq = tmp_path / "a.pdf"
    arq.write_text("x")
    runner = FakeRunner({("open",): OK})
    assert mac.abrir(runner, "https://exemplo.com") == "Abri https://exemplo.com."
    assert mac.abrir(runner, str(arq)) == f"Abri {arq}."
    assert mac.abrir(runner, "safari") == "Abri safari."
    assert runner.calls == [["open", "https://exemplo.com"], ["open", str(arq)], ["open", "-a", str(apps / "Safari.app")]]


@pytest.mark.parametrize("nome,executavel,pasta", [
    ("x.dmg", False, False), ("x.pkg", False, False), ("x.sh", False, False), ("x.command", False, False),
    ("x.workflow", False, False), ("x.html", False, False), ("x.svg", False, False), ("x.docm", False, False),
    ("x.zip", False, False), ("semextensao", False, False), ("x.pdf", True, False), ("Pasta", False, True),
    ("Coisa.app", False, True), ("x.desconhecida", False, False),
])
def test_abrir_only_reveals_risky_files(tmp_path, nome, executavel, pasta):
    alvo = tmp_path / nome
    alvo.mkdir() if pasta else alvo.write_text("x")
    if executavel:
        alvo.chmod(0o755)
    runner = FakeRunner({("open",): OK})
    resposta = mac.abrir(runner, str(alvo))
    assert runner.calls == [["open", "-R", str(alvo)]]
    assert resposta.startswith("Só mostrei") and "sem abrir" in resposta


@pytest.mark.parametrize("nome", ["a.pdf", "a.PNG", "a.docx", "a.xlsx", "a.mp4", "a.mp3", "a.txt", "a.pages", "a.key"])
def test_abrir_opens_safe_documents(tmp_path, nome):
    alvo = tmp_path / nome
    alvo.write_text("x")
    runner = FakeRunner({("open",): OK})
    assert mac.abrir(runner, str(alvo)).startswith("Abri")
    assert runner.calls == [["open", str(alvo)]]


def test_abrir_never_launches_an_app_it_did_not_find_by_name(apps):
    runner = FakeRunner({("open",): OK})
    with pytest.raises(Falha, match="não achei"):
        mac.abrir(runner, "/tmp/Evil")
    with pytest.raises(Falha, match="não achei"):
        mac.abrir(runner, "-a Terminal")
    assert runner.calls == []


def test_print_prunes_old_captures_only(fake_home):
    import os, time
    pasta = fake_home / ".local/state/wisp/capturas"
    pasta.mkdir(parents=True)
    velha, nova, outra = pasta / "captura-1.png", pasta / "captura-2.png", pasta / "nota.txt"
    for p in (velha, nova, outra):
        p.write_text("x")
    antigo = time.time() - 2 * 86400
    os.utime(velha, (antigo, antigo))
    os.utime(outra, (antigo, antigo))

    class R(FakeRunner):
        def run(self, argv, **kw):
            open(argv[-1], "wb").write(b"png")
            return OK
    mac.print_tela(R(), WispPaths.current(), False)
    assert not velha.exists() and nova.exists() and outra.exists()


def test_notificar_text_starting_with_a_dash_goes_after_the_separator():
    runner = FakeRunner({("osascript",): OK})
    mac.notificar(runner, "-e do shell script")
    assert runner.calls[0][-2:] == ["--", "-e do shell script"]
    assert runner.calls[0].count("-e") == 3


def test_abrir_unknown_app_is_one_line(apps):
    with pytest.raises(Falha, match="Não consegui abrir Nada"):
        mac.abrir(FakeRunner({("open",): OK}), "Nada")


def test_abrir_open_failure_is_one_line(tmp_path):
    arq = tmp_path / "a.pdf"
    arq.write_text("x")
    with pytest.raises(Falha, match="Não consegui abrir"):
        mac.abrir(FakeRunner({("open",): RunResult([], 1, "", "boom")}), str(arq))


def test_print_captures_to_the_state_folder_and_returns_the_path(fake_home):
    class R(FakeRunner):
        def run(self, argv, **kw):
            self.calls.append(list(argv))
            open(argv[-1], "wb").write(b"png")
            return OK
    runner = R()
    path = mac.print_tela(runner, WispPaths.current(), janela=False)
    assert path.startswith(str(fake_home / ".local/state/wisp/capturas/captura-")) and path.endswith(".png")
    assert runner.calls[0][:3] == ["screencapture", "-x", "-o"] and "-w" not in runner.calls[0]
    mac.print_tela(runner, WispPaths.current(), janela=True)
    assert "-w" in runner.calls[1]


def test_print_without_a_file_points_to_screen_recording(fake_home):
    with pytest.raises(Falha, match="Gravação de Tela"):
        mac.print_tela(FakeRunner({("screencapture",): RunResult([], 1, "", "could not create image from display")}),
                       WispPaths.current(), False)
    with pytest.raises(Falha, match="Gravação de Tela"):
        mac.print_tela(FakeRunner({("screencapture",): OK}), WispPaths.current(), False)


def test_print_window_cancelled(fake_home):
    with pytest.raises(Falha, match="cancelada"):
        mac.print_tela(FakeRunner({("screencapture",): OK}), WispPaths.current(), True)


@pytest.mark.parametrize("saida,esperado", [
    (BATT, "Bateria em 74%, descarregando, restam 8h29."),
    (BATT.replace("74%; discharging; 8:29 remaining", "80%; charging; 0:40 remaining"), "Bateria em 80%, carregando, cheia em 0h40."),
    (BATT.replace("74%; discharging; 8:29 remaining", "100%; charged;"), "Bateria em 100%, carregada."),
    (BATT.replace("74%; discharging; 8:29 remaining", "100%; charged; 0:00 remaining"), "Bateria em 100%, carregada."),
    (BATT.replace("74%; discharging; 8:29 remaining", "99%; finishing charge; 0:05 remaining"), "Bateria em 99%, terminando de carregar, cheia em 0h05."),
    (BATT.replace("74%; discharging; 8:29 remaining", "50%; charging; 0:00 remaining"), "Bateria em 50%, carregando."),
    (BATT.replace("8:29 remaining", "(no estimate)"), "Bateria em 74%, descarregando."),
    ("Now drawing from 'AC Power'\n", "Este Mac não tem bateria (está na tomada)."),
])
def test_bateria(saida, esperado):
    assert mac.bateria(FakeRunner({("pmset", "-g", "batt"): RunResult([], 0, saida, "")})) == esperado


def test_nao_perturbe_reads_the_assertions_file(fake_home):
    arquivo = fake_home / mac.DND_ASSERTIONS
    arquivo.parent.mkdir(parents=True)
    arquivo.write_text('{"data": [{"storeAssertionRecords": [{"x": 1}]}]}')
    paths = WispPaths.current()
    assert mac.nao_perturbe(paths) == "O Não perturbe está ligado."
    arquivo.write_text('{"data": [{"storeAssertionRecords": []}]}')
    assert mac.nao_perturbe(paths) == "O Não perturbe está desligado."


def test_nao_perturbe_without_access_says_so_and_never_toggles(fake_home, monkeypatch):
    paths = WispPaths.current()
    assert "Não consegui ver" in mac.nao_perturbe(paths)
    monkeypatch.setattr(mac.Path, "read_text", lambda *a, **k: (_ for _ in ()).throw(PermissionError()))
    assert "Acesso Total ao Disco" in mac.nao_perturbe(paths)


def test_cli_prints_the_line_and_failures_go_to_stderr_with_no_traceback(monkeypatch, capsys):
    monkeypatch.setattr(mac, "SubprocessRunner", lambda: FakeRunner({("osascript",): OK}))
    assert main(["mac", "volume", "30"]) == 0
    assert capsys.readouterr().out == "Volume do Mac em 30.\n"
    assert main(["mac", "volume", "30x"]) == 1
    assert capsys.readouterr().err == "Use um número de 0 a 100, ou a palavra mudo.\n"
    monkeypatch.setattr(mac, "SubprocessRunner", lambda: FakeRunner({("osascript",): NEGADO}))
    assert main(["mac", "notificar", "oi"]) == 1
    err = capsys.readouterr().err
    assert "Automação" in err and "Traceback" not in err
