import json
from pathlib import Path

import pytest

from wisp.serve.claude_session import (PermissionRequest, TurnLedger, decode_line, permission_response_line,
                                       usage_windows)

FIXTURES = Path(__file__).parent / "fixtures" / "serve"


def parse(tool, tool_input, **extra):
    home = extra.pop("home", "/home/u")
    engine = extra.pop("engine", "claude")
    return PermissionRequest.parse("r1", {"subtype": "can_use_tool", "tool_name": tool, "input": tool_input, **extra},
                                   home=home, engine=engine)


def fixture_requests():
    lines = (FIXTURES / "permission-requests.jsonl").read_text(encoding="utf-8").splitlines()
    return [e.data["request"] for line in lines for e in decode_line(line) if e.kind == "permission_request"]


def test_a_bash_suggestion_can_be_persisted_as_a_rule():
    first = fixture_requests()[0]
    assert first.summary == "rodar touch probe1"
    assert first.can_persist and first.persist_rules == ["Bash(touch probe1 *)"]
    assert [s["type"] for s in first.persist] == ["addRules"]
    assert first.requires_expansion is False
    assert first.detail == "Create empty file probe1\n\ntouch probe1"


def test_write_offers_no_always_and_locks_because_the_content_is_hidden():
    write = fixture_requests()[1]
    assert write.tool_name == "Write" and not write.can_persist and write.persist_rules == []
    assert write.summary == "escrever /tmp/wisp-scratch/notes.txt"
    assert write.requires_expansion is True
    assert '"content": "hi"' in write.detail


@pytest.mark.parametrize("tool,tool_input,locked", [
    ("Bash", {"command": "ls -la"}, False),
    ("Bash", {"command": "ls\nrm -rf x"}, True),
    ("Bash", {"command": "ls && rm x"}, True),
    ("Bash", {"command": "make 2>&1"}, False),
    ("Bash", {"command": "echo $(whoami)"}, True),
    ("Read", {"file_path": "/a/b", "limit": 10}, False),
    ("Grep", {"pattern": "x", "path": "/a"}, False),
    ("Edit", {"file_path": "/a/b", "old_string": "x", "new_string": "y"}, True),
    ("Edit", {"file_path": "/a/b"}, False),
    ("mcp__wisp__x", {"a": "um", "b": "dois"}, True),
    ("mcp__wisp__x", {"a": "um"}, False),
    ("mcp__wisp__x", {}, False),
])
def test_expansion_lock_follows_what_the_summary_hides(tool, tool_input, locked):
    assert parse(tool, tool_input).requires_expansion is locked


def test_a_summary_cut_to_one_line_locks_and_keeps_the_whole_input_in_detail():
    command = "echo " + "a" * 200
    request = parse("Bash", {"command": command})
    assert request.summary_truncated and request.requires_expansion
    assert len(request.summary) == 120 and request.summary.endswith("…")
    assert request.detail.endswith(command)


def test_paths_inside_home_show_as_tilde_and_summaries_per_tool():
    assert parse("Edit", {"file_path": "/home/u/notes.txt"}).summary == "editar ~/notes.txt"
    assert parse("Read", {"file_path": "/home/u"}).summary == "ler ~"
    assert parse("WebFetch", {"url": "https://example.com"}).summary == "abrir https://example.com"
    assert parse("WebSearch", {"query": "wisp"}).summary == "pesquisar wisp"
    assert parse("Glob", {"pattern": "*.py"}).summary == "buscar *.py"
    assert parse("PowerShell", {"command": "Get-Date"}).summary == "rodar Get-Date"
    assert parse("Bash", {}).summary == "rodar um comando"
    assert parse("mcp__x__y", {"b": "2", "a": "um"}).summary == "usar mcp__x__y: um"
    assert parse("mcp__x__y", {}).summary == "usar mcp__x__y"


def test_invisible_characters_are_shown_as_escapes_so_nothing_hides():
    request = parse("Bash", {"command": "echo a​b‮c"})
    assert "\\u{200b}" in request.summary and "\\u{202e}" in request.summary
    assert "\\u{200b}" in request.detail
    assert parse("Bash", {"command": "a\tb"}).detail == "a\tb"


def test_ask_tools_are_never_persisted_even_when_the_cli_offers_it():
    suggestion = [{"type": "addRules", "behavior": "allow", "destination": "localSettings",
                   "rules": [{"toolName": "mcp__wisp-email__email_send"}]}]
    request = parse("mcp__wisp-email__email_send", {"to": "a@b.c"}, permission_suggestions=suggestion)
    assert not request.can_persist
    other = parse("Bash", {"command": "x"}, permission_suggestions=suggestion)
    assert other.can_persist and other.persist_rules == ["mcp__wisp-email__email_send"]


def test_session_scoped_and_mode_suggestions_are_not_always():
    suggestions = [{"type": "addRules", "behavior": "allow", "destination": "session",
                    "rules": [{"toolName": "Bash", "ruleContent": "x *"}]},
                   {"type": "setMode", "mode": "acceptEdits", "destination": "session"},
                   {"type": "addRules", "behavior": "deny", "destination": "localSettings", "rules": []}]
    assert not parse("Bash", {"command": "x"}, permission_suggestions=suggestions).can_persist


def test_codex_asks_in_plain_words_for_the_ask_tools():
    email = parse("mcp__wisp-email__email_send", {"to": "a@b.c"}, engine="codex")
    assert email.summary == "enviar um e-mail" and email.asker == "Codex"
    assert parse("mcp__wisp-mac__mac_send", {}, engine="codex").summary == "enviar uma mensagem pelo app"
    assert parse("Bash", {"command": "x"}).asker == "Claude"


def test_always_allow_sends_only_the_persistable_rules_back():
    request = fixture_requests()[0]
    sent = json.loads(permission_response_line(request, True, always=True))["response"]["response"]
    assert sent["behavior"] == "allow" and sent["updatedInput"] == request.input
    assert sent["updatedPermissions"] == request.persist
    plain = json.loads(permission_response_line(request, True))["response"]["response"]
    assert "updatedPermissions" not in plain
    denied = json.loads(permission_response_line(request, False, always=True))["response"]["response"]
    assert denied["behavior"] == "deny" and "updatedPermissions" not in denied


def test_always_without_anything_to_persist_is_refused():
    with pytest.raises(ValueError):
        permission_response_line(fixture_requests()[1], True, always=True)


def test_event_fields_carry_what_the_card_needs():
    fields = fixture_requests()[0].card()
    assert fields == {"summary": "rodar touch probe1", "detail": "Create empty file probe1\n\ntouch probe1",
                      "summary_truncated": False, "requires_expansion": False, "can_persist": True,
                      "persist_rules": ["Bash(touch probe1 *)"],
                      "persist_where": ["configurações locais do projeto"], "engine": "claude", "asker": "Claude"}


def test_usage_windows_read_both_limits_and_ignore_what_is_missing():
    info = {"unifiedWindows": {"five_hour": {"utilization": 0.06, "resetsAt": 1800000000},
                               "seven_day": {"utilization": 0.5}}}
    assert usage_windows(info) == {"five_hour": {"utilization": 0.06, "resets_at": 1800000000},
                                   "seven_day": {"utilization": 0.5, "resets_at": None}}
    assert usage_windows({}) == {"five_hour": None, "seven_day": None}
    assert usage_windows({"unifiedWindows": {"five_hour": {"utilization": "x"}}})["five_hour"] is None


def test_non_claude_engines_close_one_turn_per_result():
    ledger = TurnLedger()
    for name in ("a", "b"):
        ledger.submit(name, name)
        ledger.writing(name), ledger.written(name)
    assert [e.id for e in ledger.result(engine="codex")] == ["a"]
    assert [e.id for e in ledger.result(engine="local")] == ["b"]


def suggestion(destination="localSettings", rules=None, **extra):
    return {"type": "addRules", "behavior": "allow", "destination": destination,
            "rules": rules if rules is not None else [{"toolName": "Bash", "ruleContent": "ls *"}], **extra}


def test_updated_permissions_are_rebuilt_from_what_the_card_shows_never_sent_back_verbatim():
    hostile = suggestion(rules=[{"toolName": "Bash", "ruleContent": "ls *", "extra": "x"}, {"toolName": 7}, "nope"],
                         evil="payload")
    request = parse("Bash", {"command": "ls"}, permission_suggestions=[hostile, {"type": "setMode", "mode": "bypassPermissions",
                                                                              "destination": "userSettings"}])
    assert request.persist == [{"type": "addRules", "behavior": "allow", "destination": "localSettings",
                                "rules": [{"toolName": "Bash", "ruleContent": "ls *"}]}]
    sent = json.loads(permission_response_line(request, True, always=True))["response"]["response"]
    assert sent["updatedPermissions"] == request.persist and "payload" not in json.dumps(sent)
    assert request.persist_rules == ["Bash(ls *)"]


def test_every_destination_is_named_in_plain_portuguese_and_unknown_ones_are_dropped():
    request = parse("Bash", {"command": "ls"}, permission_suggestions=[
        suggestion("userSettings"), suggestion("projectSettings"), suggestion("localSettings"), suggestion("cloud")])
    assert request.card()["persist_where"] == [
        "configurações do usuário (todos os projetos)",
        "configurações do projeto (arquivo compartilhado)",
        "configurações locais do projeto"]
    assert [s["destination"] for s in request.persist] == ["userSettings", "projectSettings", "localSettings"]
    assert not parse("Bash", {"command": "ls"}, permission_suggestions=[suggestion("cloud")]).can_persist
    assert not parse("Bash", {"command": "ls"}, permission_suggestions=[suggestion(rules=[])]).can_persist


def test_a_rule_with_invisible_characters_is_shown_escaped_and_locks_the_card():
    request = parse("Bash", {"command": "ls"}, permission_suggestions=[
        suggestion(rules=[{"toolName": "Bash", "ruleContent": "ls\u200b *"}])])
    assert request.persist_rules == ["Bash(ls\\u{200b} *)"]
    assert request.requires_expansion is True
    assert parse("Bash", {"command": "ls"}, permission_suggestions=[suggestion()]).requires_expansion is False
    long_rule = suggestion(rules=[{"toolName": "Bash", "ruleContent": "x" * 300}])
    assert parse("Bash", {"command": "ls"}, permission_suggestions=[long_rule]).requires_expansion is True
