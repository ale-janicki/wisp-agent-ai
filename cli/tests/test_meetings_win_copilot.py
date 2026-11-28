import json

import pytest

from wisp.meetings_win import copilot
from wisp.meetings_win.copilot import (AssistGate, BrainHit, EngineClient, LookupGate, assist_window, build_context,
                                       detect_entities, entity_key, merge_assist, parse_assist, parse_brain_hits,
                                       parse_prep, prep_items)
from wisp.meetings_win.transcript import MeetingSegment


def seg(start, text, speaker="eu", final=True):
    return MeetingSegment(start, start + 2, speaker, text, None, final)


def test_names_in_the_middle_of_a_sentence_are_entities_and_a_lone_first_word_is_not():
    assert detect_entities("Então falei com Marcos sobre o plano.") == ["Marcos"]
    assert detect_entities("Marcos chegou cedo.") == []
    assert detect_entities("Banco Central decidiu. Depois vimos.") == ["Banco Central"]


def test_a_keyword_takes_the_one_or_two_capitalised_words_after_it():
    assert detect_entities("nosso cliente Acme Corp pediu desconto") == ["Acme Corp"]
    assert detect_entities("o projeto Atlas atrasou e o squad Pagamentos ajudou") == ["Atlas", "Pagamentos"]
    assert detect_entities("o cliente pediu desconto") == []


def test_codes_are_four_digits_or_letters_with_digits():
    assert detect_entities("abra o pedido 12345 e o ticket ABC-123 hoje") == ["12345", "ABC-123"]
    assert detect_entities("são 12 pessoas") == []


def test_common_capitalised_words_days_and_months_are_ignored_and_the_list_is_capped():
    assert detect_entities("então Segunda Janeiro Obrigado") == []
    text = " e ".join(f"vi Pessoa{chr(97 + i)}x" for i in range(10))
    names = detect_entities(text.replace("Pessoa", "Maria"))
    assert len(names) <= 6


def test_entities_are_unique_ignoring_case_and_accents():
    assert detect_entities("falei com José e depois com jose Pereira, de novo com José") == ["José", "Pereira"]
    assert entity_key("  José   da  Silva ") == entity_key("jose da silva")


def test_the_lookup_gate_asks_two_at_a_time_twenty_seconds_apart_and_never_twice():
    gate = LookupGate()
    assert gate.pick(["Atlas", "Marcos", "Acme"], at=0) == ["Atlas", "Marcos"]
    assert gate.pick(["Acme"], at=10) == []
    assert gate.pick(["atlas", "Acme", "Zeta"], at=25) == ["Acme", "Zeta"]
    assert gate.pick(["ATLAS", "Marcos"], at=50) == []


def test_the_lookup_gate_stops_at_forty_per_meeting():
    gate = LookupGate(minimum_interval=0)
    for round_number in range(25):
        gate.pick([f"Nome{round_number}a", f"Nome{round_number}b"], at=round_number)
    assert len(gate._asked) == 40


def test_the_assist_gate_waits_for_new_finals_and_forty_seconds_and_runs_one_at_a_time():
    gate = AssistGate()
    assert not gate.should_run(0, final_count=0)
    assert gate.should_run(0, final_count=3)
    gate.started(0, final_count=3)
    assert not gate.should_run(100, final_count=9)
    gate.finished()
    assert not gate.should_run(100, final_count=3)
    assert not gate.should_run(20, final_count=9)
    assert gate.should_run(41, final_count=9)


def test_assist_items_are_at_most_three_and_new_ones_come_first_without_repeats():
    items = parse_assist(json.dumps({"itens": [{"tipo": "pergunte", "texto": "Qual o prazo?"}, {"tipo": "lembre", "texto": ""},
                                              {"tipo": "responda", "texto": "Custa 10"}, {"tipo": "lembre", "texto": "a"},
                                              {"tipo": "lembre", "texto": "b"}]}))
    assert [i.text for i in items] == ["Qual o prazo?", "Custa 10", "a"]
    shown = merge_assist(items, [])
    again = merge_assist([copilot.AssistItem("pergunte", "QUAL O PRAZO?"), copilot.AssistItem("lembre", "novo")], shown)
    assert [i.text for i in again] == ["novo", "Qual o prazo?", "Custa 10", "a"]
    assert parse_assist("not json") == [] and parse_assist(json.dumps({"itens": "x"})) == []
    many = merge_assist([copilot.AssistItem("lembre", f"i{n}") for n in range(3)], merge_assist(
        [copilot.AssistItem("lembre", f"o{n}") for n in range(3)], [copilot.AssistItem("lembre", f"p{n}") for n in range(3)]))
    assert len(many) == 6


def test_the_assist_window_is_the_last_four_minutes_of_finals_capped_at_6000_characters():
    segments = [seg(0, "antigo"), seg(100, "dentro"), seg(120, "…", final=False), seg(300, "outros dizem", "outros")]
    assert assist_window(segments, elapsed=330) == "[1:40] Você: dentro\n[5:00] Outros: outros dizem"
    long = [seg(i, "x" * 100) for i in range(100, 160)]
    assert len(assist_window(long, elapsed=200)) == 6000


def test_prep_has_a_checklist_and_questions_that_become_items_to_ask():
    report = parse_prep(json.dumps({"checklist": ["Revisar proposta", ""], "perguntas": ["Qual o orçamento?", 3]}))
    assert report == {"checklist": ["Revisar proposta"], "questions": ["Qual o orçamento?"]}
    assert prep_items(report) == ["Revisar proposta", "Perguntar: Qual o orçamento?"]
    assert parse_prep("zzz") == {"checklist": [], "questions": []}


def test_the_context_has_the_event_description_pending_checklist_and_brain_notes_within_the_limit():
    event = {"title": "Kickoff", "start": "10:00", "notes": "Levar o contrato", "attendees": ["Ana", "Rui"]}
    text = build_context(event, " pauta curta ", [{"text": "feito", "done": True}, {"text": "pendente", "done": False}],
                         [BrainHit("a.md", "Atlas", "projeto atlas")])
    assert text.splitlines()[0] == "Evento: Kickoff (10:00)"
    assert "Participantes: Ana, Rui" in text and "Notas do evento: Levar o contrato" in text
    assert "Descrição: pauta curta" in text and "- pendente" in text and "- feito" not in text
    assert "Notas do brain:\n- Atlas: projeto atlas" in text
    assert len(build_context(None, "x" * 9000, [], [])) == 6000


def test_brain_hits_are_read_from_a_list_or_a_wrapped_object_and_the_snippet_is_flattened():
    rows = [{"path": "n/a.md", "title": "A", "snippet": "um\n  dois   três"}, {"path": "n/b.md"}, {"title": "sem caminho"}]
    hits = parse_brain_hits(json.dumps(rows), limit=3)
    assert [(h.path, h.title, h.snippet) for h in hits] == [("n/a.md", "A", "um dois três"), ("n/b.md", "b.md", "")]
    wrapped = parse_brain_hits(json.dumps({"results": [{"arquivo": "x.md", "titulo": "X", "trecho": "t"}]}), 3)
    assert [(h.path, h.title, h.snippet) for h in wrapped] == [("x.md", "X", "t")]
    assert parse_brain_hits("nope", 3) == [] and len(parse_brain_hits(json.dumps(rows * 5), 2)) == 2
    assert len(parse_brain_hits(json.dumps([{"path": "a.md", "snippet": "z" * 500}]), 3)[0].snippet) == 220


def test_a_hit_opens_only_inside_the_brain(tmp_path):
    brain = tmp_path / "brain"
    (brain / "n").mkdir(parents=True)
    (brain / "n" / "a.md").write_text("x", encoding="utf-8")
    outside = tmp_path / "outside.md"
    outside.write_text("x", encoding="utf-8")
    assert BrainHit("n/a.md", "A", "").resolve(brain) == (brain / "n" / "a.md").resolve()
    assert BrainHit("../outside.md", "A", "").resolve(brain) is None
    assert BrainHit(str(outside), "A", "").resolve(brain) is None
    assert BrainHit("n/missing.md", "A", "").resolve(brain) is None


class Runner:
    def __init__(self, code=0, out="", err=""):
        self.result, self.calls = (code, out, err), []

    def __call__(self, argv, stdin=None, cancel=None):
        self.calls.append((argv, stdin))
        return self.result


def test_the_engine_client_calls_wisp_reuniao_assist_with_json_on_stdin():
    runner = Runner(0, json.dumps({"itens": [{"tipo": "lembre", "texto": "Fechar data"}], "motor": "claude"}))
    items = EngineClient(runner, ["wisp"]).assist("[0:01] Você: oi", "contexto", ["pergunte: x"])
    assert [i.text for i in items] == ["Fechar data"]
    argv, stdin = runner.calls[0]
    assert argv == ["wisp", "reuniao", "assist"]
    assert json.loads(stdin) == {"transcript": "[0:01] Você: oi", "context": "contexto", "already": ["pergunte: x"]}


def test_prep_and_failures_surface_the_engines_reason():
    runner = Runner(0, json.dumps({"checklist": ["a"], "perguntas": ["b"]}))
    assert EngineClient(runner, ["wisp"]).prep({"titulo": "X"}) == {"checklist": ["a"], "questions": ["b"]}
    failing = Runner(1, "", json.dumps({"erro": "a IA local não está pronta: sem modelo"}))
    with pytest.raises(copilot.EngineFailed, match="a IA local não está pronta"):
        EngineClient(failing, ["wisp"]).assist("t", "c", [])
    with pytest.raises(copilot.EngineFailed, match="saiu com 5"):
        EngineClient(Runner(5), ["wisp"]).prep({"titulo": "X"})


def test_brain_search_is_available_only_when_the_command_exists_and_never_takes_a_dash_query():
    ok = Runner(0, "[]")
    client = EngineClient(ok, ["wisp"])
    assert client.brain_available()
    assert ok.calls[0][0] == ["wisp", "brain", "search", "--help"]
    assert not EngineClient(Runner(2), ["wisp"]).brain_available()
    hits = Runner(0, json.dumps([{"path": "a.md", "title": "A", "snippet": "s"}]))
    assert [h.path for h in EngineClient(hits, ["wisp"]).brain_search("Atlas", "/brain", 3)] == ["a.md"]
    assert hits.calls[0][0] == ["wisp", "brain", "search", "Atlas", "--root", "/brain", "--limit", "3"]
    assert EngineClient(hits, ["wisp"]).brain_search("-rf", "/brain", 3) == [] and len(hits.calls) == 1
