import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ("cli/src", "bot/src", "core/Sources", "app/Sources")
ALLOWED = {"cli/src/wisp/migrate_folder.py"}
OLD = [
    r"Support/Wisp/anexos",
    r"Wisp/anexos",
    r'"bot"\s*/\s*"anexos"',
    r'hosting\.DIR\s*/\s*"anexos"',
    r'"bot"\s*/\s*"bot\.log"',
    r"~/Wisp/brain",
    r'"Wisp/brain"',
    r'home\s*/\s*"Wisp"',
]


def test_no_code_still_points_at_a_location_the_migration_moved_away_from():
    found = []
    for folder in SOURCES:
        for path in (ROOT / folder).rglob("*"):
            relative = path.relative_to(ROOT).as_posix()
            if path.suffix not in (".py", ".swift") or relative in ALLOWED or "/.build/" in relative:
                continue
            text = path.read_text("utf-8", errors="replace")
            found += [f"{relative}: {pattern}" for pattern in OLD if re.search(pattern, text)]
    assert found == []
