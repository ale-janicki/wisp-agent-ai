from wisp_bot import bot as _bot


def test_bloco_uses_configured_user_name(monkeypatch):
    monkeypatch.setattr(_bot, "_QUEM", "o Rafa")
    assert _bot.bloco_anexos("Telegram", ["- x"], "").startswith("[o Rafa enviou 1 arquivo(s) pelo Telegram")
