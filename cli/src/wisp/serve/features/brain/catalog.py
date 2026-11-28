from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import PurePosixPath

from wisp.brain_index import BINARY_PROBE, INLINE_CODE, READ_CAP, Graph, NoteRow, _outside_fences, parse_note

from . import links
from .vault import Vault

SKIPPED_FOLDERS = frozenset({"arquivos"})
INLINE_TAG = re.compile(r"(?:^|(?<=[ \t]))#([\w/\-]+)", re.M)
CONTEXT_LIMIT = 240


def stem_title(stem: str) -> str:
    return stem.replace("-", " ").replace("_", " ")


@dataclass(frozen=True)
class Entry:
    stamp: tuple[int, int]
    row: NoteRow
    heading_title: bool
    links: tuple[tuple[str, str], ...]
    inline_tags: tuple[str, ...]


def _inline_tags(text: str) -> tuple[str, ...]:
    from wisp.brain_index import fold, split_frontmatter

    body = split_frontmatter(text)[1]
    found: set[str] = set()
    for line in _outside_fences(body):
        for match in INLINE_TAG.finditer(INLINE_CODE.sub("", line)):
            tag = match.group(1)
            if any(c.isalpha() for c in tag):
                found.add(fold(tag))
    return tuple(sorted(found))


def _entry(rel: str, stamp: tuple[int, int], data: bytes) -> Entry | None:
    if b"\0" in data[:BINARY_PROBE]:
        return None
    text = data.decode("utf-8", errors="replace")
    parsed = parse_note(text)
    stem = PurePosixPath(rel).stem
    seen: dict[tuple[str, str], None] = {}
    for occurrence in links.scan(text, include_frontmatter=True):
        if not occurrence.is_attachment:
            seen.setdefault((occurrence.name, occurrence.heading))
    row = NoteRow(rel, parsed.title or stem_title(stem), stem, tuple(parsed.aliases), tuple(parsed.tags), parsed.status)
    return Entry(stamp, row, bool(parsed.title), tuple(seen), _inline_tags(text))


@dataclass
class Catalog:
    entries: dict[str, Entry]
    graph: Graph
    reused: int = 0
    read: int = 0
    notes: dict[str, NoteRow] = field(init=False)

    def __post_init__(self) -> None:
        self.notes = self.graph.notes

    @classmethod
    def build(cls, entries: dict[str, Entry], reused: int = 0, read: int = 0) -> Catalog:
        rows = [e.row for e in entries.values()]
        return cls(entries, Graph(rows, {rel: list(e.links) for rel, e in entries.items()}), reused, read)

    @classmethod
    def scan(cls, vault: Vault, previous: Catalog | None = None) -> Catalog:
        kept: dict[str, Entry] = {}
        reused = read = 0
        for current, dirs, names in os.walk(vault.root):
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in SKIPPED_FOLDERS)
            for name in names:
                if name.startswith(".") or not name.endswith(".md"):
                    continue
                full = os.path.join(current, name)
                try:
                    info = os.stat(full)
                    rel = os.path.relpath(full, vault.root).replace(os.sep, "/")
                    if os.path.islink(full) and not vault.root_contains(os.path.realpath(full)):
                        continue
                    stamp = (info.st_mtime_ns, info.st_size)
                    old = previous.entries.get(rel) if previous else None
                    if old and old.stamp == stamp:
                        kept[rel] = old
                        reused += 1
                        continue
                    with open(full, "rb") as handle:
                        entry = _entry(rel, stamp, handle.read(READ_CAP))
                except OSError:
                    continue
                read += 1
                if entry:
                    kept[rel] = entry
        return cls.build(kept, reused, read)

    def moved(self, mapping: dict[str, str]) -> Graph:
        rows, link_map = [], {}
        for rel, entry in self.entries.items():
            new = mapping.get(rel, rel)
            stem = PurePosixPath(new).stem
            title = entry.row.title if entry.heading_title else stem_title(stem)
            rows.append(NoteRow(new, title, stem, entry.row.aliases, entry.row.tags, entry.row.status))
            link_map[new] = list(entry.links)
        return Graph(rows, link_map)

    def resolve(self, name: str, source: str | None = None) -> str | None:
        return self.graph.resolve(name, source)

    def incoming(self, rel: str) -> list[str]:
        return sorted(self.graph.incoming.get(rel, []))

    def tag_counts(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for entry in self.entries.values():
            for tag in set(entry.row.tags) | set(entry.inline_tags):
                counts[tag] = counts.get(tag, 0) + 1
        return counts

    def notes_with_tag(self, tag: str) -> list[str]:
        return sorted(rel for rel, e in self.entries.items() if tag in e.row.tags or tag in e.inline_tags)

    def edges(self) -> list[tuple[str, str]]:
        pairs: set[tuple[str, str]] = set()
        for source, resolved in self.graph.outgoing.items():
            for link in resolved:
                if link.target and link.target != source:
                    pairs.add((min(source, link.target), max(source, link.target)))
        return sorted(pairs)

    def link_name(self, rel: str) -> str:
        return self.graph.link_name(rel) if rel in self.notes else rel.removesuffix(".md")


def backlinks(vault: Vault, catalog: Catalog, target: str) -> list[dict]:
    found = []
    for source in catalog.incoming(target):
        try:
            text = vault.read_bytes(source).decode("utf-8", errors="replace")
        except Exception:
            continue
        lines = text.split("\n")
        seen: set[int] = set()
        contexts = []
        for occurrence in links.scan(text):
            if occurrence.is_attachment or catalog.resolve(occurrence.name, source) != target:
                continue
            if occurrence.line in seen or occurrence.line >= len(lines):
                continue
            seen.add(occurrence.line)
            contexts.append({"line": occurrence.line, "text": lines[occurrence.line].strip()[:CONTEXT_LIMIT]})
        found.append({"path": source, "title": catalog.notes[source].title, "contexts": contexts})
    return found


def outgoing(vault: Vault, catalog: Catalog, source: str) -> list[dict]:
    try:
        text = vault.read_bytes(source).decode("utf-8", errors="replace")
    except Exception:
        return []
    seen: set[str] = set()
    result = []
    for occurrence in links.scan(text):
        if occurrence.is_attachment:
            continue
        target = catalog.resolve(occurrence.name, source)
        key = (target or "?" + occurrence.name.lower()) + "#" + occurrence.heading
        if key in seen:
            continue
        seen.add(key)
        result.append({"name": occurrence.name, "heading": occurrence.heading, "target": target})
    return result
