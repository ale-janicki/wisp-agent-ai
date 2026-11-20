import io
import json

import pytest

from wisp.cli import main
from wisp.guard_brain_scope import hook_guard_brain_scope


@pytest.fixture
def world(tmp_path):
    brain = tmp_path / "brain"
    brain.mkdir()
    (brain / "nota.md").write_text("x")
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("s")
    return brain, outside, {"WISP_BRAIN_SCOPE": str(brain)}


def _decide(env, tool, tool_input, cwd):
    return hook_guard_brain_scope({"tool_name": tool, "tool_input": tool_input, "cwd": str(cwd)}, env)


def test_inside_is_allowed(world):
    brain, _, env = world
    assert _decide(env, "Read", {"file_path": str(brain / "nota.md")}, brain) is None
    assert _decide(env, "Write", {"file_path": "nota.md"}, brain) is None
    assert _decide(env, "Edit", {"file_path": "sub/new.md"}, brain) is None
    assert _decide(env, "Glob", {"pattern": "**/*.md"}, brain) is None
    assert _decide(env, "Grep", {"pattern": "x", "path": str(brain)}, brain) is None
    assert _decide(env, "Glob", {"pattern": str(brain / "*.md")}, brain) is None


def test_absolute_outside_is_denied(world):
    brain, outside, env = world
    reason = _decide(env, "Read", {"file_path": str(outside / "secret.txt")}, brain)
    assert reason and reason.startswith("wisp-guard:")
    assert _decide(env, "Write", {"file_path": str(outside / "new.md")}, brain)
    assert _decide(env, "NotebookEdit", {"notebook_path": str(outside / "a.ipynb")}, brain)
    assert _decide(env, "Grep", {"pattern": "x", "path": str(outside)}, brain)


def test_dotdot_escape_is_denied(world):
    brain, _, env = world
    assert _decide(env, "Read", {"file_path": "../outside/secret.txt"}, brain)
    assert _decide(env, "Read", {"file_path": str(brain / ".." / "outside" / "secret.txt")}, brain)


def test_symlink_inside_pointing_out_is_denied(world):
    brain, outside, env = world
    (brain / "link").symlink_to(outside)
    assert _decide(env, "Read", {"file_path": str(brain / "link" / "secret.txt")}, brain)
    assert _decide(env, "Grep", {"pattern": "s", "path": "link"}, brain)


def test_tilde_is_expanded(world, monkeypatch):
    brain, _, env = world
    monkeypatch.setenv("HOME", str(brain.parent))
    assert _decide(env, "Read", {"file_path": "~/outside/secret.txt"}, brain)
    assert _decide(env, "Read", {"file_path": "~/brain/nota.md"}, brain) is None


def test_glob_and_grep_without_path_use_cwd(world):
    brain, outside, env = world
    assert _decide(env, "Glob", {"pattern": "*.txt"}, outside)
    assert _decide(env, "Grep", {"pattern": "s"}, outside)
    assert _decide(env, "Grep", {"pattern": "s", "path": ""}, outside)


def test_glob_pattern_escaping_is_denied(world):
    brain, outside, env = world
    assert _decide(env, "Glob", {"pattern": str(outside / "*")}, brain)
    assert _decide(env, "Glob", {"pattern": "/etc/*"}, brain)
    assert _decide(env, "Glob", {"pattern": "../outside/*"}, brain)
    assert _decide(env, "Glob", {"pattern": "*/../../outside/*"}, brain)
    assert _decide(env, "Glob", {"pattern": "~/*"}, brain)


def test_git_and_obsidian_are_denied(world):
    brain, _, env = world
    assert _decide(env, "Write", {"file_path": str(brain / ".git" / "hooks" / "pre-commit")}, brain)
    assert _decide(env, "Edit", {"file_path": str(brain / ".git" / "config")}, brain)
    assert _decide(env, "Write", {"file_path": str(brain / ".obsidian" / "x")}, brain)
    assert _decide(env, "Read", {"file_path": ".git/config"}, brain)
    assert _decide(env, "Glob", {"pattern": ".git/**"}, brain)
    assert _decide(env, "Glob", {"pattern": "**/.obsidian/*"}, brain)
    assert _decide(env, "Grep", {"pattern": "x", "path": ".git"}, brain)
    assert _decide(env, "Write", {"file_path": str(brain / "sub" / "nota.md")}, brain) is None


def test_protected_names_match_case_insensitively(world):
    brain, _, env = world
    assert _decide(env, "Write", {"file_path": ".GIT/config"}, brain)
    assert _decide(env, "Write", {"file_path": str(brain / ".Obsidian" / "x")}, brain)
    assert _decide(env, "Glob", {"pattern": ".GIT/**"}, brain)


@pytest.mark.parametrize("pattern", ["{../..,x}/*", "[.][.]/*", "{.g,x}it/*"])
def test_glob_patterns_that_expand_to_parent_or_protected_are_denied(world, pattern):
    brain, _, env = world
    assert _decide(env, "Glob", {"pattern": pattern}, brain)


def test_plain_glob_with_braces_and_dots_is_allowed(world):
    brain, _, env = world
    assert _decide(env, "Glob", {"pattern": "**/*.{md,txt}"}, brain) is None


@pytest.mark.parametrize("pattern", ["/*/passwd", "/**/id_rsa", "/{etc}/passwd", "/*/*/.ssh/*", "/{a,b}/*"])
def test_absolute_pattern_without_static_prefix_is_denied(world, pattern):
    brain, _, env = world
    assert _decide(env, "Glob", {"pattern": pattern}, brain)


def test_missing_env_allows(world):
    brain, outside, _ = world
    assert _decide({}, "Read", {"file_path": str(outside / "secret.txt")}, brain) is None
    assert _decide({"WISP_BRAIN_SCOPE": ""}, "Glob", {"pattern": "/etc/*"}, brain) is None


def test_cli_exit_codes(world, monkeypatch, capsys):
    brain, outside, env = world
    monkeypatch.setenv("WISP_BRAIN_SCOPE", env["WISP_BRAIN_SCOPE"])
    block = {"tool_name": "Read", "tool_input": {"file_path": str(outside / "secret.txt")}, "cwd": str(brain)}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(block)))
    assert main(["hook", "guard-brain-scope"]) == 2
    assert capsys.readouterr().err.startswith("wisp-guard:")
    ok = {"tool_name": "Read", "tool_input": {"file_path": str(brain / "nota.md")}, "cwd": str(brain)}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(ok)))
    assert main(["hook", "guard-brain-scope"]) == 0
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert main(["hook", "guard-brain-scope"]) == 2


@pytest.mark.parametrize("tool_input", [{"file_path": "a\0b"}, {"path": "a\0b"}, {"pattern": "a\0b"}])
def test_nul_byte_in_path_is_blocked_not_raised(world, tool_input):
    brain, _, env = world
    tool = "Glob" if "pattern" in tool_input else "Read"
    assert _decide(env, tool, tool_input, brain)
