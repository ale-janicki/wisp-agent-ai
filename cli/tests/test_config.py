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
    save_config(WispConfig(persona="Luna", telegram=TelegramConfig(chat_id=1, user_id=2, token_file="t")))
    raw = json.loads((fake_home / ".config/wisp/wisp.json").read_text())
    assert raw["persona"] == "Luna" and "persona" not in raw["telegram"]


def test_brain_learn_defaults_on_and_round_trips(fake_home):
    assert WispConfig().brain_learn is True
    save_config(WispConfig(brain_learn=False))
    assert load_config().brain_learn is False
    assert json.loads((fake_home / ".config/wisp/wisp.json").read_text())["brain_learn"] is False


def test_recall_tokens_defaults_to_six_thousand_and_round_trips(fake_home):
    assert WispConfig().recall_tokens == 6000
    save_config(WispConfig(recall_tokens=9000))
    assert load_config().recall_tokens == 9000


def test_brain_log_markers_default_and_round_trip(fake_home):
    assert WispConfig().brain_log_markers == ["sessions", "daily", "digest", "session", "log"]
    save_config(WispConfig(brain_log_markers=["atas"]))
    assert load_config().brain_log_markers == ["atas"]


def test_invalid_recall_tokens_and_markers_fall_back_to_defaults(fake_home, caplog):
    default = WispConfig()
    for bad in ("6000", -1, 1.5, True, None):
        raw = {"recall_tokens": bad, "brain_log_markers": ["ok", 3]}
        path = fake_home / "wisp.json"
        path.write_text(json.dumps(raw))
        with caplog.at_level("WARNING"):
            cfg = load_config(path)
        assert cfg.recall_tokens == default.recall_tokens
        assert cfg.brain_log_markers == default.brain_log_markers
    assert "recall_tokens" in caplog.text and "brain_log_markers" in caplog.text
    path.write_text(json.dumps({"recall_tokens": 0, "brain_log_markers": ["atas"]}))
    cfg = load_config(path)
    assert cfg.recall_tokens == 0 and cfg.brain_log_markers == ["atas"]
