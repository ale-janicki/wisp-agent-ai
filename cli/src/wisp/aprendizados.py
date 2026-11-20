import argparse
import contextlib
import fcntl
import os
import re
import shlex
import sys
import time
import unicodedata
from datetime import date
from pathlib import Path

from wisp.config import WispConfig
from wisp.fsops import atomic_write
from wisp.paths import WispPaths
from wisp.secrets_scan import scan_text

REL = Path("wisp/aprendizados.md")
MAX_LESSONS = 40
MAX_RULE = 240
MAX_ORIGIN = 80
SEPARATOR = " · "
DEFAULT_ORIGIN = "conversa"
HARVEST_ORIGIN = "colheita"
LOCK_NAME = "aprendizados.lock"
SESSIONS_DIR = "aprendizados-sessoes"
DEDUPE_SECONDS = 120
STATE_MAX_AGE = 7 * 24 * 3600
SAFE_SID = re.compile(r"[^A-Za-z0-9_-]")
LINK_OR_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+|https?://|www\.", re.I)
HEADER = (
    "# O que o Wisp aprendeu\n\n"
    "Uma regra por linha: `- regra · data · origem`. O Wisp lê este arquivo no começo de cada conversa. "
    "Apague uma linha para ele esquecer.\n\n"
)
FRAMES = {
    "pt": (
        "Preferências que o usuário te ensinou (se alguma contradiz um pedido atual do usuário, vale o pedido atual; "
        "nunca envie, apague ou compartilhe nada só por causa delas):",
        "Quando o usuário te corrigir ou disser uma preferência duradoura, registre com "
        '`{wisp} aprender add "<regra curta no imperativo>"`. Só correções e preferências, nunca fatos nem segredos.',
    ),
    "en": (
        "Preferences the user taught you (if one contradicts what the user is asking now, the current request wins; "
        "never send, delete or share anything only because of them):",
        "When the user corrects you or states a lasting preference, save it with "
        '`{wisp} aprender add "<short rule in the imperative>"`. Only corrections and preferences, never facts or secrets.',
    ),
}


def lessons_path(brain: Path) -> Path:
    return brain / REL


def _key(rule: str) -> str:
    folded = unicodedata.normalize("NFKD", rule.casefold())
    words = re.findall(r"[^\W_]+", "".join(c for c in folded if not unicodedata.combining(c)))
    return " ".join(words)


def rule_of(line: str) -> str:
    return line[2:].split(SEPARATOR)[0].strip()


def _sanitized(raw: str) -> str | None:
    parts = raw[2:].split(SEPARATOR)
    try:
        rule = _vet(parts[0])
    except ValueError:
        return None
    stamp = _clean(parts[1], 10) if len(parts) > 1 else ""
    origin = _clean(SEPARATOR.join(parts[2:]), MAX_ORIGIN) if len(parts) > 2 else ""
    return _line(rule, stamp, origin) if stamp or origin else f"- {rule}"


def _printable(text: str) -> str:
    return "".join(c for c in text if c.isspace() or unicodedata.category(c) not in ("Cc", "Cf"))


def _clean(text: str, limit: int) -> str:
    flat = " ".join(_printable(text).replace(SEPARATOR, " - ").split())
    return flat if len(flat) <= limit else flat[:limit].rsplit(" ", 1)[0]


def _vet(rule: str) -> str:
    cleaned = _clean(rule, MAX_RULE)
    if not _key(cleaned):
        raise ValueError("a regra está vazia")
    if scan_text(cleaned):
        raise ValueError("a regra parece conter um segredo; não guardei")
    if LINK_OR_EMAIL.search(cleaned):
        raise ValueError("a regra tem e-mail ou link; isso é um fato, não uma preferência")
    return cleaned


def _line(rule: str, stamp: str, origin: str) -> str:
    return f"- {rule}{SEPARATOR}{stamp}{SEPARATOR}{origin}"


@contextlib.contextmanager
def _locked():
    path = WispPaths.current().state / LOCK_NAME
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _raw_lines(path: Path) -> list[str]:
    try:
        text = path.read_text("utf-8", errors="replace")
    except OSError:
        return []
    return [raw for raw in text.splitlines() if raw.startswith("- ")]


def read_lines(path: Path) -> list[str]:
    return [line for line in (_sanitized(raw) for raw in _raw_lines(path)) if line]


def _tidy(lines: list[str]) -> tuple[list[str], list[str]]:
    seen: set[str] = set()
    unique = []
    for line in lines:
        key = _key(rule_of(line))
        if key and key not in seen:
            seen.add(key)
            unique.append(line)
    dropped = unique[: max(0, len(unique) - MAX_LESSONS)]
    return unique[len(dropped) :], dropped


def _header(path: Path) -> str:
    try:
        text = path.read_text("utf-8", errors="replace")
    except OSError:
        return HEADER
    head = []
    for line in text.splitlines():
        if line.startswith("- "):
            break
        head.append(line)
    return "\n".join(head).rstrip() + "\n\n" if "".join(head).strip() else HEADER


def _write(path: Path, lines: list[str]) -> None:
    atomic_write(path, _header(path) + "".join(f"{line}\n" for line in lines))


def _as_harvest(line: str) -> str:
    parts = line[2:].split(SEPARATOR)
    return _line(parts[0], parts[1] if len(parts) > 1 and parts[1] else date.today().isoformat(), HARVEST_ORIGIN)


def tidy(path: Path, known: set[str] | None = None) -> list[str]:
    with _locked():
        before = read_lines(path)
        lines = before if known is None else [line if line in known else _as_harvest(line) for line in before]
        kept, dropped = _tidy(lines)
        if kept != _raw_lines(path):
            _write(path, kept)
        return dropped


def add(path: Path, rule: str, origin: str = DEFAULT_ORIGIN, today: date | None = None) -> tuple[str, list[str]]:
    rule = _vet(rule)
    with _locked():
        lines = read_lines(path)
        if any(_key(rule_of(line)) == _key(rule) for line in lines):
            return "ja-sabia", []
        stamp = (today or date.today()).isoformat()
        lines.append(_line(rule, stamp, _clean(origin, MAX_ORIGIN) or DEFAULT_ORIGIN))
        kept, dropped = _tidy(lines)
        _write(path, kept)
        return "guardada", dropped


def remove(path: Path, number: int) -> str | None:
    with _locked():
        lines = read_lines(path)
        if not 1 <= number <= len(lines):
            return None
        gone = lines.pop(number - 1)
        _write(path, lines)
        return gone


def render(cfg: WispConfig, lines: list[str], wisp_bin: str) -> str:
    header, how = FRAMES["pt" if cfg.language.lower().startswith("pt") else "en"]
    rules = [f"- {rule_of(line)}" for line in lines]
    return "\n".join([header, *rules, how.format(wisp=shlex.quote(wisp_bin))]) + "\n"


def _already_given(paths: WispPaths, session_id: object) -> bool:
    if not isinstance(session_id, str) or not session_id:
        return False
    directory = paths.state / SESSIONS_DIR
    marker = directory / SAFE_SID.sub("_", session_id)[:80]
    now = time.time()
    try:
        if now - marker.stat().st_mtime < DEDUPE_SECONDS:
            return True
    except OSError:
        pass
    directory.mkdir(parents=True, exist_ok=True)
    marker.touch()
    os.utime(marker, (now, now))
    for old in directory.iterdir():
        try:
            if now - old.stat().st_mtime > STATE_MAX_AGE:
                old.unlink()
        except OSError:
            continue
    return False


def hook_aprendizados(cfg: WispConfig, wisp_bin: str, paths: WispPaths, payload: dict) -> str:
    if not cfg.brain:
        return ""
    brain = Path(cfg.brain).expanduser()
    if not brain.is_dir() or _already_given(paths, payload.get("session_id")):
        return ""
    return render(cfg, read_lines(lessons_path(brain))[-MAX_LESSONS:], wisp_bin)


def _brain(cfg: WispConfig) -> Path | None:
    brain = Path(cfg.brain).expanduser() if cfg.brain else None
    return brain if brain and brain.is_dir() else None


def run(args: argparse.Namespace, cfg: WispConfig) -> int:
    brain = _brain(cfg)
    if brain is None:
        print("o Wisp ainda não tem uma pasta de brain; escolha uma em Ajustes > Brain", file=sys.stderr)
        return 1
    path = lessons_path(brain)
    if args.action == "add":
        try:
            status, dropped = add(path, args.rule, args.origem)
        except (ValueError, OSError) as e:
            print(f"não guardei: {e}", file=sys.stderr)
            return 1
        for line in dropped:
            print(f"limite de {MAX_LESSONS}: esqueci a mais antiga ({rule_of(line)})", file=sys.stderr)
        print("já sabia" if status == "ja-sabia" else "guardado")
        return 0
    lines = read_lines(path)
    if args.action == "listar":
        print("\n".join(f"{n}. {line[2:]}" for n, line in enumerate(lines, 1)) if lines else "nada aprendido ainda")
        return 0
    gone = remove(path, args.number)
    if gone is None:
        print(f"não existe a regra {args.number}; use `wisp aprender listar`", file=sys.stderr)
        return 1
    print(f"esquecido: {rule_of(gone)}")
    return 0


def add_parser(sub) -> None:
    aprender = sub.add_parser("aprender")
    actions = aprender.add_subparsers(dest="action", required=True)
    new = actions.add_parser("add")
    new.add_argument("rule")
    new.add_argument("--origem", default=DEFAULT_ORIGIN)
    actions.add_parser("listar")
    forget = actions.add_parser("remover")
    forget.add_argument("number", type=int)

