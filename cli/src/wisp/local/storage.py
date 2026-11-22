import shutil
from pathlib import Path


def free_bytes(path: Path) -> int:
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    return shutil.disk_usage(probe).free


def room_problem(need_bytes: int, free: int, margin: int) -> str | None:
    if free >= need_bytes + margin:
        return None
    short = need_bytes + margin - free
    return f"falta espaço em disco: preciso de {gb(need_bytes)} GB mais {gb(margin)} GB de folga e há {gb(free)} GB livres (faltam {gb(short)} GB)"


def gb(value: int) -> str:
    return f"{value / 1e9:.1f}"
