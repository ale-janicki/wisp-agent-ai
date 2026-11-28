import json
import os
import stat
import sys
from pathlib import Path

import httpx
import pytest
from starlette.testclient import TestClient

from test_serve_app import (AUTH, FIXTURES, TOKEN, LiveServer, Sse, argv_of, data, fake_claude, fake_log, guards, option,
                            send)
from wisp.serve.app import create_app

posix_only = pytest.mark.skipif(sys.platform == "win32", reason="the fake codex and wisp are shebang scripts")


def profile(tmp_path, **agent):
    folder = tmp_path / "config" / "wisp"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "profile.json").write_text(json.dumps({"agent": agent}), encoding="utf-8")


@pytest.fixture
def engines(tmp_path, monkeypatch, fake_home, guards):
    data = fake_home / "wisp-data"
    data.mkdir()
    monkeypatch.setenv("WISP_DATA_DIR", str(data))
    for name, source in (("codex", "fake_codex.py"), ("wisp", "fake_wisp.py")):
        folder = tmp_path / f"{name}-bin"
        folder.mkdir()
        script = folder / name
        script.write_text((FIXTURES / source).read_text(encoding="utf-8").replace(
            "#!/usr/bin/env python3", f"#!{sys.executable}", 1), encoding="utf-8")
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
    wisp = tmp_path / "wisp-bin" / "wisp"
    monkeypatch.setattr("wisp.serve.guards.wisp_binary", lambda *a, **k: str(wisp))
    monkeypatch.setenv("PATH", f"{tmp_path / 'codex-bin'}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_CODEX_LOG", str(tmp_path / "codex.log"))
    monkeypatch.setenv("FAKE_WISP_LOG", str(tmp_path / "wisp.log"))
    monkeypatch.setenv("FAKE_CLAUDE_NO_PERMISSION", "1")

    def choose(engine):
        (data / "modelos.toml").write_text(f'ativo = "{engine}"\n', encoding="utf-8")

    choose.data = data
    choose.codex_log = tmp_path / "codex.log"
    choose.wisp_log = tmp_path / "wisp.log"
    return choose


def run_turn(live, sse, cid, text, **attachments):
    send(live, cid, text, **attachments)
    return sse.until("status", conversation_id=cid, state="idle", timeout=20)


def names(sse):
    return [(e["type"], e.get("state") or e.get("text") or e.get("message")) for e in sse.drain(0.3)
            if e["type"] in ("system", "error")]


def test_attachment_routes_need_the_token(data):
    client = TestClient(create_app(TOKEN))
    assert client.post("/attachments", json={"paths": []}).status_code == 401
    assert client.put("/attachments?name=a.png", content=b"x").status_code == 401
    assert client.get("/attachments/file?path=/x").status_code == 401
    assert client.delete("/attachments?path=/x").status_code == 401
    assert client.get("/engines").status_code == 401


def test_staging_copies_files_into_the_anexos_folder_and_the_message_carries_the_staged_path(data, fake_claude, tmp_path):
    photo = tmp_path / "foto.png"
    photo.write_bytes(b"12345")
    client = TestClient(create_app(TOKEN), headers=AUTH)
    staged = client.post("/attachments", json={"paths": [str(photo), str(tmp_path)]}).json()
    assert [f["name"].endswith("-foto.png") for f in staged["files"]] == [True]
    assert staged["refused"] == [tmp_path.name]
    assert staged["notice"] == f"Não anexei {tmp_path.name}: só dá para anexar arquivos, não pastas nem pacotes."
    copy = Path(staged["files"][0]["path"])
    assert copy.read_bytes() == b"12345" and copy.parent.parent == (data / "anexos").resolve()
    assert staged["files"][0]["image"] is True and staged["files"][0]["bytes"] == 5
    assert client.post("/attachments", json={"paths": []}).status_code == 400
    assert client.post("/attachments", json={"paths": ["x"] * 11}).status_code == 400
    assert client.post("/attachments", json={"paths": [1]}).status_code == 400


def test_pasted_bytes_are_saved_like_a_staged_file_and_can_be_discarded(data, tmp_path):
    client = TestClient(create_app(TOKEN), headers=AUTH)
    saved = client.put("/attachments", params={"name": "colar.png"}, content=b"png!").json()["files"][0]
    path = Path(saved["path"])
    assert path.read_bytes() == b"png!" and path.name.endswith("-colar.png") and saved["bytes"] == 4
    assert client.put("/attachments", params={"name": " "}, content=b"x").status_code == 400
    assert client.put("/attachments", params={"name": "a.png"}, content=b"").status_code == 400
    outside = tmp_path / "fora.txt"
    outside.write_text("keep")
    assert client.delete("/attachments", params={"path": str(outside)}).status_code == 404 and outside.exists()
    assert client.delete("/attachments", params={"path": str(path)}).status_code == 200 and not path.exists()


def test_only_staged_images_are_served_back(data, tmp_path):
    client = TestClient(create_app(TOKEN), headers=AUTH)
    image = client.put("/attachments", params={"name": "a.png"}, content=b"\x89PNG").json()["files"][0]["path"]
    text = client.put("/attachments", params={"name": "a.txt"}, content=b"segredo").json()["files"][0]["path"]
    shown = client.get("/attachments/file", params={"path": image})
    assert shown.status_code == 200 and shown.content == b"\x89PNG" and shown.headers["content-type"] == "image/png"
    assert shown.headers["x-content-type-options"] == "nosniff"
    assert client.get("/attachments/file", params={"path": text}).status_code == 404
    secret = tmp_path / "chave.png"
    secret.write_bytes(b"x")
    assert client.get("/attachments/file", params={"path": str(secret)}).status_code == 404
    assert client.get("/attachments/file", params={"path": str(Path(image).parent / ".." / ".." / ".." / "chave.png")}
                      ).status_code == 404
    assert client.get("/attachments/file", params={"path": "relativo.png"}).status_code == 404
    assert client.get("/attachments/file").status_code == 404


def test_list_has_the_preview_and_closed_flag_and_rename_delete_reopen_work(data):
    client = TestClient(create_app(TOKEN), headers=AUTH)
    cid = client.post("/conversations", json={"title": "Primeira"}).json()["id"]
    other = client.post("/conversations", json={"title": "Outra"}).json()["id"]
    path = data / "conversations.json"
    records = json.loads(path.read_text(encoding="utf-8"))
    for record in records:
        if record["id"].lower() == cid:
            record.update(lastPreview="oi tudo bem", lastFrom="user", closedAt="2026-01-01T00:00:00.000Z",
                          closedFrom="telegram")
    path.write_text(json.dumps(records), encoding="utf-8")
    items = {i["id"]: i for i in client.get("/conversations").json()["items"]}
    assert (items[cid]["preview"], items[cid]["closed"]) == ("Você: oi tudo bem", True)
    assert (items[other]["preview"], items[other]["closed"]) == (None, False)
    assert client.get(f"/conversations/{cid}").json()["closed"] is True

    assert client.post(f"/conversations/{cid}/reopen").status_code == 200
    assert client.get(f"/conversations/{cid}").json()["closed"] is False
    stored = next(r for r in json.loads(path.read_text(encoding="utf-8")) if r["id"].lower() == cid)
    assert "closedAt" not in stored and "closedFrom" not in stored

    renamed = client.patch(f"/conversations/{cid}", json={"title": "  Nome   novo \n"})
    assert renamed.json() == {"id": cid, "title": "Nome novo"}
    stored = next(r for r in json.loads(path.read_text(encoding="utf-8")) if r["id"].lower() == cid)
    assert stored["title"] == "Nome novo" and stored["titleGenerated"] is True
    assert client.patch(f"/conversations/{cid}", json={"title": "  "}).status_code == 400
    assert client.patch("/conversations/nope", json={"title": "x"}).status_code == 404

    assert client.delete(f"/conversations/{cid}").status_code == 200
    assert [i["id"] for i in client.get("/conversations").json()["items"]] == [other]
    assert client.delete(f"/conversations/{cid}").status_code == 404
    assert client.post(f"/conversations/{cid}/reopen").status_code == 404


def test_rename_publishes_a_title_event(data):
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        live.http.patch(f"/conversations/{cid}", json={"title": "Pronto"})
        assert sse.until("title", conversation_id=cid)["title"] == "Pronto"


def test_permission_event_carries_the_card_fields_and_always_persists_the_rule(data, fake_claude, monkeypatch):
    monkeypatch.delenv("FAKE_CLAUDE_NO_PERMISSION", raising=False)
    monkeypatch.setenv("FAKE_CLAUDE_SUGGEST", "1")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        ask = sse.until("permission_request", conversation_id=cid)
        assert (ask["summary"], ask["requires_expansion"], ask["can_persist"], ask["asker"], ask["engine"]) == (
            "rodar touch probe", False, True, "Claude", "claude")
        assert ask["persist_rules"] == ["Bash(touch probe *)"] and ask["detail"] == "touch probe"
        assert live.http.post("/permissions/req-1", json={"allow": True, "always": True}).status_code == 200
        sse.until("status", conversation_id=cid, state="idle")
        answer = next(e["control_response"] for e in fake_log(fake_claude) if "control_response" in e)
        response = answer["response"]["response"]
        assert response["behavior"] == "allow"
        assert response["updatedPermissions"] == [{"type": "addRules", "behavior": "allow",
                                                   "destination": "localSettings",
                                                   "rules": [{"toolName": "Bash", "ruleContent": "touch probe *"}]}]


def test_always_is_refused_when_the_cli_offered_nothing_to_persist(data, fake_claude, monkeypatch):
    monkeypatch.delenv("FAKE_CLAUDE_NO_PERMISSION", raising=False)
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        sse.until("permission_request", conversation_id=cid)
        refused = live.http.post("/permissions/req-1", json={"allow": True, "always": True})
        assert refused.status_code == 400
        assert live.http.post("/permissions/req-1", json={"allow": True}).status_code == 200


def test_usage_windows_are_published_and_remembered(data, fake_claude, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE_NO_PERMISSION", "1")
    monkeypatch.setenv("FAKE_CLAUDE_USAGE", "1")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        assert live.http.get("/usage").json() == {"five_hour": None, "seven_day": None}
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "oi")
        seen = next(e for e in sse.seen if e["type"] == "usage")
        assert seen["five_hour"] == {"utilization": 0.42, "resets_at": 1800000000}
        assert seen["seven_day"] == {"utilization": 0.1, "resets_at": None}
        assert live.http.get("/usage").json()["five_hour"]["utilization"] == 0.42


def test_the_status_footer_never_reaches_the_screen_or_the_history(data, fake_claude, monkeypatch, tmp_path):
    monkeypatch.setenv("FAKE_CLAUDE_NO_PERMISSION", "1")
    monkeypatch.setenv("FAKE_CLAUDE_FOOTER", "\n\nSTATUS · wisp · feito\nTeu: nada")
    profile(tmp_path, statusPrefix="STATUS ·")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "oi")
        message = next(e for e in sse.seen if e["type"] == "assistant_message")
        assert message["message"]["blocks"] == [{"type": "text", "text": "ok: oi"}]
        result = next(e for e in sse.seen if e["type"] == "result")
        assert (result["text"], result["status"]) == ("ok: oi", "wisp · feito")
        assistant = [m for m in live.http.get(f"/conversations/{cid}").json()["messages"] if m["role"] == "assistant"]
        assert assistant[0]["blocks"] == [{"type": "text", "text": "ok: oi"}]
        transcript = (data / "conversas" / f"{cid}.jsonl").read_text(encoding="utf-8")
        assert "STATUS" not in transcript


def test_claudes_own_history_is_formatted_too(data, fake_claude, monkeypatch, tmp_path):
    from wisp.serve.store import claude_history
    session = tmp_path / "s.jsonl"
    session.write_text(json.dumps({"type": "assistant", "message": {"content": [
        {"type": "text", "text": "feito.\nSTATUS · x"}, {"type": "text", "text": "STATUS · so"}]}}) + "\n",
        encoding="utf-8")
    assert claude_history(session, "STATUS ·") == [{"role": "assistant", "blocks": [{"type": "text", "text": "feito."}]}]
    assert claude_history(session)[0]["blocks"][0]["text"] == "feito.\nSTATUS · x"


def test_the_first_reply_asks_for_a_title_once_and_it_replaces_the_cut_text(data, fake_claude, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE_NO_PERMISSION", "1")
    asked = []
    monkeypatch.setattr("wisp.serve.engines.title.generate",
                        lambda executable, user, reply, **k: asked.append((user, reply)) or "Cumprimento simples")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi tudo bem com você hoje")
        sse.until("status", conversation_id=cid, state="idle")
        event = sse.until("title", conversation_id=cid)
        assert event["title"] == "Cumprimento simples"
        run_turn(live, sse, cid, "e agora")
        assert live.http.get(f"/conversations/{cid}").json()["title"] == "Cumprimento simples"
        record = json.loads((data / "conversations.json").read_text(encoding="utf-8"))[0]
        assert record["titleGenerated"] is True
    assert asked == [("oi tudo bem com você hoje", "ok: oi tudo bem com você hoje")]


def test_a_failed_title_keeps_the_cut_and_a_reopened_conversation_never_asks(data, fake_claude, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE_NO_PERMISSION", "1")
    calls = []
    monkeypatch.setattr("wisp.serve.engines.title.generate", lambda *a, **k: calls.append(a) or None)
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "quero saber como funciona o cache de build do projeto")
        time = __import__("time")
        time.sleep(0.3)
        assert live.http.get(f"/conversations/{cid}").json()["title"] == "quero saber como funciona o"
        assert len(calls) == 1
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.get("/conversations").json()["items"][0]["id"]
        run_turn(live, sse, cid, "outra")
        time.sleep(0.3)
        assert len(calls) == 1, "a conversation that already has messages never asks again"


def test_title_prompt_goes_to_claude_haiku_without_tools_or_session(data, tmp_path, monkeypatch):
    from wisp.serve.engines import title
    log = tmp_path / "args.json"
    script = tmp_path / "claude-title"
    script.write_text(f"#!{sys.executable}\nimport json,sys,os\n"
                      f"open({str(log)!r},'w').write(json.dumps({{'argv': sys.argv[1:], 'stdin': sys.stdin.read(), "
                      "'mem': os.environ.get('CLAUDE_CODE_DISABLE_AUTO_MEMORY')}))\nprint('\"Título: Plano de viagem.\"')\n",
                      encoding="utf-8")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    if sys.platform == "win32":
        pytest.skip("shebang script")
    assert title.generate(str(script), "quero viajar", "claro, vamos planejar", env=dict(os.environ)) == "Plano de viagem"
    seen = json.loads(log.read_text(encoding="utf-8"))
    assert seen["argv"] == ["-p", "--model", "haiku", "--no-session-persistence", "--output-format", "text", "--tools", "",
                            "--disable-slash-commands", "--strict-mcp-config", "--setting-sources", ""]
    assert "Mensagem do usuário:\nquero viajar" in seen["stdin"] and seen["mem"] == "1"


@posix_only
def test_title_generation_gives_up_on_a_hung_claude_and_kills_the_whole_group(data, tmp_path):
    from wisp.serve.engines import title
    pid_file = tmp_path / "pid"
    script = tmp_path / "claude-hang"
    script.write_text(f"#!{sys.executable}\nimport os,subprocess,sys,time\n"
                      f"child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
                      f"open({str(pid_file)!r},'w').write(str(child.pid))\ntime.sleep(60)\n", encoding="utf-8")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    assert title.generate(str(script), "u", "r", env=dict(os.environ), timeout=1.0) is None
    child = int(pid_file.read_text())
    import time
    time.sleep(0.3)
    with pytest.raises(ProcessLookupError):
        os.kill(child, 0)


@posix_only
def test_codex_runs_exec_json_with_the_guards_and_links_its_thread(engines, fake_claude, monkeypatch):
    data = engines.data
    engines("codex")
    (data / "settings.json").write_text(json.dumps({"permissionMode": "auto"}), encoding="utf-8")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "lista os arquivos")
        tool = sse.until("tool_use", conversation_id=cid)
        assert (tool["id"], tool["name"], tool["input"]) == ("item_0", "Bash", {"command": "ls"})
        done = sse.until("tool_result", conversation_id=cid)
        assert (done["tool_use_id"], done["content"], done["is_error"]) == ("item_0", "a.txt\n", False)
        reply = sse.until("assistant_message", conversation_id=cid)
        assert reply["message"]["blocks"] == [{"type": "text", "text": "codex: lista os arquivos"}]
        assert sse.until("result", conversation_id=cid)["text"] == "codex: lista os arquivos"
        sse.until("status", conversation_id=cid, state="idle")
        notes = [e["text"] for e in sse.seen if e["type"] == "system"]
        assert any("canal de aprovação do e-mail" in n for n in notes) == (sys.platform != "darwin")

    entry = fake_log(engines.codex_log)[0]
    argv = entry["argv"]
    assert argv[:3] == ["exec", "--json", "--skip-git-repo-check"] and argv[-1] == "-"
    assert option(argv, "--sandbox") == "workspace-write"
    assert option(argv, "-C") == str(data.resolve()) or option(argv, "-C") == str(data)
    overrides = [argv[i + 1] for i, a in enumerate(argv) if a == "-c"]
    assert overrides[0].startswith("developer_instructions=") and "The user is reading the Wisp app" in overrides[0]
    assert "You are running under Codex" in overrides[0] and "SOUL-TEXT" in overrides[0]
    assert any(o.startswith("mcp_servers.wisp-email.command=") for o in overrides)
    assert any(o.startswith("mcp_servers.wisp-brain.command=") for o in overrides)
    assert ("mcp_servers.wisp-mac.command=" in "".join(overrides)) == (sys.platform == "darwin")
    assert "mcp_servers.wisp-email.default_tools_approval_mode=\"approve\"" in overrides
    assert entry["prompt"] == "lista os arquivos" and entry["env"]["WISP_BIN"].endswith("wisp")
    assert entry["env"]["WISP_APPROVAL_SOCKET"] is None
    lines = [json.loads(line) for line in (data / "conversas" / f"{cid}.jsonl").read_text(encoding="utf-8").splitlines()]
    assert {"kind": "session", "engine": "codex", "session": "codex-thread-1"}.items() <= next(
        l for l in lines if l["kind"] == "session" and l.get("engine") == "codex").items()
    assistant = next(l for l in lines if l["kind"] == "assistant")
    assert assistant["engine"] == "codex" and assistant["text"] == "codex: lista os arquivos"
    assert argv_of(fake_claude) == [], "claude never started"
    checks = [e["codex_check"] for e in fake_log(engines.wisp_log) if "codex_check" in e]
    assert [] in checks and any(c[:1] == ["--workspace"] for c in checks)


@posix_only
def test_codex_without_a_permission_choice_is_read_only_and_resumes_its_thread(engines, fake_claude):
    data = engines.data
    engines("codex")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "um")
        run_turn(live, sse, cid, "dois")
    first, second = fake_log(engines.codex_log)
    assert option(first["argv"], "--sandbox") == "read-only" and "resume" not in first["argv"]
    assert second["argv"][-3:] == ["resume", "codex-thread-1", "-"]
    assert second["prompt"] == "dois"


@posix_only
def test_a_lost_codex_thread_is_rebuilt_from_the_wisp_transcript(engines, fake_claude, monkeypatch):
    data = engines.data
    engines("codex")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "um")
        monkeypatch.setenv("FAKE_CODEX_LOST", "1")
        send(live, cid, "dois")
        sse.until("system", conversation_id=cid, text="↻ a sessão do Codex não estava aqui; retomei pela conversa guardada no Wisp.")
        monkeypatch.delenv("FAKE_CODEX_LOST")
        sse.until("result", conversation_id=cid, text="codex: dois", timeout=20)
    last = fake_log(engines.codex_log)[-1]
    assert "resume" not in last["argv"]
    assert last["prompt"].startswith("[Wisp conversation memory") and last["prompt"].endswith("dois")
    assert "User: um" in last["prompt"] and "Assistant: codex: um" in last["prompt"]


@posix_only
@pytest.mark.parametrize("env,note", [
    ({"FAKE_CODEX_LOGGED_OUT": "1"}, "o Codex não está com o login feito neste computador; esta conversa roda no Claude"),
    ({"FAKE_WISP_CODEX_PROBLEM": "a pasta tem um config.toml próprio"},
     "o Codex não roda aqui: a pasta tem um config.toml próprio; esta conversa roda no Claude"),
])
def test_codex_not_ready_falls_back_to_claude_with_the_macs_note_once(engines, fake_claude, monkeypatch, env, note):
    data = engines.data
    engines("codex")
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "um")
        run_turn(live, sse, cid, "dois")
        notes = [e["text"] for e in sse.drain(0.2) if e["type"] == "system"]
    assert notes == [note]
    assert fake_log(engines.codex_log) == [] or all("exec" not in e.get("argv", []) for e in fake_log(engines.codex_log))
    assert len(argv_of(fake_claude)) == 1


@posix_only
def test_codex_missing_is_reported_as_not_installed_and_claude_answers(engines, fake_claude, monkeypatch):
    data = engines.data
    engines("codex")
    monkeypatch.setenv("PATH", os.pathsep.join(p for p in os.environ["PATH"].split(os.pathsep) if "codex-bin" not in p))
    monkeypatch.setattr("wisp.serve.engines.codex.locate_codex", lambda *a, **k: (_ for _ in ()).throw(
        __import__("wisp.serve.engines.codex", fromlist=["CodexNotFound"]).CodexNotFound("Codex não encontrado")))
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "um")
        notes = [e["text"] for e in sse.drain(0.2) if e["type"] == "system"]
    assert notes == ["o Codex não está instalado neste computador; esta conversa roda no Claude"]


@posix_only
def test_switching_from_claude_to_codex_primes_it_with_the_transcript(engines, fake_claude):
    data = engines.data
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "um")
        engines("codex")
        send(live, cid, "dois")
        sse.until("system", conversation_id=cid, text="↻ agora quem responde é o Codex; ele retomou pela conversa guardada no Wisp.")
        sse.until("status", conversation_id=cid, state="idle", timeout=20)
        engines("claude")
        run_turn(live, sse, cid, "tres")
    prompt = fake_log(engines.codex_log)[0]["prompt"]
    assert prompt.startswith("[Wisp conversation memory") and "Assistant: ok: um" in prompt and prompt.endswith("dois")
    claude_argvs = argv_of(fake_claude)
    assert len(claude_argvs) == 2 and "--resume" not in claude_argvs[1], "back on Claude the old session is not resumed"


@posix_only
def test_stop_kills_a_running_codex_turn_and_the_next_message_runs(engines, fake_claude, monkeypatch):
    data = engines.data
    engines("codex")
    monkeypatch.setenv("FAKE_CODEX_HANG", "1")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "trava")
        sse.until("status", conversation_id=cid, state="thinking")
        import time
        deadline = time.time() + 10
        while not fake_log(engines.codex_log) and time.time() < deadline:
            time.sleep(0.05)
        assert live.http.post(f"/conversations/{cid}/stop").status_code == 200
        sse.until("status", conversation_id=cid, state="idle")
        monkeypatch.delenv("FAKE_CODEX_HANG")
        send(live, cid, "agora vai")
        assert sse.until("result", conversation_id=cid, timeout=20)["text"] == "codex: agora vai"
    assert len(fake_log(engines.codex_log)) == 2


@posix_only
def test_codex_refuses_a_turn_without_the_wisp_cli(engines, fake_claude, monkeypatch):
    data = engines.data
    engines("codex")
    monkeypatch.setattr("wisp.serve.guards.wisp_binary", lambda *a, **k: None)
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "um")
        notes = sse.until("error", conversation_id=cid)["message"]
        assert notes.startswith("o Codex não está com") or "CLI do Wisp" in notes or "Codex" in notes


@posix_only
def test_local_runs_wisp_local_chat_and_records_the_reply_as_local(engines, fake_claude):
    data = engines.data
    engines("local")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "oi local")
        assert next(e for e in sse.seen if e["type"] == "result")["text"] == "local: oi local"
    chat = next(e["local_chat"] for e in fake_log(engines.wisp_log) if "local_chat" in e)
    assert chat == ["--message=oi local", "--approvals", "stdio", "--no-record", "--recorded", "--surface", "app",
                    "--mode", "default", "--conversation", cid]
    lines = [json.loads(l) for l in (data / "conversas" / f"{cid}.jsonl").read_text(encoding="utf-8").splitlines()]
    assert [(l["kind"], l.get("engine"), l.get("text")) for l in lines if l["kind"] != "session"] == [
        ("user", None, "oi local"), ("assistant", "local", "local: oi local")]
    assert argv_of(fake_claude) == []


@posix_only
def test_local_routes_its_approval_cards_through_the_same_permission_route(engines, monkeypatch):
    data = engines.data
    engines("local")
    monkeypatch.setenv("FAKE_WISP_LOCAL_ASK", "1")
    (data / "settings.json").write_text(json.dumps({"permissionMode": "auto"}), encoding="utf-8")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "que horas")
        ask = sse.until("permission_request", conversation_id=cid)
        assert (ask["request_id"], ask["tool_name"], ask["summary"]) == ("lreq-1", "Bash", "rodar date")
        assert live.http.post("/permissions/lreq-1", json={"allow": False, "message": "não"}).status_code == 200
        assert sse.until("tool_result", conversation_id=cid)["is_error"] is True
        sse.until("status", conversation_id=cid, state="idle", timeout=20)
        assert live.http.post("/permissions/lreq-1", json={"allow": True}).status_code == 404
    answer = next(e["control_response"] for e in fake_log(engines.wisp_log) if "control_response" in e)
    assert answer["response"]["response"]["behavior"] == "deny"
    chat = next(e["local_chat"] for e in fake_log(engines.wisp_log) if "local_chat" in e)
    assert chat[chat.index("--mode") + 1] == "auto"


@posix_only
def test_local_not_ready_shows_the_macs_unavailable_note_and_claude_answers(engines, fake_claude, monkeypatch):
    data = engines.data
    engines("local")
    missing = ("o MLX local precisa de um Mac com Apple silicon e este não tem; aponte para um servidor compatível com "
               "OpenAI")
    monkeypatch.setenv("FAKE_WISP_LOCAL_MISSING", missing)
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "oi")
        notes = [e["text"] for e in sse.drain(0.2) if e["type"] == "system"]
    assert notes == [f"a IA local não está pronta ({missing}); esta conversa roda no Claude. Ajustes > Modelo resolve."]
    assert len(argv_of(fake_claude)) == 1


@posix_only
def test_a_failing_local_turn_reports_the_clis_own_message(engines, monkeypatch):
    data = engines.data
    engines("local")
    monkeypatch.setenv("FAKE_WISP_LOCAL_FAIL", "1")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        send(live, cid, "oi")
        assert sse.until("error", conversation_id=cid)["message"] == "o servidor local caiu"
        assert sse.until("status", conversation_id=cid, state="error")


@posix_only
def test_local_message_too_large_for_the_windows_command_line_is_refused(engines, monkeypatch):
    data = engines.data
    from wisp.serve.engines import local
    assert local.too_large("x" * 40000, platform="win32") and not local.too_large("x" * 40000, platform="darwin")
    assert not local.too_large("x" * 100, platform="win32")


@posix_only
def test_engine_overview_and_choice(engines, fake_claude, monkeypatch):
    data = engines.data
    monkeypatch.setenv("FAKE_WISP_LOCAL_MISSING", "sem modelo")
    client = TestClient(create_app(TOKEN), headers=AUTH)
    overview = client.get("/engines").json()
    assert overview["active"] == "claude"
    by_id = {e["id"]: e for e in overview["engines"]}
    assert (by_id["claude"]["ready"], by_id["codex"]["ready"], by_id["local"]["ready"]) == (True, True, False)
    assert "sem modelo" in by_id["local"]["note"]
    assert client.put("/engines/active", json={"engine": "codex"}).json() == {"active": "codex"}
    assert 'ativo = "codex"' in (data / "modelos.toml").read_text(encoding="utf-8")
    assert client.get("/engines").json()["active"] == "codex"
    assert client.put("/engines/active", json={"engine": "gpt"}).status_code == 400
    assert client.put("/engines/active", json={}).status_code == 400


def test_a_message_may_be_only_attachments_and_gets_the_macs_placeholder_caption(data, fake_claude, tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_CLAUDE_NO_PERMISSION", "1")
    photo = tmp_path / "foto.png"
    photo.write_bytes(b"12345")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        assert live.http.post(f"/conversations/{cid}/messages", json={"text": "  ", "attachments": []}).status_code == 400
        send(live, cid, "", [str(photo)])
        sse.until("status", conversation_id=cid, state="idle")
        sent = next(e["user"] for e in fake_log(fake_claude) if "user" in e)
        assert sent.endswith("]\n\n(sem texto — veja o que é e me diga)")
        assert live.http.get("/conversations").json()["items"][0]["title"] == "1 foto"
        stored = json.loads((data / "conversations.json").read_text(encoding="utf-8"))[0]
        assert stored["lastFrom"] == "agent"


@posix_only
def test_a_local_conversation_never_asks_the_cloud_for_a_title(engines, fake_claude, monkeypatch):
    engines("local")
    calls = []
    monkeypatch.setattr("wisp.serve.engines.title.generate", lambda *a, **k: calls.append(a) or "Nuvem")
    with LiveServer(create_app(TOKEN)) as live:
        sse = Sse(live)
        cid = live.http.post("/conversations", json={}).json()["id"]
        run_turn(live, sse, cid, "quero saber como funciona o cache de build do projeto")
        __import__("time").sleep(0.4)
        assert live.http.get(f"/conversations/{cid}").json()["title"] == "quero saber como funciona o"
    assert calls == [] and argv_of(fake_claude) == []


def test_oversized_paths_are_reported_and_unregistered_files_cannot_be_deleted(data, tmp_path, monkeypatch):
    monkeypatch.setattr("wisp.serve.protocol.MAX_UPLOAD_BYTES", 4)
    client = TestClient(create_app(TOKEN), headers=AUTH)
    big = tmp_path / "grande.bin"
    big.write_bytes(b"12345")
    reply = client.post("/attachments", json={"paths": [str(big)]}).json()
    assert reply["files"] == [] and "grande.bin" in reply["notice"] and "passa de" in reply["notice"]
    assert client.put("/attachments", params={"name": "a"}, content=b"12345").status_code == 413
    stranger = data / "anexos" / "2026-01-01" / "wisp-deadbeef-x.png"
    stranger.parent.mkdir(parents=True)
    stranger.write_bytes(b"x")
    assert client.delete("/attachments", params={"path": str(stranger)}).status_code == 404 and stranger.exists()
