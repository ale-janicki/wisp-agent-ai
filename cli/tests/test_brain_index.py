import os
import shutil
import time
from pathlib import Path

import pytest

from wisp import brain_index
from wisp.brain_index import BrainError, BrainIndex, index_path, parse_note, query_terms, section

FIXTURE = Path(__file__).parent / "fixtures" / "brain"


@pytest.fixture
def vault(tmp_path):
    root = tmp_path / "vault"
    shutil.copytree(FIXTURE, root)
    return root


@pytest.fixture
def index(vault, tmp_path):
    found = BrainIndex(vault, index_path(tmp_path / "state", vault))
    found.sync()
    return found


def _write(root, rel, text):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def test_parse_reads_aliases_headings_and_links_outside_code():
    parsed = parse_note(
        "---\naliases: [A B, 'c']\n---\n# Título\n\n## Sub\n\n[[x#h|alias]] ![[img.png]] ![[y]] `[[z]]`\n\n```\n[[w]]\n# fake\n```\n"
    )
    assert parsed.title == "Título" and parsed.aliases == ("A B", "c")
    assert [h for _, h in parsed.headings] == ["Título", "Sub"]
    assert parsed.links == (("x", "h"), ("y", ""))


def test_link_with_block_reference_or_escaped_pipe_keeps_the_note():
    assert parse_note("[[nota#^abc]] [[outra\\|texto]]").links == (("nota", ""), ("outra", ""))


def test_query_terms_drop_stopwords_short_words_and_accents_and_dedupe():
    assert query_terms("Como validar a SEGURANÇA da Empresa, segurança!") == ["validar", "seguranca", "empresa"]


def test_section_returns_the_heading_block_until_the_next_peer():
    text = "# T\n\nintro\n\n## A\n\num\n\n### A1\n\nfundo\n\n## B\n\ndois\n"
    assert section(text, "a") == "## A\n\num\n\n### A1\n\nfundo"
    assert section(text, "nada") is None


def test_wikilinks_resolve_by_filename_case_insensitively(index):
    graph = index.graph()
    assert graph.resolve("Plano-Financeiro") == "financas/plano-financeiro.md"
    assert graph.resolve("plano-financeiro.md") == "financas/plano-financeiro.md"


def test_wikilinks_fall_back_to_frontmatter_aliases_then_titles(index):
    graph = index.graph()
    assert graph.resolve("Orçamento Mensal") == "financas/plano-financeiro.md"
    assert graph.resolve("sync do app") == "projetos/sync-do-app.md"
    assert graph.resolve("Relogio") == "relogio-de-ponto.md"
    assert graph.resolve("Como validar segurança") == "empresa/seguranca.md"


def test_a_filename_wins_over_an_alias_of_another_note(vault, tmp_path):
    _write(vault, "x/alvo.md", "# Alvo\n")
    _write(vault, "y/outro.md", "---\naliases: [alvo]\n---\n# Outro\n")
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    found.sync()
    assert found.graph().resolve("alvo") == "x/alvo.md"


def test_path_qualified_links_and_duplicate_stems_prefer_the_closest_note(index):
    graph = index.graph()
    assert graph.resolve("empresa/seguranca") == "empresa/seguranca.md"
    assert graph.resolve("index", "empresa/seguranca.md") == "empresa/index.md"
    assert graph.resolve("index", "financas/plano-financeiro.md") == "index.md"
    assert graph.resolve("index", None) == "index.md"


def test_accent_insensitive_match_is_only_the_fallback(index):
    graph = index.graph()
    assert graph.resolve("relogio de ponto") == "relogio-de-ponto.md"
    assert graph.resolve("Relógio de Ponto") == "relogio-de-ponto.md"


def test_broken_links_are_kept_with_no_target_and_attachments_are_ignored(index):
    outgoing = index.graph().outgoing
    assert ("nota-que-nao-existe", None) in [(l.name, l.target) for l in outgoing["index.md"]]
    plano = [(l.name, l.target) for l in outgoing["financas/plano-financeiro.md"]]
    assert plano == [("sync-do-app", "projetos/sync-do-app.md"), ("Relogio", "relogio-de-ponto.md")]


def test_a_heading_only_link_points_at_the_note_itself(vault, tmp_path):
    _write(vault, "n.md", "# N\n\n## Parte\n\nVeja [[#Parte]].\n")
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    found.sync()
    assert found.graph().outgoing["n.md"][0].target == "n.md"


def test_resolve_ref_understands_wikilink_syntax_heading_and_alias(index):
    assert index.resolve_ref("[[plano-financeiro#Metas|as metas]]") == ("financas/plano-financeiro.md", "Metas")
    assert index.resolve_ref("financas/plano-financeiro.md") == ("financas/plano-financeiro.md", "")
    assert index.resolve_ref("orçamento mensal") == ("financas/plano-financeiro.md", "")
    assert index.resolve_ref("[[nada-disso]]") is None
    assert index.resolve_ref("[[#só-heading]]") is None


def test_backlinks_come_from_resolved_links_across_folders(index):
    graph = index.graph()
    assert sorted(graph.incoming["empresa/seguranca.md"]) == ["empresa/index.md", "projetos/sync-do-app.md"]
    assert graph.incoming["financas/plano-financeiro.md"] == ["index.md", "projetos/sync-do-app.md"]


def test_ranking_puts_the_title_and_alias_match_first(index):
    assert index.search("plano financeiro")[0].rel == "financas/plano-financeiro.md"
    assert index.search("orçamento mensal")[0].rel == "financas/plano-financeiro.md"
    assert index.search("como validar segurança empresa")[0].rel == "empresa/seguranca.md"
    assert index.search("spec motor")[0].rel == "produto/spec-motor.md"
    assert index.search("relógio")[0].rel == "relogio-de-ponto.md"
    assert index.search("sync do app")[0].rel == "projetos/sync-do-app.md"


def test_a_body_only_mention_ranks_below_a_title_match_and_scores_are_positive(index):
    rels = [h.rel for h in index.search("financeiro")]
    assert rels.index("financas/plano-financeiro.md") < rels.index("ruido.md")
    assert all(h.score > 0 and h.lex >= 0 for h in index.search("financeiro"))


def test_hits_carry_path_title_link_and_snippet(index):
    hit = index.search("reserva emergência")[0]
    assert hit.rel == "financas/plano-financeiro.md" and hit.title == "Plano Financeiro" and hit.link == "plano-financeiro"
    assert "reserva" in hit.snippet.lower()


def test_prefix_matching_finds_inflected_words(index):
    assert index.search("sincronizar lançamentos")[0].rel == "projetos/sync-do-app.md"


def test_a_link_from_a_strong_hit_lifts_a_note_over_an_otherwise_equal_one(vault, tmp_path):
    _write(vault, "a/principal.md", "# Zebra Quartzo\n\nVeja [[irmao]].\n")
    _write(vault, "a/irmao.md", "# Irmao\n\nzebra quartzo em passagem.\n")
    _write(vault, "b/solto.md", "# Solto\n\nzebra quartzo em passagem.\n")
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    found.sync()
    rels = [h.rel for h in found.search("zebra quartzo")]
    assert rels[0] == "a/principal.md" and rels.index("a/irmao.md") < rels.index("b/solto.md")


def test_a_query_with_only_stopwords_or_no_match_returns_nothing(index):
    assert index.search("de para com") == [] and index.search("zzzxyzzy") == []


def test_special_characters_in_the_query_never_break_the_search(index):
    assert isinstance(index.search('plano" OR (financeiro* NEAR :'), list)


def test_incremental_sync_reparses_only_what_changed(vault, tmp_path, monkeypatch):
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    first = found.sync()
    assert first.indexed == 8 and first.removed == 0
    parsed = []
    real = brain_index.parse_note
    monkeypatch.setattr(brain_index, "parse_note", lambda text: parsed.append(1) or real(text))
    assert found.sync().indexed == 0 and parsed == []
    path = _write(vault, "ruido.md", "# Ruído\n\nagora fala de quasar.\n")
    os.utime(path, (time.time() + 10,) * 2)
    again = found.sync()
    assert again.indexed == 1 and len(parsed) == 1
    assert found.search("quasar")[0].rel == "ruido.md" and found.search("trimestre") == []


def test_incremental_sync_adds_and_removes_files_and_relinks(vault, tmp_path):
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    found.sync()
    _write(vault, "nova.md", "# Nova\n\nCita [[ruido]].\n")
    (vault / "relogio-de-ponto.md").unlink()
    stats = found.sync()
    assert stats.indexed == 1 and stats.removed == 1
    graph = found.graph()
    assert "nova.md" in graph.incoming["ruido.md"] and "relogio-de-ponto.md" not in graph.notes
    assert graph.resolve("Relogio") is None
    assert found.search("relógio") == [] or found.search("relógio")[0].rel != "relogio-de-ponto.md"


def test_index_is_persistent_between_instances_and_reports_its_size(vault, tmp_path):
    path = index_path(tmp_path / "s", vault)
    BrainIndex(vault, path).sync()
    other = BrainIndex(vault, path)
    assert other.sync().indexed == 0
    stats = other.stats()
    assert stats["notes"] == 8 and stats["links"] > 0 and stats["bytes"] > 0


def test_a_corrupt_index_file_is_rebuilt(vault, tmp_path):
    path = index_path(tmp_path / "s", vault)
    path.parent.mkdir(parents=True)
    path.write_bytes(b"this is not a database" * 50)
    found = BrainIndex(vault, path)
    assert found.sync().indexed == 8 and found.search("plano financeiro")


def test_a_deadline_leaves_a_consistent_partial_index_that_finishes_next_time(vault, tmp_path):
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    partial = found.sync(deadline=time.monotonic() - 1)
    assert partial.partial and partial.indexed == 0
    assert found.sync().indexed == 8


def test_skipped_folders_hidden_files_and_non_markdown_are_not_indexed(vault, tmp_path):
    _write(vault, ".trash/t.md", "# lixo plano financeiro\n")
    _write(vault, "notas.txt", "plano financeiro\n")
    _write(vault, "._lixo.md", "plano financeiro\n")
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    found.sync()
    assert set(found.graph().notes) == {
        "index.md", "relogio-de-ponto.md", "ruido.md", "empresa/index.md", "empresa/seguranca.md",
        "financas/plano-financeiro.md", "projetos/sync-do-app.md", "produto/spec-motor.md",
    }


def test_symlinks_that_leave_the_brain_are_neither_indexed_nor_readable(vault, tmp_path):
    outside = tmp_path / "fora"
    outside.mkdir()
    (outside / "segredo.md").write_text("# Segredo Absoluto\n\ncodigo quasar\n")
    (vault / "atalho.md").symlink_to(outside / "segredo.md")
    (vault / "pasta-fora").symlink_to(outside)
    (vault / "interno.md").symlink_to(vault / "ruido.md")
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    found.sync()
    rels = set(found.graph().notes)
    assert "atalho.md" not in rels and not any(r.startswith("pasta-fora") for r in rels)
    assert "interno.md" in rels
    assert found.search("segredo absoluto") == [] and found.resolve_ref("segredo") is None
    with pytest.raises(BrainError):
        found.read_note("atalho.md")


def test_resolve_ref_never_leaves_the_brain(index, tmp_path):
    secret = tmp_path / "secret.md"
    secret.write_text("# Secret\n")
    assert index.resolve_ref(str(secret)) is None
    assert index.resolve_ref("../secret.md") is None
    assert index.resolve_ref("../../etc/passwd") is None
    assert index.resolve_ref("/etc/passwd") is None
    inside = index.root / "ruido.md"
    assert index.resolve_ref(str(inside)) == ("ruido.md", "")


def test_a_note_swapped_for_an_outside_symlink_after_indexing_is_refused(index, tmp_path):
    outside = tmp_path / "fora.md"
    outside.write_text("# Fora\n")
    (index.root / "ruido.md").unlink()
    (index.root / "ruido.md").symlink_to(outside)
    with pytest.raises(BrainError):
        index.read_note("ruido.md")


def test_the_walk_follows_links_in_both_directions_up_to_the_depth(index):
    nodes, broken = index.walk("financas/plano-financeiro.md", 1)
    assert {(rel, via) for rel, level, via in nodes if level == 1} == {
        ("projetos/sync-do-app.md", "out"), ("relogio-de-ponto.md", "out"), ("index.md", "in"),
    }
    deep, _ = index.walk("financas/plano-financeiro.md", 2)
    assert {"empresa/seguranca.md", "produto/spec-motor.md"} <= {rel for rel, level, _ in deep if level == 2}
    assert ("index.md", "nota-que-nao-existe") in index.walk("index.md", 1)[1]


def _ranked(vault, tmp_path, query, **kw):
    found = BrainIndex(vault, index_path(tmp_path / "s", vault), **kw)
    found.sync()
    return [h.rel for h in found.search(query)]


def test_session_and_daily_notes_rank_below_the_topical_note(vault, tmp_path):
    _write(vault, "klaus/sessions/2026-10-01-quartzo-zebra.md", "# Quartzo zebra completo\n\nquartzo zebra\n")
    _write(vault, "daily/2026-10-02.md", "# Quartzo zebra completo\n\nquartzo zebra\n")
    _write(vault, "x/log-tagged.md", "---\ntags: [Session, klaus]\n---\n# Quartzo zebra completo\n\nquartzo zebra\n")
    _write(vault, "topicos/quartzo-zebra.md", "# Quartzo zebra\n\nresumo\n")
    rels = _ranked(vault, tmp_path, "quartzo zebra")
    assert rels[0] == "topicos/quartzo-zebra.md"
    assert set(rels[1:]) == {"klaus/sessions/2026-10-01-quartzo-zebra.md", "daily/2026-10-02.md", "x/log-tagged.md"}


def test_the_demoted_markers_are_configurable(vault, tmp_path):
    _write(vault, "klaus/sessions/2026-10-01-quartzo-zebra.md", "# Quartzo zebra completo\n\nquartzo zebra quartzo zebra\n")
    _write(vault, "topicos/assunto-x.md", "# Quartzo\n\nzebra\n")
    assert _ranked(vault, tmp_path, "quartzo zebra")[0] == "topicos/assunto-x.md"
    other = tmp_path / "other"
    assert _ranked(vault, other, "quartzo zebra", log_markers=("nada",))[0] == "klaus/sessions/2026-10-01-quartzo-zebra.md"


def test_active_status_and_many_inbound_links_lift_a_note_over_an_equal_one(vault, tmp_path):
    _write(vault, "a/ativa.md", "---\nstatus: active\n---\n# Tema quartzo\n\ntexto\n")
    _write(vault, "b/parada.md", "---\nstatus: encerrado\n---\n# Tema quartzo\n\ntexto\n")
    assert _ranked(vault, tmp_path, "tema quartzo")[:2] == ["a/ativa.md", "b/parada.md"]
    for i in range(12):
        _write(vault, f"c/ref{i}.md", f"# Ref {i}\n\n[[parada]]\n")
    assert _ranked(vault, tmp_path / "t2", "tema quartzo")[0] == "b/parada.md"


def test_hidden_folders_are_not_indexed(vault, tmp_path):
    _write(vault, ".claude/coordination/sessions/x.md", "# Escondida\n")
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    found.sync()
    assert not any(r.startswith(".claude") for r in found.graph().notes)


PROBE = """
import json, sys, time
from pathlib import Path
from wisp.brain_index import BrainIndex
root, db, gate = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
while not gate.exists():
    time.sleep(0.005)
stats = BrainIndex(root, db, 30.0).sync()
print(json.dumps({"indexed": stats.indexed, "skipped": stats.skipped, "partial": stats.partial, "complete": stats.complete}))
"""


def _probe_processes(vault, db, count=4):
    import subprocess
    import sys

    gate = db.parent / "go"
    procs = [
        subprocess.Popen([sys.executable, "-c", PROBE, str(vault), str(db), str(gate)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        for _ in range(count)
    ]
    gate.write_text("go")
    outs = []
    for proc in procs:
        try:
            out, err = proc.communicate(timeout=120)
        except Exception:
            import signal
            os.killpg(proc.pid, signal.SIGKILL)
            raise
        assert proc.returncode == 0, err.decode()
        outs.append(__import__("json").loads(out.decode().splitlines()[-1]))
    return outs


def test_four_processes_syncing_a_fresh_index_together_index_each_file_once(vault, tmp_path):
    for i in range(300):
        _write(vault, f"lote/nota{i}.md", f"# Nota {i}\n\nconteúdo {i} [[nota{(i + 1) % 300}]]\n")
    db = tmp_path / "state" / "i.sqlite3"
    db.parent.mkdir()
    outs = _probe_processes(vault, db)
    assert all(o["complete"] and not o["partial"] and not o["skipped"] for o in outs)
    assert sum(o["indexed"] for o in outs) == 308
    assert BrainIndex(vault, db).stats()["notes"] == 308


def test_four_processes_migrating_an_old_schema_together_never_delete_the_database(vault, tmp_path):
    import sqlite3
    from contextlib import closing

    for i in range(200):
        _write(vault, f"lote/nota{i}.md", f"# Nota {i}\n\nconteúdo {i}\n")
    db = tmp_path / "state" / "i.sqlite3"
    db.parent.mkdir()
    with closing(sqlite3.connect(db)) as old:
        old.execute("CREATE TABLE files(rel TEXT)")
        old.execute("PRAGMA user_version=1")
    inode = db.stat().st_ino
    outs = _probe_processes(vault, db)
    assert all(o["complete"] and not o["skipped"] for o in outs)
    assert sum(o["indexed"] for o in outs) == 208 and db.stat().st_ino == inode
    assert BrainIndex(vault, db).stats()["notes"] == 208


def test_a_busy_database_is_never_mistaken_for_a_corrupt_one(vault, tmp_path):
    import sqlite3
    from contextlib import closing

    db = tmp_path / "state" / "i.sqlite3"
    db.parent.mkdir()
    with closing(sqlite3.connect(db, isolation_level=None)) as old:
        old.execute("PRAGMA journal_mode=WAL")
        old.execute("PRAGMA user_version=1")
        old.execute("BEGIN IMMEDIATE")
        found = BrainIndex(vault, db, lock_timeout=0.2)
        with pytest.raises(sqlite3.OperationalError):
            found._connect()
        stats = found.sync()
        assert stats.skipped and not stats.complete
        assert db.exists()
        old.execute("ROLLBACK")
    assert found.sync().indexed == 8


def test_only_real_corruption_deletes_the_database(vault, tmp_path):
    db = tmp_path / "state" / "i.sqlite3"
    db.parent.mkdir()
    db.write_bytes(b"not a database at all" * 100)
    found = BrainIndex(vault, db)
    assert found.sync().indexed == 8 and found.search("plano financeiro")


def test_a_waiter_that_gets_the_write_lock_rereads_what_is_left_to_do(vault, tmp_path):
    import sqlite3
    from contextlib import closing

    db = tmp_path / "i.sqlite3"
    first, second = BrainIndex(vault, db), BrainIndex(vault, db)
    assert first.sync().indexed == 8
    assert second.sync().indexed == 0
    _write(vault, "nova.md", "# Nova\n")
    seen = second._scan()
    with closing(second._connect()) as conn:
        first.sync()
        assert second._diff(conn, seen) == ([], [])


def test_the_complete_flag_is_set_only_when_a_full_build_finishes(vault, tmp_path):
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    partial = found.sync(deadline=time.monotonic() - 1)
    assert partial.partial and not partial.complete
    done = found.sync()
    assert done.complete and not done.partial
    _write(vault, "nova.md", "# Nova\n")
    again = found.sync(deadline=time.monotonic() - 1)
    assert again.partial and again.complete


def test_binary_markdown_files_are_skipped_and_not_reread_every_sync(vault, tmp_path, monkeypatch):
    (vault / "binario.md").write_bytes(b"# Titulo\n\x00\x01\x02" + b"x" * 100)
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    assert found.sync().indexed == 8
    assert "binario.md" not in found.graph().notes and found.stats()["notes"] == 8
    assert found.search("titulo") == []
    calls = []
    real = brain_index.read_prefix
    monkeypatch.setattr(brain_index, "read_prefix", lambda *a, **k: calls.append(1) or real(*a, **k))
    assert found.sync().indexed == 0 and calls == []
    with pytest.raises(BrainError):
        found.read_note("binario.md")


def test_a_read_error_is_retried_on_the_next_sync_but_binary_is_permanent(vault, tmp_path):
    locked = _write(vault, "bloqueada.md", "# Bloqueada\n\nconteudo quasar\n")
    locked.chmod(0)
    try:
        found = BrainIndex(vault, index_path(tmp_path / "s", vault))
        first = found.sync()
        assert "bloqueada.md" not in found.graph().notes and first.indexed == 8
        assert found.sync().indexed == 0 and "bloqueada.md" not in found.graph().notes
        locked.chmod(0o644)
        again = found.sync()
        assert again.indexed == 1 and found.search("quasar")[0].rel == "bloqueada.md"
    finally:
        locked.chmod(0o644)


def test_a_file_that_vanishes_between_scan_and_read_leaves_no_stamp(vault, tmp_path, monkeypatch):
    found = BrainIndex(vault, index_path(tmp_path / "s", vault))
    found.sync()
    path = _write(vault, "fugiu.md", "# Fugiu\n")
    real = brain_index.read_prefix

    def vanish(target, limit, strict=False):
        if str(target).endswith("fugiu.md"):
            raise FileNotFoundError("gone")
        return real(target, limit, strict)

    monkeypatch.setattr(brain_index, "read_prefix", vanish)
    assert found.sync().indexed == 0
    monkeypatch.setattr(brain_index, "read_prefix", real)
    assert found.sync().indexed == 1 and "fugiu.md" in found.graph().notes
