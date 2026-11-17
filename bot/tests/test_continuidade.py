"""Decisoes puras da continuidade entre hosts, com arquivos reais em diretorio temporario.
Nada aqui toca ssh: o PC pode estar desligado."""
import json

from wisp_bot import sessao, store, topicos

SID = "11111111-2222-3333-4444-555555555555"


def _jsonl(raiz, cwd, sid, tam):
    d = raiz / sessao.slug(cwd)
    d.mkdir(parents=True)
    (d / f"{sid}.jsonl").write_bytes(b"x" * tam)


def test_nota_aponta_outra_sessao_mac_busca(tmp_path, monkeypatch):
    monkeypatch.setattr(sessao, "PROJETOS", tmp_path)
    m = {"session_id": SID, "session_host": "pc", "session_started": "true", "session_size": "500"}
    assert sessao.a_trazer(m, "outro-id", "mac", 0) == SID


def test_mesma_sessao_copia_igual_nao_traz(tmp_path):
    m = {"session_id": SID, "session_host": "mac", "session_started": "true", "session_size": "500"}
    assert sessao.a_trazer(m, SID, "pc", 500) is None       # empurrada no handover
    assert sessao.a_trazer(m, SID, "pc", 300) == SID        # defasada
    assert sessao.a_trazer(m, SID, "pc", 0) == SID


def test_mesma_sessao_mesmo_host_nao_traz():
    m = {"session_id": SID, "session_host": "pc", "session_started": "true"}
    assert sessao.a_trazer(m, SID, "pc", 10) is None


def test_nota_sem_sessao_ou_terminal_ou_invalida():
    assert sessao.a_trazer({}, SID, "mac", 0) is None
    assert sessao.a_trazer({"session_id": "x;rm"}, SID, "mac", 0) is None
    assert sessao.a_trazer({"session_id": SID, "status": "terminal"}, "o", "mac", 0) is None


def test_sessao_zerada_na_nota_so_aponta():
    m = {"session_id": SID, "session_started": "false"}
    assert sessao.a_trazer(m, "outro", "mac", 0) == SID
    assert sessao.a_trazer(m, SID, "mac", 0) is None


def test_trazer_usa_copia_local_mais_nova(tmp_path, monkeypatch):
    monkeypatch.setattr(sessao, "PROJETOS", tmp_path)
    _jsonl(tmp_path, "/outro/caminho", SID, 800)
    m = {"session_id": SID, "session_host": "pc", "session_size": "800"}
    assert sessao.trazer(SID, "/aqui/repo", m, "mac")        # sem ssh: 800 >= 800
    assert sessao.caminho(SID, "/aqui/repo").exists()


def test_trazer_copia_defasada_sem_ssh_falha_limpo(tmp_path, monkeypatch):
    monkeypatch.setattr(sessao, "PROJETOS", tmp_path)
    monkeypatch.setattr(sessao.hosting, "pc_argv", lambda *a: None)   # config do PC ausente
    _jsonl(tmp_path, "/aqui/repo", SID, 100)
    m = {"session_id": SID, "session_host": "pc", "session_size": "800"}
    assert sessao.trazer(SID, "/aqui/repo", m, "mac") is False


def test_mudadas_so_o_que_mexeu_mais_novo_primeiro():
    cand = {"a": ("/x", 10.0), "b": ("/y", 30.0), "c": ("/z", 20.0)}
    assert sessao.mudadas(cand, {"a": 10.0, "c": 5.0}) == [("b", "/y"), ("c", "/z")]


def test_seguir_sessao_restaura_idade(tmp_path):
    s = store.Store(tmp_path / "t.json")
    t = s.get_or_create("1:0", "Geral", "/tmp")
    s.seguir_sessao("1:0", SID, True, born=1000.0, last_used=2000.0)
    t = s.get("1:0")
    assert (t.session_id, t.started, t.born, t.last_used) == (SID, True, 1000.0, 2000.0)
    s.seguir_sessao("1:0", "novo", False)
    assert (s.get("1:0").started, s.get("1:0").born) == (False, 0.0)


def test_geral_resetado_pelas_24h_volta_a_receber_continuacao():
    # a nota confirmava a sessao (segue) mas o reset zerou: tem que cair no CONTINUACAO
    assert sessao.decidir_prompt(True, "sessao com 25h", "nota", False, True, None, "mac") == "continuacao"
    # sem reset, a sessao confirmada leva so a mensagem
    assert sessao.decidir_prompt(True, None, "nota", True, True, None, "mac") == "segue"
    assert sessao.decidir_prompt(False, None, "nota", False, False, None, "mac") == "puro"
    assert sessao.decidir_prompt(False, None, "nota", True, True, "pc", "mac") == "retorno"
    assert sessao.decidir_prompt(False, None, "nota", True, True, "mac", "mac") == "puro"
    assert sessao.decidir_prompt(True, None, "nota", True, True, "pc", "mac") == "retorno"    # segue, mas o Log acabou no outro host
    assert sessao.decidir_prompt(True, None, "nota", True, True, "mac", "mac") == "segue"
    assert sessao.decidir_prompt(True, "sessao zerada", "", False, False, None, "mac") == "puro"


def test_aviso_de_fila_so_com_lock_ocupado():
    import asyncio

    async def roda():
        lk = asyncio.Lock()
        assert not sessao.avisar_fila(lk)       # livre: sem aviso
        async with lk:
            assert sessao.avisar_fila(lk)       # turno anterior em curso: avisa
    asyncio.run(roda())


def test_ler_topicos_do_pc_saida_real_do_store(tmp_path):
    s = store.Store(tmp_path / "topics.json")
    s.get_or_create("1:0", "Geral", "/home/x")
    s.get_or_create("1:7", "Projeto", "/home/x/repos/projeto")
    s.get_or_create("1:9", "Novo", "/home/x")
    s.mark_started("1:0")
    s.mark_started("1:7")
    texto = "HOME=/home/x\n" + (tmp_path / "topics.json").read_text("utf-8")
    home, tops = sessao.ler_topicos_pc(texto)
    assert home == "/home/x"
    assert sorted(k for k, _, _ in tops) == ["1:0", "1:7"]       # o nao iniciado fica de fora
    assert dict((k, c) for k, _, c in tops)["1:7"] == "/home/x/repos/projeto"
    assert sessao.ler_topicos_pc("lixo sem home") is None
    assert sessao.ler_topicos_pc("HOME=/home/x\nnao e json") is None


def test_cwd_espelho_mapeia_home_e_cai_no_store_ou_padrao():
    existe = {"/Users/_x/repos/projeto", "/Users/_x/store"}.__contains__
    f = lambda cwd, store_cwd="": sessao.cwd_espelho(cwd, "/home/x", "/Users/_x", existe, store_cwd, "/padrao")
    assert f("/home/x/repos/projeto") == "/Users/_x/repos/projeto"
    assert f("/home/x/repos/some", "/Users/_x/store") == "/Users/_x/store"
    assert f("/home/x/repos/some") == "/padrao"
    assert f("/mnt/c/x", "/Users/_nao") == "/padrao"


# ---- espelho PC -> Mac nunca sobrescreve copia mais nova daqui ----

def test_deve_espelhar_casos():
    from wisp_bot import sessao
    agora = 10_000.0
    velho = agora - 500
    assert sessao.deve_espelhar(None, 200, [(100, velho)], agora) is True        # PC mais novo de verdade
    assert sessao.deve_espelhar(None, 200, [], agora) is True                    # Mac nao tem
    assert sessao.deve_espelhar({"status": "terminal"}, 200, [], agora) is False
    assert sessao.deve_espelhar({"onde": "terminal-mac"}, 200, [], agora) is False
    assert sessao.deve_espelhar({"session_host": "mac"}, 200, [], agora) is False
    assert sessao.deve_espelhar({"session_host": "pc"}, 200, [(300, velho)], agora) is False   # local maior
    assert sessao.deve_espelhar(None, 200, [(200, velho)], agora) is False       # igual
    assert sessao.deve_espelhar(None, 200, [(100, agora - 10)], agora) is False  # local viva
    assert sessao.deve_espelhar(None, 200, [(100, velho), (250, velho)], agora) is False  # qualquer copia basta


def test_trocar_sem_encolher(tmp_path):
    import pytest
    from wisp_bot import sessao
    alvo, tmp = tmp_path / "a.jsonl", tmp_path / "a.tmp"
    alvo.write_text("x" * 100)
    tmp.write_text("y" * 50)
    with pytest.raises(RuntimeError, match="copia local mais nova"):
        sessao._trocar_sem_encolher(tmp, alvo)
    assert alvo.read_text() == "x" * 100 and not tmp.exists()
    tmp.write_text("z" * 150)
    sessao._trocar_sem_encolher(tmp, alvo)
    assert alvo.read_text() == "z" * 150 and not tmp.exists()


def test_achar_local_devolve_a_maior(tmp_path, monkeypatch):
    from wisp_bot import sessao
    monkeypatch.setattr(sessao, "PROJETOS", tmp_path)
    sid = "11111111-2222-3333-4444-555555555555"
    (tmp_path / "a").mkdir(); (tmp_path / "b").mkdir()
    (tmp_path / "a" / f"{sid}.jsonl").write_text("x")
    (tmp_path / "b" / f"{sid}.jsonl").write_text("xxxx")
    assert sessao.achar_local(sid) == tmp_path / "b" / f"{sid}.jsonl"


def test_em_voo_leitura_e_validade(tmp_path):
    f = tmp_path / "em-voo-mac.test.json"
    f.write_text(json.dumps({"k1": {"sid": SID, "ts": 1000.0}, "k2": {"sid": "x;rm", "ts": 1000.0},
                             "k3": {"sid": SID, "ts": 100.0}}))
    marc = sessao.ler_em_voo(f)
    assert sessao.em_voo_vivo(marc, "k1", 1100.0) is not None
    assert sessao.em_voo_vivo(marc, "k1", 1000.0 + sessao.EM_VOO_MAX_S + 1) is None      # velha demais
    assert sessao.em_voo_vivo(marc, "k2", 1100.0) is None                               # sid invalido
    assert sessao.em_voo_vivo(marc, "k3", 100.0 + sessao.EM_VOO_MAX_S + 1) is None
    assert sessao.em_voo_vivo(marc, "nada", 1100.0) is None
    assert sessao.em_voo_vivo({}, "k1", 1100.0) is None
    assert sessao.ler_em_voo(tmp_path / "nao-existe.json") == {}
    sessao.tirar_em_voo("k1", f)
    assert "k1" not in sessao.ler_em_voo(f) and "k3" in sessao.ler_em_voo(f)
    sessao.tirar_em_voo("fantasma", f)                                                  # inexistente: sem erro


def test_script_em_voo_grava_json_atomico():
    from wisp_bot import hosting
    sc = hosting.script_em_voo({"k": {"sid": SID, "ts": 5.0}}, "em-voo-mac.test.json")
    assert "em-voo-mac.test.json.tmp" in sc and 'mv "$d/em-voo-mac.test.json.tmp"' in sc
    assert json.dumps({"k": {"sid": SID, "ts": 5.0}}, sort_keys=True) in sc
    assert hosting.script_em_voo({}).count("{}") == 1


def test_divergencia_nao_espelha():
    agora, velho = 10_000.0, 10_000.0 - 3600
    # Mac gravou (copia menor) 60s depois do PC: divergiu
    assert sessao.divergiu(200, velho, [(100, velho + 60)]) is True
    assert sessao.deve_espelhar(None, 200, [(100, velho + 60)], agora, velho) is False
    # dentro da folga de 5s: relogio, nao divergencia
    assert sessao.divergiu(200, velho, [(100, velho + 3)]) is False
    assert sessao.deve_espelhar(None, 200, [(100, velho + 3)], agora, velho) is True
    # Mac anterior ao PC: espelho normal; sem mt_pc o comportamento antigo segue igual
    assert sessao.deve_espelhar(None, 200, [(100, velho - 60)], agora, velho) is True
    assert sessao.deve_espelhar(None, 200, [(100, velho + 60)], agora) is True
    # copia local maior nao e divergencia (e o Mac na frente: ja nao espelhava)
    assert sessao.divergiu(100, velho, [(200, velho + 60)]) is False


def test_contagem_de_turnos_fim_so_no_ultimo():
    cont: dict[str, int] = {}
    sessao.contar_turno(cont, "k")                 # turno 1 segurando o lock
    sessao.contar_turno(cont, "k")                 # turno 2 enfileirado
    assert sessao.soltar_turno(cont, "k") is False  # turno 1 acaba: ainda ha o 2
    assert cont == {"k": 1}
    assert sessao.soltar_turno(cont, "k") is True   # turno 2 acaba: fim
    assert cont == {}
    assert sessao.soltar_turno(cont, "k") is True   # solto a mais nao quebra


def test_marcador_so_sai_depois_da_escrita_ok():
    assert sessao.apos_escrita_marcador(True, 0, 3) == ("remover", 0)
    assert sessao.apos_escrita_marcador(False, 0, 3) == ("tentar", 1)       # falhou: mantem a chave
    assert sessao.apos_escrita_marcador(False, 1, 3) == ("tentar", 2)
    assert sessao.apos_escrita_marcador(False, 2, 3) == ("largar", 3)       # teto
    assert sessao.apos_escrita_marcador(True, 2, 3) == ("remover", 2)


def _entrada(sid, last, size=10, started=True):
    return {"session_id": sid, "session_started": started, "session_born": 5, "session_last": last,
            "session_size": size, "cwd": "~/x"}


def test_resolver_sessao_mais_nova_vence_e_host_do_arquivo():
    por_host = {"mac": {"1:2": _entrada("a", 100, 7)}, "pc": {"1:2": _entrada("b", 200, 9, started=False)}}
    r = topicos.resolver_sessao("1:2", por_host)
    assert (r["session_id"], r["session_host"], r["session_size"], r["session_started"]) == ("b", "pc", "9", "false")
    assert (r["session_born"], r["session_last"]) == ("5", "200")
    por_host["mac"]["1:2"]["session_last"] = 300
    assert topicos.resolver_sessao("1:2", por_host)["session_host"] == "mac"
    assert topicos.resolver_sessao("9:9", por_host) is None


def test_meta_le_ponteiro_por_host_e_cai_no_frontmatter(tmp_path, monkeypatch):
    monkeypatch.setattr(topicos, "DIR", tmp_path)
    monkeypatch.setattr(topicos, "BRAIN", tmp_path)
    nota = tmp_path / "topico-7-x.md"
    nota.write_text('---\nstatus: active\ntopic_key: "1:7"\nsession_id: velha\nsession_host: pc\n'
                    'session_size: 3\n---\n\n## Log\n')
    assert topicos.meta("1:7")["session_id"] == "velha"            # sem ponteiro: frontmatter
    (tmp_path / "sessoes-mac.json").write_text(json.dumps({"1:7": _entrada("nova", 50, 99)}))
    (tmp_path / "sessoes-pc.json").write_text("{quebrado")          # arquivo ilegivel nao derruba
    m = topicos.meta("1:7")
    assert (m["session_id"], m["session_host"], m["session_size"]) == ("nova", "mac", "99")
    assert topicos.abertos()[0]["session_host"] == "mac"
    assert "session_id: velha" in nota.read_text()                  # frontmatter intacto


def test_gravar_ponteiro_so_o_proprio_arquivo_atomico(tmp_path, monkeypatch):
    monkeypatch.setattr(topicos, "DIR", tmp_path)
    outro = tmp_path / "sessoes-pc.json"
    outro.write_text('{"1:7": {"session_id": "pc"}}')
    topicos.gravar_ponteiro("mac", "1:7", SID, True, 5.0, 100.9, 42, str(__import__("pathlib").Path.home() / "r"))
    topicos.gravar_ponteiro("mac", "1:8", SID, False, 0, 0, 0, "/tmp")
    d = json.loads((tmp_path / "sessoes-mac.json").read_text())
    assert set(d) == {"1:7", "1:8"}
    assert d["1:7"] == {"session_id": SID, "session_started": True, "session_born": 5,
                        "session_last": 100, "session_size": 42, "cwd": "~/r"}
    assert outro.read_text() == '{"1:7": {"session_id": "pc"}}'     # o do outro host nao e tocado
    assert not list(tmp_path.glob("*.tmp"))


def test_reset_fica_mais_novo_que_o_outro_host(tmp_path):
    # /reset num host tem que vencer a entrada mais velha do outro (revisao 21/10)
    import time
    from wisp_bot.store import Store
    s = Store(tmp_path / "topics.json")
    s.get_or_create("k", "t", str(tmp_path))
    s.bump("k", 0.0)
    antes = s.get("k").last_used
    time.sleep(0.01)
    s.reset("k")
    assert s.get("k").last_used > antes and not s.get("k").started
