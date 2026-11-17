"""avaliar() sobre jsonl reais da noite de 22->23/10, saneados (eventos, horarios e ids reais; texto neutro); registro em tmp."""
import shutil
from datetime import datetime, timezone
from pathlib import Path

import pytest

from wisp_bot import vigia

FIX = Path(__file__).parent / "fixtures"
SID, CWD = "a5ddbd7e-4c64-4854-8d73-e8bc30d577c5", "/Users/_x/repos/app"


def t(s: str) -> datetime:
    return datetime.fromisoformat(s + "+00:00").astimezone(timezone.utc)


@pytest.fixture
def projetos(tmp_path, monkeypatch):
    """~/.claude/projects de mentira com a sessao principal real; os agentes entram por teste."""
    d = tmp_path / vigia.slug(CWD)
    d.mkdir()
    shutil.copy(FIX / "main-sessao.jsonl", d / f"{SID}.jsonl")
    (d / SID / "subagents").mkdir(parents=True)
    monkeypatch.setattr(vigia, "PROJETOS", tmp_path)
    return d / SID / "subagents"


def agente(subs: Path, fixture: str) -> None:
    shutil.copy(FIX / fixture, subs / "agent-abaf6855df5b99ee7.jsonl")


def test_agente_travado_por_cutoff(projetos):
    agente(projetos, "agent-travado.jsonl")
    r = vigia.avaliar(SID, CWD, agora=t("2026-10-23T06:00:00"))      # 2 injects "cut off" ja vistos
    assert r["estado"] == "travado" and "abaf6855" in r["motivo"] and "cortado" in r["motivo"]
    assert "Matei o shell" in r["ultimo_texto"]


def test_agente_travado_por_ociosidade(projetos):
    agente(projetos, "agent-travado.jsonl")
    # 1 inject as 05:05:44 e nenhuma tool nova desde 05:00:48: 9 min = vivo; 15,8 min = travado
    # (a mesma hora, 02:21 BRT, em que o probe 4 acusou o incidente)
    assert vigia.avaliar(SID, CWD, agora=t("2026-10-23T05:15:00"))["estado"] == "rodando"
    r = vigia.avaliar(SID, CWD, agora=t("2026-10-23T05:21:40"))
    assert r["estado"] == "travado" and "sem tool" in r["motivo"]


def test_agente_saudavel_nao_trava(projetos):
    shutil.copy(FIX / "agent-saudavel.jsonl", projetos / "agent-a234f4a6e84dc37c5.jsonl")
    meio = vigia.avaliar(SID, CWD, agora=t("2026-10-23T04:42:25"))   # em plena atividade
    fim = vigia.avaliar(SID, CWD, agora=t("2026-10-23T05:30:00"))    # acabou em end_turn as 04:42:45
    assert meio["estado"] == "rodando"
    assert fim["estado"] == "encerrada"          # agente terminou + turno principal terminou + ocioso


def test_encerrada_sem_agente_traz_o_ultimo_texto(projetos):
    r = vigia.avaliar(SID, CWD, agora=t("2026-10-23T05:00:00"))
    assert r["estado"] == "encerrada" and r["ultimo_texto"].startswith("Matei o shell")
    assert len(r["ultimo_texto"]) <= vigia.TEXTO_MAX


def test_turno_recem_terminado_ainda_nao_e_encerrada(projetos):
    assert vigia.avaliar(SID, CWD, agora=t("2026-10-23T04:57:30"))["estado"] == "rodando"


def test_turno_em_andamento(projetos):
    r = vigia.avaliar(SID, CWD, agora=t("2026-10-23T04:57:08"))      # tool em voo, sem end_turn
    assert r["estado"] == "rodando"


def test_sessao_sem_jsonl(tmp_path, monkeypatch):
    monkeypatch.setattr(vigia, "PROJETOS", tmp_path)
    assert vigia.avaliar("nao-existe", CWD)["estado"] == "rodando"


def test_registro(tmp_path):
    f = tmp_path / "sub" / "vigias.json"
    assert vigia.ler(f) == {}
    vigia.registrar({"session_id": "s1", "estado": "rodando", "avisado": "rodando"}, f)
    vigia.registrar({"session_id": "s2", "estado": "rodando", "avisado": "rodando"}, f)
    vigia.atualizar("s1", f, estado="travado")
    vigia.atualizar("nada", f, estado="x")                           # inexistente: ignora
    d = vigia.ler(f)
    assert d["s1"]["estado"] == "travado" and d["s1"]["avisado"] == "rodando" and set(d) == {"s1", "s2"}
    vigia.remover("s1", f)
    vigia.remover("s1", f)
    assert set(vigia.ler(f)) == {"s2"}
    assert not list(f.parent.glob("*.tmp"))


def test_registro_corrompido_nao_derruba(tmp_path):
    f = tmp_path / "v.json"
    f.write_text("{pela metade")
    assert vigia.ler(f) == {}


def test_principal_parada_ha_mais_de_12h(projetos):
    r = vigia.avaliar(SID, CWD, agora=t("2026-10-24T05:00:00"))     # ultimo evento ~04:57 do dia 23
    assert r["estado"] == "encerrada" and "12h" in r["motivo"]


def test_jsonl_nunca_resolve(tmp_path, monkeypatch):
    monkeypatch.setattr(vigia, "PROJETOS", tmp_path)
    agora = t("2026-10-23T12:00:00")
    assert vigia.avaliar("x", CWD, agora, "2026-10-23T11:50:00+00:00")["estado"] == "rodando"
    assert vigia.avaliar("x", CWD, agora, "2026-10-23T11:00:00+00:00")["estado"] == "encerrada"
    assert vigia.avaliar("x", CWD, agora)["estado"] == "rodando"    # sem `desde`: comportamento antigo


def test_atualizar_sem_mudanca_nao_escreve(tmp_path):
    f = tmp_path / "v.json"
    vigia.registrar({"session_id": "s1", "estado": "rodando"}, f)
    antes = f.stat().st_mtime_ns
    vigia.atualizar("s1", f, estado="rodando")
    assert f.stat().st_mtime_ns == antes
    vigia.atualizar("s1", f, estado="travado")
    assert vigia.ler(f)["s1"]["estado"] == "travado"


def _escreve(arq: str, prefixo: str, n: int) -> None:
    from wisp_bot import vigia as v
    for i in range(n):
        v.registrar({"session_id": f"{prefixo}{i}"}, Path(arq))


def test_dois_processos_nao_perdem_registros(tmp_path):
    import multiprocessing as mp
    f = tmp_path / "v.json"
    ctx = mp.get_context("spawn")
    ps = [ctx.Process(target=_escreve, args=(str(f), p, 40)) for p in "ab"]
    [p.start() for p in ps]
    [p.join(60) for p in ps]
    assert all(p.exitcode == 0 for p in ps)
    assert len(vigia.ler(f)) == 80


def test_env_vigias_file(tmp_path):
    import subprocess, sys
    f = tmp_path / "x.json"
    out = subprocess.run([sys.executable, "-c", "from wisp_bot import vigia; print(vigia.ARQUIVO)"],
                         env={**__import__("os").environ, "VIGIAS_FILE": str(f)}, capture_output=True,
                         text=True, cwd=Path(__file__).parent.parent)
    assert out.stdout.strip() == str(f)


def test_desde_epoch_int(tmp_path, monkeypatch):
    monkeypatch.setattr(vigia, "PROJETOS", tmp_path)
    agora = t("2026-10-23T12:00:00")
    epoch = int(agora.timestamp())
    assert vigia.avaliar("x", CWD, agora, epoch - 7200)["estado"] == "encerrada"
    assert vigia.avaliar("x", CWD, agora, epoch)["estado"] == "rodando"


def test_desde_lixo_nao_levanta(tmp_path, monkeypatch):
    monkeypatch.setattr(vigia, "PROJETOS", tmp_path)
    assert vigia.avaliar("x", CWD, t("2026-10-23T12:00:00"), "garbage")["estado"] == "rodando"


def test_exit_no_terminal_encerra(tmp_path, monkeypatch):
    """Sessao real de 23/10 16:22: turno terminou e o usuario deu /exit; o eco do comando nao e turno."""
    sid = "81ef1274-50f7-4b76-9a00-60be21c760d6"
    d = tmp_path / vigia.slug("/Users/_x")
    d.mkdir()
    shutil.copy(FIX / "main-exit.jsonl", d / f"{sid}.jsonl")
    monkeypatch.setattr(vigia, "PROJETOS", tmp_path)
    antes = vigia.avaliar(sid, "/Users/_x", t("2026-10-23T19:23:00"))
    assert antes["estado"] == "rodando" and antes["motivo"] == "turno acabou de terminar"
    r = vigia.avaliar(sid, "/Users/_x", t("2026-10-23T19:23:50"))
    assert r["estado"] == "encerrada" and r["motivo"] == "sessao fechada no terminal"
    assert r["ultimo_texto"].startswith("1, 2, 3.")
