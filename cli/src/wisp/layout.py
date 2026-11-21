from dataclasses import dataclass
from pathlib import Path

DEFAULT_WISP_DIR = "~/Wisp"
SUBFOLDERS = ("conversas", "reunioes", "brain", "modelos", "anexos", "skills", "ferramentas", "logs")
FILES = ("agente.md", "guardrails.toml", "modelos.toml")


@dataclass(frozen=True)
class FolderLayout:
    root: Path
    conversas: Path
    reunioes: Path
    brain: Path
    modelos_dir: Path
    anexos: Path
    skills: Path
    ferramentas: Path
    logs: Path
    agente: Path
    guardrails: Path
    modelos: Path


def expand(value: str, home: Path) -> Path:
    if value == "~":
        return home
    if value.startswith("~/"):
        return home / value[2:]
    return Path(value)


def resolve_layout(raw: dict | None, home: Path) -> FolderLayout:
    raw = raw or {}
    wisp_dir = raw.get("wisp_dir")
    root = expand(wisp_dir if isinstance(wisp_dir, str) and wisp_dir else DEFAULT_WISP_DIR, home)
    brain = raw.get("brain")
    return FolderLayout(
        root=root,
        conversas=root / "conversas",
        reunioes=root / "reunioes",
        brain=expand(brain, home) if isinstance(brain, str) and brain else root / "brain",
        modelos_dir=root / "modelos",
        anexos=root / "anexos",
        skills=root / "skills",
        ferramentas=root / "ferramentas",
        logs=root / "logs",
        agente=root / "agente.md",
        guardrails=root / "guardrails.toml",
        modelos=root / "modelos.toml",
    )


def layout_of(cfg, home: Path) -> FolderLayout:
    return resolve_layout({"wisp_dir": cfg.wisp_dir, "brain": cfg.brain}, home)
