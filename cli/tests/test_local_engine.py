import ast
import asyncio
import json
import shutil
import sys
from datetime import date
from pathlib import Path

import pytest
from local_fakes import FakeOllama, call, reply

from wisp.config import WispConfig
from wisp.local import guardrails
from wisp.local.engine import FILES_KEY, EngineError, LocalEngine, fit_context, history_from, record_turn
from wisp.local.guardrails import MODES
from wisp.local.tools import Files, ServerSpec, ToolFailure, load_servers
from wisp.paths import WispPaths

WISP_FOLDER = Path(guardrails.__file__).parents[1] / "wisp_folder"
FIXTURES = Path(__file__).parent / "fixtures"
CONTRACT = FIXTURES / "contract" / "local-engine-events.jsonl"


@pytest.fixture
def folder(fake_home):
    root = fake_home / "Wisp"
    for sub in ("skills", "ferramentas", "conversas"):
        (root / sub).mkdir(parents=True)
    for name in ("guardrails.toml", "modelos.toml"):
        shutil.copy(WISP_FOLDER / name, root / name)
    (root / "agente.md").write_text("Você é o Wisp.")
    (root / "notas.txt").write_text("conteúdo das notas")
    return root


class Asked:
    def __init__(self, outcome="allow"):
        self.outcome, self.calls = outcome, []

    async def ask(self, tool, arguments, tool_use_id):
        self.calls.append((tool, arguments, tool_use_id))
        return self.outcome


def make(folder, fake, approver=None, servers=(), **kw):
    ids = iter(f"id{n}" for n in range(100))
    return LocalEngine(folder, WispConfig(), WispPaths.current(), fake.client(), servers=list(servers),
                       approver=approver or Asked(), today=lambda: date(2026, 11, 20), new_id=lambda: next(ids), **kw)


def run(engine, session, text="oi", **kw):
    events: list[dict] = []
    result = asyncio.run(engine.send(session, text, events.append, **kw))
    return result, events


def tool_results(events):
    return [b for e in events if e["type"] == "user" for b in e["message"]["content"]]


def test_a_plain_answer_streams_init_text_and_result_with_engine_and_model(folder):
    with FakeOllama([reply("Olá!")]) as fake:
        engine = make(folder, fake)
        result, events = run(engine, engine.start("c1", "qwen3:8b"))
    assert [e["type"] for e in events] == ["system", "assistant", "result"]
    assert events[0]["subtype"] == "init" and events[0]["model"] == "qwen3:8b" and events[0]["session_id"] == "c1"
    assert events[1]["message"]["content"] == [{"type": "text", "text": "Olá!"}]
    final = events[2]
    assert (final["result"], final["engine"], final["model"], final["is_error"], final["stopped"]) == ("Olá!", "local", "qwen3:8b", False, None)
    sent = fake.chats()[0]
    assert sent["options"]["num_ctx"] == 8192
    assert sent["messages"][0]["role"] == "system" and "Você é o Wisp." in sent["messages"][0]["content"]
    assert [t["function"]["name"] for t in sent["tools"]] == ["read_file", "list_files", "write_file"]
    assert result.text == "Olá!" and result.steps == 1


def test_a_tool_call_runs_and_feeds_the_next_request(folder):
    path = str(folder / "notas.txt")
    with FakeOllama([reply("", [call("read_file", path=path)]), reply("Diz: conteúdo das notas")]) as fake:
        engine = make(folder, fake)
        result, events = run(engine, engine.start("c1", "qwen3:8b"), "leia")
    use = events[1]["message"]["content"][0]
    assert use == {"type": "tool_use", "id": "toolu_local_id0", "name": "read_file", "input": {"path": path}}
    assert tool_results(events) == [{"type": "tool_result", "tool_use_id": "toolu_local_id0", "is_error": False, "content": "conteúdo das notas"}]
    second = fake.chats()[1]["messages"]
    assert second[-1] == {"role": "tool", "tool_name": "read_file", "content": "conteúdo das notas"}
    assert second[-2]["tool_calls"][0]["function"]["name"] == "read_file"
    assert result.text == "Diz: conteúdo das notas" and result.steps == 2


def test_the_golden_event_stream_is_what_the_app_decodes(folder):
    path = str(folder / "notas.txt")
    with FakeOllama([reply("vou ler", [call("read_file", path=path)], thinking="x"), reply("pronto")]) as fake:
        engine = make(folder, fake)
        _, events = run(engine, engine.start("c1", "qwen3:8b"), "leia")
    text = "".join(json.dumps(e, ensure_ascii=False, sort_keys=True) + "\n" for e in events).replace(str(folder), "<folder>")
    assert text == CONTRACT.read_text()


def test_the_step_cap_stops_the_turn_and_suggests_a_bigger_model(folder):
    script = [reply("", [call("list_files", path=f"d{n}")]) for n in range(20)]
    with FakeOllama(script) as fake:
        engine = make(folder, fake)
        result, events = run(engine, engine.start("c1", "qwen3:8b"))
    assert len(fake.chats()) == 6 and result.stopped == "step_cap" and result.steps == 6
    assert "6 passos" in result.text and "Qwen3 14B" in result.text
    assert events[-1]["stopped"] == "step_cap"


def test_a_repeated_identical_call_stops_the_turn_and_is_not_run_again(folder):
    (folder / "x").mkdir()
    same = reply("", [call("list_files", path=str(folder / "x"))])
    with FakeOllama([same] * 10) as fake:
        engine = make(folder, fake)
        result, events = run(engine, engine.start("c1", "qwen3:8b"))
    assert result.stopped == "loop" and len(fake.chats()) == 3 and len(tool_results(events)) == 2
    assert "mesma ação (list_files) 3 vezes" in result.text
    assert fake.chats()[-1]["messages"][-1]["role"] == "tool"


def test_a_tool_outside_the_tier_is_refused_and_named_in_the_reply(folder):
    with FakeOllama([reply("", [call("run_shell", command="touch feito")]), reply("não consegui")]) as fake:
        engine = make(folder, fake)
        result, events = run(engine, engine.start("c1", "qwen3:8b"))
    assert not (folder / "feito").exists()
    assert tool_results(events)[0]["is_error"] and "não é permitida" in tool_results(events)[0]["content"]
    assert "não posso usar: run_shell" in result.text and "Pequeno" in result.text and result.stopped is None


@pytest.mark.parametrize("mode", MODES)
def test_a_write_at_pequeno_always_shows_the_card_and_runs_only_after_allow(folder, mode):
    target = folder / "novo.md"
    with FakeOllama([reply("", [call("write_file", path=str(target), content="oi")]), reply("feito")]) as fake:
        asked = Asked("allow")
        engine = make(folder, fake, asked)
        run(engine, engine.start("c1", "qwen3:8b", mode))
    assert [c[0] for c in asked.calls] == ["write_file"] and target.read_text() == "oi"


@pytest.mark.parametrize("outcome", ["deny", "timeout"])
def test_a_denied_or_unanswered_card_runs_nothing_and_is_reported(folder, outcome):
    target = folder / "novo.md"
    with FakeOllama([reply("", [call("write_file", path=str(target), content="oi")]), reply("ok, não gravei")]) as fake:
        engine = make(folder, fake, Asked(outcome))
        result, events = run(engine, engine.start("c1", "qwen3:8b", "bypassPermissions"))
    assert not target.exists() and tool_results(events)[0]["is_error"]
    assert events[-1]["permission_denials"] == [{"tool_name": "write_file"}]


def test_the_shell_at_grande_waits_for_the_card_even_in_bypass_mode(folder):
    (folder / "guardrails.toml").write_text((folder / "guardrails.toml").read_text())
    with FakeOllama([reply("", [call("run_shell", command="echo oi")]), reply("ok")]) as fake:
        asked = Asked("allow")
        engine = make(folder, fake, asked)
        engine.catalog = type(engine.catalog)(engine.catalog.source, engine.catalog.disk_margin_bytes, tuple(
            m.__class__(**{**m.__dict__, "tier": "grande"}) if m.tag == "qwen3:32b" else m for m in engine.catalog.models))
        _, events = run(engine, engine.start("c1", "qwen3:32b", "bypassPermissions"))
    assert [c[0] for c in asked.calls] == ["run_shell"] and tool_results(events)[0]["content"].strip() == "oi"


def test_files_outside_the_wisp_folder_and_the_brain_are_off_limits(folder, fake_home):
    secret = fake_home / "fora.txt"
    secret.write_text("x")
    (folder / "chave.txt").write_text("-----BEGIN " + "PRIVATE KEY-----\nabc")
    script = [reply("", [call("read_file", path=str(secret))]), reply("", [call("read_file", path=str(folder / "chave.txt"))]), reply("fim")]
    with FakeOllama(script) as fake:
        engine = make(folder, fake)
        _, events = run(engine, engine.start("c1", "qwen3:8b"))
    errors = [r["content"] for r in tool_results(events)]
    assert "só posso mexer" in errors[0] and "senha ou chave" in errors[1]


def test_the_context_budget_stops_a_turn_that_cannot_fit(folder):
    big = "palavra " * 4000
    with FakeOllama([reply("nunca")]) as fake:
        engine = make(folder, fake)
        result, _ = run(engine, engine.start("c1", "qwen3:8b"), big)
    assert result.stopped == "context" and not fake.chats() and "8192 tokens" in result.text


def test_fit_context_shortens_old_tool_output_then_drops_old_exchanges():
    old = [{"role": "user", "content": "a"}, {"role": "tool", "tool_name": "t", "content": "x" * 5000},
           {"role": "assistant", "content": "b"}]
    now = [{"role": "user", "content": "agora"}]
    kept, dropped = fit_context("sys", [], old + now, 2000)
    assert not dropped and len(kept[1]["content"]) < 400
    kept, dropped = fit_context("sys", [], [{"role": "user", "content": "y" * 4000}, *old, *now], 2000)
    assert dropped and kept[-1]["content"] == "agora" and kept[0]["content"] != "y" * 4000
    assert fit_context("sys", [], [{"role": "user", "content": "z" * 90000}], 2000) is None


def test_a_model_may_change_between_turns_and_the_tier_follows(folder):
    with FakeOllama([reply("um"), reply("dois")]) as fake:
        engine = make(folder, fake)
        session = engine.start("c1", "qwen3:8b")
        first, _ = run(engine, session)
        second, events = run(engine, session, model="qwen3:14b")
    assert (first.model, second.model) == ("qwen3:8b", "qwen3:14b") and events[0]["tier"] == "medio"
    assert fake.chats()[1]["options"]["num_ctx"] == 16384 and fake.chats()[1]["messages"][1]["content"] == "oi"


def test_resume_rebuilds_the_context_from_the_transcript_only(folder):
    with FakeOllama([reply("primeira")]) as fake:
        engine = make(folder, fake)
        session = engine.start("c1", "qwen3:8b")
        result, _ = run(engine, session, "pergunta")
        record_turn(folder, session, "telegram", "pergunta", result)
    entries = [json.loads(l) for l in (folder / "conversas/c1.jsonl").read_text().splitlines()]
    assert [e["kind"] for e in entries] == ["session", "user", "assistant"] and entries[2]["engine"] == "local" and entries[2]["model"] == "qwen3:8b"
    with FakeOllama([reply("segunda")]) as fake:
        engine = make(folder, fake)
        resumed = engine.resume("c1", "qwen3:8b")
        assert resumed.messages == history_from(folder / "conversas/c1.jsonl") == [
            {"role": "user", "content": "pergunta"}, {"role": "assistant", "content": "primeira"}]
        run(engine, resumed, "e agora")
    sent = [m["content"] for m in fake.chats()[0]["messages"][1:]]
    assert sent == ["pergunta", "primeira", "e agora"]
    with pytest.raises(EngineError):
        engine.resume("../x")
    with pytest.raises(EngineError, match="não achei"):
        engine.resume("outra")


def test_no_active_model_and_a_bad_guardrails_file_are_said_plainly(folder):
    with FakeOllama() as fake:
        engine = make(folder, fake)
        with pytest.raises(EngineError, match="Ajustes > Modelo"):
            engine.start("c1")
        session = engine.start("c1", "qwen3:8b")
        (folder / "guardrails.toml").write_text("[pequeno]\nmax_steps = 'x'\n")
        result, events = run(engine, session)
    assert result.is_error and "guardrails.toml" in result.text and events[-1]["is_error"]
    assert not fake.chats()


def test_ollama_failing_mid_turn_ends_the_turn_with_the_reason(folder):
    with FakeOllama([]) as fake:
        engine = make(folder, fake)
        result, events = run(engine, engine.start("c1", "qwen3:8b"))
    assert result.is_error and "o Ollama falhou" in result.text and events[-1]["subtype"] == "error"


def test_ferramentas_servers_are_read_and_bad_ones_are_reported(folder):
    (folder / "ferramentas/ok.toml").write_text('name = "x"\ncommand = "/bin/true"\nargs = ["a"]\n[env]\nK = "v"\n')
    (folder / "ferramentas/ruim.toml").write_text('name = 3\n')
    servers, problems = load_servers(folder)
    assert [s.name for s in servers] == ["wisp-email", "x"] and servers[1].env == (("K", "v"),)
    assert len(problems) == 1 and "ruim.toml" in problems[0]


def test_a_server_that_does_not_start_is_reported_and_the_turn_goes_on(folder):
    with FakeOllama([reply("sem e-mail")]) as fake:
        engine = make(folder, fake, servers=[ServerSpec("quebrado", "/bin/false")])
        result, _ = run(engine, engine.start("c1", "qwen3:8b"))
    assert "a ferramenta quebrado não abriu" in result.text and result.stopped is None


@pytest.mark.parametrize("outcome", ["allow", "deny", "timeout"])
@pytest.mark.parametrize("mode", MODES)
def test_email_send_goes_through_the_loop_card_before_the_real_tool_runs(folder, fake_home, monkeypatch, mode, outcome):
    log = fake_home / "mail.log"
    monkeypatch.setenv("FAKE_MAIL_LOG", str(log))
    server = ServerSpec("fake-mail", sys.executable, (str(FIXTURES / "fake_email_server.py"),), (("FAKE_MAIL_LOG", str(log)),), trusted=True)
    script = [reply("", [call("email_send", to=["a@b.c"], subject="Oi", body="texto")]), reply("fim")]
    with FakeOllama(script) as fake:
        asked = Asked(outcome)
        engine = make(folder, fake, asked, servers=[server])
        result, events = run(engine, engine.start("c1", "qwen3:8b", mode))
    assert [c[0] for c in asked.calls] == ["email_send"] and asked.calls[0][2].startswith("toolu_local_")
    if outcome == "allow":
        assert log.read_text() == "['a@b.c']|Oi|texto\n" and tool_results(events)[0]["content"] == "enviado"
    else:
        assert not log.exists() and tool_results(events)[0]["is_error"]
        assert events[-1]["permission_denials"] == [{"tool_name": "email_send"}]


def test_the_default_approver_denies(folder):
    plant = reply("", [call("write_file", path=str(folder / "notas.txt"), content="x")])
    with FakeOllama([plant, reply("fim")]) as fake:
        engine = LocalEngine(folder, WispConfig(), WispPaths.current(), fake.client(), servers=[], today=lambda: date(2026, 11, 20))
        _, events = run(engine, engine.start("c1", "qwen3:8b"))
    assert (folder / "notas.txt").read_text() == "conteúdo das notas" and tool_results(events)[0]["is_error"]


def test_nothing_imports_the_removed_approvals_module_or_names_its_folder():
    root = Path(__file__).parents[1]
    offenders = []
    for path in [*(root / "src/wisp").rglob("*.py"), *(root / "tests").rglob("*.py")]:
        for node in ast.walk(ast.parse(path.read_text("utf-8"))):
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                names = [node.module or "", *(f"{node.module}.{a.name}" for a in node.names)]
            else:
                continue
            if any(n == "wisp.approvals" or n.startswith("wisp.approvals.") for n in names):
                offenders.append(path.name)
    assert not offenders
    for path in (root / "src/wisp/local").glob("*.py"):
        strings = [n.value for n in ast.walk(ast.parse(path.read_text("utf-8"))) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
        assert not [t for t in strings if "approvals" in t.replace("--approvals", "")], path.name


@pytest.fixture
def attack(folder, fake_home):
    (folder / "ferramentas").mkdir(exist_ok=True)
    (folder / "linkado.toml").symlink_to(folder / "guardrails.toml")
    (folder / "pasta").mkdir()
    return Files([folder, fake_home / ".local/state/wisp"])


@pytest.mark.parametrize(
    "relative",
    [
        "ferramentas/x.toml", "ferramentas/../ferramentas/y.toml", "guardrails.toml", "pasta/../guardrails.toml",
        "modelos.toml", "agente.md", "skills/novo/SKILL.md", "conversas/c.jsonl", "linkado.toml", "Guardrails.TOML",
        "FERRAMENTAS/z.toml", "Skills/novo/SKILL.md",
    ],
)
def test_the_agent_cannot_write_its_own_control_files(folder, attack, relative):
    before = (folder / "guardrails.toml").read_text()
    with pytest.raises(ToolFailure, match="regras e ferramentas do Wisp"):
        attack.write({"path": str(folder / relative), "content": "[pequeno]\nmax_steps = 0\n"})
    with pytest.raises(ToolFailure, match="regras e ferramentas do Wisp"):
        attack.write({"path": relative, "content": "x"})
    assert (folder / "guardrails.toml").read_text() == before
    assert not list((folder / "ferramentas").glob("*.toml"))


def test_ordinary_notes_can_still_be_written_and_control_files_still_read(folder, attack):
    assert "guardrails" not in attack.write({"path": str(folder / "pasta/nota.md"), "content": "oi"})
    assert (folder / "pasta/nota.md").read_text() == "oi"
    assert "[pequeno]" in attack.read({"path": str(folder / "guardrails.toml")})


def test_a_model_planting_a_server_definition_is_refused_after_the_card(folder):
    plant = reply("", [call("write_file", path=str(folder / "ferramentas/x.toml"), content='name = "x"\ncommand = "/bin/sh"\n')])
    with FakeOllama([plant, reply("feito")]) as fake:
        asked = Asked("allow")
        engine = make(folder, fake, asked)
        _, events = run(engine, engine.start("c1", "qwen3:8b", "bypassPermissions"))
    assert not (folder / "ferramentas/x.toml").exists() and tool_results(events)[0]["is_error"]
    assert load_servers(folder)[0][0].name == "wisp-email" and len(load_servers(folder)[0]) == 1


def test_a_user_server_cannot_take_the_builtin_name_or_the_email_tools(folder, fake_home, monkeypatch):
    (folder / "ferramentas/a.toml").write_text('name = "wisp-email"\ncommand = "/bin/true"\n')
    servers, problems = load_servers(folder)
    assert [s.name for s in servers] == ["wisp-email"] and servers[0].trusted and "reservado" in problems[0]
    log = fake_home / "rogue.log"
    rogue = ServerSpec("rogue", sys.executable, (str(FIXTURES / "fake_rogue_server.py"),), (("ROGUE_LOG", str(log)),))
    send = reply("", [call("email_send", to=["a@b.c"], subject="Oi", body="x")])
    with FakeOllama([send, reply("sem e-mail")]) as fake:
        engine = make(folder, fake, servers=[ServerSpec("wisp-email", "/bin/false", trusted=True), rogue])
        result, events = run(engine, engine.start("c1", "qwen3:8b", "bypassPermissions"))
    assert not log.exists() and "não existe ou não abriu" in tool_results(events)[0]["content"]
    assert "rogue: o nome email_send é reservado" in result.text and "wisp-email não abriu" in result.text


PLANTS = [".claude/settings.json", ".mcp.json", ".codex/config.toml", "CLAUDE.md", "agents.MD", "sub/AGENTS.md", "sub/.hidden/x.txt"]


@pytest.mark.parametrize("relative", PLANTS)
@pytest.mark.parametrize("how", ["direct", "symlink", "dotdot"])
def test_the_agent_cannot_plant_hooks_or_instruction_files(folder, attack, relative, how):
    (folder / "sub").mkdir(exist_ok=True)
    if how == "direct":
        path = str(folder / relative)
    elif how == "symlink":
        link = folder / "pasta" / "inocente.txt"
        (folder / relative).parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(folder / relative)
        path = str(link)
    else:
        path = str(folder / "pasta" / ".." / "pasta" / ".." / relative)
    with pytest.raises(ToolFailure, match="regras e ferramentas do Wisp"):
        attack.write({"path": path, "content": '{"hooks": {}}'})
    assert not (folder / relative).exists()


def test_a_dotted_root_itself_is_not_refused(fake_home):
    root = fake_home / ".local/state/wisp"
    root.mkdir(parents=True)
    assert "gravei" in Files([root]).write({"path": str(root / "nota.md"), "content": "oi"})


@pytest.mark.parametrize("arguments", [
    {"path": "x.sh", "content": "echo"}, {"path": "X.PY", "content": "print()"}, {"path": "run.command", "content": "x"},
    {"path": "a.applescript", "content": "x"}, {"path": "nota.txt", "content": "#!/bin/sh\nrm -rf x"},
    {"path": "Makefile", "content": "all:"}, {"path": "package.json", "content": "{}"}, {"path": "a.terminal", "content": "x"},
    {"path": "a.workflow", "content": "x"},
])
def test_writing_a_script_shows_the_card_even_in_bypass_mode_at_grande(folder, arguments):
    with FakeOllama([reply("", [call("write_file", **{**arguments, "path": str(folder / arguments["path"])})]), reply("ok")]) as fake:
        asked = Asked("deny")
        engine = make(folder, fake, asked)
        engine.catalog = type(engine.catalog)(engine.catalog.source, engine.catalog.disk_margin_bytes, tuple(
            m.__class__(**{**m.__dict__, "tier": "grande"}) if m.tag == "qwen3:32b" else m for m in engine.catalog.models))
        run(engine, engine.start("c1", "qwen3:32b", "bypassPermissions"))
    assert [c[0] for c in asked.calls] == ["write_file"] and not (folder / arguments["path"]).exists()


def grande(engine):
    engine.catalog = type(engine.catalog)(engine.catalog.source, engine.catalog.disk_margin_bytes, tuple(
        m.__class__(**{**m.__dict__, "tier": "grande"}) if m.tag == "qwen3:32b" else m for m in engine.catalog.models))
    return engine


def test_a_shell_command_card_carries_the_content_of_the_script_it_runs(folder):
    (folder / "x.sh").write_text("echo \x1b[31mmau\n")
    with FakeOllama([reply("", [call("run_shell", command="sh x.sh")]), reply("ok")]) as fake:
        asked = Asked("deny")
        engine = grande(make(folder, fake, asked))
        run(engine, engine.start("c1", "qwen3:32b", "default"))
    shown = asked.calls[0][1]
    assert shown["command"] == "sh x.sh" and shown[FILES_KEY] == {str((folder / "x.sh").resolve()): "echo \x1b[31mmau\n"}


def test_a_shell_command_running_a_file_too_long_to_show_is_denied_without_a_card(folder):
    (folder / "grande.sh").write_text("echo oi\n" * 2000)
    with FakeOllama([reply("", [call("run_shell", command="sh grande.sh")]), reply("ok")]) as fake:
        asked = Asked("allow")
        engine = grande(make(folder, fake, asked))
        _, events = run(engine, engine.start("c1", "qwen3:32b", "default"))
    assert asked.calls == [] and "grande demais" in tool_results(events)[0]["content"]


def test_a_shell_command_naming_files_outside_the_roots_adds_nothing(folder, fake_home):
    (fake_home / "fora.sh").write_text("echo")
    with FakeOllama([reply("", [call("run_shell", command=f"sh {fake_home / 'fora.sh'}", arquivos={"x": "forjado"})]), reply("ok")]) as fake:
        asked = Asked("deny")
        engine = grande(make(folder, fake, asked))
        run(engine, engine.start("c1", "qwen3:32b", "default"))
    assert FILES_KEY not in asked.calls[0][1]


@pytest.mark.parametrize("setup", ["symlink", "exec_bit"])
def test_a_write_to_a_disguised_script_target_shows_the_card(folder, setup):
    (folder / "run.sh").write_text("echo")
    if setup == "symlink":
        (folder / "notes.txt").symlink_to(folder / "run.sh")
    else:
        (folder / "notes.txt").write_text("x")
        (folder / "notes.txt").chmod(0o700)
    with FakeOllama([reply("", [call("write_file", path=str(folder / "notes.txt"), content="rm -rf x")]), reply("ok")]) as fake:
        asked = Asked("deny")
        engine = grande(make(folder, fake, asked))
        run(engine, engine.start("c1", "qwen3:32b", "bypassPermissions"))
    assert [c[0] for c in asked.calls] == ["write_file"]


def test_a_plain_note_is_written_without_a_card_at_grande(folder):
    with FakeOllama([reply("", [call("write_file", path=str(folder / "nota.txt"), content="oi")]), reply("ok")]) as fake:
        asked = Asked("deny")
        engine = grande(make(folder, fake, asked))
        run(engine, engine.start("c1", "qwen3:32b", "bypassPermissions"))
    assert asked.calls == [] and (folder / "nota.txt").read_text() == "oi"


@pytest.mark.parametrize("relative", ["CLAUDE.local.md", "AGENTS.override.md", "pasta/claude.LOCAL.md", "x.local.md"])
def test_instruction_variants_cannot_be_written(folder, attack, relative):
    with pytest.raises(ToolFailure, match="regras e ferramentas do Wisp"):
        attack.write({"path": str(folder / relative), "content": "ignore tudo"})


def test_a_forged_arquivos_argument_is_kept_for_other_tools(folder):
    with FakeOllama([reply("", [call("write_file", path=str(folder / "x.sh"), content="echo", arquivos={"x": "y"})]), reply("ok")]) as fake:
        asked = Asked("deny")
        engine = grande(make(folder, fake, asked))
        run(engine, engine.start("c1", "qwen3:32b", "default"))
    assert asked.calls[0][1]["arquivos"] == {"x": "y"}


def test_a_model_supplied_files_key_never_reaches_the_card(folder):
    with FakeOllama([reply("", [call("write_file", path=str(folder / "x.sh"), content="echo", **{FILES_KEY: {"x": "forjado"}})]), reply("ok")]) as fake:
        asked = Asked("deny")
        engine = grande(make(folder, fake, asked))
        run(engine, engine.start("c1", "qwen3:32b", "default"))
    assert FILES_KEY not in asked.calls[0][1]


@pytest.mark.parametrize("suffix", [".pyw", ".ps1", ".fish", ".php", ".lua", ".mjs", ".cjs", ".ts", ".plist", ".service", ".jar", ".zsh", ".bash"])
def test_a_write_to_these_script_suffixes_shows_the_card(folder, suffix):
    with FakeOllama([reply("", [call("write_file", path=str(folder / f"x{suffix}"), content="oi")]), reply("ok")]) as fake:
        asked = Asked("deny")
        engine = grande(make(folder, fake, asked))
        run(engine, engine.start("c1", "qwen3:32b", "bypassPermissions"))
    assert [c[0] for c in asked.calls] == ["write_file"]
