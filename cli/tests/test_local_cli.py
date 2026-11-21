import json
import shutil
from pathlib import Path

import pytest
from local_fakes import FakeOllama, reply

from wisp import cli as wisp_cli
from wisp.config import WispConfig, save_config
from wisp.local import guardrails, modelos, ollama
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


def test_catalog_reports_ollama_state_and_what_is_installed(folder, capsys, monkeypatch):
    modelos.write(folder, modelos.LocalState("qwen3:8b", ("qwen3:8b", "qwen3:4b")))
    monkeypatch.setattr(ollama, "find_cli", lambda: Path("/x/ollama"))
    with FakeOllama(tags={"qwen3:8b": 5}) as fake:
        monkeypatch.setenv("WISP_OLLAMA_URL", fake.url)
        assert wisp_cli.main(["local", "catalog"]) == 0
    out = lines(capsys)[0]
    assert out["ollama"] == {"installed": True, "running": True}
    assert out["installed"] == ["qwen3:8b"] and out["active"] == "qwen3:8b" and len(out["models"]) >= 4


def test_pull_refuses_when_the_disk_has_no_room_before_touching_ollama(folder, capsys, monkeypatch):
    monkeypatch.setattr(ollama, "free_bytes", lambda path: 6_000_000_000)
    with FakeOllama() as fake:
        monkeypatch.setenv("WISP_OLLAMA_URL", fake.url)
        assert wisp_cli.main(["local", "pull", "qwen3:8b"]) == 1
        assert fake.requests == []
    assert "falta espaço" in lines(capsys)[0]["message"]
    assert modelos.read(folder).instalados == ()


def test_pull_streams_progress_and_records_the_install(folder, capsys, monkeypatch):
    monkeypatch.setattr(ollama, "free_bytes", lambda path: 100_000_000_000)
    chunks = [{"status": "downloading", "completed": 1, "total": 2}, {"status": "success"}]
    with FakeOllama(pull=chunks) as fake:
        monkeypatch.setenv("WISP_OLLAMA_URL", fake.url)
        assert wisp_cli.main(["local", "pull", "qwen3:8b"]) == 0
        assert wisp_cli.main(["local", "pull", "llama3.2:3b"]) == 1
    out = lines(capsys)
    assert [o["type"] for o in out] == ["progress", "progress", "done", "error"] and out[0]["completed"] == 1
    assert modelos.read(folder).instalados == ("qwen3:8b",)


def test_use_needs_an_installed_model_and_chat_records_the_turn(folder, capsys, monkeypatch):
    assert wisp_cli.main(["local", "use", "qwen3:8b"]) == 1
    capsys.readouterr()
    modelos.write(folder, modelos.LocalState("", ("qwen3:8b",)))
    with FakeOllama([reply("oi!")], tags={"qwen3:8b": 5}) as fake:
        monkeypatch.setenv("WISP_OLLAMA_URL", fake.url)
        assert wisp_cli.main(["local", "use", "qwen3:8b"]) == 0
        assert modelos.read(folder).ativo == "qwen3:8b"
        capsys.readouterr()
        assert wisp_cli.main(["local", "chat", "--message", "olá", "--conversation", "conv-1", "--surface", "telegram"]) == 0
    out = lines(capsys)
    assert out[-1]["type"] == "result" and out[-1]["result"] == "oi!"
    kinds = [json.loads(l)["kind"] for l in (folder / "conversas/conv-1.jsonl").read_text().splitlines()]
    assert kinds == ["session", "user", "assistant"]


def test_chat_without_an_active_model_is_one_error_line(folder, capsys):
    assert wisp_cli.main(["local", "chat", "--message", "oi"]) == 1
    assert "Ajustes > Modelo" in lines(capsys)[0]["message"]


def test_stdio_approvals_leave_stdin_to_the_host_so_the_message_cannot_come_from_it(folder, capsys):
    assert wisp_cli.main(["local", "chat", "--message", "-", "--approvals", "stdio"]) == 1
    assert "--approvals stdio" in lines(capsys)[-1]["message"]


def test_a_pull_that_does_not_end_in_success_installs_nothing(folder, capsys, monkeypatch):
    monkeypatch.setattr(ollama, "free_bytes", lambda path: 100_000_000_000)
    with FakeOllama(pull=[{"status": "pulling manifest"}, {"status": "downloading", "completed": 1, "total": 2}]) as fake:
        monkeypatch.setenv("WISP_OLLAMA_URL", fake.url)
        assert wisp_cli.main(["local", "pull", "qwen3:8b"]) == 1
    assert "não terminou" in lines(capsys)[-1]["message"]
    assert modelos.read(folder).instalados == ()


def test_a_pull_stops_when_the_disk_falls_under_the_margin(folder, capsys, monkeypatch):
    free = iter([100_000_000_000, 4_000_000_000, 4_000_000_000, 4_000_000_000])
    monkeypatch.setattr(ollama, "free_bytes", lambda path: next(free))
    monkeypatch.setattr(local_cli, "DISK_CHECK_INTERVAL", 0)
    chunks = [{"status": "downloading", "completed": n, "total": 9} for n in (1, 2, 3)] + [{"status": "success"}]
    with FakeOllama(pull=chunks) as fake:
        monkeypatch.setenv("WISP_OLLAMA_URL", fake.url)
        assert wisp_cli.main(["local", "pull", "qwen3:8b"]) == 1
    out = lines(capsys)
    assert "abaixo da folga" in out[-1]["message"] and [o["type"] for o in out].count("progress") == 1
    assert modelos.read(folder).instalados == ()


def test_c1_and_bidi_characters_in_model_text_never_reach_the_terminal_raw(capsys):
    local_cli.emit({"type": "assistant", "text": "a\x9b2J\x85‮\x7fbé"})
    out = capsys.readouterr().out
    assert not [c for c in out.rstrip("\n") if ord(c) < 0x20 or 0x7F <= ord(c) <= 0x9F or c == "‮"]
    assert json.loads(out)["text"] == "a\x9b2J\x85‮\x7fbé"
