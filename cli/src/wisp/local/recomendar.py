import re
import subprocess
from dataclasses import dataclass

from wisp.local import arch
from wisp.local.catalog import Catalog, ModelEntry

FITS_NUMERATOR, FITS_DENOMINATOR = 1, 2
GIB = 1 << 30
WORDS_NUMERATOR, WORDS_DENOMINATOR = 3, 4
SUBSCRIPTION = "use o Claude ou o Codex, que rodam na assinatura"
CHIP = re.compile(r"\bApple\s+M(\d+)(?:\s+(Pro|Max|Ultra))?\b", re.IGNORECASE)

APPLE_BANDWIDTH_GBS: dict[str, int] = {
    "M1": 67,
    "M1 Pro": 200,
    "M1 Max": 400,
    "M1 Ultra": 800,
    "M2": 100,
    "M2 Pro": 200,
    "M2 Max": 400,
    "M2 Ultra": 800,
    "M3": 100,
    "M3 Pro": 150,
    "M3 Max": 300,
    "M3 Ultra": 800,
    "M4": 120,
    "M4 Pro": 273,
    "M4 Max": 410,
    "M5": 153,
}


@dataclass(frozen=True)
class Hardware:
    chip: str
    memory_bytes: int
    free_disk_bytes: int


def chip_family(chip: str) -> str | None:
    match = CHIP.search(chip)
    if match is None:
        return None
    family = f"M{match.group(1)}"
    return f"{family} {match.group(2).capitalize()}" if match.group(2) else family


def bandwidth_gbs(chip: str) -> int | None:
    family = chip_family(chip)
    return APPLE_BANDWIDTH_GBS.get(family) if family else None


def gigabytes(value: int) -> str:
    return f"{value / 1e9:.1f}".replace(".", ",")


def memory_label(memory_bytes: int) -> str:
    return f"{(memory_bytes + GIB // 2) // GIB} GB"


def fits_comfortably(model: ModelEntry, memory_bytes: int) -> bool:
    return memory_bytes > 0 and model.memory_bytes * FITS_DENOMINATOR <= memory_bytes * FITS_NUMERATOR


def fits_disk(model: ModelEntry, free_disk_bytes: int, margin: int) -> bool:
    return free_disk_bytes >= model.size_bytes + margin


def tokens_per_second(bandwidth: int, model: ModelEntry) -> int:
    return (bandwidth * 1_000_000_000 + model.size_bytes // 2) // model.size_bytes


def words_per_second(bandwidth: int, model: ModelEntry) -> int:
    scaled = bandwidth * 1_000_000_000 * WORDS_NUMERATOR
    return (scaled + (model.size_bytes * WORDS_DENOMINATOR) // 2) // (model.size_bytes * WORDS_DENOMINATOR)


def speed_text(words: int | None) -> str:
    return f"~{words} palavras/s (estimativa)" if words is not None else "sem estimativa de velocidade neste chip"


def _entry(model: ModelEntry, bandwidth: int | None, reason: str) -> dict:
    return {
        "tag": model.tag,
        "name": model.name,
        "size_bytes": model.size_bytes,
        "tokens_per_second": tokens_per_second(bandwidth, model) if bandwidth else None,
        "words_per_second": words_per_second(bandwidth, model) if bandwidth else None,
        "reason": reason,
    }


def recommend(hardware: Hardware, catalog: Catalog) -> dict:
    bandwidth = bandwidth_gbs(hardware.chip)
    if not arch.chip_is_apple_silicon(hardware.chip):
        return {
            "chip": hardware.chip, "chip_family": None, "bandwidth_gbs": None, "memory_bytes": hardware.memory_bytes,
            "free_disk_bytes": hardware.free_disk_bytes, "best": None, "fastest": None, "notes": [arch.NEEDS_APPLE_SILICON],
        }
    fits_memory = [m for m in catalog.models if fits_comfortably(m, hardware.memory_bytes)]
    usable = [m for m in fits_memory if fits_disk(m, hardware.free_disk_bytes, catalog.disk_margin_bytes)]
    notes: list[str] = []
    best = fastest = None
    if usable:
        top = max(usable, key=lambda m: m.size_bytes)
        words = words_per_second(bandwidth, top) if bandwidth else None
        weak = "" if top.tools_reliable else "; erra mais ao usar ferramentas"
        best = _entry(top, bandwidth, f"cabe com folga em {memory_label(hardware.memory_bytes)}; {speed_text(words)}{weak}")
        reliable = [m for m in usable if m.tools_reliable]
        if reliable:
            small = min(reliable, key=lambda m: m.size_bytes)
            words = words_per_second(bandwidth, small) if bandwidth else None
            fastest = _entry(small, bandwidth, f"o menor que ainda usa ferramentas direito; {speed_text(words)}")
        else:
            notes.append("nenhum modelo que use ferramentas direito cabe com folga na memória e no disco deste Mac")
    elif fits_memory:
        smallest = min(fits_memory, key=lambda m: m.size_bytes)
        short = smallest.size_bytes + catalog.disk_margin_bytes - hardware.free_disk_bytes
        notes.append(
            f"falta espaço em disco: o menor modelo que cabe precisa de {gigabytes(smallest.size_bytes)} GB mais "
            f"{gigabytes(catalog.disk_margin_bytes)} GB de folga e faltam {gigabytes(short)} GB; libere espaço ou {SUBSCRIPTION}")
    else:
        notes.append(
            f"nenhum modelo local cabe com folga na memória deste Mac ({memory_label(hardware.memory_bytes)}); {SUBSCRIPTION}")
    return {
        "chip": hardware.chip,
        "chip_family": chip_family(hardware.chip),
        "bandwidth_gbs": bandwidth,
        "memory_bytes": hardware.memory_bytes,
        "free_disk_bytes": hardware.free_disk_bytes,
        "best": best,
        "fastest": fastest,
        "notes": notes,
    }


def read_chip() -> str:
    try:
        done = subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout.strip() if done.returncode == 0 else ""


def read_memory() -> int:
    try:
        done = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=5)
        return int(done.stdout.strip()) if done.returncode == 0 else 0
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return 0
