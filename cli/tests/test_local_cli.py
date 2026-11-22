import json
import shutil
from dataclasses import replace
from pathlib import Path

import pytest
from local_fakes import FakeHub, FakeLLM, reply

from wisp import cli as wisp_cli
from wisp.local import catalog as catalogs
from wisp.config import WispConfig, save_config
from wisp.local import arch
from wisp.local import backend as backends
from wisp.local import fetch, guardrails, modelos
from wisp.local import cli as local_cli
from wisp.local import tools as _tools  # noqa: F401

WISP_FOLDER = Path(guardrails.__file__).parents[1] / "wisp_folder"


@pytest.fixture
def folder(fake_home):
    root = fake_home / "Wisp"
    (root / "conversas").mkdir(parents=True)
    for name in ("guardrails.toml", "modelos.toml"):
        shutil.copy(WISP_FOLDER / name, root / name)
    save_config(WispConfig(wisp_dir=str(root)))
    return root


def lines(capsys) -> list[dict]:
    return [json.loads(l) for l in capsys.readouterr().out.splitlines()]





def install_model(folder, tag):
    entry = REAL_LOAD().find(tag)
    for item in entry.files:
        target = fetch.model_dir(folder, tag) / item["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("wb") as out:
            out.truncate(item["size"])
    shards = {item["path"]: item["path"] for item in catalogs.load().find(tag).files if item["path"].endswith(".safetensors")}
    (fetch.model_dir(folder, tag) / "model.safetensors.index.json").write_text(json.dumps({"weight_map": shards}))


@pytest.fixture(autouse=True)
def mlx_runtime(monkeypatch):
    monkeypatch.setattr(backends.importlib.util, "find_spec", lambda name: object())
    monkeypatch.setattr(backends.MlxBackend, "running", lambda self: True)
    monkeypatch.setattr(backends.MlxBackend, "ensure_running", lambda self, tag=None: None)


REAL_LOAD = catalogs.load


def tiny_catalog(hub: FakeHub) -> catalogs.Catalog:
    base = REAL_LOAD()
    entry = replace(base.models[0], tag="qwen3:4b", repo="mlx-community/Tiny", revision="a" * 40, files=tuple(hub.manifest()),
                    size_bytes=sum(len(d) for d in hub.files.values()))
    return replace(base, models=(entry,), disk_margin_bytes=1000)


FILES = {"config.json": b'{"a": 1}', "model.safetensors": b"weights" * 300}


def test_catalog_reports_the_backend_and_what_is_installed(folder, capsys, monkeypatch):
    install_model(folder, "qwen3:8b")
    modelos.write(folder, modelos.LocalState("qwen3:8b", ("qwen3:8b", "qwen3:4b")))
    with FakeLLM() as fake:
        monkeypatch.setenv("WISP_MLX_URL", fake.url)
        assert wisp_cli.main(["local", "catalog"]) == 0
    out = lines(capsys)[0]
    assert out["backend"] == {"kind": "mlx", "available": True, "running": True, "url": ""}
    assert out["installed"] == ["qwen3:8b"] and out["active"] == "qwen3:8b" and len(out["models"]) >= 4


def test_pull_downloads_verifies_and_records_the_install(folder, capsys, monkeypatch):
    with FakeHub("mlx-community/Tiny", "a" * 40, FILES) as hub:
        monkeypatch.setenv("WISP_HF_URL", hub.url)
        monkeypatch.setattr(catalogs, "load", lambda: tiny_catalog(hub))
        assert wisp_cli.main(["local", "pull", "qwen3:4b"]) == 0
        assert wisp_cli.main(["local", "pull", "llama3.2:3b"]) == 1
    out = lines(capsys)
    assert [o["type"] for o in out][-2:] == ["done", "error"] and out[0]["type"] == "progress" and out[0]["total"] == sum(map(len, FILES.values()))
    assert modelos.read(folder).instalados == ("qwen3:4b",)
    assert (fetch.model_dir(folder, "qwen3:4b") / "model.safetensors").read_bytes() == FILES["model.safetensors"]


def test_a_tampered_file_installs_nothing(folder, capsys, monkeypatch):
    with FakeHub("mlx-community/Tiny", "a" * 40, FILES, tamper={"model.safetensors"}) as hub:
        monkeypatch.setenv("WISP_HF_URL", hub.url)
        monkeypatch.setattr(catalogs, "load", lambda: tiny_catalog(hub))
        assert wisp_cli.main(["local", "pull", "qwen3:4b"]) == 1
    assert "verificação de model.safetensors falhou" in lines(capsys)[-1]["message"]
    assert modelos.read(folder).instalados == () and not fetch.model_dir(folder, "qwen3:4b").exists()


def test_pull_never_starts_on_a_mac_without_apple_silicon(folder, capsys, monkeypatch):
    monkeypatch.setattr(arch, "host_is_apple_silicon", lambda: False)
    with FakeHub("x/y", "b" * 40, FILES) as hub:
        monkeypatch.setenv("WISP_HF_URL", hub.url)
        assert wisp_cli.main(["local", "pull", "qwen3:4b"]) == 1
        assert hub.hits == []
    assert lines(capsys)[0]["message"] == arch.NEEDS_APPLE_SILICON and modelos.read(folder).instalados == ()


def test_pull_refuses_when_the_disk_has_no_room_before_downloading(folder, capsys, monkeypatch):
    monkeypatch.setattr(fetch.storage, "free_bytes", lambda path: 6_000_000_000)
    with FakeHub("x/y", "b" * 40, {}) as hub:
        assert wisp_cli.main(["local", "pull", "qwen3:8b"]) == 1
        assert hub.hits == []
    assert "falta espaço" in lines(capsys)[0]["message"]
    assert modelos.read(folder).instalados == ()


def test_use_needs_an_installed_model_and_chat_records_the_turn(folder, capsys, monkeypatch):
    assert wisp_cli.main(["local", "use", "qwen3:8b"]) == 1
    capsys.readouterr()
    install_model(folder, "qwen3:8b")
    modelos.write(folder, modelos.LocalState("", ("qwen3:8b",)))
    with FakeLLM([reply("oi!")]) as fake:
        monkeypatch.setenv("WISP_MLX_URL", fake.url)
        assert wisp_cli.main(["local", "use", "qwen3:8b"]) == 0
        assert modelos.read(folder).ativo == "qwen3:8b"
        capsys.readouterr()
        assert wisp_cli.main(["local", "chat", "--message", "olá", "--conversation", "conv-1", "--surface", "telegram"]) == 0
    out = lines(capsys)
    assert out[-1]["type"] == "result" and out[-1]["result"] == "oi!"
    assert fake.chats()[0]["model"] == str(fetch.model_dir(folder, "qwen3:8b"))
    kinds = [json.loads(l)["kind"] for l in (folder / "conversas/conv-1.jsonl").read_text().splitlines()]
    assert kinds == ["session", "user", "assistant"]


def test_chat_without_an_active_model_is_one_error_line(folder, capsys, monkeypatch):
    with FakeLLM() as fake:
        monkeypatch.setenv("WISP_MLX_URL", fake.url)
        assert wisp_cli.main(["local", "chat", "--message", "oi"]) == 1
    assert "Ajustes > Modelo" in lines(capsys)[0]["message"]


def test_stdio_approvals_leave_stdin_to_the_host_so_the_message_cannot_come_from_it(folder, capsys):
    assert wisp_cli.main(["local", "chat", "--message", "-", "--approvals", "stdio"]) == 1
    assert "--approvals stdio" in lines(capsys)[-1]["message"]


def test_the_backend_command_points_the_engine_at_any_openai_server_and_back(folder, capsys):
    assert wisp_cli.main(["local", "backend", "openai", "--url", "http://127.0.0.1:1234", "--model", "qwen2.5-7b"]) == 0
    assert modelos.read(folder) == modelos.LocalState("qwen2.5-7b", (), "openai", "http://127.0.0.1:1234")
    assert wisp_cli.main(["local", "backend", "mlx"]) == 0
    assert modelos.read(folder) == modelos.LocalState("", (), "mlx", "")
    capsys.readouterr()
    for bad in (["--url", "ftp://x", "--model", "m"], ["--url", 'http://x"y', "--model", "m"], ["--url", "http://x", "--model", 'a"b']):
        assert wisp_cli.main(["local", "backend", "openai", *bad]) == 1
    assert modelos.read(folder).backend == "mlx"


def test_an_openai_backend_runs_a_chat_with_the_model_name_as_given(folder, capsys, monkeypatch):
    with FakeLLM([reply("do servidor")], tags={"qwen2.5-7b": 1}) as fake:
        assert wisp_cli.main(["local", "backend", "openai", "--url", fake.url, "--model", "qwen2.5-7b"]) == 0
        capsys.readouterr()
        assert wisp_cli.main(["local", "chat", "--message", "oi"]) == 0
        assert wisp_cli.main(["local", "catalog"]) == 0
    assert fake.chats()[0]["model"] == "qwen2.5-7b" and lines(capsys)[-1]["backend"]["kind"] == "openai"


def test_c1_and_bidi_characters_in_model_text_never_reach_the_terminal_raw(capsys):
    local_cli.emit({"type": "assistant", "text": "a\x9b2J\x85‮\x7fbé"})
    out = capsys.readouterr().out
    assert not [c for c in out.rstrip("\n") if ord(c) < 0x20 or 0x7F <= ord(c) <= 0x9F or c == "‮"]
    assert json.loads(out)["text"] == "a\x9b2J\x85‮\x7fbé"


def test_thinking_is_off_by_default_and_the_command_writes_the_setting_keeping_the_rest(folder, capsys):
    modelos.write(folder, modelos.LocalState("qwen3:8b", ("qwen3:8b",), idle_minutes=20))
    assert modelos.read(folder).pensar is False
    assert wisp_cli.main(["local", "pensar", "on"]) == 0
    assert lines(capsys)[-1] == {"type": "done", "pensar": True}
    assert modelos.read(folder) == modelos.LocalState("qwen3:8b", ("qwen3:8b",), idle_minutes=20, pensar=True)
    assert "pensar = true" in (folder / "modelos.toml").read_text()
    assert wisp_cli.main(["local", "catalog"]) == 0
    assert lines(capsys)[-1]["pensar"] is True
    assert wisp_cli.main(["local", "pensar", "off"]) == 0
    assert modelos.read(folder).pensar is False and "pensar" not in (folder / "modelos.toml").read_text().split("[local]")[1]


def test_a_thinking_value_that_is_not_a_boolean_is_refused(folder):
    (folder / "modelos.toml").write_text('[local]\nativo = ""\npensar = "sim"\n')
    with pytest.raises(modelos.ModelosError, match="pensar"):
        modelos.read(folder)


def test_delete_stops_the_server_of_the_active_model_before_removing_its_folder(folder, capsys, monkeypatch):
    install_model(folder, "qwen3:4b")
    modelos.write(folder, modelos.LocalState("qwen3:4b", ("qwen3:4b",)))
    seen = []
    monkeypatch.setattr(backends, "stop_server", lambda *a: seen.append(fetch.model_dir(folder, "qwen3:4b").exists()))
    assert wisp_cli.main(["local", "delete", "qwen3:4b"]) == 0
    assert seen == [True] and not fetch.model_dir(folder, "qwen3:4b").exists()
    assert modelos.read(folder).ativo == "" and modelos.read(folder).instalados == ()
