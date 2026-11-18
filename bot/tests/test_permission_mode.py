import json
from pathlib import Path

import pytest

from wisp_bot import claude_runner


@pytest.fixture
def perfil(tmp_path, monkeypatch):
    config = tmp_path / "wisp.json"
    config.write_text("{}")
    monkeypatch.setenv("WISP_CONFIG", str(config))
    return tmp_path / "profile.json"


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
