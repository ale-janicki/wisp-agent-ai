import asyncio
import json
import time
import types
from datetime import timedelta
from pathlib import Path

import pytest
from telegram.error import BadRequest, RetryAfter

from wisp_bot import bot as _bot, claude_runner


class Bot:
    def __init__(self, falhas=None):
        self.eventos, self.falhas = [], list(falhas or [])

    def _falha(self):
        if self.falhas:
            raise self.falhas.pop(0)

    async def send_photo(self, chat_id, f, message_thread_id=None, caption=None, **k):
        self._falha()
        self.eventos.append(("foto", Path(f.name).name, message_thread_id, caption))

    async def send_document(self, chat_id, f, filename=None, message_thread_id=None, caption=None, **k):
        self._falha()
        self.eventos.append(("doc", filename, message_thread_id, caption))

    async def send_message(self, chat_id, text, **kw):
        self.eventos.append(("msg", text))


@pytest.fixture
def casa(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
    cfg = tmp_path / "wisp.json"
    token = tmp_path / "secrets" / "token"
    token.parent.mkdir()
    token.write_text("123:abc")
    cfg.write_text(json.dumps({"telegram": {"token_file": str(token)}}))
    monkeypatch.setattr(_bot, "config_path", lambda: cfg)
    monkeypatch.setattr(_bot, "_key_da_thread", lambda t: f"-100:{t}")
    return types.SimpleNamespace(home=home, token=token, tmp=tmp_path)


def _ctl(op, bot, monkeypatch):
    feitos = {}
    monkeypatch.setattr(_bot.ctl, "gravar_done", lambda id_, res: feitos.update({id_: res}))
    asyncio.run(_bot.ctl_executar(types.SimpleNamespace(bot=bot), {"id": "e1", "at": time.time(), **op}, "local"))
    return feitos["e1"]


def _arq(dir_, nome, n=3):
    p = dir_ / nome
    p.write_bytes(b"x" * n)
    return p


def test_enviar_routes_photo_vs_document_and_caption_only_on_first(casa, monkeypatch):
    a, b, c = _arq(casa.tmp, "a.png"), _arq(casa.tmp, "b.pdf"), _arq(casa.tmp, "c.jpg")
    bot = Bot()
    res = _ctl({"op": "enviar", "thread": 7, "arquivos": [str(a), str(b), str(c)], "legenda": "olha"}, bot, monkeypatch)
    assert res == {"ok": True, "enviados": 3}
    assert bot.eventos == [("foto", "a.png", 7, "olha"), ("doc", "b.pdf", 7, None), ("foto", "c.jpg", 7, None)]


def test_enviar_big_photo_goes_as_document(casa, monkeypatch):
    monkeypatch.setattr(_bot, "ANEXO_FOTO_MAX_BYTES", 2)
    a = _arq(casa.tmp, "a.png", 5)
    bot = Bot()
    assert _ctl({"op": "enviar", "thread": 7, "arquivos": [str(a)]}, bot, monkeypatch)["ok"]
    assert bot.eventos == [("doc", "a.png", 7, None)]


def test_enviar_photo_refused_by_telegram_falls_back_to_document(casa, monkeypatch):
    a = _arq(casa.tmp, "a.png")
    bot = Bot([BadRequest("Photo_invalid_dimensions")])
    assert _ctl({"op": "enviar", "thread": 7, "arquivos": [str(a)], "legenda": "x"}, bot, monkeypatch)["ok"]
    assert bot.eventos == [("doc", "a.png", 7, "x")]


def test_enviar_retries_once_on_retry_after_then_gives_up(casa, monkeypatch):
    esperas = []

    async def dormir(s):
        esperas.append(s)
    monkeypatch.setattr(_bot.asyncio, "sleep", dormir)
    a = _arq(casa.tmp, "a.pdf")
    bot = Bot([RetryAfter(timedelta(seconds=4))])
    assert _ctl({"op": "enviar", "thread": 7, "arquivos": [str(a)]}, bot, monkeypatch) == {"ok": True, "enviados": 1}
    assert esperas == [4.0] and bot.eventos == [("doc", "a.pdf", 7, None)]
    _bot._enviados_recentes.clear()
    bot = Bot([RetryAfter(1), RetryAfter(1)])
    res = _ctl({"op": "enviar", "thread": 7, "arquivos": [str(a)]}, bot, monkeypatch)
    assert res["ok"] is False and bot.eventos == []


def test_enviar_refuses_before_posting_anything(casa, monkeypatch):
    ok = _arq(casa.tmp, "ok.png")
    (casa.home / ".ssh").mkdir()
    chave = _arq(casa.home / ".ssh", "id_ed25519")
    elo = casa.tmp / "elo.txt"
    elo.symlink_to(casa.token)
    pasta = casa.tmp / "pasta"
    pasta.mkdir()
    for ruim in (str(chave), str(casa.token), str(elo), str(pasta), "rel.txt", str(casa.tmp / "nao-existe")):
        bot = Bot()
        res = _ctl({"op": "enviar", "thread": 7, "arquivos": [str(ok), ruim]}, bot, monkeypatch)
        assert res["ok"] is False and "\n" not in res["erro"], ruim
        assert bot.eventos == [], ruim


def test_enviar_refuses_too_big_too_many_and_empty(casa, monkeypatch):
    monkeypatch.setattr(_bot, "ANEXO_MAX_BYTES", 4)
    grande = _arq(casa.tmp, "g.bin", 5)
    bot = Bot()
    res = _ctl({"op": "enviar", "thread": 7, "arquivos": [str(grande)]}, bot, monkeypatch)
    assert res["ok"] is False and "MB" in res["erro"]
    ok = _arq(casa.tmp, "ok.txt")
    for lista in ([str(ok)] * 11, [], None, "x"):
        assert _ctl({"op": "enviar", "thread": 7, "arquivos": lista}, bot, monkeypatch)["ok"] is False
    assert bot.eventos == []


def test_enviar_geral_posts_without_a_thread(casa, monkeypatch):
    a = _arq(casa.tmp, "a.pdf")
    bot = Bot()
    assert _ctl({"op": "enviar", "thread": 0, "arquivos": [str(a)]}, bot, monkeypatch)["ok"]
    assert bot.eventos == [("doc", "a.pdf", None, None)]


def test_postar_with_arquivos_posts_them_after_the_user_line(casa, monkeypatch):
    a = _arq(casa.tmp, "a.png")
    bot = Bot()
    op = {"op": "postar", "thread": "9", "user": "oi", "reply": "ola", "arquivos": [str(a)]}
    assert _ctl(op, bot, monkeypatch)["ok"]
    assert [e[0] for e in bot.eventos] == ["msg", "foto", "msg"]
    assert bot.eventos[0][1] == "💻 oi" and bot.eventos[1][1:] == ("a.png", 9, None)


def test_postar_with_a_bad_file_posts_nothing(casa, monkeypatch):
    bot = Bot()
    op = {"op": "postar", "thread": "9", "user": "oi", "reply": "ola", "arquivos": ["rel.txt"]}
    assert _ctl(op, bot, monkeypatch)["ok"] is False and bot.eventos == []


def test_claude_child_gets_thread_bin_and_the_instruction(monkeypatch, tmp_path):
    visto = {}

    class Proc:
        def __init__(self):
            self.stdin = types.SimpleNamespace(write=lambda b: None, drain=self._nada, close=lambda: None)
            self.stdout = self._vazio()
            self.stderr = types.SimpleNamespace(read=self._bytes)
            self.returncode = 0

        async def _nada(self):
            pass

        async def _bytes(self):
            return b""

        async def wait(self):
            return 0

        async def _vazio(self):
            return
            yield

    async def fake_exec(*cmd, **kw):
        visto["cmd"], visto["env"] = cmd, kw["env"]
        return Proc()
    monkeypatch.setattr(claude_runner.asyncio, "create_subprocess_exec", fake_exec)
    asyncio.run(claude_runner.run("oi", session_id="s", cwd=str(tmp_path), started=False,
                                  env={"WISP_TOPIC_THREAD": "7"}))
    assert visto["env"]["WISP_TOPIC_THREAD"] == "7"
    assert visto["env"]["WISP_BIN"] == str(Path(claude_runner.sys.executable).parent / "wisp")
    prompt = visto["cmd"][visto["cmd"].index("--append-system-prompt") + 1]
    assert '"$WISP_BIN" topic enviar --thread="$WISP_TOPIC_THREAD"' in prompt


def test_the_bot_turn_always_hands_the_thread_to_claude():
    src = Path(_bot.__file__).read_text()
    assert 'env["WISP_TOPIC_THREAD"] = str(thread_id or 0)' in src


def test_caption_markdown_goes_as_telegram_html(casa, monkeypatch):
    a = _arq(casa.tmp, "a.pdf")
    capturas = []

    class B(Bot):
        async def send_document(self, chat_id, f, filename=None, message_thread_id=None, caption=None, **k):
            capturas.append((caption, k.get("parse_mode")))
    assert _ctl({"op": "enviar", "thread": 7, "arquivos": [str(a)], "legenda": "**pronto** `x<y`"}, B(), monkeypatch)["ok"]
    assert capturas == [("<b>pronto</b> <code>x&lt;y</code>", "HTML")]


def test_caption_html_refused_by_telegram_goes_as_plain_text(casa, monkeypatch):
    a = _arq(casa.tmp, "a.pdf")
    capturas = []

    class B(Bot):
        async def send_document(self, chat_id, f, filename=None, message_thread_id=None, caption=None, **k):
            capturas.append((caption, k.get("parse_mode")))
            if k.get("parse_mode"):
                raise BadRequest("Can't parse entities")
    assert _ctl({"op": "enviar", "thread": 7, "arquivos": [str(a)], "legenda": "**pronto**"}, B(), monkeypatch)["ok"]
    assert capturas == [("<b>pronto</b>", "HTML"), ("pronto", None)]


def test_postar_mirror_reply_markdown_is_converted(casa, monkeypatch):
    bot = Bot()
    res = _ctl({"op": "postar", "thread": 9, "user": "oi", "reply": "**feito**: [doc](https://x.dev) `a`"}, bot, monkeypatch)
    assert res["ok"]
    textos = [e[1] for e in bot.eventos if e[0] == "msg"]
    assert textos[-1] == '<b>feito</b>: <a href="https://x.dev">doc</a> <code>a</code>'
