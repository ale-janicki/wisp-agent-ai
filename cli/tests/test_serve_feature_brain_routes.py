import asyncio
import base64
import json
import os
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from wisp.paths import WispPaths
from wisp.serve.app import create_app
from wisp.serve.features import brain
from wisp.serve.features.brain import watch

TOKEN = "t0ken-for-tests"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
SCENE_FIXTURE = Path(__file__).resolve().parents[2] / "core/Tests/WispCoreTests/Fixtures/drawings/neutral-compressed.excalidraw.md"


def write_main_config(content: dict) -> None:
    target = Path(os.environ["WISP_CONFIG"])
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(content), encoding="utf-8", newline="\n")


@pytest.fixture
def vault_root(fake_home, tmp_path, monkeypatch):
    root = tmp_path / "cofre"
    (root / "pessoas").mkdir(parents=True)
    (root / "Inicio.md").write_text("# Inicio\n\nVeja [[Ana]].\n\n- [ ] fazer\n- [x] feito\n\n#projeto\n", encoding="utf-8", newline="\n")
    (root / "pessoas" / "Ana.md").write_text("---\ntags: [pessoa]\n---\n# Ana\n\nDe volta a [[Inicio]].\n", encoding="utf-8", newline="\n")
    (root / "foto.png").write_bytes(b"\x89PNG\r\n\x1a\nxx")
    write_main_config({"brain": str(root), "wisp_dir": str(tmp_path / "wisp")})
    monkeypatch.setenv("WISP_DATA_DIR", str(tmp_path / "data"))
    return root


@pytest.fixture
def client(vault_root):
    return TestClient(create_app(TOKEN))


def test_every_brain_route_needs_the_token(client):
    assert client.get("/api/brain/state").status_code == 401
    assert client.get("/api/brain/state", headers=AUTH).json() == {"configured": True, "name": "cofre"}


def test_state_reports_an_unconfigured_brain_and_other_routes_answer_conflict(fake_home, monkeypatch, tmp_path):
    monkeypatch.setenv("WISP_DATA_DIR", str(tmp_path / "data"))
    client = TestClient(create_app(TOKEN))
    assert client.get("/api/brain/state", headers=AUTH).json() == {"configured": False}
    assert client.get("/api/brain/tree", headers=AUTH).status_code == 409


def test_brain_path_with_a_tilde_is_expanded(fake_home, tmp_path, monkeypatch):
    (fake_home / "meu cofre").mkdir()
    (fake_home / "meu cofre" / "a.md").write_text("# A\n", encoding="utf-8", newline="\n")
    write_main_config({"brain": "~/meu cofre"})
    monkeypatch.setenv("WISP_DATA_DIR", str(tmp_path / "data"))
    client = TestClient(create_app(TOKEN))
    assert client.get("/api/brain/state", headers=AUTH).json()["name"] == "meu cofre"
    assert [e["path"] for e in client.get("/api/brain/tree", headers=AUTH).json()["entries"]] == ["a.md"]


def test_brain_falls_back_to_the_profile_memory_root(fake_home, tmp_path, monkeypatch):
    (fake_home / "memoria").mkdir()
    config = WispPaths.current().config
    config.mkdir(parents=True)
    (config / "profile.json").write_text(json.dumps({"blocks": {"memory": {"root": "~/memoria"}}}), encoding="utf-8", newline="\n")
    monkeypatch.setenv("WISP_DATA_DIR", str(tmp_path / "data"))
    assert TestClient(create_app(TOKEN)).get("/api/brain/state", headers=AUTH).json()["name"] == "memoria"


def test_note_read_write_and_conflict_guard(client, vault_root):
    note = client.get("/api/brain/note", params={"path": "Inicio.md"}, headers=AUTH).json()
    assert note["kind"] == "note" and note["read_only"] is None and note["text"].startswith("# Inicio")
    ok = client.put("/api/brain/note", headers=AUTH, json={"path": "Inicio.md", "text": "novo\n", "base": note["text"]})
    assert ok.status_code == 200 and (vault_root / "Inicio.md").read_text(encoding="utf-8") == "novo\n"
    stale = client.put("/api/brain/note", headers=AUTH, json={"path": "Inicio.md", "text": "outro\n", "base": "antigo"})
    assert stale.status_code == 409 and (vault_root / "Inicio.md").read_text(encoding="utf-8") == "novo\n"
    forced = client.put("/api/brain/note", headers=AUTH, json={"path": "Inicio.md", "text": "outro\n", "base": "antigo", "force": True})
    assert forced.status_code == 200
    assert client.get("/api/brain/note", params={"path": "nada.md"}, headers=AUTH).status_code == 404
    assert client.get("/api/brain/note", params={"path": "../x.md"}, headers=AUTH).status_code == 403
    assert client.get("/api/brain/note", params={"path": ".git/config"}, headers=AUTH).status_code == 403


def test_create_folder_note_and_trash(client, vault_root, monkeypatch):
    assert client.post("/api/brain/note", headers=AUTH, json={"path": "pessoas/Bia.md", "text": "# Bia\n"}).status_code == 200
    assert client.post("/api/brain/note", headers=AUTH, json={"path": "pessoas/Bia.md"}).status_code == 409
    assert client.post("/api/brain/note", headers=AUTH, json={"path": "a:b.md"}).status_code == 400
    assert client.post("/api/brain/folder", headers=AUTH, json={"path": "novos"}).status_code == 200
    assert (vault_root / "novos").is_dir()
    assert client.post("/api/brain/trash", headers=AUTH, json={"path": "pessoas/Bia.md"}).status_code == 200
    assert not (vault_root / "pessoas" / "Bia.md").exists()


def test_backlinks_outgoing_graph_tags_recent_and_resolve(client):
    back = client.get("/api/brain/backlinks", params={"path": "pessoas/Ana.md"}, headers=AUTH).json()["items"]
    assert back[0]["path"] == "Inicio.md" and back[0]["contexts"][0]["text"] == "Veja [[Ana]]."
    out = client.get("/api/brain/outgoing", params={"path": "Inicio.md"}, headers=AUTH).json()["items"]
    assert out == [{"name": "Ana", "heading": "", "target": "pessoas/Ana.md"}]
    graph = client.get("/api/brain/graph", headers=AUTH).json()
    assert graph["edges"] == [["Inicio.md", "pessoas/Ana.md"]]
    assert {n["id"]: n["degree"] for n in graph["nodes"]} == {"Inicio.md": 1, "pessoas/Ana.md": 1}
    assert client.get("/api/brain/tags", headers=AUTH).json()["tags"] == {"pessoa": 1, "projeto": 1}
    assert {i["path"] for i in client.get("/api/brain/recent", headers=AUTH).json()["items"]} == {"Inicio.md", "pessoas/Ana.md"}
    assert client.get("/api/brain/resolve", params={"name": "ana", "from": "Inicio.md"}, headers=AUTH).json() == {"path": "pessoas/Ana.md"}


def test_search_by_text_and_by_tag(client):
    found = client.get("/api/brain/search", params={"q": "volta"}, headers=AUTH).json()["items"]
    assert [i["path"] for i in found] == ["pessoas/Ana.md"]
    assert [i["path"] for i in client.get("/api/brain/search", params={"q": "#projeto"}, headers=AUTH).json()["items"]] == ["Inicio.md"]
    assert client.get("/api/brain/search", params={"q": ""}, headers=AUTH).json() == {"items": []}


def test_task_toggle_and_property_edit_write_the_file(client, vault_root):
    answer = client.post("/api/brain/task", headers=AUTH, json={"path": "Inicio.md", "line": 4, "expected": "- [ ] fazer"})
    assert answer.status_code == 200 and "- [x] fazer" in (vault_root / "Inicio.md").read_text(encoding="utf-8")
    assert client.post("/api/brain/task", headers=AUTH, json={"path": "Inicio.md", "line": 4, "expected": "- [ ] fazer"}).status_code == 409
    props = client.get("/api/brain/properties", params={"path": "pessoas/Ana.md"}, headers=AUTH).json()
    assert props["items"] == [{"key": "tags", "value": ["pessoa"], "kind": "list"}]
    client.post("/api/brain/property", headers=AUTH, json={"path": "pessoas/Ana.md", "key": "status", "value": "ativo"})
    client.post("/api/brain/property", headers=AUTH, json={"path": "pessoas/Ana.md", "key": "tags", "remove": True})
    assert (vault_root / "pessoas" / "Ana.md").read_text(encoding="utf-8") == "---\nstatus: ativo\n---\n# Ana\n\nDe volta a [[Inicio]].\n"


def test_rename_preview_then_apply_rewrites_links_and_refuses_a_changed_preview(client, vault_root):
    (vault_root / "Sem.md").write_text("sem titulo\n", encoding="utf-8", newline="\n")
    (vault_root / "ref.md").write_text("[[Sem]]\n", encoding="utf-8", newline="\n")
    preview = client.post("/api/brain/rename/preview", headers=AUTH, json={"from": "Sem.md", "to": "Outro.md"}).json()
    assert preview["link_count"] == 1 and preview["edits"] == [{"path": "ref.md", "count": 1}] and preview["is_complete"]
    (vault_root / "ref.md").write_text("[[Sem]] mudou\n", encoding="utf-8", newline="\n")
    stale = client.post("/api/brain/rename/apply", headers=AUTH, json={"from": "Sem.md", "to": "Outro.md", "id": preview["id"]})
    assert stale.status_code == 409 and (vault_root / "Sem.md").exists()
    fresh = client.post("/api/brain/rename/preview", headers=AUTH, json={"from": "Sem.md", "to": "Outro.md"}).json()
    ok = client.post("/api/brain/rename/apply", headers=AUTH, json={"from": "Sem.md", "to": "Outro.md", "id": fresh["id"]})
    assert ok.status_code == 200 and (vault_root / "ref.md").read_text(encoding="utf-8") == "[[Outro]] mudou\n"
    assert client.post("/api/brain/rename/preview", headers=AUTH, json={"from": "Outro.md", "to": "Inicio.md"}).status_code == 409


def test_merge_endpoint(client):
    answer = client.post("/api/brain/merge", headers=AUTH, json={"base": "a\nb\nc\n", "mine": "A\nb\nc\n", "theirs": "a\nb\nC\n"}).json()
    assert answer == {"kind": "merged", "text": "A\nb\nC\n"}


def test_daily_note_is_created_once_from_the_template(client, vault_root):
    (vault_root / ".obsidian").mkdir()
    (vault_root / ".obsidian" / "daily-notes.json").write_text('{"folder":"dias","format":"YYYY-MM-DD","template":"daily"}', encoding="utf-8", newline="\n")
    (vault_root / "daily.md").write_text("# {{title}}\n", encoding="utf-8", newline="\n")
    info = client.get("/api/brain/daily", headers=AUTH).json()
    assert info["exists"] is False and info["path"].startswith("dias/20")
    path = client.post("/api/brain/daily", headers=AUTH).json()["path"]
    assert path == info["path"]
    assert (vault_root / path).read_text(encoding="utf-8") == f"# {Path(path).stem}\n"
    assert client.get("/api/brain/daily", headers=AUTH).json()["exists"] is True
    assert client.post("/api/brain/daily", headers=AUTH).json()["path"] == path


def test_bookmarks_round_trip_per_brain(client, tmp_path, vault_root):
    assert client.get("/api/brain/bookmarks", headers=AUTH).json() == {"paths": []}
    client.put("/api/brain/bookmarks", headers=AUTH, json={"paths": ["Inicio.md"]})
    assert client.get("/api/brain/bookmarks", headers=AUTH).json() == {"paths": ["Inicio.md"]}
    assert json.loads((tmp_path / "wisp" / "brain-bookmarks.json").read_text(encoding="utf-8")) == {str(vault_root.resolve()): ["Inicio.md"]}
    assert client.put("/api/brain/bookmarks", headers=AUTH, json={"paths": [1]}).status_code == 400


def test_attachment_is_resolved_by_name_and_returned_as_base64(client):
    got = client.get("/api/brain/attachment", params={"name": "foto.png", "from": "Inicio.md"}, headers=AUTH).json()
    assert got["path"] == "foto.png" and got["mime"] == "image/png" and base64.b64decode(got["data"]).startswith(b"\x89PNG")
    assert client.get("/api/brain/attachment", params={"name": "nao.png"}, headers=AUTH).status_code == 404


def test_drawing_open_save_and_conflict(client, vault_root):
    (vault_root / "d.excalidraw.md").write_text(SCENE_FIXTURE.read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
    opened = client.get("/api/brain/drawing", params={"path": "d.excalidraw.md"}, headers=AUTH).json()
    scene = json.loads(opened["scene"])
    assert opened["kind"] == "excalidraw" and scene["elements"] and opened["read_only"] is None
    scene["elements"].append({"id": "novo1234", "type": "text", "text": "oi", "originalText": "oi", "isDeleted": False})
    saved = client.put("/api/brain/drawing", headers=AUTH, json={"path": "d.excalidraw.md", "scene": json.dumps(scene), "hash": opened["hash"]})
    assert saved.status_code == 200
    on_disk = (vault_root / "d.excalidraw.md").read_text(encoding="utf-8")
    assert "oi ^novo1234" in on_disk and "Texto livre antes dos dados, preservado." in on_disk
    again = client.put("/api/brain/drawing", headers=AUTH, json={"path": "d.excalidraw.md", "scene": json.dumps(scene), "hash": opened["hash"]})
    assert again.status_code == 409
    assert client.put("/api/brain/drawing", headers=AUTH, json={"path": "d.excalidraw.md", "scene": "[]", "hash": saved.json()["hash"]}).status_code == 422


def test_new_drawing_and_canvas_are_created_with_unique_names(client, vault_root):
    one = client.post("/api/brain/drawing/new", headers=AUTH, json={"kind": "excalidraw", "folder": "pessoas"}).json()["path"]
    two = client.post("/api/brain/drawing/new", headers=AUTH, json={"kind": "excalidraw", "folder": "pessoas"}).json()["path"]
    assert one != two and one.startswith("pessoas/Desenho ") and one.endswith(".excalidraw.md")
    canvas = client.post("/api/brain/drawing/new", headers=AUTH, json={"kind": "canvas"}).json()["path"]
    assert client.get("/api/brain/drawing", params={"path": canvas}, headers=AUTH).json()["canvas"] == {"nodes": [], "edges": []}
    assert client.post("/api/brain/drawing/new", headers=AUTH, json={"kind": "x"}).status_code == 400
    assert client.get("/api/brain/drawing", params={"path": "Inicio.md"}, headers=AUTH).status_code == 400


def test_excalidraw_assets_are_served_from_the_build_and_never_outside_it(client, tmp_path, monkeypatch):
    build = tmp_path / "excalidraw"
    (build / "assets").mkdir(parents=True)
    (build / "index.html").write_text("<html></html>", encoding="utf-8", newline="\n")
    (build / "assets" / "app.js").write_text("export {}", encoding="utf-8", newline="\n")
    (tmp_path / "secret.txt").write_text("x", encoding="utf-8", newline="\n")
    monkeypatch.setenv("WISP_EXCALIDRAW_DIR", str(build))
    index = client.get("/api/brain/excalidraw/", headers=AUTH)
    assert index.status_code == 200 and index.text == "<html></html>" and "default-src 'none'" in index.headers["content-security-policy"]
    js = client.get("/api/brain/excalidraw/assets/app.js", headers=AUTH)
    assert js.headers["content-type"].startswith("text/javascript")
    assert client.get("/api/brain/excalidraw/../secret.txt", headers=AUTH).status_code in (404, 400)
    assert client.get("/api/brain/excalidraw/assets/nope.js", headers=AUTH).status_code == 404


def test_watcher_publishes_a_changed_event_with_the_paths(vault_root):
    class Host:
        def __init__(self):
            self.events = []

        def publish_feature(self, feature, type_, **fields):
            self.events.append((feature, type_, fields))

    host = Host()
    rt = brain.Runtime(host)
    vault = rt.current()
    before = watch.snapshot(vault)
    (vault_root / "Inicio.md").write_text("mudou de verdade\n", encoding="utf-8", newline="\n")
    asyncio.run(brain.poll_once(rt, vault, before))
    assert host.events == [("brain", "changed", {"paths": ["Inicio.md"]})]
    assert rt.dirty is True


def test_excalidraw_index_gets_the_iframe_bridge_shim_and_the_token_path_form(client, tmp_path, monkeypatch):
    build = tmp_path / "excalidraw"
    build.mkdir()
    (build / "index.html").write_text('<html><head></head><body><script type="module" src="./assets/app.js"></script></body></html>', encoding="utf-8", newline="\n")
    monkeypatch.setenv("WISP_EXCALIDRAW_DIR", str(build))
    for url in ("/api/brain/excalidraw/t/abc/index.html", "/api/brain/excalidraw/t/abc/", "/api/brain/excalidraw/index.html"):
        page = client.get(url, headers=AUTH)
        assert page.status_code == 200
        assert page.text.index('src="./wisp-shim.js"') < page.text.index('src="./assets/app.js"')
    shim = client.get("/api/brain/excalidraw/t/abc/wisp-shim.js", headers=AUTH)
    assert shim.status_code == 200 and shim.headers["content-type"].startswith("text/javascript")
    assert "messageHandlers" in shim.text and "EXCALIDRAW_ASSET_PATH" in shim.text and "window.parent.postMessage" in shim.text


def test_recover_copies_what_a_choice_discards_next_to_the_wisp_folder(client, tmp_path):
    answer = client.post("/api/brain/recover", headers=AUTH, json={"path": "pessoas/Ana.md", "text": "minha versão\n"})
    saved = list((tmp_path / "wisp" / "brain-recuperado").iterdir())
    assert answer.status_code == 200 and len(saved) == 1 and saved[0].name.endswith("Ana.md")
    assert saved[0].read_text(encoding="utf-8") == "minha versão\n"


def test_excalidraw_token_in_the_path_opens_only_that_prefix(client, tmp_path, monkeypatch):
    build = tmp_path / "excalidraw"
    build.mkdir()
    (build / "index.html").write_text("<html><script src='x'></script></html>", encoding="utf-8", newline="\n")
    monkeypatch.setenv("WISP_EXCALIDRAW_DIR", str(build))
    base = "/api/brain/excalidraw/t/"
    ok = client.get(f"{base}{TOKEN}/index.html")
    assert ok.status_code == 200 and ok.headers["referrer-policy"] == "no-referrer"
    assert client.get(f"{base}{TOKEN}/wisp-shim.js").headers["referrer-policy"] == "no-referrer"
    assert client.get(f"{base}wrong/index.html").status_code == 401
    assert client.get(f"{base}/index.html").status_code == 401
    assert client.get("/api/brain/note", params={"x": f"/excalidraw/t/{TOKEN}"}).status_code == 401
    assert client.get(f"/api/brain/tree/api/brain/excalidraw/t/{TOKEN}/x").status_code == 401
    assert client.get(f"{base}{TOKEN}/../../tree").status_code in (401, 403, 404)
    assert client.get("/api/brain/tree", params={"t": TOKEN}).status_code == 401
    assert client.get("/api/brain/excalidraw/index.html").status_code == 401
    assert client.get("/api/brain/excalidraw/index.html", headers=AUTH).headers["referrer-policy"] == "no-referrer"
    assert client.get("/api/brain/excalidraw/t/%74" + TOKEN[1:] + "/index.html").status_code == 200
    assert client.get("/api/brain/excalidraw/t/x/" + TOKEN).status_code == 401


def test_an_os_error_becomes_a_json_error_not_a_bare_500(client, vault_root, monkeypatch):
    import wisp.serve.features.brain.vault as module

    monkeypatch.setattr(module.Vault, "write", lambda self, rel, text: (_ for _ in ()).throw(PermissionError(13, "negado")))
    answer = client.put("/api/brain/note", headers=AUTH, json={"path": "Inicio.md", "text": "x", "force": True})
    assert answer.status_code == 423 and "error" in answer.json()


def test_attachment_size_is_checked_before_reading(client, vault_root, monkeypatch):
    import wisp.serve.features.brain as brain

    monkeypatch.setattr(brain, "MAX_ATTACHMENT", 4)
    read = []
    monkeypatch.setattr(brain.Vault, "read_bytes", lambda self, rel: read.append(rel) or b"")
    assert client.get("/api/brain/attachment", params={"name": "foto.png"}, headers=AUTH).status_code == 413
    assert read == []


def _raw(root: Path, rel: str, text: str) -> None:
    (root / rel).write_bytes(text.encode("utf-8"))


@pytest.mark.parametrize("eol", ["\n", "\r\n"])
def test_mutating_routes_keep_the_notes_own_line_endings_byte_for_byte(client, vault_root, eol):
    _raw(vault_root, "t.md", f"---{eol}tags: [a]{eol}---{eol}- [ ] fazer{eol}fim{eol}")
    assert client.post("/api/brain/task", headers=AUTH, json={"path": "t.md", "line": 3, "expected": "- [ ] fazer"}).status_code == 200
    assert (vault_root / "t.md").read_bytes() == f"---{eol}tags: [a]{eol}---{eol}- [x] fazer{eol}fim{eol}".encode()
    assert client.post("/api/brain/property", headers=AUTH, json={"path": "t.md", "key": "status", "value": "ok"}).status_code == 200
    assert (vault_root / "t.md").read_bytes() == f"---{eol}tags: [a]{eol}status: ok{eol}---{eol}- [x] fazer{eol}fim{eol}".encode()
    _raw(vault_root, "Sem.md", "sem titulo\n")
    _raw(vault_root, "ref.md", f"[[Sem]] e [[Sem|r]]{eol}`[[Sem]]`{eol}")
    preview = client.post("/api/brain/rename/preview", headers=AUTH, json={"from": "Sem.md", "to": "Outro.md"}).json()
    assert client.post("/api/brain/rename/apply", headers=AUTH, json={"from": "Sem.md", "to": "Outro.md", "id": preview["id"]}).status_code == 200
    assert (vault_root / "ref.md").read_bytes() == f"[[Outro]] e [[Outro|r]]{eol}`[[Sem]]`{eol}".encode()
    noted = f"# N{eol}{eol}texto{eol}"
    assert client.put("/api/brain/note", headers=AUTH, json={"path": "t.md", "text": noted, "base": (vault_root / "t.md").read_bytes().decode()}).status_code == 200
    assert (vault_root / "t.md").read_bytes() == noted.encode()


@pytest.mark.parametrize("eol", ["\r\n", "\n"])
def test_drawing_round_trip_keeps_the_notes_line_endings(client, vault_root, eol):
    source = SCENE_FIXTURE.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\n", eol)
    _raw(vault_root, "d.excalidraw.md", source)
    opened = client.get("/api/brain/drawing", params={"path": "d.excalidraw.md"}, headers=AUTH).json()
    scene = json.loads(opened["scene"])
    scene["elements"].append({"id": "novo1234", "type": "text", "text": "oi", "originalText": "oi", "isDeleted": False})
    saved = client.put("/api/brain/drawing", headers=AUTH, json={"path": "d.excalidraw.md", "scene": json.dumps(scene), "hash": opened["hash"]})
    assert saved.status_code == 200
    on_disk = (vault_root / "d.excalidraw.md").read_bytes().decode("utf-8")
    assert "oi ^novo1234" in on_disk
    assert on_disk.count("\r\n") == (on_disk.count("\n") if eol == "\r\n" else 0)

