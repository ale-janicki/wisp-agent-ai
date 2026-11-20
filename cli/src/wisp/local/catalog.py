import json
from dataclasses import dataclass
from pathlib import Path

from wisp.local.guardrails import TIER_LABELS, TIERS

CATALOG_FILE = Path(__file__).with_name("catalog.json")
FALLBACK_TIER = "pequeno"
FALLBACK_CONTEXT = 8192
BIGGER_ELSEWHERE = "Para isso, use o Claude ou o Codex."


@dataclass(frozen=True)
class ModelEntry:
    tag: str
    name: str
    params: str
    size_bytes: int
    tier: str
    context_tokens: int
    memory_overhead_bytes: int
    speed: str
    limitations: str
    library_url: str

    @property
    def memory_bytes(self) -> int:
        return self.size_bytes + self.memory_overhead_bytes


@dataclass(frozen=True)
class Catalog:
    source: str
    disk_margin_bytes: int
    models: tuple[ModelEntry, ...]

    def find(self, tag: str) -> ModelEntry | None:
        return next((m for m in self.models if m.tag == tag), None)

    def tier_of(self, tag: str) -> str:
        entry = self.find(tag)
        return entry.tier if entry else FALLBACK_TIER

    def context_of(self, tag: str) -> int:
        entry = self.find(tag)
        return entry.context_tokens if entry else FALLBACK_CONTEXT

    def bigger_than(self, tag: str) -> ModelEntry | None:
        entry = self.find(tag)
        size = entry.size_bytes if entry else 0
        return next((m for m in sorted(self.models, key=lambda m: m.size_bytes) if m.size_bytes > size), None)

    def suggestion(self, tag: str) -> str:
        bigger = self.bigger_than(tag)
        if bigger is None:
            return BIGGER_ELSEWHERE
        return f"Um modelo maior, como o {bigger.name} (nível {TIER_LABELS[bigger.tier]}), dá conta com mais folga."


def load(path: Path = CATALOG_FILE) -> Catalog:
    raw = json.loads(path.read_text("utf-8"))
    models = tuple(ModelEntry(**m) for m in raw["models"])
    for model in models:
        if model.tier not in TIERS:
            raise ValueError(f"catalog: {model.tag} has the unknown tier {model.tier!r}")
    return Catalog(raw["source"], raw["disk_margin_bytes"], models)


def to_json(catalog: Catalog) -> dict:
    return {
        "source": catalog.source,
        "disk_margin_bytes": catalog.disk_margin_bytes,
        "models": [{**m.__dict__, "memory_bytes": m.memory_bytes} for m in catalog.models],
    }
