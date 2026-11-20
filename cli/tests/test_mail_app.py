import json

import pytest

from wisp.email.mail_app import DENIED, TIMEOUT, MailApp, MailError, MailSummary
from wisp.runner import FakeRunner, RunResult

ROW = {"id": '["a","INBOX",1]', "account": "a", "mailbox": "INBOX", "sender": "x@y.z", "subject": "Oi", "date": "2026-11-18T10:00:00Z", "unread": True}


def _app(result: RunResult) -> tuple[MailApp, FakeRunner]:
    runner = FakeRunner({("osascript",): result})
    return MailApp(runner), runner


def _ok(payload) -> RunResult:
    return RunResult([], 0, json.dumps(payload), "")


def test_list_parses_json():
    app, runner = _app(_ok([ROW, {**ROW, "id": '["a","INBOX",2]', "unread": False}]))
    out = app.list("INBOX", 2)
    assert [m.subject for m in out] == ["Oi", "Oi"]
    assert out[0] == MailSummary(ROW["id"], "a", "INBOX", "x@y.z", "Oi", "2026-11-18T10:00:00Z", True)
    assert out[1].unread is False
    assert json.loads(runner.calls[0][-1]) == {"mailbox": "INBOX", "limit": 2}


def test_read_parses_message():
    app, _ = _app(_ok({**ROW, "to": ["me@x.y"], "cc": [], "body_text": "corpo"}))
    msg = app.read(ROW["id"])
    assert msg.body_text == "corpo" and msg.to == ["me@x.y"] and msg.subject == "Oi"


def test_arguments_not_interpolated():
    query = 'x"); Application("Finder")'
    app, runner = _app(_ok([]))
    app.search(query)
    argv = runner.calls[0]
    assert argv[:4] == ["osascript", "-l", "JavaScript", "-e"]
    assert query not in argv[4] and "Finder" not in argv[4]
    assert json.loads(argv[5])["query"] == query
    app.search("outra")
    assert runner.calls[1][4] == argv[4]


def test_automation_denied_message():
    app, _ = _app(RunResult([], 1, "", "execution error: Not authorized to send Apple events to Mail. (-1743)"))
    with pytest.raises(MailError) as e:
        app.list()
    assert str(e.value) == "o Mail não deixou: libere em Ajustes do Sistema › Privacidade e Segurança › Automação" == DENIED


def test_timeout_message():
    app, _ = _app(RunResult([], -9, "", "", timed_out=True))
    with pytest.raises(MailError) as e:
        app.list()
    assert str(e.value) == "o Mail não respondeu em 30 s" == TIMEOUT


def test_other_failure_is_one_sentence():
    app, _ = _app(RunResult([], 1, "", "Traceback...\nboom"))
    with pytest.raises(MailError) as e:
        app.read("x")
    assert "\n" not in str(e.value) and "Traceback" not in str(e.value)


def test_script_error_sentence_passes_through():
    app, _ = _app(_ok({"error": "a caixa 'Nada' não existe"}))
    with pytest.raises(MailError, match="não existe"):
        app.list("Nada")


def test_send_builds_recipients():
    app, runner = _app(_ok({"sent": True}))
    app.send(["a@x.y", "b@x.y"], "Assunto", "Texto", cc=["c@x.y"])
    args = json.loads(runner.calls[0][-1])
    assert args == {"to": ["a@x.y", "b@x.y"], "cc": ["c@x.y"], "subject": "Assunto", "body": "Texto"}


def test_read_unknown_id_uses_script_error():
    app, _ = _app(_ok({"error": "a mensagem não existe mais no Mail"}))
    with pytest.raises(MailError, match="não existe mais"):
        app.read('["a",["INBOX"],999]')


def test_send_empty_to_rejected_without_spawning():
    app, runner = _app(_ok({"sent": True}))
    with pytest.raises(MailError, match="falta o destinatário"):
        app.send([], "s", "b")
    assert runner.calls == []


def test_send_blank_address_rejected():
    app, runner = _app(_ok({"sent": True}))
    with pytest.raises(MailError, match="falta o destinatário"):
        app.send(["a@x.y", "  "], "s", "b")
    with pytest.raises(MailError, match="falta o destinatário"):
        app.send(["a@x.y"], "s", "b", cc=[""])
    assert runner.calls == []


def test_error_1712_is_timeout():
    app, _ = _app(RunResult([], 1, "", "execution error: Mail got an error: AppleEvent timed out. (-1712)"))
    with pytest.raises(MailError) as e:
        app.list()
    assert str(e.value) == TIMEOUT


def test_error_600_is_not_open():
    app, _ = _app(RunResult([], 1, "", "execution error: Application isn't running. (-600)"))
    with pytest.raises(MailError) as e:
        app.list()
    assert str(e.value) == "o Mail não está aberto e não abriu a tempo"


def test_nested_path_id_round_trip():
    nested = json.dumps(["Gmail", ["[Gmail]", "Sent Mail"], 7])
    row = {**ROW, "id": nested, "account": "Gmail", "mailbox": "[Gmail]/Sent Mail"}
    app, runner = _app(_ok([row]))
    listed = app.list("[Gmail]/Sent Mail")
    assert json.loads(runner.calls[0][-1])["mailbox"] == "[Gmail]/Sent Mail"
    assert json.loads(listed[0].id) == ["Gmail", ["[Gmail]", "Sent Mail"], 7]
    app2, runner2 = _app(_ok({**row, "to": [], "cc": [], "body_text": "x"}))
    msg = app2.read(listed[0].id)
    assert json.loads(json.loads(runner2.calls[0][-1])["id"]) == ["Gmail", ["[Gmail]", "Sent Mail"], 7]
    assert msg.id == nested


def test_malformed_row_is_mail_error():
    app, _ = _app(_ok([{"id": "x"}]))
    with pytest.raises(MailError, match="mensagem incompleta"):
        app.list()
    app2, _ = _app(_ok({**ROW}))
    with pytest.raises(MailError, match="mensagem incompleta"):
        app2.read(ROW["id"])
