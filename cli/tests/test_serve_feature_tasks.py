import json
import os
import threading
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from wisp.paths import WispPaths
from wisp.serve.app import create_app
from wisp.serve.features import tasks

TOKEN = "t0ken-for-tests"
AUTH = {"Authorization": f"Bearer {TOKEN}"}

SAMPLE = """---
titulo: pendencias
---
## Frente A
- **[Ana] Projeto — Entregar o relatório**. Revisar com o time #urgente <!-- alerta:rel-1 tema:x -->
- **[Bia]** Pagar a conta `luz`
- item solto com [[nota|link]] e **negrito**

## Frente B
- item solto com [[nota|link]] e **negrito**
```
- dentro de cerca
```
- item solto com [[nota|link]] e **negrito**
"""


@pytest.fixture
def profile(fake_home, tmp_path, monkeypatch):
    brain = tmp_path / "cofre"
    brain.mkdir()
    file = brain / "pendencias.md"
    file.write_text(SAMPLE, encoding="utf-8", newline="\n")
    config = WispPaths.current().config
    config.mkdir(parents=True, exist_ok=True)
    Path(os.environ["WISP_CONFIG"]).parent.mkdir(parents=True, exist_ok=True)
    (config / "profile.json").write_text(json.dumps({"blocks": {"tasks": {"file": "~/tarefas.md", "lock": str(tmp_path / "t.lock")}}}), encoding="utf-8", newline="\n")
    (fake_home / "tarefas.md").write_text(SAMPLE, encoding="utf-8", newline="\n")
    Path(os.environ["WISP_CONFIG"]).write_text(json.dumps({"brain": str(brain)}), encoding="utf-8", newline="\n")
    monkeypatch.setenv("WISP_DATA_DIR", str(tmp_path / "data"))
    return {"home_file": fake_home / "tarefas.md", "brain_file": file, "brain": brain, "lock": tmp_path / "t.lock", "config": config}


@pytest.fixture
def client(profile):
    return TestClient(create_app(TOKEN))


def test_parse_reads_owner_front_title_detail_and_urgent():
    groups = tasks.parse(SAMPLE)
    assert [g["title"] for g in groups] == ["Frente A", "Frente B"]
    first, second, third = groups[0]["items"]
    assert (first["owner"], first["front"], first["title"], first["detail"], first["urgent"], first["alert_id"]) == (
        "Ana", "Projeto", "Entregar o relatório", "Revisar com o time", True, "rel-1")
    assert (second["owner"], second["title"], second["detail"], second["urgent"]) == ("Bia", "", "Pagar a conta luz", False)
    assert third["title"] == "item solto com link e negrito" and third["owner"] is None
    assert [i["line"] for i in groups[1]["items"]].count(third["line"]) == 2
    assert [i["occurrence"] for i in groups[1]["items"]] == [1, 2]
    assert all("dentro de cerca" not in i["line"] for g in groups for i in g["items"])


def test_list_endpoint_uses_the_profile_file_with_tilde_expanded(client, profile):
    assert client.get("/api/tasks/list").status_code == 401
    body = client.get("/api/tasks/list", headers=AUTH).json()
    assert body["configured"] and body["file"] == "tarefas.md" and body["open_count"] == 5
    assert body["brain_path"] is None


def test_list_reports_brain_relative_path_when_the_file_is_inside_the_brain(client, profile):
    profile["config"].joinpath("profile.json").write_text(json.dumps({"blocks": {"tasks": {"file": str(profile["brain_file"])}}}), encoding="utf-8", newline="\n")
    body = client.get("/api/tasks/list", headers=AUTH).json()
    assert body["brain_path"] == "pendencias.md"
    assert body["groups"][0]["items"][0]["index"] == 4


def test_list_falls_back_to_the_pendencias_note_of_the_brain(client, profile):
    profile["config"].joinpath("profile.json").unlink()
    assert client.get("/api/tasks/list", headers=AUTH).json()["file"] == "pendencias.md"
    profile["brain_file"].unlink()
    assert client.get("/api/tasks/list", headers=AUTH).json() == {"configured": False, "groups": [], "open_count": 0}


def test_complete_removes_exactly_the_given_occurrence(client, profile):
    groups = client.get("/api/tasks/list", headers=AUTH).json()["groups"]
    target = groups[1]["items"][1]
    answer = client.post("/api/tasks/complete", headers=AUTH, json={"line": target["line"], "occurrence": target["occurrence"]})
    assert answer.status_code == 200
    after = profile["home_file"].read_text(encoding="utf-8")
    assert after.count("item solto com [[nota|link]]") == 2 and "dentro de cerca" in after
    assert [i["occurrence"] for i in client.get("/api/tasks/list", headers=AUTH).json()["groups"][1]["items"]] == [1]


def test_complete_refuses_a_line_that_changed(client, profile):
    answer = client.post("/api/tasks/complete", headers=AUTH, json={"line": "- nunca existiu", "occurrence": 0})
    assert answer.status_code == 409
    assert profile["home_file"].read_text(encoding="utf-8") == SAMPLE
    assert client.post("/api/tasks/complete", headers=AUTH, json={}).status_code == 400


def test_complete_waits_for_the_lock_and_gives_up_busy(profile):
    line = "- item solto com [[nota|link]] e **negrito**"
    release = threading.Event()
    held = threading.Event()

    def hold():
        with tasks.file_lock(profile["lock"]):
            held.set()
            release.wait(5)

    thread = threading.Thread(target=hold)
    thread.start()
    held.wait(5)
    try:
        with pytest.raises(tasks.LockBusy):
            tasks.complete(profile["home_file"], line, 0, profile["lock"], wait=0.2)
    finally:
        release.set()
        thread.join()
    tasks.complete(profile["home_file"], line, 0, profile["lock"], wait=1)
    assert profile["home_file"].read_text(encoding="utf-8").count(line) == 2


def test_deleting_the_last_line_keeps_a_trailing_newline():
    assert tasks.deleting("## A\n- x\n- y", "- y", 0) == "## A\n- x\n"
    with pytest.raises(tasks.LineChanged):
        tasks.deleting("- x\n", "- x", 1)


def test_complete_keeps_a_crlf_file_crlf_byte_for_byte(client, profile):
    raw = SAMPLE.replace("\n", "\r\n").encode("utf-8")
    profile["home_file"].write_bytes(raw)
    groups = client.get("/api/tasks/list", headers=AUTH).json()["groups"]
    target = groups[1]["items"][1]
    assert client.post("/api/tasks/complete", headers=AUTH, json={"line": target["line"], "occurrence": target["occurrence"]}).status_code == 200
    after = profile["home_file"].read_bytes()
    assert after.count(b"\n") == after.count(b"\r\n") == raw.count(b"\r\n") - 1
    assert after.count("item solto com [[nota|link]]".encode()) == 2


def test_complete_keeps_an_lf_file_lf(client, profile):
    groups = client.get("/api/tasks/list", headers=AUTH).json()["groups"]
    target = groups[1]["items"][1]
    client.post("/api/tasks/complete", headers=AUTH, json={"line": target["line"], "occurrence": target["occurrence"]})
    assert b"\r" not in profile["home_file"].read_bytes()
