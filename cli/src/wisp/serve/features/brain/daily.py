from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path, PurePosixPath

DEFAULT_FORMAT = "YYYY-MM-DD"
KNOWN_FORMATS = ["YYYY-MM-DD", "DD-MM-YYYY", "YYYYMMDD", "DD.MM.YYYY", "YYYY.MM.DD", "YYYY/MM/DD"]
TOKENS = ["YYYY", "YY", "MMMM", "MMM", "MM", "M", "DDDD", "DD", "Do", "D", "dddd", "ddd", "HH", "H", "hh", "h", "mm", "m", "ss", "s",
          "A", "a", "WW", "W", "ww", "w", "gggg", "GGGG"]
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


@dataclass
class DailyConfig:
    folder: str = ""
    format: str = DEFAULT_FORMAT
    template: str | None = None


def ordinal(day: int) -> str:
    if 11 <= day % 100 <= 13:
        return f"{day}th"
    return f"{day}{ {1: 'st', 2: 'nd', 3: 'rd'}.get(day % 10, 'th') }"


def _value(token: str, moment: datetime) -> str:
    iso_year, iso_week, _ = moment.isocalendar()
    hour12 = moment.hour % 12 or 12
    table = {
        "YYYY": f"{moment.year:04d}", "YY": f"{moment.year % 100:02d}", "MMMM": MONTHS[moment.month - 1],
        "MMM": MONTHS[moment.month - 1][:3], "MM": f"{moment.month:02d}", "M": str(moment.month),
        "DDDD": f"{moment.timetuple().tm_yday:03d}", "DD": f"{moment.day:02d}", "Do": ordinal(moment.day), "D": str(moment.day),
        "dddd": DAYS[moment.weekday()], "ddd": DAYS[moment.weekday()][:3], "HH": f"{moment.hour:02d}", "H": str(moment.hour),
        "hh": f"{hour12:02d}", "h": str(hour12), "mm": f"{moment.minute:02d}", "m": str(moment.minute),
        "ss": f"{moment.second:02d}", "s": str(moment.second), "A": "AM" if moment.hour < 12 else "PM",
        "a": "am" if moment.hour < 12 else "pm", "WW": f"{iso_week:02d}", "W": str(iso_week), "ww": f"{iso_week:02d}",
        "w": str(iso_week), "gggg": f"{iso_year:04d}", "GGGG": f"{iso_year:04d}",
    }
    return table[token]


def moment(fmt: str, when: date | datetime) -> str:
    stamp = when if isinstance(when, datetime) else datetime(when.year, when.month, when.day)
    out, i = "", 0
    while i < len(fmt):
        if fmt[i] == "[" and "]" in fmt[i:]:
            close = fmt.index("]", i)
            out += fmt[i + 1 : close]
            i = close + 1
            continue
        token = next((t for t in TOKENS if fmt.startswith(t, i)), None)
        if token:
            out += _value(token, stamp)
            i += len(token)
        else:
            out += fmt[i]
            i += 1
    return out


def _json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _clean(folder: str) -> str:
    return folder.strip("/ ")


def _parent(path: str) -> str:
    parent = str(PurePosixPath(path).parent)
    return "" if parent == "." else parent


def _join(folder: str, name: str) -> str:
    return f"{folder}/{name}" if folder else name


def _infer(notes: list[str]) -> DailyConfig | None:
    probe = date(2023, 11, 14)
    best: tuple[DailyConfig, int] | None = None
    folders: dict[str, list[str]] = {}
    for note in notes:
        folders.setdefault(_parent(note), []).append(note)
    for folder, paths in folders.items():
        if len(paths) < 5:
            continue
        for fmt in KNOWN_FORMATS:
            shape = re.compile("^" + "".join(r"\d" if c.isdigit() else re.escape(c) for c in moment(fmt, probe)) + "$")
            count = sum(1 for p in paths if shape.match(PurePosixPath(p).stem))
            if count * 2 >= len(paths) and count >= 5 and count > (best[1] if best else 0):
                best = (DailyConfig(folder, fmt), count)
    return best[0] if best else None


def templates_folder(root: Path, notes: list[str]) -> str | None:
    folder = _clean(str((_json(root / ".obsidian/templates.json") or {}).get("folder", "")))
    if folder:
        return folder
    return next((f for f in {_parent(n) for n in notes} if f.lower() == "templates"), None)


def load_config(root: Path, notes: list[str]) -> DailyConfig:
    daily = _json(root / ".obsidian/daily-notes.json")
    config = DailyConfig()
    if daily is not None:
        config.folder = _clean(str(daily.get("folder", "")))
        if isinstance(daily.get("format"), str) and daily["format"]:
            config.format = daily["format"]
        template = daily.get("template")
        if isinstance(template, str) and template:
            trimmed = template.strip("/ ")
            config.template = trimmed if trimmed.lower().endswith(".md") else trimmed + ".md"
    else:
        config = _infer(notes) or config
    if config.template is None:
        folder = templates_folder(root, notes)
        candidates = [folder] if folder else sorted({_parent(n) for n in notes if _parent(n).lower() == "templates"})
        config.template = next((c for c in (_join(f, "daily.md") for f in candidates if f) if c in notes), None)
    return config


def path_for(config: DailyConfig, when: date | datetime) -> str:
    return _join(config.folder, moment(config.format, when) + ".md")


def render(template: str, title: str, when: date | datetime) -> str:
    def replace(match: re.Match) -> str:
        inner = match.group(1).strip()
        name, _, fmt = inner.partition(":")
        if name == "title":
            return title
        if name == "date":
            return moment(fmt or "YYYY-MM-DD", when)
        if name == "time":
            return moment(fmt or "HH:mm", when)
        return match.group(0)

    return re.sub(r"\{\{(.*?)\}\}", replace, template)
