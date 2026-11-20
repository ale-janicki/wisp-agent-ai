import io
import json
from pathlib import Path

import pytest

from wisp.cli import main
from wisp.config import WispConfig
from wisp.guard_lessons import hook_guard_lessons
from wisp.paths import WispPaths

HOME = "/Users/rita"
BRAIN = f"{HOME}/Wisp/brain"
ACTIVE = f"{BRAIN}/wisp/aprendizados.md"
PENDING = f"{BRAIN}/wisp/aprendizados-pendentes.md"
PATHS = WispPaths(Path(HOME), Path(HOME) / ".config/wisp", Path("/d"), Path("/s"), Path("/b"), None)


def _decide(tool, tool_input, brain=BRAIN, cwd=f"{HOME}/code"):
    return hook_guard_lessons({"tool_name": tool, "tool_input": tool_input, "cwd": cwd}, PATHS, WispConfig(brain=brain))


@pytest.mark.parametrize("tool,key", [("Write", "file_path"), ("Edit", "file_path"), ("MultiEdit", "file_path"), ("NotebookEdit", "notebook_path")])
@pytest.mark.parametrize("target", [ACTIVE, PENDING, "~/Wisp/brain/wisp/aprendizados.md"])
def test_file_tools_cannot_touch_the_lessons_files(tool, key, target):
    assert "wisp-guard:" in (_decide(tool, {key: target.replace("~", HOME) if target.startswith("~") else target}) or "")


def test_relative_path_and_a_custom_brain_folder_are_resolved():
    assert _decide("Write", {"file_path": "wisp/aprendizados.md"}, cwd=BRAIN)
    assert _decide("Write", {"file_path": "/elsewhere/mine/wisp/aprendizados.md"}, brain="/elsewhere/mine")
    assert _decide("Write", {"file_path": "/other/wisp/aprendizados-pendentes.md"}, brain=None)


def test_other_files_and_reads_are_allowed():
    assert _decide("Write", {"file_path": f"{BRAIN}/wisp/notes.md"}) is None
    assert _decide("Write", {"file_path": f"{HOME}/code/aprendizados.md"}) is None
    assert _decide("Read", {"file_path": ACTIVE}) is None
    assert _decide("Bash", {"command": f"cat {ACTIVE}"}) is None
    assert _decide("Bash", {"command": f"grep regra {ACTIVE} 2>&1 >/dev/null"}) is None
    assert _decide("Bash", {"command": '"$WISP_BIN" aprender add "Responda curto"'}) is None


@pytest.mark.parametrize("command", [
    f"echo '- x' >> {ACTIVE}",
    f"echo '- x' > {BRAIN}/wisp/aprendizados.md",
    f"echo x | tee -a {ACTIVE}",
    f"sed -i '' 's/a/b/' {ACTIVE}",
    f"sed -i.bak s/a/b/ {ACTIVE}",
    f"mv /tmp/x {ACTIVE}",
    f"cp /tmp/x {ACTIVE}",
    f"python3 -c \"open('{ACTIVE}','a').write('- x')\"",
    f"cd {BRAIN}/wisp && echo '- x' >> aprendizados.md",
])
def test_bash_commands_that_write_where_aprendizados_is_named_are_blocked(command):
    assert "wisp-guard:" in (_decide("Bash", {"command": command}) or "")


def test_cli_hook_exits_2_with_the_reason(fake_home, monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"tool_name": "Write", "tool_input": {"file_path": "/a/wisp/aprendizados.md"}})))
    assert main(["hook", "guard-lessons"]) == 2
    assert "wisp-guard:" in capsys.readouterr().err
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"tool_name": "Write", "tool_input": {"file_path": "/a/b.md"}})))
    assert main(["hook", "guard-lessons"]) == 0


def test_the_harvest_never_gets_this_guard():
    from wisp.brain_colher import GUARD_HOOKS, SCOPE_HOOK

    assert "guard-lessons" not in GUARD_HOOKS and SCOPE_HOOK != "guard-lessons"
