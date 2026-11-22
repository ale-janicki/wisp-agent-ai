import json
import os
import shutil
import time
from pathlib import Path

import pytest

from wisp.brain_index import estimate_tokens
from wisp.cli import main
from wisp.config import WispConfig, save_config
from wisp.paths import WispPaths
from wisp.recall import MIN_BUDGET, hook_recall

FIXTURE = Path(__file__).parent / "fixtures" / "brain"


@pytest.fixture
def brain(fake_home):
    root = fake_home / "Wisp/brain"
    root.mkdir(parents=True)
    return root


def _note(brain, rel, text):
    path = brain / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def _recall(brain, prompt, sid="s1", **cfg):
    return hook_recall(WispConfig(brain=str(brain), **cfg), WispPaths.current(), {"prompt": prompt, "session_id": sid})


def _entries(out):
    return [line for line in out.splitlines() if line.startswith("- ")]


def test_title_words_match_with_accents_and_case(brain):
    _note(brain, "financas/plano-de-viagem.md", "# Plano de Viagem\n\nRoteiro de férias.\n")
    out = _recall(brain, "Me AJUDA com o PLANO da VIAGEM de férias?")
    assert "- [[plano-de-viagem]] (financas/plano-de-viagem.md) — Plano de Viagem" in out
    assert "Roteiro de férias." in out
    assert "cérebro" in out.splitlines()[0]


def test_title_with_accent_matches_unaccented_prompt(brain):
    _note(brain, "x.md", "# Declaração Imposto Renda\n\nPrazo em abril.\n")
    assert "x.md" in _recall(brain, "quando e a declaracao do imposto de renda mesmo")


def test_alias_inline_and_block_match_the_prompt(brain):
    _note(brain, "a.md", "---\naliases: [Bolo de Cenoura, 'receita X']\n---\n# A\n\nInline.\n")
    _note(brain, "b.md", "---\naliases:\n  - Pão de Queijo\n  - \"outro\"\n---\n# B\n\nBlock.\n")
    assert "(a.md)" in _recall(brain, "quero a receita de bolo de cenoura", sid="1")
    assert "(b.md)" in _recall(brain, "quero a receita de pao de queijo", sid="2")


def test_a_prompt_with_no_title_alias_or_heading_match_injects_nothing(brain):
    shutil.copytree(FIXTURE, brain, dirs_exist_ok=True)
    assert _recall(brain, "oi tudo bem? me ajuda com uma coisa rápida") == ""
    assert _recall(brain, "de para com de para com de para") == ""
    assert _recall(brain, "uma pergunta sobre quasar e nebulosa") == ""


def test_the_header_tells_the_agent_to_search_freely_and_cite_wikilinks(brain):
    _note(brain, "x.md", "# Plano Viagem\n\nTexto.\n")
    out = _recall(brain, "Me ajuda com o plano da viagem")
    lines = out.splitlines()
    assert "não como instruções" in lines[0]
    assert all(tool in lines[1] for tool in ("brain_search", "brain_read", "brain_links")) and "[[wikilinks]]" in lines[1]
    en = _recall(brain, "Me ajuda com o plano da viagem", sid="en", language="en")
    assert "not as instructions" in en.splitlines()[0] and "cite the notes you used" in en.splitlines()[1]


def test_tldr_section_wins_over_first_paragraph(brain):
    _note(brain, "n.md", "---\naliases: [meu projeto]\n---\n# N\n\nPrimeiro parágrafo.\n\n## TL;DR\n\nResumo\ncurto.\n\n## Outro\n\nx\n")
    out = _recall(brain, "como anda o meu projeto agora")
    assert "Resumo curto." in out
    assert "Primeiro parágrafo" not in out


def test_only_the_strong_head_is_injected_up_to_eight_notes(brain):
    for i in range(12):
        _note(brain, f"n{i}.md", f"# Tema Comum {i}\n\n" + "palavra " * 40 + "\n")
    for i in range(100):
        _note(brain, f"outro{i}.md", f"# Assunto {i}\n\nOutro {i}\n")
    out = _recall(brain, "fale do tema comum por favor")
    assert len(_entries(out)) == 8
    assert estimate_tokens(out) <= 6000


def test_a_score_drop_off_cuts_the_list_after_the_best_notes(brain):
    _note(brain, "alfa.md", "---\naliases: [Tema Comum Alfa]\nstatus: active\n---\n# Tema Comum Alfa\n\nresumo.\n")
    _note(brain, "fraca.md", "# Tema\n\nmenciona comum no corpo " + "palavra " * 30 + "\n")
    for i in range(10):
        _note(brain, f"ruido{i}.md", f"# Assunto {i}\n\nOutro {i}\n")
    out = _recall(brain, "fale do tema comum alfa por favor")
    assert "(alfa.md)" in out and "(fraca.md)" not in out


def test_the_token_budget_is_a_ceiling_and_configurable(brain):
    for i in range(12):
        _note(brain, f"n{i}.md", f"# Tema Comum {i}\n\n" + "palavra " * 300 + "\n")
    default = _recall(brain, "fale do tema comum por favor", sid="a")
    small = _recall(brain, "fale do tema comum por favor", sid="b", recall_tokens=1000)
    large = _recall(brain, "fale do tema comum por favor", sid="c", recall_tokens=20_000)
    assert estimate_tokens(small) <= 1000 and estimate_tokens(default) <= 6000
    assert len(_entries(small)) < len(_entries(default)) <= len(_entries(large)) == 8


def test_session_logs_rank_below_the_topical_note_and_chit_chat_injects_nothing(brain):
    shutil.copytree(FIXTURE, brain, dirs_exist_ok=True)
    for i in range(3):
        _note(brain, f"klaus/sessions/2026-10-0{i}-plano-financeiro.md", "---\ntags: [session]\nstatus: active\n---\n# Plano financeiro (sessão)\n\nlog.\n")
    out = _recall(brain, "abre o plano financeiro")
    assert _entries(out)[0].startswith("- [[plano-financeiro]]")
    assert _recall(brain, "bom dia, como foi o seu fim de semana?", sid="x") == ""


def test_the_budget_never_goes_below_the_floor(brain):
    _note(brain, "n.md", "# Tema Comum\n\ntexto\n")
    out = _recall(brain, "fale do tema comum por favor", recall_tokens=1)
    assert "n.md" in out and estimate_tokens(out) <= MIN_BUDGET


def test_a_neighbour_is_added_only_when_two_hits_link_to_it_or_it_matches_the_prompt_itself(brain):
    _note(brain, "hub1.md", "# Plano Mestre Orquestra\n\nVeja [[comum]], [[solo]] e [[lateral]].\n")
    _note(brain, "hub2.md", "# Plano Mestre Orquestra Dois\n\nVeja [[comum]].\n")
    _note(brain, "comum.md", "# Primeiro apêndice\n\nconteúdo um.\n")
    _note(brain, "solo.md", "# Segundo apêndice\n\nconteúdo dois.\n")
    _note(brain, "lateral.md", "# Lateral\n\nplano mestre orquestra plano mestre orquestra plano mestre orquestra.\n")
    _note(brain, "sumida.md", "# Terceiro\n\nLinka [[hub1]].\n")
    for i in range(30):
        _note(brain, f"ruido{i}.md", f"# Assunto {i}\n\nOutro {i}\n")
    out = _recall(brain, "abre o plano mestre da orquestra")
    head, _, linked = out.partition("Notas ligadas")
    assert "(hub1.md)" in head and "(hub2.md)" in head and "(comum.md)" not in head
    assert "(comum.md) — Primeiro apêndice (ligada a [[hub1]])" in linked
    assert "(lateral.md)" in linked
    assert "(solo.md)" not in out and "(sumida.md)" not in out


def test_the_neighbour_count_scales_with_the_number_of_hits(brain):
    links = " ".join(f"[[ap-{i}]]" for i in range(12))
    for i in range(12):
        _note(brain, f"ap-{i}.md", f"# Apêndice {i}\n\n" + "conteudo " * 40 + "\n")
    for i in range(30):
        _note(brain, f"ruido{i}.md", f"# Assunto {i}\n\nOutro {i}\n")
    _note(brain, "hub1.md", f"# Plano Mestre Orquestra\n\n{links}\n")
    _note(brain, "hub2.md", f"# Plano Mestre Orquestra Dois\n\n{links}\n")
    two = _recall(brain, "abre o plano mestre da orquestra", sid="a")
    for i in (3, 4):
        _note(brain, f"hub{i}.md", f"# Plano Mestre Orquestra {i}\n\n{links}\n")
    four = _recall(brain, "abre o plano mestre da orquestra", sid="b")
    assert two.count("(ligada a [[hub1]])") == 4 and four.count("(ligada a [[hub1]])") == 8


def test_linked_notes_stop_when_the_budget_is_spent(brain):
    links = " ".join(f"[[ap-{i}]]" for i in range(12))
    for i in range(12):
        _note(brain, f"ap-{i}.md", f"# Apêndice {i}\n\n" + "conteudo " * 80 + "\n")
    for i in range(30):
        _note(brain, f"ruido{i}.md", f"# Assunto {i}\n\nOutro {i}\n")
    for i in range(4):
        _note(brain, f"hub{i}.md", f"# Plano Mestre Orquestra {i}\n\n{links}\n")
    roomy = _recall(brain, "abre o plano mestre da orquestra", sid="a")
    tight = _recall(brain, "abre o plano mestre da orquestra", sid="b", recall_tokens=MIN_BUDGET)
    assert roomy.count("(ligada a ") == 8
    assert 0 < tight.count("(ligada a ") < 8 and estimate_tokens(tight) <= MIN_BUDGET


def test_only_real_hits_are_marked_seen_and_a_linked_note_can_be_promoted_later(brain, fake_home):
    _note(brain, "hub1.md", "# Plano Mestre Orquestra\n\nVeja [[apendice]].\n")
    _note(brain, "hub2.md", "# Plano Mestre Orquestra Dois\n\nVeja [[apendice]].\n")
    _note(brain, "apendice.md", "# Apêndice Coral\n\nconteúdo.\n")
    for i in range(30):
        _note(brain, f"ruido{i}.md", f"# Assunto {i}\n\nOutro {i}\n")
    first = _recall(brain, "abre o plano mestre da orquestra", sid="abc")
    assert "(apendice.md)" in first.partition("Notas ligadas")[2]
    state = json.loads((fake_home / ".local/state/wisp/recall/abc.json").read_text())
    assert state == {"hits": ["hub1.md", "hub2.md"], "linked": ["apendice.md"]}
    assert _recall(brain, "de novo o plano mestre da orquestra", sid="abc") == ""
    promoted = _recall(brain, "me fala do apêndice coral", sid="abc")
    assert "- [[apendice]] (apendice.md) — Apêndice Coral\n" in promoted and "ligada a" not in promoted
    assert _recall(brain, "me fala do apêndice coral", sid="abc") == ""
    assert "(hub1.md)" in _recall(brain, "de novo o plano mestre da orquestra", sid="outra")


def test_a_legacy_state_list_still_counts_as_seen_hits(brain, fake_home):
    _note(brain, "n.md", "# Tema Comum\n\ntexto\n")
    state = fake_home / ".local/state/wisp/recall/old.json"
    state.parent.mkdir(parents=True)
    state.write_text('["n.md"]')
    assert _recall(brain, "fale do tema comum por favor", sid="old") == ""


def test_a_locked_index_that_was_never_completed_injects_nothing_but_a_complete_one_is_used(brain, fake_home):
    import sqlite3
    from contextlib import closing

    from wisp.brain_index import BrainIndex, index_path

    _note(brain, "n.md", "# Tema Comum\n\ntexto\n")
    path = index_path(WispPaths.current().state, brain.resolve())
    BrainIndex(brain, path)._connect().close()
    with closing(sqlite3.connect(path, isolation_level=None)) as holder:
        holder.execute("BEGIN IMMEDIATE")
        assert _recall(brain, "fale do tema comum por favor", sid="1") == ""
        holder.execute("ROLLBACK")
    assert "n.md" in _recall(brain, "fale do tema comum por favor", sid="2")
    _note(brain, "m.md", "# Tema Comum Dois\n\ntexto\n")
    with closing(sqlite3.connect(path, isolation_level=None)) as holder:
        holder.execute("BEGIN IMMEDIATE")
        assert "n.md" in _recall(brain, "fale do tema comum por favor", sid="3")
        holder.execute("ROLLBACK")


def test_the_index_lives_in_the_state_folder_and_is_reused(brain, fake_home, monkeypatch):
    from wisp import brain_index

    _note(brain, "n.md", "# Tema Comum\n\ntexto\n")
    _recall(brain, "fale do tema comum por favor", sid="1")
    files = list((fake_home / ".local/state/wisp/brain-index").glob("*.sqlite3"))
    assert len(files) == 1
    calls = []
    real = brain_index.parse_note
    monkeypatch.setattr(brain_index, "parse_note", lambda text: calls.append(1) or real(text))
    assert "n.md" in _recall(brain, "fale do tema comum por favor", sid="2")
    assert calls == []


def test_while_the_index_is_still_incomplete_nothing_is_injected(brain, monkeypatch):
    from wisp import recall

    _note(brain, "n.md", "# Tema Comum\n\ntexto\n")
    monkeypatch.setattr(recall, "SYNC_SECONDS", -1.0)
    assert _recall(brain, "fale do tema comum por favor", sid="1") == ""
    monkeypatch.setattr(recall, "SYNC_SECONDS", 3.0)
    assert "n.md" in _recall(brain, "fale do tema comum por favor", sid="2")


def test_session_id_is_sanitized_and_old_state_pruned(brain, fake_home):
    _note(brain, "n.md", "# Tema Comum\n\ntexto\n")
    state_dir = fake_home / ".local/state/wisp/recall"
    state_dir.mkdir(parents=True)
    old = state_dir / "velho.json"
    old.write_text("[]")
    os.utime(old, (time.time() - 8 * 86400,) * 2)
    _recall(brain, "algo sobre tema comum", sid="../../etc/x")
    assert not old.exists()
    assert [p.name for p in state_dir.iterdir()] == ["______etc_x.json"]


def test_skipped_folders_and_short_prompt_and_missing_brain(brain, fake_home):
    for folder in (".git", ".obsidian", ".trash", "arquivos"):
        _note(brain, f"{folder}/n.md", "# Tema Comum\n")
    assert _recall(brain, "algo sobre tema comum") == ""
    _note(brain, "n.md", "# Tema\n")
    assert _recall(brain, "tema") == ""
    cfg = WispConfig(brain=str(fake_home / "missing"))
    assert hook_recall(cfg, WispPaths.current(), {"prompt": "algo sobre tema comum"}) == ""
    assert hook_recall(WispConfig(), WispPaths.current(), {"prompt": "algo sobre tema comum"}) == ""


def test_a_symlink_that_leaves_the_brain_is_never_recalled(brain, tmp_path):
    outside = tmp_path / "fora.md"
    outside.write_text("# Tema Comum Secreto\n\nsegredo\n")
    (brain / "atalho.md").symlink_to(outside)
    assert _recall(brain, "fale do tema comum secreto") == ""


def test_cli_prints_context_and_never_fails(brain, monkeypatch, capsys):
    import io
    save_config(WispConfig(brain=str(brain)))
    _note(brain, "n.md", "# Tema Comum\n\ntexto\n")
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"prompt": "algo sobre tema comum", "session_id": "q"})))
    assert main(["hook", "recall"]) == 0
    assert "n.md" in capsys.readouterr().out
    for raw in ("{quebrado", "[]", ""):
        monkeypatch.setattr("sys.stdin", io.StringIO(raw))
        assert main(["hook", "recall"]) == 0
        captured = capsys.readouterr()
        assert captured.out == "" and captured.err == ""


def test_exception_inside_recall_is_silent_exit0(brain, monkeypatch, capsys):
    import io
    def boom(*_):
        raise RuntimeError("x")
    monkeypatch.setattr("wisp.cli.hook_recall", boom)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"prompt": "algo sobre tema comum"})))
    assert main(["hook", "recall"]) == 0
    captured = capsys.readouterr()
    assert captured.out == "" and captured.err == ""


def test_a_broken_index_file_still_fails_open_through_the_cli(brain, fake_home, monkeypatch, capsys):
    import io
    save_config(WispConfig(brain=str(brain)))
    _note(brain, "n.md", "# Tema Comum\n\ntexto\n")
    monkeypatch.setattr("wisp.recall.BrainIndex.sync", lambda *a, **k: (_ for _ in ()).throw(OSError("disk")))
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"prompt": "algo sobre tema comum", "session_id": "q"})))
    assert main(["hook", "recall"]) == 0
    captured = capsys.readouterr()
    assert captured.out == "" and captured.err == ""


def test_recall_off_env_returns_nothing(brain, monkeypatch):
    _note(brain, "x.md", "# Plano Viagem\n\nTexto.\n")
    monkeypatch.setenv("WISP_RECALL_OFF", "1")
    assert _recall(brain, "Me ajuda com o plano da viagem") == ""


def test_fifo_is_skipped_without_blocking(brain):
    _note(brain, "x.md", "# Plano Viagem\n\nTexto.\n")
    os.mkfifo(brain / "pipe.md")
    assert "x.md" in _recall(brain, "Me ajuda com o plano da viagem")


def test_snippet_reads_only_a_bounded_prefix(brain):
    _note(brain, "x.md", "# Plano Viagem\n\n" + "a" * 200_000 + "\n\n## TLDR\nfim\n")
    out = _recall(brain, "Me ajuda com o plano da viagem")
    assert "x.md" in out and "fim" not in out
