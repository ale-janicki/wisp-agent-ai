"""Alerta de login expirado do claude: binario e alert_cmd reais, so que scripts de tmp."""
import asyncio

from wisp_bot import claude_runner, hosting

SID = "11111111-1111-1111-1111-111111111111"


def _script(p, corpo):
    p.write_text("#!/bin/sh\n" + corpo)
    p.chmod(0o755)
    return str(p)


def _mundo(tmp_path, monkeypatch):
    log = tmp_path / "alerta.log"
    rec = _script(tmp_path / "alerta", f'echo "$@" >> {log}\n')
    monkeypatch.setattr(hosting, "ALERTA", [rec])
    monkeypatch.setattr(claude_runner, "_alerta_aberto", False)
    monkeypatch.setattr(claude_runner, "_resolvido_boot", False)
    return log


def _roda(tmp_path, monkeypatch, bin_):
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", bin_)

    async def go():
        r = await claude_runner.run("oi", session_id=SID, cwd=str(tmp_path), started=False, timeout=20)
        await asyncio.gather(*list(claude_runner._soltas))
        return r
    return asyncio.run(go())


def _linhas(log):
    return log.read_text().splitlines() if log.exists() else []


def test_auth_expirada_alerta_uma_vez_e_sucesso_resolve(tmp_path, monkeypatch):
    log = _mundo(tmp_path, monkeypatch)
    ruim = _script(tmp_path / "ruim", 'echo "Failed to authenticate: OAuth session expired and could not be refreshed" >&2\nexit 1\n')
    bom = _script(tmp_path / "bom", 'echo \'{"type":"result","result":"ok","session_id":"s"}\'\n')
    assert not _roda(tmp_path, monkeypatch, ruim).ok
    assert not _roda(tmp_path, monkeypatch, ruim).ok
    adds = _linhas(log)
    assert len(adds) == 1
    assert adds[0].startswith("add --nivel red --chave claude-oauth-expirado --frente bot ")
    assert "/login" in adds[0]
    assert _roda(tmp_path, monkeypatch, bom).ok
    assert _linhas(log)[1:] == ["resolve claude-oauth-expirado"]
    assert _roda(tmp_path, monkeypatch, bom).ok
    assert len(_linhas(log)) == 2          # so fecha uma vez


def test_not_logged_in_no_stdout_tambem_alerta(tmp_path, monkeypatch):
    log = _mundo(tmp_path, monkeypatch)
    ruim = _script(tmp_path / "ruim", 'echo "Not logged in · Please run /login"\nexit 1\n')
    _roda(tmp_path, monkeypatch, ruim)
    assert len(_linhas(log)) == 1


def test_falha_comum_nao_alerta(tmp_path, monkeypatch):
    log = _mundo(tmp_path, monkeypatch)
    ruim = _script(tmp_path / "ruim", 'echo "boom" >&2\nexit 1\n')
    _roda(tmp_path, monkeypatch, ruim)
    assert _linhas(log) == []


def test_primeiro_sucesso_do_processo_fecha_alerta_antigo(tmp_path, monkeypatch):
    log = _mundo(tmp_path, monkeypatch)
    bom = _script(tmp_path / "bom", 'echo \'{"type":"result","result":"ok"}\'\n')
    _roda(tmp_path, monkeypatch, bom)
    assert _linhas(log) == ["resolve claude-oauth-expirado"]


def test_alert_cmd_ausente_nunca_quebra_o_turno(tmp_path, monkeypatch):
    _mundo(tmp_path, monkeypatch)
    monkeypatch.setattr(hosting, "ALERTA", [str(tmp_path / "nao-existe")])
    bom = _script(tmp_path / "bom", 'echo \'{"type":"result","result":"ok"}\'\n')
    assert _roda(tmp_path, monkeypatch, bom).ok
