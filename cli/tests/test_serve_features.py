import sys

import pytest
from starlette.testclient import TestClient

from wisp.serve import features
from wisp.serve.app import create_app

TOKEN = "t0ken-for-tests"
AUTH = {"Authorization": f"Bearer {TOKEN}"}

DUMMY = '''
from starlette.responses import JSONResponse
from starlette.routing import Route


async def hello(request):
    return JSONResponse({"hello": request.path_params.get("who", "world")})


async def emit(request):
    host = request.app.state.host
    queue = host.hub.subscribe()
    host.publish_feature("dummy", "ticked", n=1)
    return JSONResponse(queue.get_nowait())


routes = [Route("/hello", hello), Route("/hello/{who}", hello), Route("/emit", emit, methods=["POST"])]
'''


@pytest.fixture
def drop(tmp_path, monkeypatch, data_dir):
    monkeypatch.setattr(features, "__path__", [*features.__path__, str(tmp_path)])
    added = []

    def write(name, source):
        (tmp_path / f"{name}.py").write_text(source, encoding="utf-8")
        added.append(f"{features.__name__}.{name}")

    yield write
    for name in added:
        sys.modules.pop(name, None)


@pytest.fixture
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("WISP_DATA_DIR", str(tmp_path / "data"))


def test_dummy_feature_is_mounted_under_api_and_needs_the_token(drop):
    drop("dummy", DUMMY)
    client = TestClient(create_app(TOKEN))
    assert client.get("/api/dummy/hello").status_code == 401
    assert client.get("/api/dummy/hello", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.get("/api/dummy/hello", params={"token": TOKEN}).status_code == 401
    ok = client.get("/api/dummy/hello", headers=AUTH)
    assert ok.status_code == 200 and ok.json() == {"hello": "world"}
    assert client.get("/api/dummy/hello/ale", headers=AUTH).json() == {"hello": "ale"}
    assert client.get("/api/nobody/hello", headers=AUTH).status_code == 404


def test_feature_event_carries_the_feature_key_and_chat_events_do_not(drop):
    drop("dummy", DUMMY)
    client = TestClient(create_app(TOKEN), headers=AUTH)
    assert client.post("/api/dummy/emit").json() == {"feature": "dummy", "type": "ticked", "n": 1}
    from wisp.serve import protocol

    assert "feature" not in protocol.event("c1", "status", state="idle")


def test_helpers_and_broken_modules_are_skipped_not_fatal(drop):
    drop("_helper", "routes = []\n")
    drop("noroutes", "x = 1\n")
    drop("broken", "raise RuntimeError('boom')\n")
    drop("dummy", DUMMY)
    assert sorted(features.discover()) == ["dummy"]
    assert TestClient(create_app(TOKEN), headers=AUTH).get("/health").status_code == 200


def test_preflight_allows_the_verbs_a_tab_needs():
    client = TestClient(create_app(TOKEN))
    ask = {"Origin": "http://tauri.localhost", "Access-Control-Request-Method": "DELETE"}
    assert client.options("/api/anything", headers=ask).status_code == 200
