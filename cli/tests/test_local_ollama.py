import os
import shutil
import signal
import subprocess
import zipfile
from pathlib import Path

import pytest
from local_fakes import FakeOllama, reply

from wisp.local import ollama
from wisp.local.ollama import OllamaClient, OllamaError


def test_chat_joins_the_streamed_chunks_and_reads_tool_calls():
    call = {"function": {"name": "read_file", "arguments": {"path": "a"}}}
    with FakeOllama([reply("olá mundo", [call], thinking="hmm")]) as fake:
        out = fake.client().chat("qwen3:8b", [{"role": "user", "content": "oi"}], [], {"num_ctx": 8192})
    assert out.content == "olá mundo" and out.thinking == "hmm" and out.tool_calls == [call]
    assert (out.prompt_tokens, out.reply_tokens) == (11, 7)
    sent = fake.chats()[0]
    assert sent["model"] == "qwen3:8b" and sent["stream"] is True and sent["options"] == {"num_ctx": 8192}


def test_tags_and_running():
    with FakeOllama(tags={"qwen3:8b": 5}) as fake:
        assert fake.client().running() and fake.client().tags() == {"qwen3:8b": 5}
    assert not OllamaClient("http://127.0.0.1:9").running()


def test_a_server_error_and_a_dead_server_become_one_sentence():
    with FakeOllama(status=500) as fake, pytest.raises(OllamaError, match="500"):
        fake.client().chat("m", [], [], {})
    with pytest.raises(OllamaError, match="não consegui falar"):
        OllamaClient("http://127.0.0.1:9").chat("m", [], [], {})
    with FakeOllama([]) as fake, pytest.raises(OllamaError, match="o Ollama falhou"):
        fake.client().chat("m", [], [], {})
    with pytest.raises(OllamaError, match="inválido"):
        OllamaClient("ftp://x")


def test_pull_streams_progress():
    chunks = [{"status": "pulling manifest"}, {"status": "downloading", "completed": 5, "total": 10}, {"status": "success"}]
    with FakeOllama(pull=chunks) as fake:
        assert list(fake.client().pull("qwen3:8b")) == chunks
        assert fake.requests[0]["model"] == "qwen3:8b"


def test_ensure_running_is_a_noop_when_up_and_explains_when_nothing_is_installed(monkeypatch):
    with FakeOllama() as fake:
        fake.client().ensure_running()
    monkeypatch.setattr(ollama, "find_cli", lambda: None)
    with pytest.raises(OllamaError, match="não está instalado"):
        OllamaClient("http://127.0.0.1:9").ensure_running()


def test_room_problem_needs_size_plus_margin():
    assert ollama.room_problem(5_000, 10_000, 5_000) is None
    assert "faltam" in ollama.room_problem(5_000, 9_999_000_000 // 1_000_000, 5_000)
    assert ollama.room_problem(5_200_000_000, 9_000_000_000, 5_000_000_000) is not None


def make_zip(path: Path) -> None:
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Ollama.app/Contents/Resources/ollama", "#!/bin/sh\n")


def stub(failing: str | None = None, seen: list | None = None):
    def run(argv, **kw):
        if argv[0].endswith("ditto"):
            return subprocess.run(argv, **kw)
        if seen is not None:
            seen.append(argv)
        bad = failing is not None and any(failing in part for part in argv)
        return subprocess.CompletedProcess(argv, 1 if bad else 0, "", "")
    return run


def test_install_downloads_unpacks_verifies_the_pinned_identity_and_cleans_up(fake_home):
    source = fake_home / "src.zip"
    make_zip(source)
    root = fake_home / "ollama"
    events: list[dict] = []
    seen: list[list[str]] = []
    cli = ollama.install(events.append, url=source.as_uri(), root=root, margin=0, run=stub(seen=seen))
    assert cli == root / ollama.CLI_IN_APP and cli.is_file()
    assert [e["status"] for e in events][0] == "downloading" and {"unpacking", "verifying"} <= {e["status"] for e in events}
    assert any(e.get("completed") == e.get("total") > 0 for e in events)
    assert not (root / ".download").exists()
    codesign = next(a for a in seen if a[0].endswith("codesign"))
    assert f'certificate leaf[subject.OU] = "{ollama.TEAM_ID}"' in codesign[-2] and "anchor apple generic" in codesign[-2]
    assert any(a[0].endswith("spctl") for a in seen) and any("stapler" in a for a in seen)


@pytest.mark.parametrize("failing, message", [("codesign", "não é da Ollama"), ("stapler", "notarização"), ("spctl", "não aceitou")])
def test_install_refuses_when_any_identity_check_fails_and_removes_the_app(fake_home, failing, message):
    source = fake_home / "src.zip"
    make_zip(source)
    root = fake_home / "ollama"
    with pytest.raises(OllamaError, match=message):
        ollama.install(lambda e: None, url=source.as_uri(), root=root, margin=0, run=stub(failing))
    assert not (root / "Ollama.app").exists() and not (root / ".download").exists()


def test_the_real_codesign_refuses_a_bundle_signed_by_another_identity(fake_home):
    app = fake_home / "Other.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>x</string>'
        '<key>CFBundleIdentifier</key><string>com.example.x</string></dict></plist>')
    shutil.copy("/bin/echo", app / "Contents/MacOS/x")
    signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], capture_output=True, text=True)
    assert signed.returncode == 0, signed.stderr
    assert ollama.verify_app(app, subprocess.run) == "a assinatura não é da Ollama"


def test_install_refuses_a_download_without_a_declared_size_or_over_the_cap(fake_home, monkeypatch):
    source = fake_home / "src.zip"
    make_zip(source)

    class NoLength:
        headers: dict = {}

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self, n):
            return b"x"

    monkeypatch.setattr(ollama.urllib.request, "urlopen", lambda url, timeout: NoLength())
    with pytest.raises(OllamaError, match="não informou o tamanho"):
        ollama.install(lambda e: None, url="http://x", root=fake_home / "ollama", margin=0, run=stub())
    monkeypatch.undo()
    monkeypatch.setattr(ollama, "MAX_DOWNLOAD", 5)
    with pytest.raises(OllamaError, match="maior que o esperado"):
        ollama.install(lambda e: None, url=source.as_uri(), root=fake_home / "ollama", margin=0, run=stub())


def test_install_stops_a_stream_that_runs_past_its_declared_size(fake_home, monkeypatch):
    class Liar:
        headers = {"Content-Length": "4"}
        sent = 0

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self, n):
            Liar.sent += 1
            return b"xxxx" if Liar.sent < 50 else b""

    monkeypatch.setattr(ollama.urllib.request, "urlopen", lambda url, timeout: Liar())
    with pytest.raises(OllamaError, match="passou do tamanho"):
        ollama.install(lambda e: None, url="http://x", root=fake_home / "ollama", margin=0, run=stub())
    assert Liar.sent == 2


def test_install_refuses_when_the_disk_has_no_room(fake_home):
    source = fake_home / "src.zip"
    make_zip(source)
    with pytest.raises(OllamaError, match="falta espaço"):
        ollama.install(lambda e: None, url=source.as_uri(), root=fake_home / "ollama", margin=10**18, run=stub())
    assert not (fake_home / "ollama" / "Ollama.app").exists()


def test_a_leftover_partial_download_is_cleared_at_the_start_of_the_next_install(fake_home):
    root = fake_home / "ollama"
    (root / ".download").mkdir(parents=True)
    (root / ".download" / "old.zip").write_text("half")
    source = fake_home / "src.zip"
    make_zip(source)
    seen_old = []

    def run(argv, **kw):
        seen_old.append((root / ".download" / "old.zip").exists())
        return stub()(argv, **kw)

    ollama.install(lambda e: None, url=source.as_uri(), root=root, margin=0, run=run)
    assert seen_old and not any(seen_old)


def test_a_sigterm_during_install_removes_the_partial_download(fake_home):
    source = fake_home / "src.zip"
    make_zip(source)
    root = fake_home / "ollama"

    def run(argv, **kw):
        os.kill(os.getpid(), signal.SIGTERM)
        return subprocess.CompletedProcess(argv, 0, "", "")

    before = signal.getsignal(signal.SIGTERM)
    with pytest.raises(SystemExit):
        ollama.install(lambda e: None, url=source.as_uri(), root=root, margin=0, run=run)
    assert not (root / ".download").exists() and signal.getsignal(signal.SIGTERM) == before


def test_a_serve_that_exits_at_once_is_reaped_and_reported(fake_home):
    script = fake_home / "ollama"
    script.write_text("#!/bin/sh\nexit 3\n")
    script.chmod(0o755)
    with pytest.raises(OllamaError, match="encerrou ao iniciar \\(código 3\\)"):
        OllamaClient("http://127.0.0.1:9").ensure_running(script, wait=10)
    with pytest.raises(ChildProcessError):
        os.waitpid(-1, os.WNOHANG)
