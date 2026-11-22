import asyncio
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

from wisp.brain_index import BrainIndex, index_path
from wisp.brain_server import (
    ToolFailure,
    brain_links,
    brain_read,
    brain_search,
    build_server,
    open_index,
)
from wisp.config import WispConfig, save_config
from wisp.paths import WispPaths

FIXTURE = Path(__file__).parent / "fixtures" / "brain"


@pytest.fixture
def vault(tmp_path):
    root = tmp_path / "vault"
    shutil.copytree(FIXTURE, root)
    return root


@pytest.fixture
def index(vault, tmp_path):
    return BrainIndex(vault, index_path(tmp_path / "state", vault))


def test_search_returns_path_title_link_snippet_and_score(index):
    hits = brain_search(index, "plano financeiro", 3)
    assert hits[0]["path"] == "financas/plano-financeiro.md" and hits[0]["title"] == "Plano Financeiro"
    assert hits[0]["link"] == "[[plano-financeiro]]" and hits[0]["snippet"] and hits[0]["score"] > 0
    assert len(hits) <= 3


def test_search_sees_a_file_changed_since_the_last_call(index, vault):
    assert brain_search(index, "quasar") == []
    (vault / "novo.md").write_text("# Quasar\n\nobjeto distante\n")
    assert brain_search(index, "quasar")[0]["path"] == "novo.md"


def test_search_limit_is_clamped(index):
    assert len(brain_search(index, "plano financeiro", 0)) == 1
    assert len(brain_search(index, "index", 10_000)) <= 30


def test_read_resolves_wikilink_syntax_and_returns_the_note_with_links_and_backlinks(index):
    note = brain_read(index, "[[Orçamento Mensal|o plano]]")
    assert note["path"] == "financas/plano-financeiro.md" and note["aliases"] == ["Orçamento Mensal", "plano de gastos"]
    assert "Meta de poupar" in note["content"] and note["heading_found"] is None
    assert [(l["name"], l["path"]) for l in note["links"]] == [
        ("sync-do-app", "projetos/sync-do-app.md"), ("Relogio", "relogio-de-ponto.md"),
    ]
    assert [b["path"] for b in note["backlinks"]] == ["index.md", "projetos/sync-do-app.md"]


def test_read_returns_only_the_requested_heading_section(index):
    note = brain_read(index, "plano-financeiro#metas")
    assert note["heading_found"] is True and note["content"].startswith("## Metas") and "Anexos" not in note["content"]
    missing = brain_read(index, "plano-financeiro#inexistente")
    assert missing["heading_found"] is False and "Meta de poupar" in missing["content"]


def test_read_reports_broken_links_with_no_path(index):
    links = brain_read(index, "index")["links"]
    assert {"name": "nota-que-nao-existe", "heading": None, "path": None, "title": None} in links


def test_read_of_a_missing_note_fails_with_suggestions(index):
    with pytest.raises(ToolFailure) as err:
        brain_read(index, "plano inexistente")
    assert "não achei a nota" in str(err.value) and "[[plano-financeiro]]" in str(err.value)


def test_read_refuses_paths_outside_the_brain(index, tmp_path):
    (tmp_path / "secret.md").write_text("# Secret\n")
    for ref in (str(tmp_path / "secret.md"), "../secret.md", "/etc/passwd", "~/.ssh/id_rsa"):
        with pytest.raises(ToolFailure):
            brain_read(index, ref)


def test_links_walks_the_graph_by_depth_and_flags_broken_links(index):
    near = brain_links(index, "plano-financeiro", 1)
    assert near["root"] == "financas/plano-financeiro.md"
    assert {n["path"] for n in near["nodes"] if n["depth"] == 1} == {"projetos/sync-do-app.md", "relogio-de-ponto.md", "index.md"}
    deep = brain_links(index, "plano-financeiro", 2)
    assert "empresa/seguranca.md" in {n["path"] for n in deep["nodes"]}
    assert {"from": "index.md", "name": "nota-que-nao-existe"} in deep["broken"]
    assert brain_links(index, "plano-financeiro", 99)["nodes"] == brain_links(index, "plano-financeiro", 3)["nodes"]


def test_links_of_a_missing_note_fails(index):
    with pytest.raises(ToolFailure):
        brain_links(index, "nada")


def test_open_index_needs_a_configured_existing_brain(fake_home, vault):
    paths = WispPaths.current()
    with pytest.raises(ToolFailure):
        open_index(WispConfig(), paths)
    with pytest.raises(ToolFailure):
        open_index(WispConfig(brain=str(fake_home / "missing")), paths)
    found = open_index(WispConfig(brain=str(vault)), paths)
    assert found.root == vault.resolve() and found.db_path.is_relative_to(paths.state)


def test_the_server_exposes_three_read_only_tools_and_flags_errors(index):
    server = build_server(lambda: index)
    assert {t.name for t in asyncio.run(server.list_tools())} == {"brain_search", "brain_read", "brain_links"}
    result = asyncio.run(server.call_tool("brain_read", {"path_or_title": "nada"}))
    assert result.is_error is True and "não achei" in result.content[0].text
    ok = asyncio.run(server.call_tool("brain_search", {"query": "relógio"}))
    assert ok.is_error is not True and json.loads(ok.content[0].text)[0]["path"] == "relogio-de-ponto.md"


def _rpc(id, method, params=None):
    msg = {"jsonrpc": "2.0", "method": method, **({"id": id} if id is not None else {}), "params": params or {}}
    return (json.dumps(msg) + "\n").encode()


def _stdio(env, requests, wanted, timeout=60):
    proc = subprocess.Popen(
        [sys.executable, "-m", "wisp", "mcp", "brain"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=env, start_new_session=True,
    )
    replies = {}
    deadline = time.monotonic() + timeout
    try:
        proc.stdin.write(requests)
        proc.stdin.flush()
        while wanted - replies.keys() and time.monotonic() < deadline:
            if not select.select([proc.stdout], [], [], 1.0)[0]:
                continue
            line = proc.stdout.readline()
            if not line:
                break
            message = json.loads(line)
            if "id" in message:
                replies[message["id"]] = message
    finally:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
    return replies


def test_without_a_brain_the_server_starts_and_each_tool_says_so(fake_home):
    init = {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}
    stdin = (
        _rpc(1, "initialize", init) + _rpc(None, "notifications/initialized")
        + _rpc(2, "tools/call", {"name": "brain_search", "arguments": {"query": "plano"}})
    )
    replies = _stdio(os.environ.copy(), stdin, {1, 2})
    assert replies[2]["result"]["isError"] is True and "o brain não está configurado" in replies[2]["result"]["content"][0]["text"]


def test_the_local_engine_host_gets_the_brain_tools_from_the_trusted_builtin_server(fake_home, vault, tmp_path):
    from wisp.local.tools import brain_server, open_host

    save_config(WispConfig(brain=str(vault)))

    async def go():
        async with open_host([brain_server()], [], tmp_path) as host:
            found = await host.call("brain_search", {"query": "relógio", "limit": 2})
            return set(host.specs), host.problems, found

    names, problems, found = asyncio.run(go())
    assert {"brain_search", "brain_read", "brain_links"} <= names and problems == []
    assert json.loads(found)[0]["path"] == "relogio-de-ponto.md"


def test_a_sqlite_failure_becomes_one_tool_sentence(index, monkeypatch):
    import sqlite3

    from wisp.brain_server import DB_FAILURE

    def boom(*a, **k):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(index, "sync", boom)
    with pytest.raises(ToolFailure) as err:
        brain_search(index, "plano")
    assert str(err.value) == DB_FAILURE
    result = asyncio.run(build_server(lambda: index).call_tool("brain_read", {"path_or_title": "plano"}))
    assert result.is_error is True and result.content[0].text == DB_FAILURE
    monkeypatch.undo()
    monkeypatch.setattr(type(index), "graph", boom)
    result = asyncio.run(build_server(lambda: index).call_tool("brain_links", {"note": "plano"}))
    assert result.is_error is True and result.content[0].text == DB_FAILURE
