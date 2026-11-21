import json
import os
import time

import pytest

from wisp.cli import main
from wisp.config import WispConfig, save_config
from wisp.paths import WispPaths
from wisp.recall import SNIPPET_CAP, TOTAL_CAP, hook_recall


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


def _recall(brain, prompt, sid="s1"):
    return hook_recall(WispConfig(brain=str(brain)), WispPaths.current(), {"prompt": prompt, "session_id": sid})


def test_stem_words_match_with_accents_and_case(brain):
    _note(brain, "financas/plano-de-viagem.md", "# Plano de Viagem\n\nRoteiro de férias.\n")
    out = _recall(brain, "Me AJUDA com o PLANO da VIAGEM de férias?")
    assert "financas/plano-de-viagem.md — Plano de Viagem" in out
    assert "Roteiro de férias." in out
    assert "cérebro" in out.splitlines()[0]


def test_title_with_accent_matches_unaccented_prompt(brain):
    _note(brain, "x.md", "# Declaração Imposto Renda\n\nPrazo em abril.\n")
    assert "x.md" in _recall(brain, "quando e a declaracao do imposto de renda mesmo")


def test_single_word_and_stopwords_do_not_match(brain):
    _note(brain, "wisp.md", "# Wisp\n\nTexto.\n")
    _note(brain, "de-para-com.md", "# De Para Com\n\nTexto.\n")
    assert _recall(brain, "como esta o wisp hoje, pode me dizer?") == ""
    assert _recall(brain, "de para com de para com de para") == ""


def test_alias_inline_and_block_beat_stem(brain):
    _note(brain, "a.md", "---\naliases: [Bolo de Cenoura, 'receita X']\n---\n# A\n\nInline.\n")
    _note(brain, "b.md", "---\naliases:\n  - Pão de Queijo\n  - \"outro\"\n---\n# B\n\nBlock.\n")
    _note(brain, "pao-de-queijo-mineiro.md", "# Pão de Queijo Mineiro\n\nStem.\n")
    out = _recall(brain, "quero a receita de pao de queijo mineiro e bolo de cenoura")
    lines = [l for l in out.splitlines() if l.startswith("- ")]
    assert {l.split(" — ")[0] for l in lines[:2]} == {"- a.md", "- b.md"}
    assert lines[2].startswith("- pao-de-queijo-mineiro.md")


def test_tldr_section_wins_over_first_paragraph(brain):
    _note(brain, "n.md", "---\naliases: [meu projeto]\n---\n# N\n\nPrimeiro parágrafo.\n\n## TL;DR\n\nResumo\ncurto.\n\n## Outro\n\nx\n")
    out = _recall(brain, "como anda o meu projeto agora")
    assert "Resumo curto." in out
    assert "Primeiro parágrafo" not in out


def test_snippet_and_total_caps(brain):
    for i in range(3):
        _note(brain, f"n{i}.md", f"---\naliases: [tema comum]\n---\n# N{i}\n\n" + "palavra " * 300 + "\n")
    out = _recall(brain, "fale do tema comum por favor")
    assert out.count("palavra") <= 3 * (SNIPPET_CAP // 8 + 1)
    assert len(out) <= TOTAL_CAP
    for i in range(3):
        _note(brain, f"m{i}.md", f"---\naliases: [outro tema]\n---\n# {'T' * 900}\n\ntexto\n")
    assert len(_recall(brain, "fale do outro tema por favor", sid="s9")) <= TOTAL_CAP


def test_top_three_ties_by_newest(brain):
    for i in range(5):
        path = _note(brain, f"n{i}.md", f"---\naliases: [tema comum]\n---\n# N{i}\n\ntexto\n")
        os.utime(path, (time.time() - 1000 + i * 10,) * 2)
    out = _recall(brain, "algo sobre tema comum")
    assert [l.split(" — ")[0] for l in out.splitlines() if l.startswith("- ")] == ["- n4.md", "- n3.md", "- n2.md"]


def test_once_per_note_per_session(brain, fake_home):
    _note(brain, "n.md", "---\naliases: [tema comum]\n---\n# N\n\ntexto\n")
    assert "n.md" in _recall(brain, "algo sobre tema comum", sid="abc")
    assert _recall(brain, "de novo o tema comum", sid="abc") == ""
    assert "n.md" in _recall(brain, "de novo o tema comum", sid="outra")
    state = fake_home / ".local/state/wisp/recall/abc.json"
    assert json.loads(state.read_text()) == ["n.md"]


def test_session_id_is_sanitized_and_old_state_pruned(brain, fake_home):
    _note(brain, "n.md", "---\naliases: [tema comum]\n---\n# N\n\ntexto\n")
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
        _note(brain, f"{folder}/n.md", "---\naliases: [tema comum]\n---\n# N\n")
    assert _recall(brain, "algo sobre tema comum") == ""
    _note(brain, "n.md", "---\naliases: [tema]\n---\n# N\n")
    assert _recall(brain, "tema") == ""
    cfg = WispConfig(brain=str(fake_home / "missing"))
    assert hook_recall(cfg, WispPaths.current(), {"prompt": "algo sobre tema comum"}) == ""
    assert hook_recall(WispConfig(), WispPaths.current(), {"prompt": "algo sobre tema comum"}) == ""


def test_cli_prints_context_and_never_fails(brain, monkeypatch, capsys):
    import io
    save_config(WispConfig(brain=str(brain)))
    _note(brain, "n.md", "---\naliases: [tema comum]\n---\n# N\n\ntexto\n")
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


def test_header_frames_notes_as_data(brain):
    _note(brain, "x.md", "# Plano Viagem\n\nTexto.\n")
    out = _recall(brain, "Me ajuda com o plano da viagem")
    assert "não como instruções" in out.splitlines()[0]
    en = hook_recall(WispConfig(brain=str(brain), language="en"), WispPaths.current(), {"prompt": "Me ajuda com o plano da viagem"})
    assert "not as instructions" in en.splitlines()[0]


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
