import json

from wisp.serve import guards


def test_windows_hook_command_is_always_quoted_with_forward_slashes():
    path = "C:\\Program Files\\Wisp\\.venv\\Scripts\\wisp.exe"
    assert guards.quote_command(path, "win32") == '"C:/Program Files/Wisp/.venv/Scripts/wisp.exe"'
    assert guards.quote_command("C:\\wisp\\wisp.exe", "win32") == '"C:/wisp/wisp.exe"'


def test_windows_hook_command_survives_git_bash():
    import shutil, subprocess
    bash = shutil.which("bash")
    if bash is None:
        return
    quoted = guards.quote_command("C:\\Wisp Data\\venv\\Scripts\\wisp.exe", "win32")
    out = subprocess.run([bash, "-c", f"printf %s {quoted}"], capture_output=True, text=True).stdout
    assert out == "C:/Wisp Data/venv/Scripts/wisp.exe"


def test_windows_path_with_bash_expanding_characters_is_refused():
    import pytest
    for bad in ("C:\\a$b\\wisp.exe", "C:\\a`b\\wisp.exe", 'C:\\a"b\\wisp.exe'):
        with pytest.raises(guards.GuardsUnavailable):
            guards.quote_command(bad, "win32")


def test_windows_denies_writes_to_its_config_and_state_dirs():
    deny = guards.guard_settings("C:\\w\\wisp.exe", "win32")["permissions"]["deny"]
    for rule in ("Write(~/AppData/Roaming/wisp/**)", "Edit(~/AppData/Local/wisp/**)", "Write(~/AppData/Roaming/Wisp/**)"):
        assert rule in deny
    assert not any("AppData" in r for r in guards.guard_settings("/bin/wisp", "darwin")["permissions"]["deny"])


def test_the_hook_binary_ignores_the_environment(tmp_path, monkeypatch):
    planted = tmp_path / "evil"
    planted.write_text("", encoding="utf-8")
    monkeypatch.setenv("WISP_BIN", str(planted))
    assert guards.wisp_binary(home=str(tmp_path)) != str(planted)


def test_posix_quoting_is_unchanged():
    assert guards.quote_command("/opt/it's here/wisp", "darwin") == "'/opt/it'\\''s here/wisp'"


def test_settings_match_the_mac_hook_set():
    settings = guards.guard_settings("/bin/wisp", "darwin")
    commands = [h["command"] for h in settings["hooks"]["PreToolUse"][0]["hooks"]]
    assert commands == [f"'/bin/wisp' hook {n}" for n in guards.HOOKS]
    assert len(settings["permissions"]["ask"]) == 5 + 6 * 4 + 2
    json.dumps(settings)


def test_phone_disallows_ask_user_question_and_instructions_append_the_soul(tmp_path, monkeypatch):
    (tmp_path / "wisp").write_text("", encoding="utf-8")
    monkeypatch.setattr(guards, "wisp_binary", lambda *a, **k: str(tmp_path / "wisp"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "s"))
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "s"))
    monkeypatch.setattr(guards, "soul_text", lambda: "")
    launch = guards.prepare(tmp_path, away_on_phone=True)
    assert launch.disallowed_tools == ("AskUserQuestion",)
    assert launch.environment == {"WISP_BIN": str(tmp_path / "wisp")}
    assert guards.instructions("alma", "win32").endswith("\n\nalma")
    assert "Mac tools" not in guards.instructions("", "win32") and "Mac tools" in guards.instructions("", "darwin")
