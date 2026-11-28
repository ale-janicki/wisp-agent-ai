import json

import pytest

from wisp.meetings_win import settings
from wisp.meetings_win.language import (LanguagePicker, POST_CALL_ENGINES, engine_label, language_label,
                                        refine_language, whisper_code)


def test_defaults_match_the_mac(tmp_path):
    got = settings.read(tmp_path / "settings.json")
    assert got == {"webhookEnabled": False, "webhookSigns": False, "limitMinutes": 120, "autoSummary": True,
                   "language": "pt", "postCallEngine": "whisperLargeV3", "cleanupDays": 0}
    assert settings.limit_seconds(got) == 7200


def test_values_outside_the_choices_fall_back_and_the_limit_is_clamped(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"meetings": {"language": "xx", "postCallEngine": "magic", "limitMinutes": 5,
                                             "cleanupDays": 9000, "autoSummary": "yes"}}))
    got = settings.read(path)
    assert got["language"] == "pt" and got["postCallEngine"] == "whisperLargeV3"
    assert got["autoSummary"] is True and got["cleanupDays"] == 365
    assert settings.limit_seconds(got) == 15 * 60
    assert settings.limit_seconds({"limitMinutes": 9999}) == 720 * 60


def test_a_broken_file_reads_as_defaults(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text("{oops")
    assert settings.read(path)["limitMinutes"] == 120


def test_update_keeps_every_other_key_and_validates(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"theme": "dark", "recordingsPath": "~/R", "meetings": {"autoSummary": False}}))
    settings.update(path, {"language": "en", "cleanupDays": 14, "limitMinutes": 60})
    raw = json.loads(path.read_text())
    assert raw["theme"] == "dark" and raw["recordingsPath"] == "~/R"
    assert raw["meetings"]["autoSummary"] is False and raw["meetings"]["language"] == "en"
    with pytest.raises(ValueError):
        settings.update(path, {"language": "klingon"})
    with pytest.raises(ValueError):
        settings.update(path, {"limitMinutes": 7})
    with pytest.raises(ValueError):
        settings.update(path, {"nope": 1})


def test_recordings_root_is_the_setting_else_the_wisp_folder(tmp_path):
    home = tmp_path / "h"
    assert settings.recordings_root({}, tmp_path / "wisp", home) == tmp_path / "wisp" / "reunioes"
    assert settings.recordings_root({"recordingsPath": " ~/R "}, tmp_path / "wisp", home) == home / "R"
    assert settings.recordings_root({"recordingsPath": "~"}, tmp_path / "wisp", home) == home
    assert settings.recordings_root({"recordingsPath": str(tmp_path / "x")}, tmp_path / "wisp", home) == tmp_path / "x"
    assert settings.recordings_root({"recordingsPath": "  "}, tmp_path / "wisp", home) == tmp_path / "wisp" / "reunioes"


def test_language_codes_and_labels():
    assert whisper_code("pt") == "pt" and whisper_code("auto") is None
    assert language_label("pt") == "Português (BR)" and language_label("auto") == "Detectar"
    assert [e["id"] for e in POST_CALL_ENGINES] == ["whisperLargeV3", "whisperTurbo", "off"]
    assert engine_label("whisperTurbo") == "Whisper turbo (mais rápido)"
    assert engine_label("off") == "Desligado (só o ao vivo)"


def test_a_fixed_language_is_never_detected():
    picker = LanguagePicker("pt")
    assert picker.code() == "pt"
    picker.observe("en", 0.99)
    assert picker.code() == "pt"


def test_auto_detects_until_two_confident_segments_agree_and_then_locks():
    picker = LanguagePicker("auto")
    assert picker.code() is None
    picker.observe("en", 0.9)
    assert picker.code() is None
    picker.observe("pt", 0.5)
    picker.observe("en", 0.95)
    assert picker.code() == "en" and picker.locked == "en"
    picker.observe("pt", 0.99)
    picker.observe("pt", 0.99)
    assert picker.code() == "en"


def test_the_refine_language_prefers_the_setting_then_what_live_locked():
    assert refine_language("es", "auto") == "es"
    assert refine_language("auto", "en") == "en"
    assert refine_language("auto", "auto") is None
    assert refine_language("auto", None) is None
