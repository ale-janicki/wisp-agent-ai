"""ctl `falar` with attachments: validation before anything is posted, then banner + files + turn."""
import asyncio
import time
import types

import pytest

from wisp_bot import bot as _bot


@pytest.fixture
def anexos(tmp_path, monkeypatch):
    root = tmp_path / "anexos"
    (root / "d").mkdir(parents=True)
    monkeypatch.setattr(_bot, "ANEXOS_DIR", root)
    return root / "d"


def test_validos_returns_resolved_real_paths(anexos, tmp_path):
    real = anexos / "a.png"
    real.write_bytes(b"12345")
    link = anexos / "link.png"
    link.symlink_to(real)
    assert _bot.anexos_validos([str(link)]) == [(real.resolve(), 5)]


def test_validos_refuses_outside_relative_symlink_escape_and_too_many(anexos, tmp_path):
    outside = tmp_path / "secret.txt"
    outside.write_text("x")
    (anexos / "esc.txt").symlink_to(outside)
    for bad in (str(outside), "rel.txt", str(anexos / "esc.txt"), str(anexos), str(anexos / "missing")):
        with pytest.raises(ValueError):
            _bot.anexos_validos([bad])
    ok = anexos / "ok.txt"
    ok.write_text("x")
    with pytest.raises(ValueError):
        _bot.anexos_validos([str(ok)] * 11)


def _run(op, monkeypatch):
    monkeypatch.setattr(_bot, "_key_da_thread", lambda thread: f"-1:{thread}")
    eventos, feitos = [], {}

    async def send(bot, chat, tid, texto):
        eventos.append(("banner", texto))

    async def postar(bot, chat_id, tid, p):
        eventos.append(("anexo", p.name))

    async def turno(bot, chat, tid, key, texto, contexto=""):
        eventos.append(("turno", texto))
    monkeypatch.setattr(_bot, "send", send)
    monkeypatch.setattr(_bot, "_postar_anexo", postar)
    monkeypatch.setattr(_bot, "turno", turno)
    monkeypatch.setattr(_bot.ctl, "gravar_done", lambda id_, res: feitos.update({id_: res}))

    async def cenario():
        await _bot.ctl_executar(types.SimpleNamespace(bot=None), {"id": "g", "op": "falar", "thread": "7",
                                                                  "at": time.time(), **op}, "local")
        await asyncio.sleep(0)
    asyncio.run(cenario())
    return eventos, feitos["g"]


def test_falar_with_attachment_posts_banner_file_and_prompt_block(anexos, monkeypatch):
    f = anexos / "a.png"
    f.write_bytes(b"123")
    eventos, res = _run({"texto": "olha", "anexos": [str(f)]}, monkeypatch)
    assert res["ok"] is True
    assert [e[0] for e in eventos] == ["banner", "anexo", "turno"]
    assert eventos[2][1] == (f"[o usuario enviou 1 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n"
                             f"- {f.resolve()} (a.png, 3 bytes)]\n\nolha")


def test_falar_only_attachment_uses_default_text(anexos, monkeypatch):
    f = anexos / "a.txt"
    f.write_text("x")
    eventos, res = _run({"anexos": [str(f)]}, monkeypatch)
    assert res["ok"] and eventos[2][1].endswith("\n\n(sem texto — veja o que é e me diga)")


def test_falar_one_bad_attachment_posts_nothing(anexos, monkeypatch):
    f = anexos / "a.png"
    f.write_bytes(b"1")
    eventos, res = _run({"texto": "x", "anexos": [str(f), "/etc/passwd"]}, monkeypatch)
    assert eventos == [] and res["ok"] is False and "\n" not in res["erro"]


def test_bloco_uses_configured_user_name(monkeypatch):
    monkeypatch.setattr(_bot, "_QUEM", "o Rafa")
    assert _bot.bloco_anexos("Telegram", ["- x"], "").startswith("[o Rafa enviou 1 arquivo(s) pelo Telegram")


def test_postar_anexo_opens_resolved_path_as_photo_then_document(anexos):
    f = anexos / "a.heic"
    f.write_bytes(b"1")
    sent = []

    class Bot:
        async def send_document(self, chat_id, fh, filename, message_thread_id, **k):
            sent.append(("doc", filename))
    asyncio.run(_bot._postar_anexo(Bot(), 1, None, f))
    assert sent == [("doc", "a.heic")]
