from __future__ import annotations

from dataclasses import dataclass
from pathlib import PurePosixPath

ATTACHMENT_EXTENSIONS = frozenset(
    "png jpg jpeg gif svg webp heic pdf mp3 mp4 mov wav m4a webm excalidraw canvas base".split()
)


@dataclass(frozen=True)
class Occurrence:
    start: int
    end: int
    name_start: int
    name_end: int
    name: str
    heading: str
    alias: str | None
    is_embed: bool
    line: int

    @property
    def extension(self) -> str:
        return PurePosixPath(self.name).suffix.lower().lstrip(".")

    @property
    def is_attachment(self) -> bool:
        return self.extension in ATTACHMENT_EXTENSIONS


def frontmatter_length(text: str) -> int:
    if not text.startswith("---"):
        return 0
    position, first = 0, True
    while position < len(text):
        end = text.find("\n", position)
        end = len(text) if end < 0 else end
        line = text[position:end].strip(" \t\r")
        if first:
            if line != "---":
                return 0
            first = False
        elif line in ("---", "..."):
            return min(end + 1, len(text))
        position = end + 1
    return 0


def scan(text: str, include_frontmatter: bool = False) -> list[Occurrence]:
    found: list[Occurrence] = []
    skipped = 0 if include_frontmatter else frontmatter_length(text)
    fence: tuple[str, int] | None = None
    start, line_number = 0, 0
    while start < len(text):
        end = text.find("\n", start)
        end = len(text) if end < 0 else end
        first = start
        while first < end and first - start < 4 and text[first] in " \t":
            first += 1
        is_fence = False
        if first < end and text[first] in "`~":
            mark = text[first]
            run = first
            while run < end and text[run] == mark:
                run += 1
            if run - first >= 3:
                is_fence = True
                if fence is not None:
                    if fence[0] == mark and run - first >= fence[1]:
                        fence = None
                else:
                    fence = (mark, run - first)
        if not is_fence and fence is None and start >= skipped:
            _scan_line(text, start, end, line_number, found)
        start = end + 1
        line_number += 1
    return found


def _closing_backticks(text: str, length: int, start: int, end: int) -> int | None:
    i = start
    while i < end:
        if text[i] != "`":
            i += 1
            continue
        run = i
        while run < end and text[run] == "`":
            run += 1
        if run - i == length:
            return run
        i = run
    return None


def _scan_line(text: str, start: int, end: int, line: int, found: list[Occurrence]) -> None:
    i = start
    while i < end:
        char = text[i]
        if char == "`":
            run = i
            while run < end and text[run] == "`":
                run += 1
            closing = _closing_backticks(text, run - i, run, end)
            i = closing if closing is not None else run
            continue
        embed = char == "!" and text.startswith("[[", i + 1, end)
        if embed or text.startswith("[[", i, end):
            occurrence = _parse(text, i, i + 3 if embed else i + 2, end, embed, line)
            if occurrence:
                found.append(occurrence)
                i = occurrence.end
                continue
        i += 1


def _parse(text: str, token_start: int, inner: int, end: int, embed: bool, line: int) -> Occurrence | None:
    j, pipe_at = inner, None
    while j < end:
        char = text[j]
        if char == "[":
            return None
        if char == "]":
            if not text.startswith("]]", j, end):
                return None
            break
        if char == "|" and pipe_at is None:
            pipe_at = j
        j += 1
    if j + 1 >= end:
        return None
    name_end = pipe_at if pipe_at is not None else j
    target_end, heading_start = name_end, None
    hash_at = text.find("#", inner, name_end)
    if hash_at >= 0:
        target_end, heading_start = hash_at, hash_at + 1
    trailing = target_end
    if trailing > inner and text[trailing - 1] == "\\" and pipe_at is not None and heading_start is None:
        trailing -= 1
    lower, upper = inner, trailing
    while lower < upper and text[lower] in " \t":
        lower += 1
    while upper > lower and text[upper - 1] in " \t":
        upper -= 1
    name = text[lower:upper]
    heading = text[heading_start:name_end].strip(" \t") if heading_start is not None else ""
    if heading.startswith("^"):
        heading = ""
    alias = text[pipe_at + 1 : j] if pipe_at is not None else None
    if not name and not heading:
        return None
    return Occurrence(token_start, j + 2, lower, upper, name, heading, alias, embed, line)
