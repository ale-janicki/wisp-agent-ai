import sys
import time
from datetime import date
from pathlib import Path

from wisp.config import WispConfig
from wisp.paths import WispPaths
from wisp.runner import Runner
from wisp.secrets_scan import scan_paths

PENDENCIAS_LINES = 60
COMMIT_BUDGET_SECONDS = 10
GIT_EMAIL = "wisp@localhost"
BOOT_LABELS = {"pt": ("Hoje", "Cérebro", "Pendências"), "en": ("Today", "Brain", "Pendências")}
HELD_NOTE = "Arquivo {rel} ficou fora do commit por parecer conter um segredo"


def _brain_dir(cfg: WispConfig) -> Path | None:
    if not cfg.brain:
        return None
    brain = Path(cfg.brain).expanduser()
    return brain if brain.is_dir() else None


def hook_boot(cfg: WispConfig, paths: WispPaths) -> str:
    brain = _brain_dir(cfg)
    if brain is None:
        return ""
    today, brain_label, pending_label = BOOT_LABELS["pt" if cfg.language.lower().startswith("pt") else "en"]
    lines = [f"{today}: {date.today().isoformat()}", f"{brain_label}: {brain}"]
    pendencias = brain / "pendencias.md"
    if pendencias.is_file():
        head = pendencias.read_text(errors="replace").splitlines()[:PENDENCIAS_LINES]
        lines += ["", f"{pending_label} (pendencias.md):", *head]
    return "\n".join(lines) + "\n"


def _changed_paths(status_z: str) -> list[str]:
    return [entry[3:] for entry in status_z.split("\0") if len(entry) > 3]


def _note_held(brain: Path, held: list[str], persona: str) -> bool:
    pendencias = brain / "pendencias.md"
    text = pendencias.read_text(errors="replace") if pendencias.is_file() else ""
    new = [rel for rel in held if HELD_NOTE.format(rel=rel) not in text]
    if not new:
        return False
    lines = [
        f"- **[{persona}] Segurança — {HELD_NOTE.format(rel=rel)}**. Próximo: tirar o segredo do arquivo. Pronto quando: o arquivo entra no commit."
        for rel in new
    ]
    separator = "" if not text or text.endswith("\n") else "\n"
    pendencias.write_text(text + separator + "\n".join(lines) + "\n")
    return True


def hook_brain_commit(cfg: WispConfig, runner: Runner) -> int:
    try:
        _commit(cfg, runner)
    except Exception as e:
        print(f"wisp: o cérebro não foi salvo agora ({type(e).__name__})", file=sys.stderr)
    return 0


def _commit(cfg: WispConfig, runner: Runner) -> None:
    brain = _brain_dir(cfg)
    if brain is None or not (brain / ".git").exists():
        return
    deadline = time.monotonic() + COMMIT_BUDGET_SECONDS

    def git(*args: str):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("budget spent")
        return runner.run(["git", "-C", str(brain), *args], timeout=remaining)

    status = git("status", "--porcelain", "-z", "-uall", "--no-renames")
    if status.exit != 0:
        return
    changed = _changed_paths(status.stdout)
    present = [brain / rel for rel in changed if (brain / rel).is_file()]
    held = {path.relative_to(brain).as_posix() for path in scan_paths(present)}
    for rel in sorted(held):
        print(f"wisp: não salvei {rel} no cérebro porque parece conter uma senha ou chave", file=sys.stderr)
    safe = [rel for rel in changed if rel not in held]
    if held and _note_held(brain, sorted(held), cfg.persona) and "pendencias.md" not in held and "pendencias.md" not in safe:
        safe.append("pendencias.md")
    if not safe:
        return
    identity: list[str] = []
    if not git("config", "user.name").stdout.strip():
        identity += ["-c", f"user.name={cfg.user_name or 'Wisp'}"]
    if not git("config", "user.email").stdout.strip():
        identity += ["-c", f"user.email={GIT_EMAIL}"]
    if git("add", "--", *safe).exit != 0:
        return
    git(*identity, "commit", "-q", "-m", f"chore: save the brain {date.today().isoformat()}", "--", *safe)
