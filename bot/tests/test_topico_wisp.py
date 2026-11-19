import json
import subprocess
import time


SID = "11111111-2222-4333-8444-555555555555"


def test_trazer_se_maior_traz_so_se_o_pc_tem_mais(monkeypatch):
    from wisp_bot import sessao
    monkeypatch.setattr(sessao, "ssh_pc", lambda script, prazo: (0, "5000\n"))
    trazidas = []
    monkeypatch.setattr(sessao, "buscar_do_pc", lambda sid, cwd, timeout_s: trazidas.append((sid, cwd, timeout_s)))
    monkeypatch.setattr(sessao, "tamanho_local", lambda sid: 1000)
    assert sessao.trazer_se_maior(SID, "/x", 30) == "trazida" and trazidas[0][0] == SID and trazidas[0][2] <= 30
    monkeypatch.setattr(sessao, "tamanho_local", lambda sid: 5000)
    assert sessao.trazer_se_maior(SID, "/x", 30) == "local" and len(trazidas) == 1

    def falha(sid, cwd, timeout_s): raise RuntimeError("ssh caiu")
    monkeypatch.setattr(sessao, "buscar_do_pc", falha)
    monkeypatch.setattr(sessao, "tamanho_local", lambda sid: 0)
    assert sessao.trazer_se_maior(SID, "/x", 30) == "falhou"


def _saida_claim(anterior: str, nosso: str, pc_st: dict | None, agora: int | None = None) -> str:
    agora = int(time.time()) if agora is None else agora
    return f"{anterior}\n{nosso}\n{json.dumps(pc_st) if pc_st else ''}\n{agora}\n"


NOSSO = '{"host": "mac", "ts": 2000}'
ANTERIOR = '{"host": "pc", "ts": 1000}'
PC_NOVO = {"host": "pc", "state": "active", "ts": int(time.time()), "proto": 2}


def test_restaurar_claim_num_bash_real_so_se_ainda_e_o_nosso(tmp_path):
    d = tmp_path / cli_hosting().DIR_REMOTO_REL
    d.mkdir(parents=True)
    f = d / "reader-claim.json"
    f.write_text(NOSSO)
    env = {"HOME": str(tmp_path), "PATH": "/usr/bin:/bin"}
    r = subprocess.run(["bash", "-s"], input=cli_hosting().script_restaurar_claim(NOSSO, ANTERIOR).encode(),
                       capture_output=True, env=env, timeout=10)
    assert r.returncode == 0 and f.read_text() == ANTERIOR
    f.write_text('{"host": "pc", "ts": 3000}')
    subprocess.run(["bash", "-s"], input=cli_hosting().script_restaurar_claim(NOSSO, ANTERIOR).encode(), env=env, timeout=10)
    assert f.read_text() == '{"host": "pc", "ts": 3000}'
    f.write_text(NOSSO)
    subprocess.run(["bash", "-s"], input=cli_hosting().script_restaurar_claim(NOSSO, "").encode(), env=env, timeout=10)
    assert not f.exists()


def cli_hosting():
    from wisp_bot import hosting
    return hosting


