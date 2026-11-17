import json

from wisp.report import Detail, StepReport


def test_failed_exit_code_is_1_and_json_still_printed(capsys):
    from wisp.cli import emit

    r = StepReport("system", "failed", "nao deu", [], {})
    assert r.exit_code() == 1
    assert emit(r) == 1
    out = json.loads(capsys.readouterr().out)
    assert out["status"] == "failed"
    assert StepReport("x", "needs_user", "s", [], {}).exit_code() == 0


def test_output_tail_capped_at_4000():
    d = Detail.capture("cmd", 0, "a" * 3000, "b" * 3000)
    assert len(d.output) == 4000
    assert d.output.endswith("b" * 3000)
