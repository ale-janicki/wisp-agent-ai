from __future__ import annotations

import math
import unicodedata

from wisp.meetings_win.transcript import RecognizedSpan

SILENCE_RMS = 0.004
REPEAT_LIMIT = 3
PHRASE_SLACK = 30
LOOP_LIMIT = 4
LOOP_WORDS = 4
ENVELOPE_WINDOW = 0.5

PHRASES = ("legenda por", "legendas pela comunidade", "transcricao e legendas", "se inscreva no canal", "ative o sininho",
           "obrigado por assistir", "a cidade no brasil", "acesse o nosso site", "amara org")
SILENT_ONLY = ("tchau tchau", "obrigado", "obrigada", "aplausos", "e ai", "musica")
NORDIC_LETTERS = set("ðþæøå")
NORDIC_WORDS = {"hvað", "að", "ég", "eftir", "segja", "ekki", "og"}


class ChannelEnvelope:
    def __init__(self, mean_squares: list[float] | None = None):
        self.mean_squares = mean_squares if mean_squares is not None else []

    def rms(self, start: float, end: float) -> float:
        if not self.mean_squares:
            return 0.0
        count = len(self.mean_squares)
        first = min(max(0, int(start / ENVELOPE_WINDOW)), count - 1)
        last = min(max(first, math.ceil(end / ENVELOPE_WINDOW) - 1), count - 1)
        window = self.mean_squares[first:last + 1]
        return math.sqrt(sum(window) / len(window))


def normalized(text: str) -> str:
    folded = "".join(c for c in unicodedata.normalize("NFD", text.lower()) if not unicodedata.combining(c))
    return " ".join("".join(c if c.isalnum() else " " for c in folded).split())


def collapse_loops(text: str) -> str:
    words = text.split()
    keys = [normalized(w) for w in words]
    out: list[str] = []
    index = 0
    while index < len(words):
        collapsed = False
        for size in range(1, LOOP_WORDS + 1):
            reps = 1
            while index + (reps + 1) * size <= len(words) and \
                    keys[index + reps * size:index + (reps + 1) * size] == keys[index:index + size]:
                reps += 1
            if reps >= LOOP_LIMIT and index + size <= len(words):
                out.extend(words[index:index + size])
                index += size * reps
                collapsed = True
                break
        if not collapsed:
            out.append(words[index])
            index += 1
    return " ".join(out)


def is_nordic_gibberish(text: str) -> bool:
    tokens = "".join(c if c.isalpha() else " " for c in text.lower()).split()
    return sum(1 for t in tokens if any(c in NORDIC_LETTERS for c in t) or t in NORDIC_WORDS) >= 2


def _is_invented(span: RecognizedSpan, envelope: ChannelEnvelope, language: str | None) -> bool:
    if language in ("pt", "es") and is_nordic_gibberish(span.text):
        return True
    text = normalized(span.text)
    if not text:
        return True
    if any(phrase in text and len(text) <= len(phrase) + PHRASE_SLACK for phrase in PHRASES):
        return True
    return text in SILENT_ONLY and envelope.rms(span.start, span.end) < SILENCE_RMS


def filter_spans(spans: list[RecognizedSpan], envelope: ChannelEnvelope, language: str | None = "pt"):
    survivors = [RecognizedSpan(collapse_loops(s.text), s.start, s.end, s.confidence)
                 for s in spans if not _is_invented(s, envelope, language)]
    out: list[RecognizedSpan] = []
    index = 0
    while index < len(survivors):
        text = normalized(survivors[index].text)
        end = index
        while end + 1 < len(survivors) and normalized(survivors[end + 1].text) == text:
            end += 1
        out.extend([survivors[index]] if end - index + 1 >= REPEAT_LIMIT else survivors[index:end + 1])
        index = end + 1
    return out, len(spans) - len(out)
