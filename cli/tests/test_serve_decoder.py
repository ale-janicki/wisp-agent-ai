import json
import os
import sys
from pathlib import Path

import pytest

from wisp.serve.claude_session import (ClaudeNotFound, Event, PermissionRequest, TurnLedger, claude_arguments,
                                       decode_line, locate_claude, permission_response_line, plan_resume)

FIXTURES = Path(__file__).parent / "fixtures" / "serve"


def fixture_events(name):
    lines = (FIXTURES / name).read_text(encoding="utf-8").splitlines()
    return [event for line in lines if line for event in decode_line(line)]


def kinds(events):
    return [event.kind for event in events]


def test_two_turns_init_text_result():
    events = fixture_events("two-turns.jsonl")
    init = next(e for e in events if e.kind == "initialized")
    assert init.data["session_id"] == "99f6caac-8493-4246-9c13-04c5e4262742"
    assert init.data["subscription"] is True
    assert any(e.kind == "permission_mode" and e.data["mode"] == "auto" for e in events)
    results = [e for e in events if e.kind == "result"]
    assert len(results) == 2
    assert results[0].data["text"].startswith("um")
    assert results[1].data["text"].startswith("dois")
    assert len({r.data["session_id"] for r in results}) == 1
    assert "text" in kinds(events)
    assert "thinking" in kinds(events)


def test_usage_from_rate_limit_event():
    usage = [e for e in fixture_events("two-turns.jsonl") if e.kind == "usage"]
    assert usage[0].data["info"]["unifiedWindows"]["five_hour"]["utilization"] == 0.06


def test_result_carries_usage_object():
    result = next(e for e in fixture_events("two-turns.jsonl") if e.kind == "result")
    assert result.data["usage"]["output_tokens"] == 343


def test_replayed_user_echo_is_the_engine_consuming_it():
    echo = '{"type":"user","uuid":"e6cb0441","isReplay":true,"message":{"role":"user","content":"dois"}}'
    assert decode_line(echo) == [Event("user_replayed")]
    other = '{"type":"user","uuid":"f865","message":{"role":"user","content":[{"type":"text","text":"x"}]}}'
    assert decode_line(other) == [Event("ignored", {"type": "user"})]


def test_tool_use_keeps_id_name_input_and_summary():
    line = '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}]}}'
    [event] = decode_line(line)
    assert event.kind == "tool_use"
    assert event.data == {"id": "t1", "name": "Bash", "input": {"command": "ls -la"}, "summary": "ls -la"}


def test_tool_result_text_from_string_and_blocks():
    one = '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"12:00"}]}}'
    two = ('{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,'
           '"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}]}}')
    assert decode_line(one) == [Event("tool_result", {"tool_use_id": "t1", "is_error": False, "text": "12:00"})]
    assert decode_line(two) == [Event("tool_result", {"tool_use_id": "t2", "is_error": True, "text": "a\nb"})]


def test_permission_requests_fixture():
    events = fixture_events("permission-requests.jsonl")
    requests = [e.data["request"] for e in events if e.kind == "permission_request"]
    assert len(requests) >= 2
    first = requests[0]
    assert first.request_id == "60b7088a-a770-4ca8-b509-34df85ee1490"
    assert first.tool_name == "Bash"
    assert first.input == {"command": "touch probe1", "description": "Create empty file probe1"}
    assert first.tool_use_id == "toolu_0119S42dja9dtfk53vCGodgb"


def test_unknown_malformed_and_cancel():
    assert decode_line('{"type":"future_event"}') == [Event("ignored", {"type": "future_event"})]
    assert decode_line("not json") == [Event("malformed", {"line": "not json"})]
    assert decode_line('{"type":"control_cancel_request","request_id":"r9"}') == [Event("permission_cancelled", {"id": "r9"})]


def test_stream_event_text_delta():
    line = ('{"type":"stream_event","event":{"type":"content_block_delta","index":0,'
            '"delta":{"type":"text_delta","text":"oi"}}}')
    assert decode_line(line) == [Event("text_delta", {"text": "oi"})]


def test_arguments_match_the_mac_command():
    assert claude_arguments(model=None, resume=None) == [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--replay-user-messages", "--permission-prompt-tool", "stdio"]
    args = claude_arguments(model="m", resume="s1", permission_mode="plan", append_system_prompt="p",
                            settings="/x.json", disallowed_tools=["A", "B"])
    assert args[7:] == ["--model", "m", "--resume", "s1", "--permission-mode", "plan", "--append-system-prompt", "p",
                        "--settings", "/x.json", "--disallowedTools", "A", "B", "--permission-prompt-tool", "stdio"]


def test_resume_plan_matches_engine_resume():
    keep = plan_resume("claude", last_engine="claude", claude_session="s1", codex_session=None, lost=False)
    assert (keep.resume, keep.prime) == ("s1", False)
    fresh = plan_resume("claude", last_engine=None, claude_session=None, codex_session=None, lost=False)
    assert (fresh.resume, fresh.prime) == (None, False)
    missing = plan_resume("claude", last_engine="claude", claude_session=None, codex_session=None, lost=False)
    assert (missing.resume, missing.prime, missing.link_reason) == (None, True, "rebuilt")
    lost = plan_resume("claude", last_engine="claude", claude_session="s1", codex_session=None, lost=True)
    assert (lost.resume, lost.prime, lost.drop_claude_session) == (None, True, True)


def test_control_response_allow_and_deny():
    request = PermissionRequest.parse("req-1", {"subtype": "can_use_tool", "tool_name": "Bash",
                                                "input": {"command": "touch x"}})
    allow = permission_response_line(request, True)
    assert allow.endswith(b"\n")
    assert json.loads(allow) == {"type": "control_response", "response": {
        "subtype": "success", "request_id": "req-1",
        "response": {"behavior": "allow", "updatedInput": {"command": "touch x"}}}}
    deny = json.loads(permission_response_line(request, False, "no"))
    assert deny["response"]["response"] == {"behavior": "deny", "message": "no"}
    default_deny = json.loads(permission_response_line(request, False))["response"]["response"]
    assert default_deny["behavior"] == "deny" and default_deny["message"]


def test_permission_parse_rejects_other_subtypes_and_empty_id():
    assert PermissionRequest.parse("r", {"subtype": "hook_callback"}) is None
    assert PermissionRequest.parse("", {"subtype": "can_use_tool"}) is None


def test_ledger_echo_closes_only_consumed_messages():
    ledger = TurnLedger()
    ledger.submit("a", "one")
    ledger.writing("a"), ledger.written("a")
    ledger.submit("b", "two")
    ledger.writing("b"), ledger.written("b")
    assert ledger.pending == 2
    ledger.consumed()
    assert [e.id for e in ledger.result(is_error=False)] == ["a"]
    assert ledger.pending == 1
    ledger.consumed()
    assert [e.id for e in ledger.result(is_error=False)] == ["b"]
    assert ledger.pending == 0


def test_ledger_error_closes_everything_in_flight_but_not_queued():
    ledger = TurnLedger()
    ledger.submit("a", "one"), ledger.writing("a"), ledger.written("a")
    ledger.submit("b", "two")
    assert [e.id for e in ledger.result(is_error=True)] == ["a"]
    assert ledger.pending == 1


def test_locate_claude_prefers_configured_then_path_then_home(tmp_path):
    platform = sys.platform if sys.platform == "win32" else "linux"
    name = "claude.exe" if platform == "win32" else "claude"
    exe = tmp_path / name
    exe.write_text("#!/bin/sh\n")
    exe.chmod(0o755)
    assert locate_claude(str(exe), env={}, platform=platform, home=str(tmp_path / "nohome")) == str(exe)
    with pytest.raises(ClaudeNotFound):
        locate_claude(str(tmp_path / "missing"), env={}, platform=platform, home=str(tmp_path))
    assert locate_claude(None, env={"PATH": str(tmp_path)}, platform=platform, home=str(tmp_path / "nohome")) == str(exe)
    local = tmp_path / "h" / ".local" / "bin"
    local.mkdir(parents=True)
    (local / name).write_text("x")
    (local / name).chmod(0o755)
    assert locate_claude(None, env={"PATH": ""}, platform=platform, home=str(tmp_path / "h")) == str(local / name)
    with pytest.raises(ClaudeNotFound):
        locate_claude(None, env={"PATH": ""}, platform=platform, home=str(tmp_path / "empty"))


def test_locate_claude_windows_ignores_the_extensionless_npm_shim(tmp_path):
    (tmp_path / "claude").write_text("#!/bin/sh\n")
    with pytest.raises(ClaudeNotFound):
        locate_claude(None, env={"PATH": str(tmp_path)}, platform="win32", home=str(tmp_path / "nohome"))
    (tmp_path / "claude.cmd").write_text("@echo off\r\n")
    assert locate_claude(None, env={"PATH": str(tmp_path)}, platform="win32",
                         home=str(tmp_path / "nohome")) == os.path.join(str(tmp_path), "claude.cmd")


def test_locate_claude_windows_candidates(tmp_path):
    npm = tmp_path / "AppData" / "npm"
    npm.mkdir(parents=True)
    (npm / "claude.cmd").write_text("x")
    found = locate_claude(None, env={"PATH": "", "APPDATA": str(tmp_path / "AppData")}, platform="win32",
                          home=str(tmp_path / "nohome"))
    assert found == str(npm / "claude.cmd")
