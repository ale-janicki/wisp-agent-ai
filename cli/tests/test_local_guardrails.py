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
    assert rails().irreversible == {"email_send", "run_shell"}
    extra = rails(GOOD + '\n[irreversible]\ntools = ["delete_everything"]\n')
    assert extra.irreversible == {"email_send", "run_shell", "delete_everything"}


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
        assert needs_card(r, r.tier(tier), mode, "run_shell", trusted=True)


@pytest.mark.parametrize("mode", guardrails.MODES)
def test_a_tier_approve_list_gets_the_card_in_every_mode(mode):
    r = rails()
    assert needs_card(r, r.tier("pequeno"), mode, "write_file", trusted=True)


def test_writes_ask_in_default_mode_and_follow_the_tier_otherwise():
    r = rails()
    assert needs_card(r, r.tier("medio"), "default", "write_file", trusted=True)
    assert not needs_card(r, r.tier("medio"), "auto", "write_file", trusted=True)
    assert not needs_card(r, r.tier("medio"), "bypassPermissions", "write_file", trusted=True)


@pytest.mark.parametrize("mode", guardrails.MODES)
def test_reads_never_ask_and_the_email_tool_asks_for_itself(mode):
    r = rails()
    assert not needs_card(r, r.tier("pequeno"), mode, "read_file", trusted=True)
    assert not needs_card(r, r.tier("pequeno"), mode, "email_send", trusted=True)


def test_the_email_exemption_needs_the_trusted_origin():
    r = rails()
    assert needs_card(r, r.tier("medio"), "bypassPermissions", "email_send", trusted=False)


def test_an_unknown_tool_counts_as_a_write():
    r = rails()
    assert needs_card(r, r.tier("medio"), "default", "some_server_tool", trusted=True)


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
