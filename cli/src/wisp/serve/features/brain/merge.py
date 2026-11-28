from __future__ import annotations

MINE_MARKER = "<<<<<<< minhas edições"
DIVIDER = "======="
THEIRS_MARKER = ">>>>>>> no disco"
CELL_LIMIT = 1_000_000


def has_markers(text: str) -> bool:
    lines = [ln.removesuffix("\r") for ln in text.split("\n")]
    return MINE_MARKER in lines and THEIRS_MARKER in lines


def matches(a: list[str], b: list[str]) -> list[int | None]:
    result: list[int | None] = [None] * len(a)
    prefix = 0
    while prefix < len(a) and prefix < len(b) and a[prefix] == b[prefix]:
        result[prefix] = prefix
        prefix += 1
    suffix = 0
    while suffix < len(a) - prefix and suffix < len(b) - prefix and a[-1 - suffix] == b[-1 - suffix]:
        result[len(a) - 1 - suffix] = len(b) - 1 - suffix
        suffix += 1
    n, m = len(a) - prefix - suffix, len(b) - prefix - suffix
    if n <= 0 or m <= 0 or (n + 1) * (m + 1) > CELL_LIMIT:
        return result
    left, right = a[prefix : prefix + n], b[prefix : prefix + m]
    width = m + 1
    table = [0] * ((n + 1) * width)
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            table[i * width + j] = (
                table[(i + 1) * width + j + 1] + 1 if left[i] == right[j] else max(table[(i + 1) * width + j], table[i * width + j + 1])
            )
    i = j = 0
    while i < n and j < m:
        if left[i] == right[j]:
            result[prefix + i] = prefix + j
            i += 1
            j += 1
        elif table[(i + 1) * width + j] >= table[i * width + j + 1]:
            i += 1
        else:
            j += 1
    return result


def merge(base: str, mine: str, theirs: str) -> tuple[str, str]:
    if theirs == base or theirs == mine:
        return "unchanged", ""
    if mine == base:
        return "reload", theirs
    base_lines, mine_lines, their_lines = base.split("\n"), mine.split("\n"), theirs.split("\n")
    match_mine, match_theirs = matches(base_lines, mine_lines), matches(base_lines, their_lines)
    carriage = "\r" if "\r\n" in mine + theirs + base else ""
    out: list[str] = []
    conflicted = False
    previous = [-1, -1, -1]

    def chunk(base_at: int, mine_at: int, theirs_at: int) -> None:
        nonlocal conflicted
        original = base_lines[previous[0] + 1 : base_at]
        mine_part = mine_lines[previous[1] + 1 : mine_at]
        their_part = their_lines[previous[2] + 1 : theirs_at]
        if mine_part == original:
            out.extend(their_part)
        elif their_part == original or their_part == mine_part:
            out.extend(mine_part)
        else:
            conflicted = True
            out.extend([MINE_MARKER + carriage, *mine_part, DIVIDER + carriage, *their_part, THEIRS_MARKER + carriage])

    for i in range(len(base_lines)):
        mi, ti = match_mine[i], match_theirs[i]
        if mi is None or ti is None:
            continue
        chunk(i, mi, ti)
        out.append(base_lines[i])
        previous = [i, mi, ti]
    chunk(len(base_lines), len(mine_lines), len(their_lines))
    return ("conflict" if conflicted else "merged"), "\n".join(out)
