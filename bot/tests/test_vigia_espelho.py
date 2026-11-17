"""O espelho (/me-avisa) e persistente: replay do jsonl REAL da sessao c769c446 (recorte saneado em fixtures/,
23/10 20:38-20:59 UTC) pela logica nova de avaliar() + _vigia_um() do bot. Nada fala com o Telegram: o post e capturado."""
import asyncio
import json
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from wisp_bot import bot, vigia
from wisp_bot.store import Store

FIX = Path(__file__).parent / "fixtures" / "espelho-c769c446.jsonl"
SID, CWD = "c769c446-3a27-4237-80e2-51ef11c5ed8c", "/Users/_x/repos/app"
CHAT, THREAD = 1, 2317


def t(s: str) -> datetime:
    return datetime.fromisoformat(s + "+00:00").astimezone(timezone.utc)


def linha(ts: str, tipo: str, conteudo, **extra) -> str:
    return json.dumps({"type": tipo, "timestamp": ts + "Z", "message": {"role": tipo, "content": conteudo, **extra}})


class Mundo:
    """Registro, store e projetos em tmp; o relogio do avaliar() e o do teste."""

    def __init__(self, tmp_path, monkeypatch):
        self.jsonl = tmp_path / vigia.slug(CWD) / f"{SID}.jsonl"
        self.jsonl.parent.mkdir(parents=True)
        self.posts: list[tuple[str, str]] = []
        self.agora = t("2026-10-23T20:39:00")
        monkeypatch.setattr(vigia, "PROJETOS", tmp_path)
        monkeypatch.setattr(vigia, "ARQUIVO", tmp_path / "vigias.json")
        monkeypatch.setattr(bot, "store", Store(tmp_path / "topics.json"))
        bot.store.get_or_create(f"{CHAT}:{THREAD}", "mirror", CWD, meta={"espelho": SID})
        monkeypatch.setattr(bot, "vigilia", SimpleNamespace(segurar=lambda *a: None, soltar=lambda *a: None))
        orig = vigia.avaliar
        monkeypatch.setattr(vigia, "avaliar", lambda sid, cwd, agora=None, desde=None: orig(sid, cwd, self.agora, desde))

        async def postar(app, rec, texto):
            self.posts.append((self.agora.strftime("%H:%M:%S"), texto))
        monkeypatch.setattr(bot, "_vigia_postar", postar)
        vigia.registrar({"session_id": SID, "cwd": CWD, "thread": THREAD, "chat": CHAT, "nome": "mirror",
                         "host": bot.HOST, "desde": t("2026-10-23T20:42:47").timestamp(),
                         "estado": "rodando", "avisado": "rodando", "motivo": ""})

    def tick(self, ate: str, passo_s: int = 30) -> None:
        fim = t(ate)
        while self.agora <= fim and SID in vigia.ler():
            asyncio.run(bot._vigia_um(None, SID, vigia.ler()[SID]))
            self.agora += timedelta(seconds=passo_s)

    def registro(self) -> dict | None:
        return vigia.ler().get(SID)


@pytest.fixture
def mundo(tmp_path, monkeypatch):
    m = Mundo(tmp_path, monkeypatch)
    shutil.copy(FIX, m.jsonl)
    return m


def test_a1_replay_real_um_terminou_por_turno_e_registro_fica(mundo):
    mundo.tick("2026-10-23T21:10:00")
    # Antes: avaliar dava "encerrada" ~2 min depois do end_turn das 20:42:57 e o bot removia o registro (bug de 23/10).
    # Agora: a varredura (bzx30pbf3, depois VQeCn6) segura "rodando" ate o aviso de fim das 20:56:37; o vigia-wait nao conta.
    # Dos end_turn seguintes (20:56:44, 20:57:34) nenhum fica 120 s parado: chega prompt antes. Sobra o das 20:59:14.
    assert [p[0] for p in mundo.posts] == ["21:01:30"]
    assert mundo.posts[0][1].startswith("✅ terminou")
    assert mundo.registro() is not None                           # espelho continua
    assert mundo.registro()["avisado_fim"].startswith("2026-10-23T20:59:14")


def test_a1_red_sem_contar_o_shell_o_terminou_sai_cedo_demais(mundo, monkeypatch):
    monkeypatch.setattr(vigia, "_bg_pendentes", lambda linhas, agora: [])   # o comportamento de antes
    mundo.tick("2026-10-23T20:50:00")
    assert mundo.posts and mundo.posts[0][0] < "20:50:00"                    # "terminou" com a varredura ainda rodando


def test_a1_mesmo_fim_nao_avisa_duas_vezes_e_turno_novo_rearma(mundo):
    mundo.tick("2026-10-23T21:05:00")
    assert len(mundo.posts) == 1
    with open(mundo.jsonl, "a") as f:                             # novo turno: prompt + resposta final
        f.write(linha("2026-10-23T21:10:00", "user", "mais uma pergunta") + "\n")
        f.write(linha("2026-10-23T21:10:10", "assistant", [{"type": "text", "text": "feito"}], stop_reason="end_turn") + "\n")
    mundo.agora = t("2026-10-23T21:05:30")
    mundo.tick("2026-10-23T21:20:00")
    assert len(mundo.posts) == 2 and "feito" in mundo.posts[1][1]       # 1 por turno acabado: 20:59:14 e 21:10:10
    assert mundo.registro() is not None


def test_a1_turno_ja_terminado_antes_do_vinculo_nao_gera_terminou(mundo):
    vigia.atualizar(SID, desde=t("2026-10-23T22:00:00").timestamp())   # vinculo depois de tudo que o jsonl tem
    mundo.agora = t("2026-10-23T22:10:00")
    mundo.tick("2026-10-23T22:12:00")
    assert mundo.posts == [] and mundo.registro() is not None


def test_a2_bash_em_segundo_plano_pendente_e_rodando_e_o_vigia_wait_nao_conta(tmp_path, monkeypatch):
    m = Mundo(tmp_path, monkeypatch)
    bg = lambda i, cmd: [{"type": "tool_use", "id": i, "name": "Bash", "input": {"command": cmd, "run_in_background": True}}]
    m.jsonl.write_text("\n".join([
        linha("2026-10-23T20:00:00", "user", "faz"),
        linha("2026-10-23T20:00:01", "assistant", bg("toolu_A", "sleep 900")),
        linha("2026-10-23T20:00:02", "assistant", bg("toolu_W", "~/.claude/bin/vigia-wait " + SID)),
        linha("2026-10-23T20:00:05", "assistant", [{"type": "text", "text": "rodando"}], stop_reason="end_turn"),
    ]) + "\n")
    r = vigia.avaliar(SID, CWD, t("2026-10-23T20:10:00"))
    assert r["estado"] == "rodando" and "1 shell" in r["motivo"]       # so o toolu_A; o vigia-wait fica de fora
    with open(m.jsonl, "a") as f:                                     # o aviso de fim chega (mensagem user, string)
        f.write(linha("2026-10-23T20:11:00", "user",
                      "<task-notification>\n<task-id>x</task-id>\n<tool-use-id>toolu_A</tool-use-id>\n"
                      "<status>completed</status>\n</task-notification>") + "\n")
        f.write(linha("2026-10-23T20:11:05", "assistant", [{"type": "text", "text": "acabou"}], stop_reason="end_turn") + "\n")
    r = vigia.avaliar(SID, CWD, t("2026-10-23T20:14:00"))
    assert r["estado"] == "encerrada" and r["fim"].startswith("2026-10-23T20:11:05") and not r.get("remover")


def test_a2_so_o_vigia_wait_pendente_nao_segura_o_encerrada(tmp_path, monkeypatch):
    m = Mundo(tmp_path, monkeypatch)
    m.jsonl.write_text("\n".join([
        linha("2026-10-23T20:00:00", "user", "faz"),
        linha("2026-10-23T20:00:01", "assistant", [{"type": "tool_use", "id": "toolu_W", "name": "Bash",
              "input": {"command": "vigia-wait " + SID, "run_in_background": True}}]),
        linha("2026-10-23T20:00:05", "assistant", [{"type": "text", "text": "ok"}], stop_reason="end_turn"),
    ]) + "\n")
    assert vigia.avaliar(SID, CWD, t("2026-10-23T20:03:00"))["estado"] == "encerrada"


def test_a3_exit_remove_o_registro(mundo):
    mundo.tick("2026-10-23T21:05:00")
    assert mundo.registro() is not None
    with open(mundo.jsonl, "a") as f:
        f.write(linha("2026-10-23T21:06:00", "user", "<command-name>/exit</command-name>") + "\n")
    mundo.agora = t("2026-10-23T21:06:30")
    r = vigia.avaliar(SID, CWD, mundo.agora)
    assert r["estado"] == "encerrada" and r["remover"] is True
    mundo.tick("2026-10-23T21:07:00")
    assert mundo.registro() is None
    assert any("vigia encerrado" in p[1] for p in mundo.posts)


def test_idade_maior_que_12h_remove(mundo):
    mundo.agora = t("2026-10-24T09:00:00")                        # ultimo evento do jsonl: 23/10 20:59
    mundo.tick("2026-10-24T09:00:00")
    assert mundo.registro() is None


def _linha(ts, **k):
    import json as _j
    return _j.dumps({"timestamp": ts, **k}) + "\n"


def test_agente_parado_com_taskstop_nao_trava_e_retomado_volta_a_contar(tmp_path, monkeypatch):
    from wisp_bot import vigia as v
    proj = tmp_path / "proj"; sub = proj / "s1" / "subagents"; sub.mkdir(parents=True)
    principal = proj / "s1.jsonl"
    stop = {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t9", "name": "TaskStop",
                                                          "input": {"task_id": "aaa"}}]}}
    principal.write_text(_linha("2026-10-23T10:00:00Z", type="user", message={"content": "faz"})
                         + _linha("2026-10-23T12:00:00Z", **stop), "utf-8")
    passo = {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "x1", "name": "Bash", "input": {}}]}}
    (sub / "agent-aaa.jsonl").write_text(_linha("2026-10-23T11:00:00Z", **passo), "utf-8")   # parou antes do TaskStop
    v._fechados_cache.clear()
    agora = v._ts("2026-10-23T13:00:00Z")
    monkeypatch.setattr(v, "_jsonl_principal", lambda sid, cwd: principal)
    r = v.avaliar("s1", "", agora=agora)
    assert r["estado"] != "travado", r                                       # 120 min sem tool, mas foi parado
    (sub / "agent-aaa.jsonl").write_text(_linha("2026-10-23T11:00:00Z", **passo)
                                         + _linha("2026-10-23T12:55:00Z", **passo), "utf-8")   # retomado depois
    r = v.avaliar("s1", "", agora=agora)
    assert r["estado"] == "rodando" and "agente" in r["motivo"], r


def test_pergunta_pendente_aparece_e_some_quando_respondida(tmp_path):
    from wisp_bot import vigia as v
    p = tmp_path / "s.jsonl"
    ask = {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "q1", "name": "AskUserQuestion",
           "input": {"questions": [{"question": "Sigo?", "options": [{"label": "Sim"}, {"label": "Não"}]}]}}]}}
    p.write_text(_linha("2026-10-23T10:00:00Z", **ask), "utf-8")
    perg = v._pergunta_pendente(p)
    assert perg and perg["id"] == "q1" and "Sigo?" in perg["texto"] and "Sim · Não" in perg["texto"]
    res = {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "q1", "content": "Sim"}]}}
    p.write_text(_linha("2026-10-23T10:00:00Z", **ask) + _linha("2026-10-23T10:01:00Z", **res), "utf-8")
    assert v._pergunta_pendente(p) is None
