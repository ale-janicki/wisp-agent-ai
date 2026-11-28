from __future__ import annotations

import json
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from wisp.meetings_win.transcript import MeetingSegment, clock

MAX_ASSIST_ITEMS = 3
SHOWN_LIMIT = 6
ASSIST_INTERVAL = 40.0
ASSIST_WINDOW_SECONDS = 240.0
ASSIST_CHARACTER_LIMIT = 6000
CONTEXT_LIMIT = 6000
MAX_ENTITIES = 6
LOOKUP_INTERVAL = 20.0
LOOKUP_PER_ROUND = 2
LOOKUP_PER_MEETING = 40
SNIPPET_LIMIT = 220
ASSIST_KINDS = {"pergunte": "Pergunte", "responda": "Responda", "lembre": "Lembre"}

KEYWORDS = {"cliente", "projeto", "empresa", "contrato", "proposta", "fornecedor", "produto", "sistema", "ferramenta",
            "squad", "client", "project", "company", "contract", "vendor", "product", "tool"}
FILLERS = {"o", "a", "os", "as", "um", "uma", "de", "do", "da", "dos", "das", "the", "of", "our", "nosso", "nossa", "esse",
           "essa", "este", "esta"}
NOT_ENTITIES = {
    "você", "voce", "outros", "eu", "ele", "ela", "nós", "nos", "eles", "elas", "então", "entao", "mas", "bom", "boa", "sim",
    "não", "nao", "tá", "ta", "ok", "olá", "ola", "oi", "obrigado", "obrigada", "porque", "também", "tambem", "agora", "aqui",
    "isso", "isto", "pois", "the", "this", "that", "yes", "no", "hello", "thanks", "well", "so", "and", "but", "right",
    "segunda", "terça", "terca", "quarta", "quinta", "sexta", "sábado", "sabado", "domingo", "monday", "tuesday", "wednesday",
    "thursday", "friday", "saturday", "sunday", "janeiro", "fevereiro", "março", "marco", "abril", "maio", "junho", "julho",
    "agosto", "setembro", "outubro", "novembro", "dezembro", "january", "february", "march", "april", "may", "june", "july",
    "august", "september", "october", "november", "december"}


class EngineFailed(Exception):
    pass


def entity_key(text: str) -> str:
    folded = "".join(c for c in unicodedata.normalize("NFD", text.lower()) if not unicodedata.combining(c))
    return " ".join(folded.split())


def _trimmed(token: str) -> str:
    keep = lambda c: c.isalnum() or c in "-_"  # noqa: E731
    start, end = 0, len(token)
    while start < end and not keep(token[start]):
        start += 1
    while end > start and not keep(token[end - 1]):
        end -= 1
    return token[start:end]


def _ends_sentence(token: str) -> bool:
    return bool(token) and token[-1] in ".!?"


def _is_capitalised(word: str) -> bool:
    return len(word) >= 3 and word[0].isupper() and not any(c.isdigit() for c in word)


def _is_code(word: str) -> bool:
    digits = sum(c.isdigit() for c in word)
    if digits == 0 or word.startswith("-"):
        return False
    return digits >= 4 or (any(c.isalpha() for c in word) and len(word) >= 3)


def _following(tokens: list[str], index: int) -> list[str]:
    name: list[str] = []
    position = index + 1
    while position < len(tokens) and len(name) < 2:
        word = _trimmed(tokens[position])
        lowered = word.lower()
        if not word or lowered in NOT_ENTITIES:
            break
        if lowered in FILLERS and not name:
            position += 1
            continue
        if lowered in FILLERS or not (_is_capitalised(word) or _is_code(word)):
            break
        name.append(word)
        if _ends_sentence(tokens[position]):
            break
        position += 1
    return name


def detect_entities(text: str) -> list[str]:
    tokens = text.split()
    found: list[str] = []
    index = 0
    while index < len(tokens):
        word = _trimmed(tokens[index])
        lowered = word.lower()
        starts_sentence = index == 0 or _ends_sentence(tokens[index - 1])
        if lowered in KEYWORDS:
            name = _following(tokens, index)
            if name:
                found.append(" ".join(name))
            index += 1 + len(name)
            continue
        if _is_capitalised(word) and lowered not in NOT_ENTITIES:
            run = [word]
            position = index + 1
            while position < len(tokens) and not _ends_sentence(tokens[position - 1]):
                candidate = _trimmed(tokens[position])
                if not _is_capitalised(candidate) or candidate.lower() in NOT_ENTITIES:
                    break
                run.append(candidate)
                position += 1
            if not starts_sentence or len(run) > 1:
                found.append(" ".join(run))
            index = position
            continue
        if _is_code(word):
            found.append(word)
        index += 1
    seen: set[str] = set()
    unique = []
    for value in found:
        key = entity_key(value)
        if value and not value.startswith("-") and key not in seen:
            seen.add(key)
            unique.append(value)
    return unique[:MAX_ENTITIES]


def entities_in(segments: list[MeetingSegment], include_others: bool) -> list[str]:
    spoken = [s for s in segments if s.is_final and (include_others or s.channel == "mic")]
    return detect_entities(". ".join(s.text for s in spoken))


class LookupGate:
    def __init__(self, minimum_interval: float = LOOKUP_INTERVAL):
        self.minimum_interval = minimum_interval
        self._asked: set[str] = set()
        self._last: float | None = None

    def pick(self, candidates: list[str], at: float) -> list[str]:
        if self._last is not None and at - self._last < self.minimum_interval:
            return []
        picked: list[str] = []
        for candidate in candidates:
            if len(picked) >= LOOKUP_PER_ROUND or len(self._asked) + len(picked) >= LOOKUP_PER_MEETING:
                break
            key = entity_key(candidate)
            if key in self._asked or any(entity_key(p) == key for p in picked):
                continue
            picked.append(candidate)
        if not picked:
            return []
        self._asked.update(entity_key(p) for p in picked)
        self._last = at
        return picked


@dataclass(frozen=True)
class AssistItem:
    kind: str
    text: str

    @property
    def id(self) -> str:
        return f"{self.kind}-{entity_key(self.text)}"

    @property
    def label(self) -> str:
        return ASSIST_KINDS.get(self.kind, self.kind)

    def to_json(self) -> dict:
        return {"id": self.id, "kind": self.kind, "label": self.label, "text": self.text}


def parse_assist(raw: str) -> list[AssistItem]:
    try:
        data = json.loads(raw)
    except ValueError:
        return []
    rows = data.get("itens") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        return []
    items = [AssistItem(str(r["tipo"]), str(r["texto"])) for r in rows
             if isinstance(r, dict) and r.get("tipo") in ASSIST_KINDS and isinstance(r.get("texto"), str) and r["texto"]]
    return items[:MAX_ASSIST_ITEMS]


def merge_assist(fresh: list[AssistItem], shown: list[AssistItem]) -> list[AssistItem]:
    known = {i.id for i in shown}
    added = []
    for item in fresh:
        if item.id not in known:
            known.add(item.id)
            added.append(item)
    return (added + shown)[:SHOWN_LIMIT]


class AssistGate:
    def __init__(self, minimum_interval: float = ASSIST_INTERVAL):
        self.minimum_interval = minimum_interval
        self._last_start: float | None = None
        self._last_count = -1
        self.in_flight = False

    def should_run(self, now: float, final_count: int) -> bool:
        if self.in_flight or final_count <= 0 or final_count == self._last_count:
            return False
        return self._last_start is None or now - self._last_start >= self.minimum_interval

    def started(self, now: float, final_count: int) -> None:
        self.in_flight, self._last_start, self._last_count = True, now, final_count

    def finished(self) -> None:
        self.in_flight = False


def assist_window(segments: list[MeetingSegment], elapsed: float) -> str:
    recent = [s for s in segments if s.is_final and s.start >= elapsed - ASSIST_WINDOW_SECONDS]
    text = "\n".join(f"[{clock(s.start)}] {s.speaker_name}: {s.text}" for s in recent)
    return text[-ASSIST_CHARACTER_LIMIT:]


def parse_prep(raw: str) -> dict:
    try:
        data = json.loads(raw)
    except ValueError:
        data = None
    data = data if isinstance(data, dict) else {}

    def strings(key: str) -> list[str]:
        return [s for s in (data.get(key) or []) if isinstance(s, str) and s]

    return {"checklist": strings("checklist"), "questions": strings("perguntas")}


def prep_items(report: dict) -> list[str]:
    return [*report["checklist"], *(f"Perguntar: {q}" for q in report["questions"])]


@dataclass(frozen=True)
class BrainHit:
    path: str
    title: str
    snippet: str

    def resolve(self, root: Path) -> Path | None:
        base = Path(root).resolve()
        candidate = (base / self.path).resolve()
        try:
            candidate.relative_to(base)
        except ValueError:
            return None
        return candidate if candidate.exists() and candidate != base else None

    def to_json(self) -> dict:
        return {"path": self.path, "title": self.title, "snippet": self.snippet}


def parse_brain_hits(raw: str, limit: int) -> list[BrainHit]:
    try:
        data = json.loads(raw)
    except ValueError:
        return []
    rows = data if isinstance(data, list) else next(
        (data[k] for k in ("results", "hits", "notas", "notes") if isinstance(data, dict) and isinstance(data.get(k), list)), [])
    hits = []
    for row in rows[:limit]:
        if not isinstance(row, dict):
            continue
        path = next((row[k] for k in ("path", "arquivo", "file") if isinstance(row.get(k), str)), "")
        if not path:
            continue
        title = next((row[k] for k in ("title", "titulo") if isinstance(row.get(k), str)), Path(path).name)
        snippet = next((row[k] for k in ("snippet", "trecho", "excerpt") if isinstance(row.get(k), str)), "")
        hits.append(BrainHit(path, title, " ".join(snippet.split())[:SNIPPET_LIMIT]))
    return hits


def build_context(event: dict | None, description: str, checklist: list[dict], hits: list[BrainHit]) -> str:
    parts = []
    if event:
        parts.append(f"Evento: {event.get('title', '')} ({event.get('start', '')})")
        if event.get("attendees"):
            parts.append("Participantes: " + ", ".join(event["attendees"]))
        if event.get("notes"):
            parts.append(f"Notas do evento: {event['notes']}")
    typed = (description or "").strip()
    if typed:
        parts.append(f"Descrição: {typed}")
    pending = [f"- {i['text']}" for i in checklist if not i.get("done")]
    if pending:
        parts.append("Checklist pendente:\n" + "\n".join(pending))
    if hits:
        parts.append("Notas do brain:\n" + "\n".join(f"- {h.title}: {h.snippet}" for h in hits))
    return "\n\n".join(parts)[:CONTEXT_LIMIT]


Runner = Callable[..., "tuple[int, str, str]"]


def _reason(err: str, code: int) -> str:
    for line in reversed([l for l in err.splitlines() if l.strip()]):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and value.get("erro"):
            return str(value["erro"])
    return f"o comando saiu com {code}"


class EngineClient:
    def __init__(self, runner: Runner, wisp: list[str]):
        self._run = runner
        self._wisp = wisp

    def assist(self, transcript: str, context: str, already: list[str], cancel=None) -> list[AssistItem]:
        payload = json.dumps({"transcript": transcript, "context": context, "already": already}, ensure_ascii=False)
        code, out, err = self._run([*self._wisp, "reuniao", "assist"], payload.encode("utf-8"), cancel)
        if code != 0:
            raise EngineFailed(_reason(err, code))
        return parse_assist(out)

    def prep(self, payload: dict, cancel=None) -> dict:
        code, out, err = self._run([*self._wisp, "reuniao", "prep"], json.dumps(payload, ensure_ascii=False).encode("utf-8"), cancel)
        if code != 0:
            raise EngineFailed(_reason(err, code))
        return parse_prep(out)

    def brain_available(self) -> bool:
        try:
            return self._run([*self._wisp, "brain", "search", "--help"], None, None)[0] == 0
        except OSError:
            return False

    def brain_search(self, query: str, root: str, limit: int) -> list[BrainHit]:
        if query.startswith("-"):
            return []
        code, out, _ = self._run([*self._wisp, "brain", "search", query, "--root", root, "--limit", str(limit)], None, None)
        return parse_brain_hits(out, limit) if code == 0 else []
