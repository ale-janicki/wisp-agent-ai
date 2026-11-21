from pathlib import Path

import pytest

from wisp.local import guardrails
from wisp.local.guardrails import GuardrailsError, TurnGuard, needs_card

SHIPPED = Path(guardrails.__file__).parents[1] / "wisp_folder" / "guardrails.toml"
GOOD = """
[pequeno]
max_steps = 6
tools = ["read_file", "write_file"]
approve = ["write_file"]
[medio]
max_steps = 12
tools = ["read_file", "write_file"]
[grande]
max_steps = 0
tools = ["read_file", "run_shell"]
"""


def rails(text: str = GOOD) -> guardrails.Guardrails:
    return guardrails.parse(text)


def test_the_shipped_file_is_valid_and_has_the_three_tiers():
    shipped = guardrails.parse(SHIPPED.read_text())
    assert [shipped.tier(n).max_steps for n in guardrails.TIERS] == [6, 12, 40]
    assert "email_send" in shipped.tier("pequeno").tools and "run_shell" not in shipped.tier("medio").tools
    assert shipped.repeat_limit == 3


def test_the_irreversible_floor_cannot_be_removed_from_the_file():
    assert rails().irreversible == {"email_send", "mac_send", "run_shell"}
    extra = rails(GOOD + '\n[irreversible]\ntools = ["delete_everything"]\n')
    assert extra.irreversible == {"email_send", "mac_send", "run_shell", "delete_everything"}


@pytest.mark.parametrize(
    "text, fragment",
    [
        ("[pequeno\n", "não consegui ler"),
        (GOOD.replace("[medio]", "[meio]"), "[meio]"),
        (GOOD.replace("max_steps = 6", 'max_steps = "seis"'), "[pequeno] max_steps"),
        (GOOD.replace("max_steps = 6", "max_steps = -1"), "[pequeno] max_steps"),
        (GOOD.replace("max_steps = 12", "max_steps = true"), "[medio] max_steps"),
        (GOOD.replace('tools = ["read_file", "run_shell"]', "tools = 3"), "[grande] tools"),
        (GOOD.replace('approve = ["write_file"]', 'approve = ["email_list"]'), "'email_list', que não está em tools"),
        (GOOD.replace("max_steps = 6", "max_steps = 6\nspeed = 1"), "'speed'"),
        (GOOD + "[loop]\nrepeat_limit = 1\n", "repeat_limit"),
        (GOOD + "[irreversible]\nnames = []\n", "[irreversible]"),
        (GOOD.replace("[grande]\nmax_steps = 0\ntools = [\"read_file\", \"run_shell\"]", ""), "falta a seção [grande]"),
    ],
)
def test_an_invalid_file_is_refused_with_the_reason(text, fragment):
    with pytest.raises(GuardrailsError) as e:
        rails(text)
    assert fragment in str(e.value) and str(e.value).startswith("guardrails.toml:")


def test_a_missing_file_says_where_to_get_it_back(tmp_path):
    with pytest.raises(GuardrailsError, match="wisp setup folder"):
        guardrails.load(tmp_path)


@pytest.mark.parametrize("mode", guardrails.MODES)
def test_irreversible_tools_always_get_the_card_in_every_mode(mode):
    r = rails()
    for tier in ("pequeno", "medio", "grande"):
        assert needs_card(r, r.tier(tier), mode, "run_shell")


@pytest.mark.parametrize("mode", guardrails.MODES)
def test_a_tier_approve_list_gets_the_card_in_every_mode(mode):
    r = rails()
    assert needs_card(r, r.tier("pequeno"), mode, "write_file")


def test_writes_ask_in_default_mode_and_follow_the_tier_otherwise():
    r = rails()
    assert needs_card(r, r.tier("medio"), "default", "write_file")
    assert not needs_card(r, r.tier("medio"), "auto", "write_file")
    assert not needs_card(r, r.tier("medio"), "bypassPermissions", "write_file")


@pytest.mark.parametrize("mode", guardrails.MODES)
def test_reads_never_ask(mode):
    r = rails()
    assert not needs_card(r, r.tier("pequeno"), mode, "read_file")


@pytest.mark.parametrize("mode", guardrails.MODES)
@pytest.mark.parametrize("tier", ["pequeno", "medio", "grande"])
def test_email_send_is_always_carded(mode, tier):
    r = rails()
    assert needs_card(r, r.tier(tier), mode, "email_send")


def test_an_unknown_tool_counts_as_a_write():
    r = rails()
    assert needs_card(r, r.tier("medio"), "default", "some_server_tool")


def test_the_step_cap_trips_at_max_steps_and_zero_means_no_cap():
    guard = TurnGuard(rails().tier("pequeno"), 3)
    for _ in range(5):
        guard.count_step()
    assert not guard.capped
    guard.count_step()
    assert guard.capped
    free = TurnGuard(rails().tier("grande"), 3)
    for _ in range(500):
        free.count_step()
    assert not free.capped


def test_the_same_call_trips_the_loop_check_at_the_limit_only():
    guard = TurnGuard(rails().tier("pequeno"), 3)
    assert [guard.repeated("read_file", {"path": "a", "x": 1}) for _ in range(3)] == [False, False, True]
    assert not guard.repeated("read_file", {"path": "b"})
    assert not guard.repeated("list_files", {"path": "a"})
    again = TurnGuard(rails().tier("pequeno"), 2)
    assert [again.repeated("t", {"b": 1, "a": 2}), again.repeated("t", {"a": 2, "b": 1})] == [False, True]


def test_the_allowlist_is_the_tier_tools():
    guard = TurnGuard(rails().tier("pequeno"), 3)
    assert guard.allowed("read_file") and not guard.allowed("run_shell")


def test_mac_send_always_needs_the_card_and_read_only_mac_tools_never_do():
    shipped = guardrails.parse(SHIPPED.read_text())
    for mode in guardrails.MODES:
        assert needs_card(shipped, shipped.tier("grande"), mode, "mac_send")
        assert not needs_card(shipped, shipped.tier("grande"), mode, "mac_ui_tree")
    assert needs_card(shipped, shipped.tier("grande"), "default", "mac_ui_click")
    assert not needs_card(shipped, shipped.tier("grande"), "auto", "mac_ui_click")


def test_the_shipped_tiers_only_list_real_mac_tools():
    from wisp.mac_control import TOOLS

    shipped = guardrails.parse(SHIPPED.read_text())
    for name in guardrails.TIERS:
        listed = {t for t in shipped.tier(name).tools if t.startswith("mac_")}
        assert listed <= set(TOOLS), name
    assert "mac_send" in shipped.tier("grande").tools and "mac_send" not in shipped.tier("pequeno").tools
    assert "mac_script" not in shipped.tier("medio").tools


def _loaded(tmp_path, text):
    (tmp_path / guardrails.FILE).write_text(text)
    return guardrails.load(tmp_path)


def test_an_existing_file_without_mac_tools_gets_the_shipped_mac_defaults_at_load_time(tmp_path):
    from wisp.mac_control import TOOLS

    old = _loaded(tmp_path, GOOD)
    shipped = guardrails.parse(SHIPPED.read_text())
    for name in guardrails.TIERS:
        assert {t for t in old.tier(name).tools if t.startswith("mac_")} == {t for t in shipped.tier(name).tools if t in TOOLS}
    assert "mac_send" in old.tier("grande").tools and "mac_send" not in old.tier("medio").tools
    assert not any(t.startswith("mac_") for t in rails().tier("grande").tools), "parse alone adds nothing"


def test_the_merge_adds_only_mac_tools_and_changes_nothing_else(tmp_path):
    text = GOOD + '\n[irreversible]\ntools = ["x"]\n[loop]\nrepeat_limit = 5\n'
    plain, merged = rails(text), _loaded(tmp_path, text)
    for name in guardrails.TIERS:
        a, b = plain.tier(name), merged.tier(name)
        assert (a.max_steps, a.approve) == (b.max_steps, b.approve)
        assert a.tools <= b.tools and all(t.startswith("mac_") for t in b.tools - a.tools)
    assert (plain.irreversible, plain.repeat_limit) == (merged.irreversible, merged.repeat_limit)
    assert needs_card(merged, merged.tier("grande"), "auto", "mac_send")


def test_the_users_file_can_remove_builtin_mac_tools_but_not_anything_else(tmp_path):
    text = GOOD.replace('tools = ["read_file", "run_shell"]', 'tools = ["read_file", "run_shell"]\nremove = ["mac_script", "mac_send"]')
    merged = _loaded(tmp_path, text)
    assert "mac_script" not in merged.tier("grande").tools and "mac_send" not in merged.tier("grande").tools
    assert "mac_ui_click" in merged.tier("grande").tools
    for bad in ('remove = ["run_shell"]', 'remove = ["email_send"]', 'remove = "mac_script"'):
        with pytest.raises(GuardrailsError):
            rails(GOOD.replace('tools = ["read_file", "run_shell"]', f'tools = ["read_file", "run_shell"]\n{bad}'))
