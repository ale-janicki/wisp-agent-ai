import json
from pathlib import Path

import pytest

from wisp_bot import claude_runner


@pytest.fixture
def perfil(tmp_path, monkeypatch):
    config = tmp_path / "wisp.json"
    config.write_text("{}")
    monkeypatch.setenv("WISP_CONFIG", str(config))
    monkeypatch.setattr(claude_runner, "AJUSTES_DO_APP", tmp_path / "app" / "settings.json")
    monkeypatch.setattr(claude_runner, "_auto_recusado", False)
    return tmp_path / "profile.json"


def _ajustes(tmp_path: Path, conteudo) -> None:
    arquivo = tmp_path / "app" / "settings.json"
    arquivo.parent.mkdir(exist_ok=True)
    arquivo.write_text(conteudo if isinstance(conteudo, str) else json.dumps(conteudo))


def _grava(perfil: Path, agente) -> None:
    perfil.write_text(json.dumps({"persona": {"name": "W", "language": "pt-BR"}, "agent": agente}))


@pytest.mark.parametrize("modo, esperado", [
    ("bypassPermissions", "bypassPermissions"),
    ("auto", "auto"),
    ("default", "auto"),
    ("manual", "auto"),
    ("plan", "bypassPermissions"),
])
def test_modo_do_perfil(perfil, modo, esperado):
    _grava(perfil, {"cwd": "~", "permissionMode": modo})
    assert claude_runner.permission_mode() == esperado


def test_sem_valor_sem_perfil_ou_quebrado_fica_sem_pedir(perfil):
    assert claude_runner.permission_mode() == "bypassPermissions"
    _grava(perfil, {"cwd": "~"})
    assert claude_runner.permission_mode() == "bypassPermissions"
    _grava(perfil, "nao e objeto")
    assert claude_runner.permission_mode() == "bypassPermissions"
    perfil.write_text("{quebrado")
    assert claude_runner.permission_mode() == "bypassPermissions"


def test_o_turno_usa_o_modo(perfil, tmp_path, monkeypatch):
    import asyncio
    _grava(perfil, {"cwd": "~", "permissionMode": "default"})
    args = tmp_path / "args"
    fake = tmp_path / "claude"
    fake.write_text(f'#!/bin/sh\necho "$@" > {args}\n'
                    'echo \'{"type":"result","is_error":false,"result":"ok","session_id":"s"}\'\n')
    fake.chmod(0o755)
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(fake))
    sid = "11111111-1111-1111-1111-111111111111"
    asyncio.run(claude_runner.run("oi", session_id=sid, cwd=str(tmp_path), started=False, timeout=20))
    assert "--permission-mode auto" in args.read_text()


def test_perfil_link_usa_os_ajustes_do_app(perfil, tmp_path):
    _grava(perfil, {"cwd": "~"})
    _ajustes(tmp_path, {"theme": "x", "permissionMode": "default"})
    assert claude_runner.permission_source() == ("auto", "ajustes do Wisp")


def test_ajustes_vencem_o_perfil_como_no_app(perfil, tmp_path):
    _grava(perfil, {"cwd": "~", "permissionMode": "bypassPermissions"})
    _ajustes(tmp_path, {"permissionMode": "auto"})
    assert claude_runner.permission_source() == ("auto", "ajustes do Wisp")


def test_ajustes_sem_chave_ou_quebrados_caem_no_perfil(perfil, tmp_path):
    _grava(perfil, {"cwd": "~", "permissionMode": "auto"})
    _ajustes(tmp_path, {"theme": "x"})
    assert claude_runner.permission_source() == ("auto", "profile.json")
    _ajustes(tmp_path, {"permissionMode": "plan"})
    assert claude_runner.permission_source() == ("auto", "profile.json")
    _ajustes(tmp_path, "{quebrado")
    assert claude_runner.permission_source() == ("auto", "profile.json")
    perfil.unlink()
    assert claude_runner.permission_source() == ("bypassPermissions", "padrao")


@pytest.mark.parametrize("codigo, stderr, init, esperado", [
    (1, "error: option '--permission-mode <mode>' argument 'auto' is invalid", None, True),
    (1, "Permission mode auto is not available for this account", None, True),
    (0, "permission-mode auto", None, False),
    (1, "permission-mode auto", "default", False),
    (1, "failed to authenticate", None, False),
])
def test_detecta_recusa_do_auto(codigo, stderr, init, esperado):
    assert claude_runner.auto_recusado(codigo, stderr, init) is esperado


def _claude_que_recusa_auto(tmp_path: Path) -> Path:
    log = tmp_path / "chamadas"
    fake = tmp_path / "claude"
    fake.write_text('#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --permission-mode ] && modo=$2; shift; done\n'
                    f'echo "$modo" >> {log}\n'
                    '[ "$modo" = auto ] && { echo "error: option \'--permission-mode <mode>\' argument \'auto\' is invalid" >&2; exit 1; }\n'
                    'echo \'{"type":"result","is_error":false,"result":"ok","session_id":"s"}\'\n')
    fake.chmod(0o755)
    return log


def test_auto_recusado_roda_de_novo_em_accept_edits_nunca_bypass(perfil, tmp_path, monkeypatch, caplog):
    import asyncio, logging
    _grava(perfil, {"cwd": "~", "permissionMode": "default"})
    chamadas = _claude_que_recusa_auto(tmp_path)
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(tmp_path / "claude"))
    sid = "11111111-1111-1111-1111-111111111111"
    with caplog.at_level(logging.INFO, logger="wisp.claude"):
        r = asyncio.run(claude_runner.run("oi", session_id=sid, cwd=str(tmp_path), started=False, timeout=20))
    assert r.ok and r.text == "ok"
    linhas = chamadas.read_text().splitlines()
    assert linhas == ["auto", "acceptEdits"]
    assert "permissao do turno: auto (profile.json)" in caplog.text

    asyncio.run(claude_runner.run("oi", session_id=sid, cwd=str(tmp_path), started=True, timeout=20))
    linhas = chamadas.read_text().splitlines()
    assert linhas == ["auto", "acceptEdits", "acceptEdits"], "o processo lembra da recusa"


def test_sem_pedir_nunca_tenta_auto(perfil, tmp_path, monkeypatch):
    import asyncio
    _grava(perfil, {"cwd": "~", "permissionMode": "bypassPermissions"})
    chamadas = _claude_que_recusa_auto(tmp_path)
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(tmp_path / "claude"))
    sid = "11111111-1111-1111-1111-111111111111"
    asyncio.run(claude_runner.run("oi", session_id=sid, cwd=str(tmp_path), started=False, timeout=20))
    assert chamadas.read_text().splitlines() == ["bypassPermissions"]


def test_o_turno_leva_o_settings_com_os_guards(perfil, tmp_path, monkeypatch):
    import asyncio, json, shlex
    args = tmp_path / "args"
    fake = tmp_path / "claude"
    fake.write_text(f'#!/bin/sh\necho "$@" > {args}\n'
                    'echo \'{"type":"result","is_error":false,"result":"ok","session_id":"s"}\'\n')
    fake.chmod(0o755)
    settings = tmp_path / "state" / "guard-settings.json"
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(fake))
    monkeypatch.setattr(claude_runner, "guard_settings_path", lambda: settings)
    sid = "11111111-1111-1111-1111-111111111111"
    asyncio.run(claude_runner.run("oi", session_id=sid, cwd=str(tmp_path), started=False, timeout=20))
    assert f"--settings {settings}" in args.read_text()
    commands = [h["command"] for h in json.loads(settings.read_text())["hooks"]["PreToolUse"][0]["hooks"]]
    assert [shlex.split(c)[0] for c in commands] == [claude_runner.WISP_BIN] * 5
    assert [c.rsplit(" ", 1)[1] for c in commands] == ["guard-secrets", "guard-telegram", "guard-destructive", "guard-lessons", "guard-agenda"]
    recall = json.loads(settings.read_text())["hooks"]["UserPromptSubmit"][0]["hooks"][0]
    assert recall["command"].endswith(" hook recall") and recall["timeout"] == 5
    lessons = json.loads(settings.read_text())["hooks"]["SessionStart"][0]["hooks"][0]
    assert lessons["command"].endswith(" hook aprendizados") and lessons["timeout"] == 5


def test_settings_dos_guards_igual_ao_fixture_e_idempotente(tmp_path):
    import json
    from pathlib import Path
    fixture = json.loads((Path(__file__).parents[2] / "cli/tests/fixtures/contract/guard-settings.json").read_text())
    assert claude_runner.guard_settings("/opt/my wisp/bin/wisp") == fixture
    path = tmp_path / "g.json"
    claude_runner.write_guard_settings(path, "/opt/my wisp/bin/wisp")
    mtime = path.stat().st_mtime_ns
    claude_runner.write_guard_settings(path, "/opt/my wisp/bin/wisp")
    assert path.stat().st_mtime_ns == mtime


def test_sem_as_travas_o_turno_e_recusado_e_o_claude_nao_roda(perfil, tmp_path, monkeypatch, caplog):
    import asyncio
    ran = tmp_path / "ran"
    fake = tmp_path / "claude"
    fake.write_text(f"#!/bin/sh\ntouch {ran}\n")
    fake.chmod(0o755)
    blocker = tmp_path / "blocker"
    blocker.write_text("x")
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(fake))
    monkeypatch.setattr(claude_runner, "guard_settings_path", lambda: blocker / "sub" / "guard-settings.json")
    sid = "11111111-1111-1111-1111-111111111111"
    with caplog.at_level("ERROR"):
        res = asyncio.run(claude_runner.run("oi", session_id=sid, cwd=str(tmp_path), started=False, timeout=20))
    assert not res.ok and res.text.startswith("não consegui ativar as travas do Wisp: ")
    assert not ran.exists()
    assert any("travas" in r.message for r in caplog.records)


@pytest.mark.parametrize("modo_do_arquivo", [None, 0o644])
def test_sem_o_cli_do_wisp_o_turno_e_recusado_e_o_claude_nao_roda(perfil, tmp_path, monkeypatch, modo_do_arquivo):
    import asyncio
    ran = tmp_path / "ran"
    fake = tmp_path / "claude"
    fake.write_text(f"#!/bin/sh\ntouch {ran}\n")
    fake.chmod(0o755)
    wisp = tmp_path / "wisp"
    if modo_do_arquivo is not None:
        wisp.write_text("x")
        wisp.chmod(modo_do_arquivo)
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(fake))
    monkeypatch.setattr(claude_runner, "WISP_BIN", str(wisp))
    sid = "11111111-1111-1111-1111-111111111111"
    res = asyncio.run(claude_runner.run("oi", session_id=sid, cwd=str(tmp_path), started=False, timeout=20))
    assert not res.ok and res.text.startswith("não consegui ativar as travas do Wisp: ")
    assert str(wisp) in res.text
    assert not ran.exists()


def test_every_bot_turn_runs_without_the_ui_only_question_tool(perfil, tmp_path, monkeypatch):
    import asyncio
    _grava(perfil, {"cwd": "~"})
    args = tmp_path / "args"
    fake = tmp_path / "claude"
    fake.write_text(f'#!/bin/sh\nfor a in "$@"; do echo "$a"; done > {args}\n'
                    'echo \'{"type":"result","is_error":false,"result":"ok","session_id":"s"}\'\n')
    fake.chmod(0o755)
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(fake))
    sid = "11111111-1111-1111-1111-111111111111"
    asyncio.run(claude_runner.run("oi", session_id=sid, cwd=str(tmp_path), started=False, timeout=20))
    lines = args.read_text().splitlines()
    assert lines[lines.index("--disallowedTools") + 1] == "AskUserQuestion"
    asyncio.run(claude_runner.run("oi", session_id=sid, cwd=str(tmp_path), started=False, timeout=20, disallowed="Bash"))
    lines = args.read_text().splitlines()
    assert lines[lines.index("--disallowedTools") + 1] == "AskUserQuestion,Bash"
