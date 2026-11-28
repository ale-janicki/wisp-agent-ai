from pathlib import Path

from wisp import brain_colher, reuniao
from wisp.config import WispConfig


def fake_resolver(monkeypatch):
    calls = []

    def resolve(executable, platform=None):
        calls.append(executable)
        return ["C:/node/node.exe", "C:/npm/node_modules/pkg/cli.js"]

    monkeypatch.setattr("wisp.serve.claude_session.resolve_launch", resolve)
    return calls


def test_meeting_notes_never_run_the_agent_through_a_cmd_launcher(monkeypatch, tmp_path):
    calls = fake_resolver(monkeypatch)
    argv = reuniao.engine_argv(WispConfig(), "line one\nline two")
    assert argv[:2] == ["C:/node/node.exe", "C:/npm/node_modules/pkg/cli.js"]
    assert argv[2] == "--print" and argv[-1] == "line one\nline two"
    assert len(calls) == 1


def test_brain_harvest_never_runs_the_agent_through_a_cmd_launcher(monkeypatch, tmp_path):
    fake_resolver(monkeypatch)
    argv = brain_colher.model_argv(WispConfig(), Path(tmp_path / "settings.json"))
    assert argv[:2] == ["C:/node/node.exe", "C:/npm/node_modules/pkg/cli.js"]
    assert "--settings" in argv and argv[argv.index("--settings") + 1] == str(tmp_path / "settings.json")


def test_on_the_mac_the_argv_starts_with_the_binary_itself(monkeypatch, tmp_path):
    monkeypatch.setattr(brain_colher, "claude_bin", lambda cfg: "/usr/local/bin/claude")
    monkeypatch.setattr(reuniao, "claude_bin", lambda cfg: "/usr/local/bin/claude")
    assert reuniao.engine_argv(WispConfig(), "x")[0] == "/usr/local/bin/claude"
    assert brain_colher.model_argv(WispConfig(), Path(tmp_path / "s.json"))[0] == "/usr/local/bin/claude"
