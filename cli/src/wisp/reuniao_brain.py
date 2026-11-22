from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import sqlite3
import tempfile
from contextlib import contextmanager
from datetime import datetime, tzinfo
from pathlib import Path
from urllib.parse import quote

from wisp import reuniao
from wisp.brain_index import STOPWORDS, BrainError, BrainIndex, NoteRow, fold, index_path
from wisp.config import WispConfig
from wisp.paths import WispPaths

MEETINGS_DIR = "meetings"
MARKER = "sync: wisp-reuniao"
PLACEHOLDER = "> Resumo ainda não gerado."
FALLBACK_TITLE = "Reunião"
SUMMARY_HEADINGS = ("## Resumo", "## Pontos principais", "## Ações")
SLUG_CHARS = 48
INDEX_LINE_CHARS = 200
INDEX_NAME = "meetings-index.md"
MAX_EVENT_NOTES_CHARS = 2000
MIN_KEY_CHARS = 3
MAX_KEYS = 20_000
HEADER_PROBE = 16384
VAULT_LOCK = ".wisp-index.lock"
LOCKS_DIR = "locks"
LOCK_FILE = "meetings-index.lock"
MOVED = "a nota da reunião foi movida ou apagada no brain"
DATED = re.compile(r"\d{4}-\d{2}-\d{2}-\d{2}h\d{2}m-")
LOCK_NAME = ".brain.lock"
PROTECTED = re.compile(r"\[\[.*?\]\]|`[^`\n]*`|\[[^\]\n]*\]\([^)\n]*\)|https?://\S+")


def norm(text: str) -> str:
    return " ".join(fold(text).split())


def folded_with_map(text: str) -> tuple[str, list[int]]:
    out: list[str] = []
    index: list[int] = []
    for position, char in enumerate(text):
        piece = fold(char)
        out.append(piece)
        index.extend([position] * len(piece))
    return "".join(out), index


class Names:
    def __init__(self, rows: list[NoteRow]):
        claims: dict[str, set[str]] = {}
        stems: dict[str, int] = {}
        self.target: dict[str, str] = {}
        kept = [row for row in rows if not row.rel.startswith(MEETINGS_DIR + "/")]
        for row in kept:
            stems[row.stem.casefold()] = stems.get(row.stem.casefold(), 0) + 1
        for row in kept:
            self.target[row.rel] = row.stem if stems[row.stem.casefold()] == 1 else row.rel[:-3]
            for key in {row.title, row.stem, *row.aliases}:
                folded = norm(key)
                if folded:
                    claims.setdefault(folded, set()).add(row.rel)
        self.unique = {key: next(iter(rels)) for key, rels in claims.items() if len(rels) == 1}
        scannable = [
            key for key in self.unique
            if len(key) >= MIN_KEY_CHARS and not all(word in STOPWORDS for word in key.split())
        ]
        scannable.sort(key=lambda key: (-len(key), key))
        scannable = scannable[:MAX_KEYS]
        self.pattern = (
            re.compile(r"(?<![^\W_])(?:" + "|".join(re.escape(key) for key in scannable) + r")(?![^\W_])")
            if scannable else None
        )

    def lookup(self, name: str) -> str | None:
        return self.unique.get(norm(name)) if name.strip() else None

    def wikilink(self, rel: str, shown: str) -> str:
        target = self.target[rel]
        label = " ".join(shown.replace("|", " ").replace("[", " ").replace("]", " ").split())
        return f"[[{target}]]" if label == target or not label else f"[[{target}|{label}]]"

    def link_name(self, name: str, email: str | None = None) -> str:
        shown = name.strip() or (email or "").strip()
        for candidate in (name, email or ""):
            rel = self.lookup(candidate)
            if rel:
                return self.wikilink(rel, shown)
        return shown

    def link_text(self, text: str) -> str:
        if self.pattern is None:
            return text
        linked: set[str] = set()
        return "\n".join(
            line if line.lstrip().startswith("#") else self.link_line(line, linked) for line in text.split("\n")
        )

    def link_line(self, line: str, linked: set[str]) -> str:
        folded, index = folded_with_map(line)
        protected = [match.span() for match in PROTECTED.finditer(line)]
        out: list[str] = []
        cursor = 0
        for match in self.pattern.finditer(folded):
            if match.start() == match.end():
                continue
            start, end = index[match.start()], index[match.end() - 1] + 1
            rel = self.unique[match.group(0)]
            if start < cursor or rel in linked or not line[start].isupper():
                continue
            if any(first < end and start < last for first, last in protected):
                continue
            linked.add(rel)
            out.append(line[cursor:start])
            out.append(self.wikilink(rel, line[start:end]))
            cursor = end
        out.append(line[cursor:])
        return "".join(out)


def text_of(value) -> str:
    return value.strip() if isinstance(value, str) else ""


def line_of(value) -> str:
    return " ".join(value.split()) if isinstance(value, str) else ""


def home_path(path: Path, home: Path | None) -> str:
    base = home if home is not None else Path.home()
    try:
        return "~/" + path.relative_to(base).as_posix()
    except ValueError:
        return str(path)


def people_of(event: dict) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    seen: set[str] = set()
    organizer = event.get("organizer")
    sources = list(event.get("attendees") or [])
    if isinstance(organizer, dict):
        sources.append(organizer)
    for person in sources:
        if not isinstance(person, dict):
            continue
        name, email = line_of(person.get("name")), line_of(person.get("email"))
        key = email.casefold() or norm(name)
        if not (name or email) or key in seen:
            continue
        seen.add(key)
        found.append((name, email))
    return found


def person_label(name: str, email: str) -> str:
    if name and email and name.casefold() != email.casefold():
        return f"{name} <{email}>"
    return name or email


def started_at(meta: dict, tz: tzinfo | None) -> datetime:
    raw = text_of(meta.get("started_at"))
    try:
        moment = datetime.fromisoformat(raw)
    except ValueError:
        raise reuniao.Falha("a reunião não tem data de início")
    return moment.astimezone(tz)


def slug(title: str, limit: int = SLUG_CHARS) -> str:
    words = re.findall(r"[a-z0-9]+", fold(title))
    return "-".join(words)[:limit].strip("-") or "reuniao"


def file_stem(moment: datetime, title: str) -> str:
    return f"{moment:%Y-%m-%d-%Hh%Mm}-{slug(title)}"


def index_line(name: str, title: str, moment: datetime) -> str:
    clean = " ".join(title.replace("[[", " ").replace("]]", " ").replace("|", " ").split())
    line = f"- [[{name}]] — {clean} ({moment:%Y-%m-%d})"
    return line if len(line) <= INDEX_LINE_CHARS else line[: INDEX_LINE_CHARS - 1] + "…"


@contextmanager
def vault_lock(meetings: Path):
    folder = WispPaths.current().state / LOCKS_DIR / hashlib.sha1(str(meetings.resolve()).encode("utf-8", "surrogateescape")).hexdigest()[:12]
    folder.mkdir(parents=True, exist_ok=True)
    fd = os.open(folder / LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        old = meetings / VAULT_LOCK
        if old.is_file() and old.stat().st_size == 0:
            old.unlink(missing_ok=True)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def rewrite(path: Path, transform) -> bool:
    for _ in range(2):
        before = path.read_bytes()
        updated = transform(before.decode("utf-8"))
        if updated is None:
            return False
        mode = path.stat().st_mode & 0o777
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".wisp-rewrite-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(updated)
            os.chmod(tmp, mode)
            if digest(path.read_bytes()) != digest(before):
                continue
            os.replace(tmp, path)
            return True
        finally:
            Path(tmp).unlink(missing_ok=True)
    raise reuniao.Falha(f"{path.name} mudou enquanto eu gravava; tente de novo")


def append_index(meetings: Path, name: str, title: str, moment: datetime) -> bool:
    index = meetings / INDEX_NAME
    if not index.is_file() or index.resolve().parent != meetings:
        return False

    def add(existing: str) -> str | None:
        if f"[[{name}]]" in existing:
            return None
        separator = "" if not existing or existing.endswith("\n") else "\n"
        return existing + separator + index_line(name, title, moment) + "\n"

    try:
        return rewrite(index, add)
    except (OSError, UnicodeDecodeError) as problem:
        raise reuniao.Falha(f"não consegui atualizar o índice das reuniões: {problem}")


def summary_of(folder: Path, meta: dict) -> tuple[str | None, str | None]:
    if meta.get("note_state") != "generated":
        return None, None
    try:
        text = (folder / "nota.md").read_text("utf-8")
    except OSError:
        return None, None
    blocks: dict[str, list[str]] = {}
    current = None
    for line in text.splitlines():
        if line.startswith("## "):
            current = next((heading for heading in SUMMARY_HEADINGS if line.strip() == heading), None)
            if current:
                blocks[current] = [line]
        elif current:
            blocks[current].append(line)
    body = "\n\n".join("\n".join(blocks[heading]).strip() for heading in SUMMARY_HEADINGS if heading in blocks)
    return reuniao.title_of(text), (body or None)


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def frontmatter(meta: dict, event: dict, moment: datetime, folder: Path, has_summary: bool, home: Path | None = None) -> str:
    lines = [
        "---",
        "tipo: reuniao",
        MARKER,
        f"data: {moment:%Y-%m-%d %H:%M}",
        f"duracao: {reuniao.clock(float(meta.get('duration_s') or 0))}",
    ]
    calendar = line_of(event.get("calendar"))
    if calendar:
        lines.append(f"calendario: {quoted(calendar)}")
    people = people_of(event)
    if people:
        lines.append("participantes:")
        lines.extend(f"  - {quoted(person_label(*person))}" for person in people)
    organizer = event.get("organizer")
    label = person_label(line_of(organizer.get("name")), line_of(organizer.get("email"))) if isinstance(organizer, dict) else ""
    if label:
        lines.append(f"organizador: {quoted(label)}")
    link = line_of(event.get("url"))
    if link:
        lines.append(f"link: {quoted(link)}")
    lines.append(f"gravacao: {quoted(home_path(folder, home))}")
    lines.append(f"resumo_gerado: {'sim' if has_summary else 'nao'}")
    lines.extend(["---", ""])
    return "\n".join(lines)


def transcript_link(folder: Path, home: Path | None = None) -> str:
    target = folder / "transcript.json"
    if (folder / "nota.md").exists():
        target = folder / "nota.md"
    return f"[Transcrição completa]({quote(home_path(target, home), safe='/~')})"


def compose(
    meta: dict, folder: Path, names: Names, moment: datetime, title: str, summary: str | None, home: Path | None = None
) -> str:
    event = meta.get("event") if isinstance(meta.get("event"), dict) else {}
    parts = [frontmatter(meta, event, moment, folder, summary is not None, home), f"# {line_of(title) or FALLBACK_TITLE}", ""]
    people = people_of(event)
    if people:
        parts.append("**Participantes:** " + ", ".join(names.link_name(name, email) for name, email in people))
        parts.append("")
    description = text_of(event.get("notes"))[:MAX_EVENT_NOTES_CHARS]
    if description:
        parts.extend(["## Descrição do evento", "", *(f"> {line}" for line in description.splitlines()), ""])
    parts.append(names.link_text(summary) if summary else PLACEHOLDER)
    parts.extend(["", "## Transcrição", "", transcript_link(folder, home), ""])
    return "\n".join(parts)


def meetings_folder(brain: Path) -> Path:
    if not brain.is_dir():
        raise reuniao.Falha("o brain não existe; não criei nada")
    root = brain.resolve()
    folder = brain / MEETINGS_DIR
    try:
        folder.mkdir(exist_ok=True)
    except OSError as problem:
        raise reuniao.Falha(f"não consegui criar a pasta meetings do brain: {problem}")
    resolved = folder.resolve()
    if not folder.is_dir() or root not in resolved.parents:
        raise reuniao.Falha("a pasta meetings do brain aponta para fora do brain; não salvei nada")
    return resolved


def head_of(path: Path) -> list[str] | None:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return handle.read(HEADER_PROBE).splitlines()
    except (OSError, UnicodeDecodeError):
        return None


def inside(path: Path, root: Path) -> bool:
    try:
        return path.is_file() and path.suffix == ".md" and root in path.resolve().parents
    except OSError:
        return False


def existing_note(meta: dict, folder: Path, brain: Path, meetings: Path, rows: list[NoteRow], home: Path | None) -> Path | None:
    root = brain.resolve()
    raw = text_of(meta.get("brain_note"))
    if raw:
        path = Path(raw)
        head = head_of(path) if inside(path, root) else None
        if head is not None and MARKER in head:
            return path.resolve()
    wanted = {f"gravacao: {quoted(home_path(folder, home))}", f"gravacao: {quoted(str(folder))}"}
    candidates = sorted(meetings.rglob("*.md"))
    candidates += [root / row.rel for row in rows if not row.rel.startswith(MEETINGS_DIR + "/") and DATED.match(row.stem)]
    for path in candidates:
        if not inside(path, root):
            continue
        head = head_of(path)
        if head is not None and MARKER in head and wanted & set(head):
            return path.resolve()
    return None


def create_unique(folder: Path, stem: str, text: str) -> Path:
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".wisp-brain-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, 0o600)
        linking = True
        number = 1
        while True:
            target = folder / (f"{stem}.md" if number == 1 else f"{stem}-{number}.md")
            try:
                if linking:
                    try:
                        os.link(tmp, target)
                        return target
                    except FileExistsError:
                        raise
                    except OSError:
                        linking = False
                return write_exclusive(target, text)
            except FileExistsError:
                number += 1
            except OSError as problem:
                raise reuniao.Falha(f"não consegui gravar a nota no brain: {problem}")
    finally:
        Path(tmp).unlink(missing_ok=True)


def write_exclusive(target: Path, text: str) -> Path:
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    return target


def fill_summary(path: Path, names: Names, summary: str | None, title: str | None) -> bool:
    if summary is None:
        return False

    def fill(current: str) -> str | None:
        if PLACEHOLDER not in current:
            return None
        updated = current.replace(PLACEHOLDER, names.link_text(summary), 1)
        updated = updated.replace("resumo_gerado: nao", "resumo_gerado: sim", 1)
        if title and f"\n# {FALLBACK_TITLE}\n" in updated:
            updated = updated.replace(f"\n# {FALLBACK_TITLE}\n", f"\n# {line_of(title)}\n", 1)
        return updated

    return rewrite(path, fill)


def sync(
    folder: Path, brain: Path, rows: list[NoteRow], tz: tzinfo | None = None, home: Path | None = None, recreate: bool = False
) -> dict:
    meta = reuniao.read_json(folder / "meta.json")
    brain = brain.expanduser()
    meetings = meetings_folder(brain)
    names = Names(rows)
    note_title, summary = summary_of(folder, meta)
    event = meta.get("event") if isinstance(meta.get("event"), dict) else {}
    title = line_of(event.get("title")) or line_of(note_title) or FALLBACK_TITLE
    moment = started_at(meta, tz)
    with vault_lock(meetings):
        existing = existing_note(meta, folder, brain, meetings, rows, home)
        if existing:
            return {"nota": str(existing), "criada": False, "resumo": fill_summary(existing, names, summary, note_title)}
        recorded = text_of(meta.get("brain_note"))
        if recorded and not recreate and not Path(recorded).exists():
            raise reuniao.Falha(MOVED)
        text = compose(meta, folder, names, moment, title, summary, home)
        target = create_unique(meetings, file_stem(moment, title), text)
        indexed = append_index(meetings, target.stem, title, moment)
    return {"nota": str(target), "criada": True, "resumo": summary is not None, "indice": indexed}


def load_rows(cfg: WispConfig, paths: WispPaths, brain: Path) -> list[NoteRow]:
    if not brain.is_dir():
        return []
    root = brain.resolve()
    index = BrainIndex(root, index_path(paths.state, root), log_markers=tuple(cfg.brain_log_markers))
    try:
        index.sync()
        return list(index.graph().notes.values())
    except (BrainError, sqlite3.Error, OSError):
        return []


def make_brain_note(
    cfg: WispConfig, paths: WispPaths, folder: Path, brain: Path | None = None, tz: tzinfo | None = None, recreate: bool = False
) -> dict:
    from wisp.layout import layout_of

    target = (brain or layout_of(cfg, paths.home).brain).expanduser()
    lock = reuniao.acquire_lock(folder, LOCK_NAME)
    try:
        return sync(folder, target, load_rows(cfg, paths, target), tz, paths.home, recreate)
    finally:
        os.close(lock)
