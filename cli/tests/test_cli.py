import json

import pytest

from wisp.cli import main
from wisp.paths import resources_root


def test_version(capsys):
    with pytest.raises(SystemExit) as e:
        main(["--version"])
    assert e.value.code == 0
    assert capsys.readouterr().out.strip() == "wisp 0.1.0"


def test_unknown_command_exits_2():
    with pytest.raises(SystemExit) as e:
        main(["nope"])
    assert e.value.code == 2


def test_doctor_json_survives_corrupt_config(fake_home, capsys):
    import json

    config = fake_home / ".config/wisp/wisp.json"
    config.parent.mkdir(parents=True)
    config.write_text("{not json")
    assert main(["doctor", "--json", "--only", "profile"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert [c["id"] for c in out["checks"]] == ["profile"]
    assert "wisp.json" in out["warning"]


def test_brain_colher_json_without_brain(fake_home, capsys):
    import json

    assert main(["brain", "colher", "--if-due", "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["colhidas"] == []
    assert out["puladas"][0]["motivo"] == "brain nao encontrado"


def test_brain_colher_requires_action():
    with pytest.raises(SystemExit) as e:
        main(["brain"])
    assert e.value.code == 2


def _fake_runner(monkeypatch):
    from wisp import cli
    from wisp.runner import FakeRunner

    runner = FakeRunner()
    monkeypatch.setattr(cli, "SubprocessRunner", lambda: runner)
    return runner


def _saved(fake_home):
    import json

    return json.loads((fake_home / ".config/wisp/wisp.json").read_text())


def test_config_set_brain_keeps_files(fake_home, monkeypatch, capsys):
    import json

    _fake_runner(monkeypatch)
    old = fake_home / "old-brain"
    old.mkdir()
    (old / "nota.md").write_text("minha nota")
    new = fake_home / "vault"
    assert main(["config", "set", "brain", str(new), "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["step"] == "config" and out["status"] == "done"
    assert _saved(fake_home)["brain"] == str(new)
    assert new.is_dir() and list(new.iterdir()) == []
    assert (old / "nota.md").read_text() == "minha nota"


def test_config_set_rejects_file_path(fake_home, monkeypatch, capsys):
    import json

    _fake_runner(monkeypatch)
    afile = fake_home / "arquivo.txt"
    afile.write_text("x")
    assert main(["config", "set", "wisp_dir", str(afile), "--json"]) == 1
    out = json.loads(capsys.readouterr().out)
    assert out["status"] == "failed"
    assert not (fake_home / ".config/wisp/wisp.json").exists()
    assert afile.read_text() == "x"


def test_config_set_runs_sync(fake_home, monkeypatch, capsys):
    runner = _fake_runner(monkeypatch)
    target = fake_home / "MeuWisp"
    brain = fake_home / "brain"
    brain.mkdir()
    (fake_home / ".config/wisp").mkdir(parents=True)
    (fake_home / ".config/wisp/wisp.json").write_text(f'{{"brain": "{brain}"}}')
    assert main(["config", "set", "wisp_dir", str(target), "--json"]) == 0
    capsys.readouterr()
    assert _saved(fake_home)["wisp_dir"] == str(target)
    assert (target / "agente.md").is_file() and (target / "skills").is_dir()
    assert ["claude", "mcp", "get", "wisp-email"] in runner.calls
    assert (fake_home / ".claude/CLAUDE.md").exists()


def _set(key, value, capsys):
    import json

    code = main(["config", "set", key, value, "--json"])
    return code, json.loads(capsys.readouterr().out)


def test_config_set_expands_tilde_and_normalises(fake_home, monkeypatch, capsys):
    _fake_runner(monkeypatch)
    code, _ = _set("brain", "~/a/../cofre", capsys)
    assert code == 0
    assert _saved(fake_home)["brain"] == str(fake_home / "cofre")


def test_config_set_accepts_spaces_and_accents(fake_home, monkeypatch, capsys):
    _fake_runner(monkeypatch)
    brain = fake_home / "brain"
    brain.mkdir()
    (fake_home / ".config/wisp").mkdir(parents=True)
    (fake_home / ".config/wisp/wisp.json").write_text(f'{{"brain": "{brain}"}}')
    target = fake_home / "Minha Pasta" / "Wisp ç"
    code, _ = _set("wisp_dir", str(target), capsys)
    assert code == 0
    assert _saved(fake_home)["wisp_dir"] == str(target)
    assert (target / "agente.md").is_file()


def test_config_set_rejects_relative_path(fake_home, monkeypatch, capsys):
    _fake_runner(monkeypatch)
    code, out = _set("brain", "pasta/relativa", capsys)
    assert code == 1
    assert out["summary"] == "use um caminho completo (começando com / ou ~)"
    assert not (fake_home / ".config/wisp/wisp.json").exists()


def test_config_set_reports_sync_failure(fake_home, monkeypatch, capsys):
    from wisp import cli

    _fake_runner(monkeypatch)
    monkeypatch.setattr(cli, "setup_harness", lambda *a, **k: cli.StepReport("harness", "failed", "falta criar o cérebro antes"))
    code, out = _set("wisp_dir", str(fake_home / "W"), capsys)
    assert code == 1
    assert out["status"] == "failed"
    assert out["summary"] == "caminho salvo, mas o harness não sincronizou: falta criar o cérebro antes"
    assert _saved(fake_home)["wisp_dir"] == str(fake_home / "W")


def test_config_set_path_managed_elsewhere_is_a_neutral_success(fake_home, monkeypatch, capsys):
    from wisp import cli

    _fake_runner(monkeypatch)
    monkeypatch.setattr(
        cli, "setup_harness", lambda *a, **k: cli.StepReport("harness", "failed", "harness gerenciado fora do Wisp", data={"harness": "managed_elsewhere"})
    )
    code, out = _set("wisp_dir", str(fake_home / "W"), capsys)
    assert code == 0
    assert out["status"] == "done"
    assert out["summary"] == "caminho salvo; o harness é gerenciado fora do Wisp, então ele não foi alterado"
    assert out["data"]["harness"] == "managed_elsewhere"
    assert _saved(fake_home)["wisp_dir"] == str(fake_home / "W")


def test_config_set_engine_managed_elsewhere_is_a_neutral_success(fake_home, monkeypatch, capsys):
    from wisp import cli

    _fake_runner(monkeypatch)
    monkeypatch.setattr(
        cli, "setup_harness", lambda *a, **k: cli.StepReport("harness", "failed", "harness gerenciado fora do Wisp", data={"harness": "managed_elsewhere"})
    )
    code, out = _set("engine", "claude", capsys)
    assert code == 0
    assert out["status"] == "done"
    assert out["summary"] == "motor salvo; o harness é gerenciado fora do Wisp, então ele não foi alterado"
    assert out["data"]["harness"] == "managed_elsewhere"


def test_config_set_engine_managed_elsewhere_still_syncs_codex(fake_home, monkeypatch, capsys):
    from wisp import cli
    from wisp.setup.codex import CodexSync

    _fake_runner(monkeypatch)
    monkeypatch.setattr(
        cli, "setup_harness", lambda *a, **k: cli.StepReport("harness", "failed", "harness gerenciado fora do Wisp", data={"harness": "managed_elsewhere"})
    )
    calls = []
    monkeypatch.setattr(cli, "sync_codex", lambda *a, **k: calls.append(1) or CodexSync("updated"))
    code, out = _set("engine", "codex", capsys)
    assert code == 0
    assert calls == [1]
    assert out["status"] == "done"
    assert out["data"]["codex"] == "updated"
    assert out["data"]["harness"] == "managed_elsewhere"


def test_config_set_engine_managed_elsewhere_codex_failure_is_failed(fake_home, monkeypatch, capsys):
    from wisp import cli
    from wisp.setup.codex import CodexSync

    _fake_runner(monkeypatch)
    monkeypatch.setattr(
        cli, "setup_harness", lambda *a, **k: cli.StepReport("harness", "failed", "harness gerenciado fora do Wisp", data={"harness": "managed_elsewhere"})
    )
    monkeypatch.setattr(cli, "sync_codex", lambda *a, **k: CodexSync("failed"))
    code, out = _set("engine", "codex", capsys)
    assert code == 1
    assert out["status"] == "failed"
    assert out["data"]["codex"] == "failed"
    assert "o Codex não sincronizou" in out["summary"]


def test_config_set_engine_real_harness_failure_stays_failed(fake_home, monkeypatch, capsys):
    from wisp import cli

    _fake_runner(monkeypatch)
    monkeypatch.setattr(cli, "setup_harness", lambda *a, **k: cli.StepReport("harness", "failed", "falta criar o cérebro antes"))
    code, out = _set("engine", "claude", capsys)
    assert code == 1
    assert out["summary"] == "motor salvo, mas o harness não sincronizou: falta criar o cérebro antes"


def test_config_set_brain_existing_dir_untouched(fake_home, monkeypatch, capsys):
    _fake_runner(monkeypatch)
    vault = fake_home / "Vault"
    (vault / "sub").mkdir(parents=True)
    (vault / "sub/n.md").write_text("n")
    code, _ = _set("brain", str(vault), capsys)
    assert code == 0
    assert sorted(p.relative_to(vault).as_posix() for p in vault.rglob("*")) == ["sub", "sub/n.md"]
    assert (vault / "sub/n.md").read_text() == "n"


def test_config_set_sync_renders_from_new_folder(fake_home, monkeypatch, capsys):
    _fake_runner(monkeypatch)
    brain = fake_home / "brain"
    brain.mkdir()
    (fake_home / ".config/wisp").mkdir(parents=True)
    (fake_home / ".config/wisp/wisp.json").write_text(f'{{"brain": "{brain}"}}')
    target = fake_home / "Outro"
    target.mkdir()
    (target / "agente.md").write_text(
        (resources_root() / "harness/claude-md-block.md").read_text().split("<!-- wisp:begin -->\n", 1)[1].split("<!-- wisp:end -->", 1)[0]
        + "\nREGRA-DA-PASTA-NOVA\n"
    )
    code, _ = _set("wisp_dir", str(target), capsys)
    assert code == 0
    assert "REGRA-DA-PASTA-NOVA" in (fake_home / ".claude/CLAUDE.md").read_text()


def test_config_set_refuses_unreadable_config(fake_home, monkeypatch, capsys):
    _fake_runner(monkeypatch)
    cfg = fake_home / ".config/wisp/wisp.json"
    cfg.parent.mkdir(parents=True)
    cfg.write_text("{quebrado")
    target = fake_home / "cofre"
    code, out = _set("brain", str(target), capsys)
    assert code == 1
    assert out["summary"] == "não consegui ler o wisp.json; nada foi alterado"
    assert cfg.read_text() == "{quebrado"
    assert not target.exists()


def test_setup_folder_refuses_unreadable_config(fake_home, capsys):
    cfg = fake_home / ".config/wisp/wisp.json"
    cfg.parent.mkdir(parents=True)
    cfg.write_text("{quebrado")
    assert main(["setup", "folder", "--path", str(fake_home / "W"), "--json"]) == 1
    assert json.loads(capsys.readouterr().out)["summary"] == "não consegui ler o wisp.json; nada foi alterado"
    assert cfg.read_text() == "{quebrado"
    assert not (fake_home / "W").exists()


def test_setup_folder_rejects_relative_path(fake_home, capsys):
    assert main(["setup", "folder", "--path", "pasta/relativa", "--json"]) == 1
    assert json.loads(capsys.readouterr().out)["summary"] == "use um caminho completo (começando com / ou ~)"
    assert not (fake_home / ".config/wisp/wisp.json").exists()


def test_cli_import_does_not_load_mcp():
    import subprocess
    import sys

    code = "import sys, wisp.cli; print(any(m == 'mcp' or m.startswith(('mcp.', 'wisp.email')) for m in sys.modules))"
    assert subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True).stdout.strip() == "False"
