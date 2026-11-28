from __future__ import annotations

LANGUAGES = ("pt", "en", "es", "auto")
LANGUAGE_LABELS = {"pt": "Português (BR)", "en": "English", "es": "Español", "auto": "Detectar"}
POST_CALL_ENGINES = (
    {"id": "whisperLargeV3", "label": "Whisper large-v3 (recomendado)", "model": "large-v3", "engine_name": "whisper-large-v3"},
    {"id": "whisperTurbo", "label": "Whisper turbo (mais rápido)", "model": "large-v3-turbo", "engine_name": "whisper-large-v3-turbo"},
    {"id": "off", "label": "Desligado (só o ao vivo)", "model": None, "engine_name": "off"},
)
LIVE_MODEL = "small"
LIVE_ENGINE_NAME = "whisper-small"
CONFIDENT = 0.6
VOTES_TO_LOCK = 2


def whisper_code(language: str) -> str | None:
    return None if language == "auto" else language


def language_label(language: str) -> str:
    return LANGUAGE_LABELS.get(language, language)


def engine_of(engine_id: str) -> dict:
    return next((e for e in POST_CALL_ENGINES if e["id"] == engine_id), POST_CALL_ENGINES[0])


def engine_label(engine_id: str) -> str:
    return engine_of(engine_id)["label"]


def refine_language(setting: str, document_language: str | None) -> str | None:
    if setting != "auto":
        return setting
    return document_language if document_language and document_language != "auto" else None


class LanguagePicker:
    def __init__(self, setting: str):
        self._setting = setting if setting in LANGUAGES else "pt"
        self.locked: str | None = None
        self._votes: dict[str, int] = {}

    def code(self) -> str | None:
        if self._setting != "auto":
            return self._setting
        return self.locked

    def observe(self, detected: str | None, probability: float | None) -> None:
        if self._setting != "auto" or self.locked or not detected or (probability or 0) < CONFIDENT:
            return
        self._votes[detected] = self._votes.get(detected, 0) + 1
        if self._votes[detected] >= VOTES_TO_LOCK:
            self.locked = detected
