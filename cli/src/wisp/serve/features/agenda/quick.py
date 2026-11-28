from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone, tzinfo
from functools import lru_cache


MONTHS = {
    "janeiro": 1, "jan": 1, "january": 1, "fevereiro": 2, "fev": 2, "feb": 2, "february": 2,
    "marco": 3, "mar": 3, "march": 3, "abril": 4, "abr": 4, "apr": 4, "april": 4, "maio": 5, "mai": 5, "may": 5,
    "junho": 6, "jun": 6, "june": 6, "julho": 7, "jul": 7, "july": 7, "agosto": 8, "ago": 8, "aug": 8, "august": 8,
    "setembro": 9, "set": 9, "sep": 9, "sept": 9, "september": 9, "outubro": 10, "out": 10, "oct": 10, "october": 10,
    "novembro": 11, "nov": 11, "november": 11, "dezembro": 12, "dez": 12, "dec": 12, "december": 12,
}
MONTH_NAMES = "|".join(sorted(MONTHS, key=len, reverse=True))
WEEKDAYS = {
    "domingo": 1, "sunday": 1, "sun": 1, "segunda": 2, "monday": 2, "mon": 2, "terca": 3, "tuesday": 3, "tues": 3,
    "tue": 3, "quarta": 4, "wednesday": 4, "wed": 4, "quinta": 5, "thursday": 5, "thurs": 5, "thu": 5, "sexta": 6,
    "friday": 6, "fri": 6, "sabado": 7, "saturday": 7, "sat": 7,
}
WEEKDAY_NAMES = "|".join(sorted(WEEKDAYS, key=len, reverse=True))
MAX_DURATION_MINUTES = 7 * 24 * 60
TRAILING = {"as", "a", "at", "on", "em", "no", "na", "de", "do", "da", "para", "for", "to", "in", "from", "das", "dos",
            "entre", "between", "por", "ate", "until", "e", "and", "-", "–", ",", "o", "the", "dia", "day", "@", "com-o"}
PUNCT = set("-–,;:@")


@dataclass
class QuickEvent:
    title: str
    start: datetime
    end: datetime
    all_day: bool
    calendar_name: str | None
    location: str | None
    has_date: bool
    has_time: bool


@dataclass
class Clock:
    hour: int
    minute: int


def _fold_char(char: str) -> str:
    stripped = "".join(c for c in unicodedata.normalize("NFD", char) if unicodedata.category(c) != "Mn").lower()
    return stripped if len(stripped) == len(char) else "?" * len(char)


def fold(text: str) -> str:
    return "".join(_fold_char(c) for c in unicodedata.normalize("NFC", text))


@lru_cache(maxsize=None)
def rx(pattern: str) -> re.Pattern:
    return re.compile(pattern)


class Text:
    def __init__(self, source: str) -> None:
        composed = unicodedata.normalize("NFC", source)
        self.original = composed
        self.folded = fold(composed)

    def matches(self, pattern: str) -> list[re.Match]:
        return list(rx(pattern).finditer(self.folded))

    def first(self, pattern: str) -> re.Match | None:
        return rx(pattern).search(self.folded)

    def g(self, match: re.Match, index: int) -> str | None:
        return match.group(index)

    def raw(self, match: re.Match, index: int) -> str | None:
        start = match.start(index)
        return None if start < 0 else self.original[start:match.end(index)]

    def int(self, match: re.Match, index: int) -> int | None:
        value = match.group(index)
        try:
            return int(value) if value is not None else None
        except ValueError:
            return None

    def blank(self, start: int, end: int) -> None:
        if start < 0:
            return
        spaces = " " * (end - start)
        self.original = self.original[:start] + spaces + self.original[end:]
        self.folded = self.folded[:start] + spaces + self.folded[end:]


def parse(text_in: str, now: datetime, tz: tzinfo | None = None, calendar_names: list[str] | None = None,
          default_minutes: int = 60) -> QuickEvent | None:
    trimmed = text_in.strip()
    if not trimmed:
        return None
    now = now.astimezone(tz)
    local_now = now.replace(tzinfo=None)
    today = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    text = Text(trimmed)
    all_day = False
    start_clock: Clock | None = None
    end_clock: Clock | None = None
    end_had_meridiem = False
    day: datetime | None = None
    relative_start: datetime | None = None
    duration: int | None = None

    calendar_name = _take_calendar(text, calendar_names or [])
    location = _take_location(text)

    if m := text.first(r"\b(?:o\s+)?dia\s+(?:todo|inteiro)\b|\ball[\s-]?day\b|\bwhole\s+day\b"):
        all_day = True
        text.blank(m.start(), m.end())

    if m := text.first(r"\b(?:em|daqui\s+a|in)\s+(\d{1,4}|uma?|an?|meia|half(?:\s+an?)?)\s*"
                       r"(horas?|hours?|hrs?|h|minutos?|minutes?|mins?|dias?|days?|semanas?|weeks?)\b"):
        word = m.group(1) or "1"
        try:
            quantity = float(word)
        except ValueError:
            quantity = 0.5 if word.startswith(("meia", "half")) else 1.0
        unit = m.group(2) or "h"
        if unit.startswith("m"):
            relative_start = _round_minute(now + timedelta(seconds=quantity * 60))
        elif unit.startswith("h"):
            relative_start = _round_minute(now + timedelta(seconds=quantity * 3600))
        elif unit.startswith("d"):
            day = today + timedelta(days=min(int(quantity), 3650))
        else:
            day = today + timedelta(days=min(int(quantity), 520) * 7)
        text.blank(m.start(), m.end())

    found = _take_duration(text)
    if found is not None:
        duration = found

    if day is None:
        day = _take_numeric_date(text, today)

    if relative_start is None:
        taken = _take_range(text)
        if taken:
            start_clock, end_clock, end_had_meridiem = taken
        else:
            start_clock = _take_clock(text)

    if m := text.first(r"\btonight\b"):
        day = day or today
        start_clock = start_clock or Clock(20, 0)
        text.blank(m.start(), m.end())

    if day is None:
        day = _take_named_date(text, today)

    if start_clock is None and relative_start is None and day is not None:
        start_clock = _take_day_part(text)

    title = _cleaned(text)
    has_date = day is not None or relative_start is not None
    has_time = start_clock is not None or relative_start is not None

    if all_day or (day is not None and start_clock is None and relative_start is None):
        first = day or today
        last_midnight = first + timedelta(days=1)
        return QuickEvent(title, _local(first, tz), _local(last_midnight, tz) - timedelta(seconds=1), True,
                          calendar_name, location, True, False)
    if relative_start is not None:
        start = relative_start
    elif start_clock is not None:
        wall = _at(start_clock, day or today)
        start = _local(wall, tz)
        if day is None and start <= now:
            start = _local(wall + timedelta(days=1), tz)
    else:
        start = _next_quarter(now)
    if end_clock is not None:
        base = start.astimezone(tz).replace(tzinfo=None).replace(hour=0, minute=0, second=0, microsecond=0)
        end_wall = _at(end_clock, base)
        first_try = True
        while _local(end_wall, tz) <= start:
            shifted = end_wall + timedelta(hours=12)
            if first_try and not end_had_meridiem and end_clock.hour < 12 and _local(shifted, tz) > start:
                end_wall = shifted
            else:
                end_wall += timedelta(days=1)
            first_try = False
        end = _local(end_wall, tz)
    else:
        end = start + timedelta(minutes=duration if duration is not None else default_minutes)
    return QuickEvent(title, start, end, False, calendar_name, location, has_date, has_time)


def _local(wall: datetime, tz: tzinfo | None) -> datetime:
    if tz is None:
        return wall.astimezone()
    return wall.replace(tzinfo=tz).astimezone(timezone.utc).astimezone(tz)


def _at(clock: Clock, day: datetime) -> datetime:
    return day.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(minutes=clock.hour * 60 + clock.minute)


def _round_minute(moment: datetime) -> datetime:
    seconds = int(moment.timestamp() / 60 + 0.5) * 60
    return datetime.fromtimestamp(seconds, moment.tzinfo)


def _next_quarter(moment: datetime) -> datetime:
    return datetime.fromtimestamp((int(moment.timestamp() // 900) + 1) * 900, moment.tzinfo)


def _cleaned(text: Text) -> str:
    words = text.original.split()

    def connector(word: str) -> bool:
        return fold(word) in TRAILING or all(c in PUNCT for c in word)

    while words and connector(words[-1]):
        words.pop()
    while words and all(c in PUNCT for c in words[0]):
        words.pop(0)
    return " ".join(words).strip("-–,;: ")


def _take_calendar(text: Text, known: list[str]) -> str | None:
    if m := text.first(r"(?<![^\W_])#([\w-]+)"):
        name = text.raw(m, 1)
        text.blank(m.start(), m.end())
        return name
    pattern = (r"(?:\b(?:no|na|em|in|on|to|para)\s+)?\b(?:calendario|calendar)\b\s*:?\s*"
               r"(?:(?:do|da|de|chamado|named|called)\s+)?(.+?)(?=\s+@|$)")
    m = text.first(pattern)
    if m is None:
        return None
    rest = m.group(1)
    folded_known = [(name, fold(name)) for name in known]
    hits = [h for h in folded_known if rest == h[1] or rest.startswith(h[1] + " ")]
    if hits:
        hit = max(hits, key=lambda h: len(h[1]))
        if len(hit[1]) <= len(rest):
            text.blank(m.start(), m.start(1) + len(hit[1]))
            return hit[0]
    name = (text.raw(m, 1) or "").strip()
    text.blank(m.start(), m.end())
    return name


def _take_location(text: Text) -> str | None:
    m = text.first(r"(?:(?<!\S)@(?!\s*\d{1,2}(?::\d{2})?\s*(?:am|pm|h)\b)|\b(?:local|location)\s*:)\s*(.+?)\s*$")
    if m is None:
        return None
    place = (text.raw(m, 1) or "").strip()
    text.blank(m.start(), m.end())
    return place or None


def _take_duration(text: Text) -> int | None:
    tails = [
        (r"(\d{1,4})\s*h(?:ours?|oras?|rs?)?\s*(?:e|and)?\s*(\d{1,2})\s*(?:m|min\w*)\b",
         lambda m, t: (t.int(m, 1) or 0) * 60 + (t.int(m, 2) or 0)),
        (r"(\d{1,4})h(\d{2})\b", lambda m, t: (t.int(m, 1) or 0) * 60 + (t.int(m, 2) or 0)),
        (r"(\d{1,4}(?:[.,]\d{1,2})?)\s*(?:h|hr|hrs|hours?|horas?)\b",
         lambda m, t: int(round(float(m.group(1).replace(",", ".")) * 60 + 1e-9))),
        (r"(\d{1,4})\s*(?:m|min|mins|minutos?|minutes?)\b", lambda m, t: t.int(m, 1)),
        (r"(?:uma?|an?)\s+(?:hora|hour)\b", lambda m, t: 60),
        (r"(?:meia\s+hora|half\s+an?\s+hour|half\s+hour)\b", lambda m, t: 30),
        (r"(?:um|uma|a|an)\s+(?:minuto|minute)\b", lambda m, t: 1),
    ]
    for keyword in text.matches(r"\b(?:por|for|durante|lasting)\s+"):
        tail_start = keyword.end()
        for pattern, minutes in tails:
            m = rx(pattern).match(text.folded, tail_start)
            if m is None:
                continue
            value = minutes(m, text)
            if value is None or value < 1 or value > MAX_DURATION_MINUTES:
                continue
            text.blank(keyword.start(), m.end())
            return value
    return None


def _resolve(hour: int, minute: int, meridiem: str | None) -> Clock | None:
    if not 0 <= minute <= 59:
        return None
    if meridiem:
        if not 1 <= hour <= 12:
            return None
        return Clock(hour % 12 + (12 if meridiem.startswith("p") else 0), minute)
    if not 0 <= hour <= 24 or (hour == 24 and minute > 0):
        return None
    return Clock(hour % 24, minute)


def _take_range(text: Text) -> tuple[Clock, Clock, bool] | None:
    atom = r"(\d{1,2})(?:[:h](\d{2})|h)?\s*(am|pm)?"
    pattern = (r"(?<![\d:/.\-])(?<!\bdia\s)(?<!\bday\s)(?<!\bthe\s)(?<!\bon\s)(?:(das?|from|entre|between)\s+)?" + atom
               + r"\s*(-|–|—|\ba\b|\bas\b|\bate\b|\bto\b|\band\b|\be\b|\buntil\b|\btill\b)\s*" + atom + r"(?![\d:/])")
    for m in text.matches(pattern):
        prefix = m.group(1)
        h1, m1, mer1 = text.int(m, 2), text.int(m, 3) or 0, m.group(4)
        separator = m.group(5) or ""
        h2, m2, mer2 = text.int(m, 6), text.int(m, 7) or 0, m.group(8)
        if h1 is None or h2 is None:
            continue
        marked = any(c in "h:" for c in m.group(0)) or mer1 is not None or mer2 is not None
        dashed = separator in ("-", "–", "—")
        if not dashed and not marked and prefix is None:
            continue
        if not marked and prefix is None and h1 < 6:
            continue
        first_meridiem = mer1
        if mer1 is None and mer2 is not None:
            opposite = "am" if mer2.startswith("p") else "pm"
            first_meridiem = mer2 if h1 % 12 <= h2 % 12 else opposite
        a, b = _resolve(h1, m1, first_meridiem), _resolve(h2, m2, mer2)
        if a is None or b is None:
            continue
        text.blank(m.start(), m.end())
        return a, b, mer2 is not None
    return None


def _take_day_part(text: Text) -> Clock | None:
    m = text.first(r"(?:\b(?:a|de|da|na|pela|in the|this)\s+)?\b(noite|tarde|manha|tonight|evening|afternoon|morning)\b")
    if m is None:
        return None
    word = m.group(1)
    text.blank(m.start(), m.end())
    if word in ("manha", "morning"):
        return Clock(9, 0)
    return Clock(15, 0) if word in ("tarde", "afternoon") else Clock(20, 0)


def _take_clock(text: Text) -> Clock | None:
    def hour_ampm(m, t):
        h = t.int(m, 1)
        return None if h is None else _resolve(h, t.int(m, 2) or 0, m.group(3))

    def hour_h(m, t):
        h = t.int(m, 1)
        return None if h is None else _resolve(h, t.int(m, 2) or 0, None)

    def colon(m, t):
        h = t.int(m, 1)
        return None if h is None else _resolve(h, t.int(m, 2) or 0, None)

    def bare(m, t):
        h = t.int(m, 1)
        return None if h is None else _resolve(h + 12 if 1 <= h <= 6 else h, 0, None)

    def named(m, t):
        word = m.group(1)
        return Clock(0 if "noite" in word or "night" in word else 12, 0)

    patterns = [
        (r"(?:\b(?:as|at|@)\s+)?(?<![\d:/.])(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b", hour_ampm),
        (r"(?:\b(?:as|at|@|a)\s+)?(?<![\d:/.])(\d{1,2})h(\d{2})?\b", hour_h),
        (r"(?<![\d:/.])(\d{1,2}):(\d{2})\b", colon),
        (r"\b(?:as|at|@)\s+(\d{1,2})\b(?![/:\d])", bare),
        (r"\b(meio[\s-]?dia|noon|midday|meia[\s-]?noite|midnight)\b", named),
    ]
    for pattern, build in patterns:
        for m in text.matches(pattern):
            clock = build(m, text)
            if clock is None:
                continue
            text.blank(m.start(), m.end())
            return clock
    return None


def _make_date(year: int | None, month: int, day: int, today: datetime) -> datetime | None:
    def make(y: int) -> datetime | None:
        try:
            return datetime(y, month, day)
        except ValueError:
            return None

    if year is not None:
        return make(2000 + year if year < 100 else year)
    first = make(today.year)
    if first is None:
        return None
    return first if first >= today else make(today.year + 1)


def _take_numeric_date(text: Text, today: datetime) -> datetime | None:
    m = text.first(r"\b(\d{4})-(\d{2})-(\d{2})\b")
    if m:
        found = _make_date(text.int(m, 1), text.int(m, 2), text.int(m, 3), today)
        if found:
            text.blank(m.start(), m.end())
            return found
    for m in text.matches(r"(?<![\d/])(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?![\d/])"):
        a, b, year = text.int(m, 1), text.int(m, 2), text.int(m, 3)
        if a is None or b is None:
            continue
        if a > 12 and b <= 12:
            d, mo = a, b
        elif b > 12 and a <= 12:
            d, mo = b, a
        else:
            d, mo = a, b
        found = _make_date(year, mo, d, today)
        if found:
            text.blank(m.start(), m.end())
            return found
    return None


def _take_named_date(text: Text, today: datetime) -> datetime | None:
    def plus(days: int) -> datetime:
        return today + timedelta(days=days)

    if m := text.first(r"\b(depois\s+de\s+amanha|day\s+after\s+tomorrow|amanha|tomorrow|tmrw|hoje|today)\b"):
        word = m.group(1)
        text.blank(m.start(), m.end())
        if word.startswith(("depois", "day after")):
            return plus(2)
        if word.startswith(("amanha", "tomorrow")) or word == "tmrw":
            return plus(1)
        return today
    if m := text.first(r"\b(?:semana\s+que\s+vem|proxima\s+semana|next\s+week)\b"):
        text.blank(m.start(), m.end())
        return plus(7)
    weekday = (r"\b(?:(proxima|proximo|next|this|esta|este)\s+)?(" + WEEKDAY_NAMES
               + r")(?:[\s-]feira)?\b(?:\s+(que\s+vem|next))?")
    if (m := text.first(weekday)) and m.group(2) in WEEKDAYS:
        target = WEEKDAYS[m.group(2)]
        current = (today.weekday() + 1) % 7 + 1
        delta = (target - current + 7) % 7
        modifier = m.group(1) or ""
        if (modifier.startswith("prox") or modifier == "next" or m.group(3) is not None) and delta == 0:
            delta = 7
        text.blank(m.start(), m.end())
        return plus(delta)
    m = text.first(r"(?<![\d/])(\d{1,2})(?:o|st|nd|rd|th|º)?\s*(?:de\s+)?(" + MONTH_NAMES + r")\b(?:\s+(?:de\s+)?(\d{4}))?")
    if m and text.int(m, 1) is not None and m.group(2) in MONTHS:
        found = _make_date(text.int(m, 3), MONTHS[m.group(2)], text.int(m, 1), today)
        if found:
            text.blank(m.start(), m.end())
            return found
    m = text.first(r"\b(" + MONTH_NAMES + r")\s+(\d{1,2})(?:st|nd|rd|th)?\b(?!\s*[:h]\d)")
    if m and m.group(1) in MONTHS and text.int(m, 2) is not None:
        found = _make_date(None, MONTHS[m.group(1)], text.int(m, 2), today)
        if found:
            text.blank(m.start(), m.end())
            return found
    for pattern in (r"\b(?:dia|day)\s+(\d{1,2})\b", r"\b(?:on\s+)?the\s+(\d{1,2})(?:st|nd|rd|th)\b",
                    r"\bon\s+(\d{1,2})(?:st|nd|rd|th)\b"):
        m = text.first(pattern)
        number = text.int(m, 1) if m else None
        if number is None or not 1 <= number <= 31:
            continue
        year, month = today.year, today.month
        for _ in range(14):
            try:
                built = datetime(year, month, number)
            except ValueError:
                built = None
            if built is not None and built >= today:
                text.blank(m.start(), m.end())
                return built
            month += 1
            if month > 12:
                year, month = year + 1, 1
    return None
