import stat
from pathlib import Path

import pytest

from wisp import agenda
from wisp.cli import main


@pytest.fixture(autouse=True)
def no_installed_app(tmp_path, monkeypatch):
    monkeypatch.setattr(agenda, "SYSTEM_APPLICATIONS", tmp_path / "system-applications")


def make_helper(path: Path, script: str = "#!/bin/sh\nexit 0\n") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(script)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def test_helper_missing_says_so_in_portuguese_and_fails(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(agenda.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(agenda.Path, "home", lambda: tmp_path)
    monkeypatch.delenv(agenda.ENV_OVERRIDE, raising=False)
    monkeypatch.setattr(agenda, "candidates", lambda env, home: [tmp_path / "Wisp.app" / agenda.HELPER_IN_APP])
    assert main(["agenda", "eventos", "--hoje"]) == 1
    err = capsys.readouterr().err
    assert "não achei o ajudante da agenda" in err
    assert "Wisp.app" in err


def test_outside_the_mac_there_is_no_agenda(capsys):
    assert agenda.run_helper(["calendarios"], system="Linux", env={}, home=Path("/nonexistent")) == 1
    assert agenda.SO_NO_MAC in capsys.readouterr().err


def test_env_override_wins_over_the_app_locations(tmp_path):
    override = make_helper(tmp_path / "custom" / "wisp-agenda")
    in_home = make_helper(tmp_path / "Applications" / "Wisp.app" / agenda.HELPER_IN_APP)
    assert agenda.find_helper({agenda.ENV_OVERRIDE: str(override)}, tmp_path) == override
    assert agenda.find_helper({}, tmp_path) == in_home


def test_a_file_that_is_not_executable_is_not_a_helper(tmp_path):
    path = tmp_path / "Applications" / "Wisp.app" / agenda.HELPER_IN_APP
    path.parent.mkdir(parents=True)
    path.write_text("x")
    path.chmod(0o644)
    assert agenda.find_helper({}, tmp_path) is None


def test_arguments_pass_through_untouched_including_flags(tmp_path, monkeypatch, capfd):
    log = tmp_path / "args.txt"
    helper = make_helper(tmp_path / "wisp-agenda", f'#!/bin/sh\nprintf "%s|" "$@" > "{log}"\necho \'[]\'\n')
    monkeypatch.setattr(agenda.platform, "system", lambda: "Darwin")
    monkeypatch.setenv(agenda.ENV_OVERRIDE, str(helper))
    assert main(["agenda", "eventos", "--hoje", "--calendario", "Casa e Trabalho"]) == 0
    assert capfd.readouterr().out.strip() == "[]"
    assert log.read_text() == "eventos|--hoje|--calendario|Casa e Trabalho|"


def test_the_helper_exit_code_and_stderr_reach_the_caller(tmp_path, monkeypatch, capfd):
    helper = make_helper(tmp_path / "wisp-agenda", "#!/bin/sh\necho 'sem permissão' >&2\nexit 2\n")
    monkeypatch.setattr(agenda.platform, "system", lambda: "Darwin")
    monkeypatch.setenv(agenda.ENV_OVERRIDE, str(helper))
    assert main(["agenda", "calendarios"]) == 2
    assert "sem permissão" in capfd.readouterr().err


@pytest.mark.parametrize("command", ["eventos", "criar-evento", "editar-evento", "apagar-evento", "lembretes", "criar-lembrete", "concluir-lembrete", "calendarios"])
def test_every_command_is_forwarded(tmp_path, monkeypatch, command):
    seen = []
    monkeypatch.setattr(agenda.subprocess, "run", lambda argv, check: seen.append(argv) or type("R", (), {"returncode": 0})())
    monkeypatch.setattr(agenda.platform, "system", lambda: "Darwin")
    monkeypatch.setenv(agenda.ENV_OVERRIDE, str(make_helper(tmp_path / "wisp-agenda")))
    assert main(["agenda", command, "--x", "1"]) == 0
    assert seen[0][1:] == [command, "--x", "1"]


def test_a_forced_helper_that_is_missing_is_an_error_not_a_fallback(tmp_path, monkeypatch, capsys):
    in_home = make_helper(tmp_path / "Applications" / "Wisp.app" / agenda.HELPER_IN_APP)
    assert in_home.exists()
    code = agenda.run_helper(["calendarios"], system="Darwin", env={agenda.ENV_OVERRIDE: str(tmp_path / "nada")}, home=tmp_path)
    assert code == 1
    assert "WISP_AGENDA_BIN aponta para" in capsys.readouterr().err


def test_a_helper_killed_by_a_signal_returns_one_with_a_message(tmp_path, monkeypatch, capsys):
    helper = make_helper(tmp_path / "wisp-agenda", "#!/bin/sh\nkill -9 $$\n")
    code = agenda.run_helper(["eventos"], system="Darwin", env={agenda.ENV_OVERRIDE: str(helper)}, home=tmp_path)
    assert code == 1
    assert "interrompido pelo sistema (sinal 9)" in capsys.readouterr().err
