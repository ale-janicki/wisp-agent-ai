import json
import re

from wisp.paths import resources_root

HARNESS = resources_root() / "harness"
PLACEHOLDERS = {"PERSONA_NAME", "USER_NAME", "BRAIN_DIR", "LANGUAGE", "WISP_DIR"}


def _shipped_files():
    return [p for p in HARNESS.rglob("*") if p.is_file()]


def _table_rows(section: str) -> list[list[str]]:
    text = (HARNESS / "MANIFEST.md").read_text()
    body = re.split(rf"^## {section}\s*$", text, flags=re.M)[1]
    body = re.split(r"^## ", body, flags=re.M)[0]
    rows = [[c.strip() for c in line.strip().strip("|").split("|")] for line in body.splitlines() if line.startswith("|")]
    return rows[2:]


def test_every_manifest_row_exists():
    rows = _table_rows("Included")
    assert rows
    for row in rows:
        destination = row[1].strip("`")
        assert (HARNESS / destination).is_file(), destination


def test_every_shipped_file_is_in_the_manifest():
    listed = {row[1].strip("`") for row in _table_rows("Included")}
    on_disk = {str(p.relative_to(HARNESS)) for p in _shipped_files()} - {"MANIFEST.md"}
    assert on_disk == listed


def test_excluded_table_gives_a_reason_for_each_item():
    rows = _table_rows("Excluded")
    assert rows
    assert all(len(row) >= 2 and row[0] and row[1] for row in rows)


def _hook_commands(settings: dict) -> list[str]:
    return [h["command"] for groups in settings["hooks"].values() for g in groups for h in g["hooks"]]


def test_settings_hooks_never_call_python3():
    commands = _hook_commands(json.loads((HARNESS / "settings.json").read_text()))
    assert commands
    assert not [c for c in commands if "python" in c]
    assert all("wisp hook" in c for c in commands)


def test_settings_fragment_is_valid_json_with_only_known_keys():
    settings = json.loads((HARNESS / "settings.json").read_text())
    assert set(settings) <= {"permissions", "hooks"}
    assert set(settings["hooks"]) == {"PreToolUse", "UserPromptSubmit", "SessionStart", "Stop"}
    assert "Bash(sudo *)" in settings["permissions"]["deny"]


def test_settings_ask_before_every_agenda_change():
    ask = json.loads((HARNESS / "settings.json").read_text())["permissions"]["ask"]
    for sub in ("criar-evento", "editar-evento", "apagar-evento", "criar-lembrete", "concluir-lembrete", "permissao --pedir"):
        assert f'Bash("$WISP_BIN" agenda {sub}:*)' in ask
        assert f'Bash("$WISP_AGENDA_BIN" {sub}:*)' in ask


def test_placeholders_are_only_the_five_known():
    found = set()
    for path in _shipped_files():
        found |= set(re.findall(r"\{\{([^}]*)\}\}", path.read_text()))
    assert found <= PLACEHOLDERS
    assert PLACEHOLDERS <= found



def test_settings_deny_the_secrets_folder_for_read_and_shell():
    deny = json.loads((HARNESS / "settings.json").read_text())["permissions"]["deny"]
    assert "Read(~/.config/wisp/secrets/**)" in deny
    assert any(rule.startswith("Bash(cat ") and "wisp/secrets" in rule for rule in deny)
    assert any(rule.startswith("Bash(grep ") and "wisp/secrets" in rule for rule in deny)
    assert "Bash(git push -f*)" in deny


def test_settings_ask_before_sending_mail_and_never_allow_it():
    permissions = json.loads((HARNESS / "settings.json").read_text())["permissions"]
    assert "mcp__wisp-email__email_send" in permissions["ask"]
    assert not any(rule.startswith("mcp__wisp-email") for rule in permissions["allow"])
    assert not any("approvals" in rule for rule in permissions["deny"])


def test_block_tells_the_agent_to_sync_after_changing_the_wisp_folder():
    line = next(ln for ln in (HARNESS / "claude-md-block.md").read_text().splitlines() if "{{WISP_DIR}}" in ln)
    assert "never under ~/.claude" in line and "`wisp harness sync`" in line


def _format_line(path) -> str:
    lines = [ln.strip().strip("`") for ln in path.read_text().splitlines() if ln.strip().strip("`").startswith("- **[Quem]")]
    assert len(lines) == 1, path
    return lines[0]


def test_pendencias_format_matches_the_vault_template():
    assert _format_line(HARNESS / "claude-md-block.md") == _format_line(resources_root() / "vault-template/pendencias.md")


def test_settings_register_the_outbound_guard():
    groups = json.loads((HARNESS / "settings.json").read_text())["hooks"]["PreToolUse"]
    commands = [h["command"] for g in groups for h in g["hooks"]]
    assert any(c.endswith("wisp hook guard-outbound") for c in commands)
