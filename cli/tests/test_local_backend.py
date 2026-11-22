import json
import os
import signal
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest
from local_fakes import FakeLLM, call, reply

from wisp.local import backend as backends
from wisp.local import catalog as catalogs
from wisp.local import fetch
from wisp.local.backend import Backend, BackendError, MlxBackend, OpenAIClient, to_openai_messages


def test_a_streamed_reply_is_assembled_with_tool_calls_thinking_and_usage():
    with FakeLLM([reply("olá mundo", [call("read_file", path="/x")], thinking="hum")]) as fake:
        out = fake.client().chat("m", [{"role": "user", "content": "oi"}], [], {})
    assert out.content == "olá mundo" and out.thinking == "hum" and (out.prompt_tokens, out.reply_tokens) == (11, 7)
    assert out.tool_calls == [{"id": "call_0", "function": {"name": "read_file", "arguments": {"path": "/x"}}}]


def test_think_tags_in_the_content_become_thinking():
    with FakeLLM([reply("<think>pensando</think>resposta")]) as fake:
        out = fake.client().chat("m", [{"role": "user", "content": "oi"}], [], {})
    assert out.content == "resposta" and out.thinking == "pensando"


def test_messages_leave_as_openai_shapes_with_json_arguments_and_call_ids():
    sent = to_openai_messages([
        {"role": "user", "content": "x"},
        {"role": "assistant", "content": "", "tool_calls": [{"id": "t1", "function": {"name": "f", "arguments": {"a": "é"}}}]},
        {"role": "tool", "tool_name": "f", "tool_call_id": "t1", "content": "r"},
    ])
    assert sent[1]["tool_calls"] == [{"id": "t1", "type": "function", "function": {"name": "f", "arguments": '{"a": "é"}'}}]
    assert sent[2] == {"role": "tool", "tool_call_id": "t1", "content": "r"}


def test_tools_and_the_api_key_are_sent_and_models_are_listed():
    with FakeLLM([reply("ok")], tags={"a": 1, "b": 2}) as fake:
        client = OpenAIClient(fake.url, api_key="segredo")
        client.chat("m", [{"role": "user", "content": "oi"}], [{"type": "function", "function": {"name": "f"}}], {})
        assert client.models() == ["a", "b"] and client.running()
    assert fake.chats()[0]["authorization"] == "Bearer segredo" and fake.chats()[0]["tools"][0]["function"]["name"] == "f"


def test_errors_say_what_went_wrong():
    with FakeLLM([]) as fake:
        with pytest.raises(BackendError, match="no more replies"):
            fake.client().chat("m", [], [], {})
    with FakeLLM(status=500) as fake:
        with pytest.raises(BackendError, match="respondeu 500|falhou"):
            fake.client().chat("m", [], [], {})
    assert not OpenAIClient("http://127.0.0.1:1").running()
    with pytest.raises(BackendError, match="inválido"):
        OpenAIClient("ftp://x")
    with pytest.raises(BackendError, match="não consegui falar"):
        OpenAIClient("http://127.0.0.1:1").chat("m", [], [], {})


def test_an_openai_backend_is_ready_only_with_a_reachable_server_and_a_listed_model():
    assert Backend(OpenAIClient("http://127.0.0.1:1")).readiness("m") == "o servidor http://127.0.0.1:1 não respondeu"
    with FakeLLM(tags={"m": 1}) as fake:
        assert fake.client().readiness("") == "nenhum modelo local está ativo"
        assert fake.client().readiness("outro") == "o servidor não oferece o modelo outro"
        assert fake.client().readiness("m") is None


CHILD = [sys.executable, str(Path(__file__).parent / "fixtures/fake_mlx_child.py"), "{socket}", "{model}"]


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@pytest.fixture
def mlx(tmp_path, monkeypatch):
    made = []
    monkeypatch.setenv("FAKE_CHILD_LOG", str(tmp_path / "child.log"))

    def make(**kw):
        port = kw.pop("port", None) or free_port()
        backend = MlxBackend(OpenAIClient(f"http://127.0.0.1:{port}"), tmp_path, catalogs.load(), state_dir=tmp_path / "state",
                             runtime_ok=kw.pop("runtime_ok", lambda: True), child=kw.pop("child", CHILD), **kw)
        made.append(backend)
        return backend

    yield make
    for backend in made:
        backend.stop()
    subprocess.run(["pkill", "-f", str(tmp_path)])


def install(tmp_path, tag="qwen3:4b"):
    for item in catalogs.load().find(tag).files:
        target = fetch.model_dir(tmp_path, tag) / item["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("wb") as out:
            out.truncate(item["size"])
    shards = {item["path"]: item["path"] for item in catalogs.load().find(tag).files if item["path"].endswith(".safetensors")}
    (fetch.model_dir(tmp_path, tag) / "model.safetensors.index.json").write_text(json.dumps({"weight_map": shards}))


def alive(pid: int) -> bool:
    done = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    return done.returncode == 0 and bool(done.stdout.strip()) and not done.stdout.strip().startswith("Z")


def test_the_mlx_backend_names_a_missing_runtime_a_missing_model_and_then_is_ready(mlx, tmp_path):
    assert mlx(runtime_ok=lambda: False).readiness("qwen3:8b") == backends.MLX_MISSING
    assert mlx().readiness("") == "nenhum modelo local está ativo"
    assert mlx().readiness("qwen3:4b") == "o modelo qwen3:4b não está baixado"
    install(tmp_path)
    backend = mlx()
    assert backend.readiness("qwen3:4b") is None and backend.available() == ["qwen3:4b"]
    assert backend.model_id("qwen3:4b") == str(fetch.model_dir(tmp_path, "qwen3:4b"))


def test_a_half_downloaded_model_is_not_available(mlx, tmp_path):
    entry = catalogs.load().find("qwen3:4b")
    first = fetch.model_dir(tmp_path, "qwen3:4b") / entry.files[0]["path"]
    first.parent.mkdir(parents=True)
    first.write_bytes(b"x")
    assert mlx().available() == []


def test_the_server_starts_with_a_private_key_answers_through_the_proxy_and_is_reused(mlx, tmp_path):
    backend = mlx()
    backend.ensure_running("qwen3:4b")
    info = backends.read_server_info(backend.state_dir)
    key_file = backend.state_dir / "server.key"
    assert stat.S_IMODE(key_file.stat().st_mode) == 0o600 and stat.S_IMODE((backend.state_dir / "server.json").stat().st_mode) == 0o600
    assert len(key_file.read_text()) == 64 and alive(info["pid"]) and alive(info["child"])
    reply = backend.chat("qwen3:4b", [{"role": "user", "content": "oi"}], [], {})
    assert reply.content == "oi do mlx" and (reply.prompt_tokens, reply.reply_tokens) == (3, 2)
    logged = json.loads((tmp_path / "child.log").read_text().splitlines()[0])
    assert logged["body"]["model"] == "default_model" and logged["offline"] == "1"
    backend.ensure_running("qwen3:4b")
    assert backends.read_server_info(backend.state_dir)["pid"] == info["pid"]


def raw(backend, method, path, headers=None, body=None):
    import http.client as hc
    connection = hc.HTTPConnection("127.0.0.1", backend.client.port, timeout=5)
    connection.request(method, path, body, headers or {})
    response = connection.getresponse()
    return response.status, response.read()


def test_the_proxy_refuses_no_key_a_wrong_key_another_model_and_extra_fields(mlx, tmp_path):
    backend = mlx()
    backend.ensure_running("qwen3:4b")
    key = backend._key()
    body = json.dumps({"model": "mlx-community/Other", "messages": []})
    assert raw(backend, "GET", "/v1/models")[0] == 401
    assert raw(backend, "GET", "/v1/models", {"Authorization": "Bearer nope"})[0] == 401
    assert raw(backend, "POST", "/v1/chat/completions", {"Content-Length": str(len(body))}, body)[0] == 401
    assert raw(backend, "POST", "/v1/chat/completions", {"Authorization": f"Bearer {key}", "Content-Length": str(len(body))}, body)[0] == 403
    assert raw(backend, "GET", "/v1/models", {"Authorization": f"Bearer {key}"})[0] == 200
    assert raw(backend, "POST", "/v1/completions", {"Authorization": f"Bearer {key}", "Content-Length": "2"}, "{}")[0] == 404
    ok = json.dumps({"model": backend.model_id("qwen3:4b"), "messages": [], "draft_model": "x/y", "adapters": "z"})
    assert raw(backend, "POST", "/v1/chat/completions", {"Authorization": f"Bearer {key}", "Content-Length": str(len(ok))}, ok)[0] == 200
    forwarded = json.loads((tmp_path / "child.log").read_text().splitlines()[-1])["body"]
    assert "draft_model" not in forwarded and "adapters" not in forwarded


def test_a_server_that_does_not_know_the_key_is_never_sent_anything_and_the_port_is_not_taken_over(mlx):
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    seen = []

    class Rogue(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            seen.append(dict(self.headers))
            body = json.dumps({"wisp": "mlx-proxy", "model": "x"}).encode()
            self.send_response(200)
            self.send_header("X-Wisp-Proof", "0" * 64)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_POST = do_GET

    server = ThreadingHTTPServer(("127.0.0.1", 0), Rogue)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        backend = mlx(port=server.server_address[1], wait=8)
        with pytest.raises(BackendError, match="encerrou ao iniciar"):
            backend.ensure_running("qwen3:4b")
        assert not backend.running()
        assert all("Authorization" not in headers for headers in seen) and seen
    finally:
        server.shutdown()


def test_asking_for_another_model_restarts_the_server_for_it(mlx):
    backend = mlx()
    backend.ensure_running("qwen3:4b")
    first = backends.read_server_info(backend.state_dir)
    backend.ensure_running("qwen3:8b")
    second = backends.read_server_info(backend.state_dir)
    assert second["pid"] != first["pid"] and not alive(first["pid"]) and not alive(first["child"])
    assert second["model"] == backend.model_id("qwen3:8b")


def test_stop_ends_the_server_and_its_child_and_forgets_the_files(mlx):
    backend = mlx()
    backend.ensure_running("qwen3:4b")
    info = backends.read_server_info(backend.state_dir)
    assert backend.stop() is True
    assert not alive(info["pid"]) and not alive(info["child"])
    assert not (backend.state_dir / "server.json").exists() and not (backend.state_dir / "server.key").exists()
    assert backend.stop() is False and not backend.running()


def test_a_stale_record_is_reaped_and_a_reused_pid_is_not_killed(mlx):
    backend = mlx()
    innocent = subprocess.Popen(["sleep", "60"])
    try:
        backend.state_dir.mkdir(parents=True)
        (backend.state_dir / "server.json").write_text(json.dumps({"pid": innocent.pid, "child": innocent.pid, "model": "/x", "marker": "wisp-mlx-nada"}))
        (backend.state_dir / "server.key").write_text("k")
        backend.ensure_running("qwen3:4b")
        assert innocent.poll() is None
        assert backends.read_server_info(backend.state_dir)["pid"] != innocent.pid
    finally:
        innocent.kill()
        innocent.wait()


def test_a_server_that_never_gets_ready_is_killed_on_the_timeout(mlx):
    backend = mlx(child=[sys.executable, "-c", "import time; time.sleep(120)", "{socket}", "{model}"], wait=3)
    with pytest.raises(BackendError, match="não respondeu depois de iniciar"):
        backend.ensure_running("qwen3:4b")
    time.sleep(0.5)
    assert subprocess.run(["pgrep", "-f", "time.sleep\\(120\\)"], capture_output=True).returncode != 0
    assert backends.read_server_info(backend.state_dir) is None


def test_an_idle_server_shuts_itself_down(mlx):
    backend = mlx(idle_minutes=0.03)
    backend.ensure_running("qwen3:4b")
    info = backends.read_server_info(backend.state_dir)
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline and (alive(info["pid"]) or alive(info["child"])):
        time.sleep(0.5)
    assert not alive(info["pid"]) and not alive(info["child"])
    assert backends.read_server_info(backend.state_dir) is None


def test_a_server_in_the_middle_of_an_answer_is_not_idle(mlx):
    from wisp.local import proxy as proxies

    gate = proxies.Gate("m", "k", 1, 0.01)
    gate.touch(1)
    time.sleep(0.05)
    assert not gate.idle()
    gate.touch(-1)
    time.sleep(0.05)
    assert gate.idle()


def test_a_server_that_dies_while_starting_is_reported_with_its_exit_code(mlx):
    backend = mlx(launcher=[sys.executable, "-c", "raise SystemExit(3)"])
    with pytest.raises(BackendError, match="código 3"):
        backend.ensure_running("qwen3:4b")


def test_without_the_runtime_nothing_is_started(mlx):
    with pytest.raises(BackendError, match="componente de IA local"):
        mlx(runtime_ok=lambda: False).ensure_running("qwen3:4b")


def test_a_mac_without_apple_silicon_never_starts_anything_and_says_so(mlx, monkeypatch):
    from wisp.local import arch

    monkeypatch.setattr(arch, "host_is_apple_silicon", lambda: False)
    backend = mlx()
    assert backend.readiness("qwen3:4b") == arch.NEEDS_APPLE_SILICON
    with pytest.raises(BackendError, match="Apple silicon"):
        backend.ensure_running("qwen3:4b")
    assert backends.read_server_info(backend.state_dir) is None and "wisp local backend openai" in arch.NEEDS_APPLE_SILICON


def test_the_mlx_backend_refuses_an_address_that_is_not_this_machine(tmp_path, monkeypatch):
    from wisp.local import modelos

    cat = catalogs.load()
    for url in ("http://192.168.0.5:8421", "http://0.0.0.0:8421", "http://example.com:8421"):
        monkeypatch.setenv("WISP_MLX_URL", url)
        with pytest.raises(BackendError, match="só aceita um endereço local"):
            backends.make_backend(tmp_path, modelos.LocalState(), cat)
    monkeypatch.setenv("WISP_MLX_URL", "http://localhost:9999")
    assert backends.make_backend(tmp_path, modelos.LocalState(), cat).client.port == 9999


def test_the_default_backend_follows_the_toml(tmp_path, monkeypatch):
    from wisp.local import modelos

    monkeypatch.delenv("WISP_MLX_URL", raising=False)
    cat = catalogs.load()
    assert backends.make_backend(tmp_path, modelos.LocalState(), cat).kind == "mlx"
    assert backends.make_backend(tmp_path, modelos.LocalState(), cat).client.url == backends.DEFAULT_MLX_URL
    assert backends.make_backend(tmp_path, modelos.LocalState("m", (), "openai", "http://localhost:1234"), cat).kind == "openai"
    with pytest.raises(BackendError, match="falta o endereço"):
        backends.make_backend(tmp_path, modelos.LocalState("m", (), "openai", ""), cat)


@pytest.mark.parametrize("think,expected", [(False, {"enable_thinking": False}), (True, {"enable_thinking": True}), (None, None)])
def test_the_template_flag_is_sent_only_when_the_client_has_a_setting(think, expected):
    with FakeLLM([reply("ok")]) as fake:
        OpenAIClient(fake.url, think=think).chat("m", [{"role": "user", "content": "oi"}], [], {})
    assert fake.chats()[0].get("chat_template_kwargs") == expected


def test_the_mlx_backend_takes_the_setting_and_a_generic_server_never_gets_it(tmp_path, monkeypatch):
    from wisp.local import modelos

    monkeypatch.delenv("WISP_MLX_URL", raising=False)
    cat = catalogs.load()
    assert backends.make_backend(tmp_path, modelos.LocalState(), cat).client.think is False
    assert backends.make_backend(tmp_path, modelos.LocalState(pensar=True), cat).client.think is True
    assert backends.make_backend(tmp_path, modelos.LocalState("m", (), "openai", "http://localhost:1234", pensar=True), cat).client.think is None


@pytest.mark.parametrize("think", [False, True])
def test_the_proxy_hands_the_thinking_flag_to_the_real_server_request(mlx, tmp_path, think):
    backend = mlx()
    backend.client.think = think
    backend.chat("qwen3:4b", [{"role": "user", "content": "oi"}], [], {})
    forwarded = json.loads((tmp_path / "child.log").read_text().splitlines()[-1])["body"]
    assert forwarded["chat_template_kwargs"] == {"enable_thinking": think}


def listening_tcp(pid: int) -> str:
    done = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"], capture_output=True, text=True)
    return done.stdout.strip()


def test_the_model_process_listens_on_no_tcp_port_and_its_socket_is_private(mlx):
    backend = mlx()
    backend.ensure_running("qwen3:4b")
    info = backends.read_server_info(backend.state_dir)
    assert "child_port" not in info and "child_port" not in json.dumps(info)
    folder = Path(info["socket_dir"])
    assert stat.S_IMODE(folder.stat().st_mode) == 0o700 and folder.parent == Path("/tmp")
    assert (folder / "child.sock").is_socket()
    assert listening_tcp(info["child"]) == ""
    assert f":{backend.client.port} " in listening_tcp(info["pid"]) + " "
    backend.stop()
    assert not folder.exists()


def test_a_killed_launcher_leaves_no_socket_folder_behind_after_stop(mlx):
    backend = mlx()
    backend.ensure_running("qwen3:4b")
    info = backends.read_server_info(backend.state_dir)
    os.kill(info["pid"], signal.SIGKILL)
    time.sleep(0.5)
    backend.stop()
    assert not Path(info["socket_dir"]).exists()


def test_the_real_mlx_server_entry_points_the_child_relies_on_still_exist():
    mlx_server = pytest.importorskip("mlx_lm.server")
    assert callable(mlx_server.main) and callable(mlx_server._run_http_server) and mlx_server.APIHandler
    assert mlx_server._run_http_server.__defaults__[1] is mlx_server.APIHandler


def test_the_child_rebuilds_the_mlx_server_the_way_the_installed_mlx_lm_expects():
    import inspect

    mlx_server = pytest.importorskip("mlx_lm.server")
    run_http = inspect.signature(mlx_server._run_http_server)
    assert list(run_http.parameters) == ["host", "port", "response_generator", "server_class", "handler_class"]
    defaults = mlx_server._run_http_server.__defaults__
    assert len(defaults) == 2 and defaults[1] is mlx_server.APIHandler
    from http.server import ThreadingHTTPServer

    assert defaults[0] is ThreadingHTTPServer
    caller = inspect.getsource(mlx_server.run)
    assert "_run_http_server(host, port, response_generator)" in caller
    assert list(inspect.signature(mlx_server.run).parameters)[:3] == ["host", "port", "model_provider"]
    entry = inspect.getsource(mlx_server.main)
    assert "run(args.host, args.port, ModelProvider(args))" in entry
    for option in ('"--model"', '"--host"', '"--port"'):
        assert option in entry
    source = inspect.getsource(mlx_server._run_http_server)
    assert "server_class.address_family" in source and "server_class(" in source
    assert mlx_server.__name__ == "mlx_lm.server"


def test_the_mlx_lm_version_the_child_was_checked_against_is_the_pinned_one():
    metadata = pytest.importorskip("importlib.metadata")
    assert metadata.version("mlx-lm") == "0.32.2"
