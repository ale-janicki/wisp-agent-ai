import json

from wisp.config import TelegramConfig, WispConfig, load_config, save_config


def test_missing_file_is_default(fake_home):
    assert load_config() == WispConfig()


def test_round_trip_with_telegram(fake_home):
    cfg = WispConfig(
        user_name="Bia",
        brain="~/Wisp/brain",
        telegram=TelegramConfig(chat_id=-100, user_id=7, token_file="~/t", pair={"a": "b"}),
    )
    save_config(cfg)
    assert load_config() == cfg


def test_unknown_keys_ignored(fake_home):
    path = fake_home / ".config/wisp/wisp.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"user_name": "A", "future": 1, "telegram": {"chat_id": 1, "user_id": 2, "token_file": "t", "x": 3}}))
    cfg = load_config()
    assert cfg.user_name == "A"
    assert cfg.telegram == TelegramConfig(chat_id=1, user_id=2, token_file="t")


def test_persona_lives_only_at_top_level(fake_home):
    # the bot reads only the top-level persona: a telegram copy would always say the default
    save_config(WispConfig(persona="Luna", telegram=TelegramConfig(chat_id=1, user_id=2, token_file="t")))
    raw = json.loads((fake_home / ".config/wisp/wisp.json").read_text())
    assert raw["persona"] == "Luna" and "persona" not in raw["telegram"]
