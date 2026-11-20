import asyncio
import json
import os
import stat
from pathlib import Path
from types import SimpleNamespace

from wisp_bot import aprovacoes, broker, codex_runner

CONTRACT = json.loads((Path(__file__).parents[2] / "cli/tests/fixtures/contract/approval-broker.json").read_text("utf-8"))
REQUEST = CONTRACT["request"]
THREAD = "0199a213-81c0-7800-8aa1-bbab2a035a53"


async def talk(path, raw: bytes, *, close_after_send=False):
    reader, writer = await asyncio.open_unix_connection(path)
    writer.write(raw)
    await writer.drain()
    if close_after_send:
        writer.close()
        return None
    line = await asyncio.wait_for(reader.readline(), 5)
    writer.close()
    return json.loads(line) if line else None


def line(msg) -> bytes:
    return json.dumps(msg).encode() + b"\n"


class Decider:
    def __init__(self, answer=None, wait=False):
        self.answer, self.wait, self.seen, self.cancelled = answer, wait, [], False

    async def __call__(self, req):
        self.seen.append(req)
        if self.wait:
            try:
                await asyncio.sleep(60)
            except asyncio.CancelledError:
                self.cancelled = True
                raise
        return self.answer


def with_broker(decider, body, validade=5):
    async def go():
        b = await broker.Broker(decider, validade=validade).start()
        try:
            return await body(b)
        finally:
            await b.close()
    return asyncio.run(go())


def test_the_socket_lives_in_a_private_folder_and_goes_away_on_close():
    async def go():
        b = await broker.Broker(Decider()).start()
        folder = os.path.dirname(b.path)
        assert stat.S_IMODE(os.stat(folder).st_mode) == 0o700 and stat.S_IMODE(os.stat(b.path).st_mode) == 0o600
        assert stat.S_ISSOCK(os.stat(b.path).st_mode) and len(b.path) <= 103
        await b.close()
        assert not os.path.exists(folder)
    asyncio.run(go())


def test_the_contract_request_reaches_the_host_in_the_can_use_tool_shape_and_allow_answers_allow():
    decider = Decider(None)
    answer = with_broker(decider, lambda b: talk(b.path, line(REQUEST)))
    assert answer == CONTRACT["allow"]
    assert decider.seen == [{"tool_name": CONTRACT["tool"], "input": REQUEST["input"], "engine": "codex"}]


def test_a_denial_carries_the_text_the_model_reads():
    answer = with_broker(Decider("não"), lambda b: talk(b.path, line(REQUEST)))
    assert answer == {"decision": "deny", "message": "não"}


def test_no_answer_in_time_denies_and_withdraws_the_card():
    decider = Decider(wait=True)
    answer = with_broker(decider, lambda b: talk(b.path, line(REQUEST)), validade=0.1)
    assert answer == {"decision": "deny", "message": broker.EXPIROU} and decider.cancelled


def test_a_client_that_disappears_withdraws_the_card():
    decider = Decider(wait=True)

    async def body(b):
        await talk(b.path, line(REQUEST), close_after_send=True)
        for _ in range(100):
            if decider.cancelled:
                break
            await asyncio.sleep(0.02)
    with_broker(decider, body)
    assert decider.cancelled


def test_a_failing_card_denies():
    async def boom(req):
        raise RuntimeError("telegram caiu")
    answer = with_broker(boom, lambda b: talk(b.path, line(REQUEST)))
    assert answer == {"decision": "deny", "message": broker.FALHOU}


def test_the_client_has_no_approve_verb_and_nothing_malformed_reaches_the_host():
    decider = Decider(None)
    bad = [
        b"not json\n", b"\n", b"[]\n",
        line({"op": "approve", "tool": "email_send", "input": {}}),
        line({"op": "allow"}), line({"decision": "allow"}), line({"approve": True}),
        line({**REQUEST, "op": "answer"}), line({**REQUEST, "tool": "Bash"}), line({**REQUEST, "input": "x"}),
        line({"op": "request", "tool": "email_send"}),
    ]

    async def body(b):
        return [await talk(b.path, raw) for raw in bad]
    answers = with_broker(decider, body)
    assert all(a == {"decision": "deny", "message": broker.MALFORMADO} for a in answers) and decider.seen == []


def test_extra_bytes_after_the_request_never_turn_into_an_allow():
    decider = Decider(wait=True)

    async def body(b):
        reader, writer = await asyncio.open_unix_connection(b.path)
        writer.write(line(REQUEST) + line({"decision": "allow"}))
        await writer.drain()
        got = await asyncio.wait_for(reader.read(), 5)
        writer.close()
        return got
    assert with_broker(decider, body) == b"" and decider.cancelled


class FakeBot:
    def __init__(self):
        self.enviadas = []

    async def send_message(self, chat_id, text, **kw):
        self.enviadas.append((chat_id, text, kw))
        return SimpleNamespace(message_id=1)

    async def edit_message_text(self, text, **kw):
        pass


class FakeQuery:
    def __init__(self, data, user_id):
        self.data, self.from_user = data, SimpleNamespace(id=user_id)

    async def answer(self, text=None, **kw):
        pass


def test_the_bot_shows_the_normal_card_with_the_whole_mail_and_only_the_owner_click_allows():
    async def go():
        bot = FakeBot()
        ap = aprovacoes.Aprovacoes(bot, 1)

        async def decidir(req):
            return await ap.pedir(-1001, 7, req)
        b = await broker.Broker(decidir).start()
        try:
            task = asyncio.ensure_future(talk(b.path, line(REQUEST)))
            for _ in range(200):
                if bot.enviadas:
                    break
                await asyncio.sleep(0.01)
            chat, corpo, kw = bot.enviadas[0]
            assert chat == -1001 and kw["message_thread_id"] == 7
            assert "O Codex quer enviar um e-mail" in corpo and "Claude" not in corpo
            assert "ana@exemplo.com" in corpo and "bia@exemplo.com" in corpo and "Oi" in corpo and "tudo bem" in corpo
            assert [x.text for x in kw["reply_markup"].inline_keyboard[0]] == ["Permitir", "Negar"]
            data = kw["reply_markup"].inline_keyboard[0][0].callback_data
            await ap.pressionou(SimpleNamespace(callback_query=FakeQuery(data, 2)))
            assert not task.done()
            await ap.pressionou(SimpleNamespace(callback_query=FakeQuery(data, 1)))
            assert await task == CONTRACT["allow"]
        finally:
            await b.close()
    asyncio.run(go())


def _dump_env_codex(tmp_path):
    fake = tmp_path / "codex"
    out = tmp_path / "env"
    lines = (Path(__file__).parents[2] / "cli/tests/fixtures/contract/codex-exec-stream-from-docs.jsonl").read_text("utf-8")
    fake.write_text(f"#!/bin/sh\ncat >/dev/null\necho \"SOCK=${{WISP_APPROVAL_SOCKET}}\" > {out}\n"
                    f"[ -S \"$WISP_APPROVAL_SOCKET\" ] && echo live >> {out}\ncat <<'EOF'\n{lines}EOF\n")
    fake.chmod(0o755)
    return fake, out


def test_a_codex_turn_gets_the_socket_in_its_env_only_while_it_runs(tmp_path, monkeypatch):
    fake, out = _dump_env_codex(tmp_path)
    monkeypatch.setattr(codex_runner, "CODEX_BIN", str(fake))

    async def go():
        return await codex_runner.run("oi", session_id="", cwd=str(tmp_path), started=False, timeout=20,
                                      on_permission=Decider())
    res = asyncio.run(go())
    seen = out.read_text().splitlines()
    sock = seen[0].removeprefix("SOCK=")
    assert res.ok and sock and "live" in seen and not os.path.exists(os.path.dirname(sock))


def test_no_handler_means_no_socket_and_a_stale_variable_is_dropped(tmp_path, monkeypatch):
    fake, out = _dump_env_codex(tmp_path)
    monkeypatch.setattr(codex_runner, "CODEX_BIN", str(fake))
    monkeypatch.setenv("WISP_APPROVAL_SOCKET", "/tmp/stale")
    res = asyncio.run(codex_runner.run("oi", session_id="", cwd=str(tmp_path), started=False, timeout=20))
    assert res.ok and out.read_text().splitlines() == ["SOCK="]


def test_the_codex_memory_path_hands_the_host_card_to_the_engine(tmp_path, monkeypatch):
    from wisp_bot import bot
    from wisp_bot.engine import Result
    from wisp_bot.store import Store
    from wisp_bot.transcript import Transcripts
    store = Store(tmp_path / "topics.json")
    store.get_or_create("1:7", "t", str(tmp_path))
    topic = store.get("1:7")
    monkeypatch.setattr(bot, "transcripts", Transcripts(tmp_path / "conversas"))
    got = []

    class Codex:
        name = "codex"

        async def run(self, prompt, **kw):
            got.append(kw.get("on_permission"))
            return Result(True, "ok", session_id=THREAD, engine="codex")

    async def pedir(req):
        return None

    async def note():
        pass
    asyncio.run(bot.codex_com_memoria(topic, Codex(), "oi", "oi", note, cwd="x", on_permission=pedir))
    assert got == [pedir]


def test_the_card_names_the_engine_that_asks_and_keeps_the_full_input():
    claude = aprovacoes.descrever({"tool_name": "mcp__wisp-email__email_send", "input": REQUEST["input"]})
    codex = aprovacoes.descrever({"tool_name": "mcp__wisp-email__email_send", "input": REQUEST["input"], "engine": "codex"})
    assert claude["summary"] == "O Claude quer usar mcp__wisp-email__email_send"
    assert codex["summary"] == "O Codex quer enviar um e-mail"
    assert claude["detail"] == codex["detail"] and "tudo bem" in codex["detail"] and "bia@exemplo.com" in codex["detail"]
    assert aprovacoes.descrever({"tool_name": "Bash", "input": {"command": "ls"}, "engine": "codex"})["summary"] == "O Codex quer rodar um comando"


def _fake_wisp(tmp_path, body):
    fake = tmp_path / "wisp"
    fake.write_text(f"#!/bin/sh\n{body}\n")
    fake.chmod(0o755)
    return str(fake)


def test_codex_is_not_ready_when_the_send_gate_check_fails_or_cannot_run(tmp_path, monkeypatch):
    monkeypatch.setattr(codex_runner, "WISP_BIN", _fake_wisp(tmp_path, "echo '{\"ready\": false, \"problem\": \"x\"}'; exit 1"))
    assert asyncio.run(codex_runner.gate_stale()) == codex_runner.GATE_STALE
    monkeypatch.setattr(codex_runner, "WISP_BIN", _fake_wisp(tmp_path, "echo '{\"ready\": true, \"problem\": null}'; exit 1"))
    assert asyncio.run(codex_runner.gate_stale()) == codex_runner.GATE_STALE
    monkeypatch.setattr(codex_runner, "WISP_BIN", _fake_wisp(tmp_path, "echo nope"))
    assert asyncio.run(codex_runner.gate_stale()) == codex_runner.GATE_STALE
    monkeypatch.setattr(codex_runner, "WISP_BIN", str(tmp_path / "missing"))
    assert asyncio.run(codex_runner.gate_stale()) == codex_runner.GATE_STALE
    monkeypatch.setattr(codex_runner, "WISP_BIN", _fake_wisp(tmp_path, "sleep 30"))
    assert asyncio.run(codex_runner.gate_stale(timeout=0.3)) == codex_runner.GATE_STALE


def test_codex_is_ready_when_the_send_gate_check_passes(tmp_path, monkeypatch):
    monkeypatch.setattr(codex_runner, "WISP_BIN", _fake_wisp(tmp_path, "echo '{\"ready\": true, \"problem\": null}'"))
    assert asyncio.run(codex_runner.gate_stale()) is None


def test_status_makes_a_stale_gate_a_reason_to_run_on_the_default_engine(tmp_path, monkeypatch):
    fake = tmp_path / "codex"
    fake.write_text("#!/bin/sh\nexit 0\n")
    fake.chmod(0o755)
    monkeypatch.setattr(codex_runner, "CODEX_BIN", str(fake))
    monkeypatch.setattr(codex_runner, "safe_dir", lambda raw: tmp_path)
    monkeypatch.setattr(codex_runner, "WISP_BIN", _fake_wisp(tmp_path, "echo '{\"ready\": false}'; exit 1"))
    status = asyncio.run(codex_runner.CODEX.status())
    assert status.installed and status.logged_in and not status.ready and "wisp harness sync" in status.problem
    from wisp_bot import engine
    assert "wisp harness sync" in engine.fallback_note("codex", status)
    monkeypatch.setattr(codex_runner, "WISP_BIN", _fake_wisp(tmp_path, "echo '{\"ready\": true}'"))
    assert asyncio.run(codex_runner.CODEX.status()).ready


def test_cancel_text_names_the_engine_of_the_request():
    async def go(engine):
        bot = FakeBot()
        edits = []

        async def edit(text, **kw):
            edits.append(text)
        bot.edit_message_text = edit
        ap = aprovacoes.Aprovacoes(bot, 1)
        req = {"tool_name": "mcp__wisp-email__email_send", "input": REQUEST["input"], **({"engine": engine} if engine else {})}
        task = asyncio.ensure_future(ap.pedir(-1001, 7, req))
        for _ in range(100):
            if bot.enviadas:
                break
            await asyncio.sleep(0)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        return edits[0]
    assert "o Codex desistiu" in asyncio.run(go("codex")) and "Claude" not in asyncio.run(go("codex"))
    assert "o Claude desistiu" in asyncio.run(go(None))


def _short_tmp(monkeypatch):
    import shutil
    import tempfile
    from pathlib import Path as P
    folder = P(tempfile.mkdtemp(prefix="t-", dir="/tmp"))
    monkeypatch.setattr(tempfile, "tempdir", str(folder))
    return folder, lambda: shutil.rmtree(folder, ignore_errors=True)


def test_bot_folders_are_named_with_the_pid_and_dead_ones_are_swept(monkeypatch):
    import re
    tmp_path, cleanup = _short_tmp(monkeypatch)

    def make(name, files=("b",)):
        folder = tmp_path / name
        folder.mkdir()
        for f in files:
            (folder / f).write_text("")
        return folder
    dead = make("wisp-999999-abcdef01")
    live = make(f"wisp-{os.getpid()}-abcdef02")
    foreign = make("wisp-999998-abcdef03", files=("notes.txt",))
    other = make("wisp-notes")
    odd = make("wisp-999997-short")
    broker.varrer_mortos()
    assert not dead.exists()
    assert all(p.exists() for p in (live, foreign, other, odd))

    async def go():
        b = await broker.Broker(Decider()).start()
        name = os.path.basename(os.path.dirname(b.path))
        assert re.fullmatch(rf"wisp-{os.getpid()}-[a-z0-9_]{{8}}", name)
        await b.close()
    asyncio.run(go())
    cleanup()


def test_starting_a_broker_sweeps_the_folder_a_crashed_bot_left(monkeypatch):
    tmp_path, cleanup = _short_tmp(monkeypatch)
    left = tmp_path / "wisp-999996-abcdef09"
    left.mkdir()
    (left / "b").write_text("")

    async def go():
        b = await broker.Broker(Decider()).start()
        assert not left.exists()
        await b.close()
    asyncio.run(go())
    cleanup()


TICKET = CONTRACT["ticket"]


def _mail(**changes):
    return {**TICKET["input"], **changes}


def _ask(mail):
    return line({"op": "request", "tool": "email_send", "input": mail})


def test_the_hash_matches_the_contract_vector_and_treats_a_missing_cc_as_empty():
    assert broker.huella(TICKET["input"]) == TICKET["sha256"]
    assert broker.huella(TICKET["same_without_cc"]) == TICKET["sha256"]
    assert broker.huella(_mail(to="ana@exemplo.com")) is None and broker.huella(_mail(subject=None)) is None


def test_a_claude_ticket_is_consumed_once_and_a_second_send_is_refused():
    async def body(b):
        assert b.autorizar(TICKET["input"])
        return [await talk(b.path, _ask(TICKET["input"])), await talk(b.path, _ask(TICKET["input"]))]
    first, second = with_broker(None, body)
    assert first == CONTRACT["allow"] and second == {"decision": "deny", "message": broker.SEM_BILHETE}


def test_no_ticket_means_no_send_even_for_a_perfectly_formed_request():
    answer = with_broker(None, lambda b: talk(b.path, _ask(TICKET["input"])))
    assert answer == {"decision": "deny", "message": broker.SEM_BILHETE}


def test_a_ticket_for_different_content_is_refused_and_stays_valid_for_the_right_one():
    changes = [{"to": ["x@exemplo.com"]}, {"cc": ["x@exemplo.com"]}, {"subject": "Outro"}, {"body": "outro corpo"},
               {"to": TICKET["input"]["to"][::-1]}, {"to": TICKET["input"]["to"] + ["x@exemplo.com"]}]

    async def body(b):
        b.autorizar(TICKET["input"])
        wrong = [await talk(b.path, _ask(_mail(**c))) for c in changes]
        return wrong, await talk(b.path, _ask(TICKET["input"]))
    wrong, right = with_broker(None, body)
    assert all(a == {"decision": "deny", "message": broker.SEM_BILHETE} for a in wrong) and right == CONTRACT["allow"]


def test_an_expired_ticket_is_refused():
    async def body(b):
        b.autorizar(TICKET["input"])
        await asyncio.sleep(0.2)
        return await talk(b.path, _ask(TICKET["input"]))
    answer = asyncio.run(_with(broker.Broker(bilhete_s=0.1), body))
    assert answer == {"decision": "deny", "message": broker.SEM_BILHETE}


async def _with(b, body):
    await b.start()
    try:
        return await body(b)
    finally:
        await b.close()


def test_a_ticket_is_never_minted_for_a_malformed_input():
    async def body(b):
        return [b.autorizar(x) for x in (None, "x", {}, {"to": "a@b.c", "subject": "s", "body": "b"}, {"to": ["a@b.c"], "subject": 1, "body": "b"})]
    assert with_broker(None, body) == [False] * 5


def test_the_socket_has_no_verb_that_mints_a_ticket():
    bad = [line({"op": op, "tool": "email_send", "input": TICKET["input"]}) for op in ("authorize", "mint", "ticket", "allow", "approve")]

    async def body(b):
        answers = [await talk(b.path, raw) for raw in bad]
        return answers, await talk(b.path, _ask(TICKET["input"]))
    answers, after = with_broker(None, body)
    assert all(a == {"decision": "deny", "message": broker.MALFORMADO} for a in answers)
    assert after == {"decision": "deny", "message": broker.SEM_BILHETE}


def test_a_peer_with_another_uid_is_dropped_without_being_read_or_asked():
    decider = Decider(None)

    async def body(b):
        return await talk(b.path, _ask(TICKET["input"]))
    assert asyncio.run(_with(broker.Broker(decider, uid=os.getuid() + 1), body)) is None and decider.seen == []

    async def same(b):
        return await talk(b.path, _ask(TICKET["input"]))
    assert asyncio.run(_with(broker.Broker(decider), same)) == CONTRACT["allow"] and len(decider.seen) == 1


def test_only_one_card_is_open_at_a_time_and_the_extra_request_is_refused():
    decider = Decider(wait=True)

    async def body(b):
        first = asyncio.ensure_future(talk(b.path, _ask(TICKET["input"])))
        for _ in range(100):
            if decider.seen:
                break
            await asyncio.sleep(0.01)
        extras = [await talk(b.path, _ask(_mail(subject=f"outro {i}"))) for i in range(3)]
        first.cancel()
        return extras
    extras = with_broker(decider, body)
    assert all(a == {"decision": "deny", "message": broker.OCUPADO} for a in extras) and len(decider.seen) == 1


def test_a_new_card_can_open_once_the_previous_one_is_answered():
    decider = Decider(None)

    async def body(b):
        return [await talk(b.path, _ask(_mail(subject=f"s{i}"))) for i in range(3)]
    assert with_broker(decider, body) == [CONTRACT["allow"]] * 3 and len(decider.seen) == 3


FAKE_CLAUDE_MAIL = """#!{python}
import json, os, socket, sys
json.loads(sys.stdin.readline())
print(json.dumps({{"type": "control_request", "request_id": "r1", "request": {request}}}), flush=True)
json.loads(sys.stdin.readline())
path = os.environ.get("WISP_APPROVAL_SOCKET")
out = {{"socket": bool(path)}}
for attempt in ("same", "again"):
    if not path:
        break
    s = socket.socket(socket.AF_UNIX); s.connect(path)
    s.sendall(json.dumps({{"op": "request", "tool": "email_send", "input": {sent}}}).encode() + b"\\n")
    out[attempt] = json.loads(s.makefile().readline()); s.close()
print(json.dumps({{"type": "result", "is_error": False, "session_id": "s", "result": json.dumps(out)}}), flush=True)
sys.stdin.read()
"""


def _claude_turn(tmp_path, monkeypatch, on_permission, asked=None, sent=None, stale=None):
    from wisp_bot import claude_runner
    request = {"subtype": "can_use_tool", "tool_name": "mcp__wisp-email__email_send", "input": asked or TICKET["input"]}
    fake = tmp_path / "claude"
    fake.write_text(FAKE_CLAUDE_MAIL.format(python=__import__("sys").executable, request=json.dumps(request),
                                            sent=json.dumps(sent or TICKET["input"])))
    fake.chmod(0o755)
    monkeypatch.setattr(claude_runner, "CLAUDE_BIN", str(fake))
    monkeypatch.setattr(claude_runner, "guard_settings_path", lambda: tmp_path / "g.json")
    monkeypatch.setattr(claude_runner, "WISP_BIN", str(fake))
    if stale:
        monkeypatch.setenv("WISP_APPROVAL_SOCKET", stale)
    res = asyncio.run(claude_runner.run("oi", session_id="11111111-1111-1111-1111-111111111111", cwd=str(tmp_path),
                                        started=False, timeout=20, on_permission=on_permission))
    assert res.ok, res.text
    return json.loads(res.text)


def test_a_claude_turn_sends_only_after_the_owner_allowed_that_exact_mail_and_only_once(tmp_path, monkeypatch):
    async def allow(req):
        return None
    out = _claude_turn(tmp_path, monkeypatch, allow)
    assert out["socket"] is True and out["same"] == CONTRACT["allow"]
    assert out["again"] == {"decision": "deny", "message": broker.SEM_BILHETE}


def test_a_claude_turn_the_owner_denied_or_with_other_content_gets_no_ticket(tmp_path, monkeypatch):
    async def deny(req):
        return "não"

    async def allow(req):
        return None
    out = _claude_turn(tmp_path, monkeypatch, deny)
    assert out["same"] == {"decision": "deny", "message": broker.SEM_BILHETE}
    out = _claude_turn(tmp_path, monkeypatch, allow, sent=_mail(body="trocado depois do clique"))
    assert out["same"] == {"decision": "deny", "message": broker.SEM_BILHETE}


def test_a_claude_turn_without_a_host_handler_has_no_socket_and_a_stale_path_is_dropped(tmp_path, monkeypatch):
    out = _claude_turn(tmp_path, monkeypatch, None, stale="/tmp/stale")
    assert out == {"socket": False}
