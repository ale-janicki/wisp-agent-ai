import asyncio
from pathlib import Path

from wisp import mac_server
from wisp.local import tools as local_tools
from wisp.mac_control import READ_ONLY, TOOLS, Ctx
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult


import pytest


@pytest.fixture(autouse=True)
def no_installed_app(tmp_path, monkeypatch):
    monkeypatch.setattr("wisp.mac_control.APP_ROOTS", (tmp_path / "system-applications",))


def _server(fake_home, script=None, gate=None):
    paths = WispPaths.for_os("Darwin", fake_home, {})
    runner = FakeRunner(script or {})
    return mac_server.build_server(Ctx(runner, paths, gate=gate)), runner


def test_the_server_exposes_every_tool_with_a_typed_schema(fake_home):
    server, _ = _server(fake_home)
    listed = {t.name: t for t in asyncio.run(server.list_tools())}
    assert set(listed) == set(TOOLS)
    send = listed["mac_send"].input_schema
    assert set(send["required"]) == {"app", "to", "subject", "body"} and send["properties"]["to"]["type"] == "array"
    assert listed["mac_open_url"].input_schema["properties"]["busca"]["anyOf"][0]["description"] == "o que buscar no site"
    assert "required" not in listed["mac_apps"].input_schema or not listed["mac_apps"].input_schema["required"]


def test_a_call_runs_the_action_and_a_failure_is_an_error_result_the_model_can_read(fake_home):
    server, runner = _server(fake_home, {("open",): RunResult([], 0, "", "")})
    ok = asyncio.run(server.call_tool("mac_open_url", {"site": "youtube", "busca": "lo-fi"}))
    assert not ok.is_error and ok.content[0].text.startswith("Abri https://www.youtube.com/results")
    assert runner.calls == [["open", "https://www.youtube.com/results?search_query=lo-fi"]]
    bad = asyncio.run(server.call_tool("mac_open_url", {"url": "file:///etc/passwd"}))
    assert bad.is_error and "http" in bad.content[0].text


def test_mac_send_without_a_helper_or_a_channel_is_an_error_and_sends_nothing(fake_home):
    server, runner = _server(fake_home)
    result = asyncio.run(server.call_tool("mac_send", {"app": "Mail", "to": ["a@b.c"], "subject": "s", "body": "b"}))
    assert result.is_error and runner.calls == []


def test_the_server_asks_the_host_for_mac_send_under_its_own_tool_name(monkeypatch):
    seen = {}
    monkeypatch.setattr(mac_server, "gate_from_env", lambda env, tool: seen.setdefault("tool", tool) or (lambda request: None))
    monkeypatch.setattr(mac_server, "build_server", lambda ctx: type("S", (), {"run": lambda self, mode: seen.setdefault("mode", mode)})())
    mac_server.run_server()
    assert seen == {"tool": "mac_send", "mode": "stdio"}


def test_the_local_engine_gets_every_mac_tool_as_a_builtin_and_the_names_are_reserved(tmp_path):
    specs, runs = local_tools.builtins([tmp_path], tmp_path)
    assert set(TOOLS) <= set(specs) and set(TOOLS) <= set(runs)
    assert set(TOOLS) <= local_tools.RESERVED_TOOLS
    assert specs["mac_send"].schema["required"] == ["app", "to", "subject", "body"]


def test_a_local_builtin_failure_is_a_tool_failure_with_the_sentence(tmp_path):
    _, runs = local_tools.builtins([tmp_path], tmp_path)
    try:
        runs["mac_volume"]({"valor": "alto"})
    except local_tools.ToolFailure as e:
        assert "0 a 100" in str(e)
    else:
        raise AssertionError("expected a ToolFailure")


def test_read_only_names_match_the_harness_allow_list():
    from wisp.setup.harness import MAC_ALLOW

    assert MAC_ALLOW == [f"mcp__wisp-mac__{n}" for n in sorted(READ_ONLY)]
