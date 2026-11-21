import argparse
import contextlib
import fcntl
import hashlib
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
PENDING_REL = Path("wisp/aprendizados-pendentes.md")
MAX_LESSONS = 40
MAX_RULE = 240
MAX_ORIGIN = 80
SEPARATOR = " · "
DEFAULT_ORIGIN = "conversa"
HARVEST_ORIGIN = "colheita"
LOCK_NAME = "aprendizados.lock"
SESSIONS_DIR = "aprendizados-sessoes"
REINJECT_SOURCES = ("compact", "clear")
STATE_MAX_AGE = 7 * 24 * 3600
SAFE_SID = re.compile(r"[^A-Za-z0-9_-]")
LINK_OR_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+|https?://|www\.", re.I)
HEADER = (
    "# O que o Wisp aprendeu\n\n"
    "Uma regra por linha: `- regra · data · origem`. O Wisp lê este arquivo no começo de cada conversa. "
    "Apague uma linha para ele esquecer.\n\n"
)
PENDING_HEADER = (
    "# O que o Wisp quer aprender\n\n"
    "Regras que o Wisp tirou sozinho de uma conversa. Ele só passa a segui-las depois que você confirmar "
    "(`wisp aprender confirmar N` ou Ajustes > Brain). Apague uma linha para descartar.\n\n"
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


def pending_path(brain: Path) -> Path:
    return brain / PENDING_REL


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


def _header(path: Path, default: str = HEADER) -> str:
    try:
        text = path.read_text("utf-8", errors="replace")
    except OSError:
        return default
    head = []
    for line in text.splitlines():
        if line.startswith("- "):
            break
        head.append(line)
    return "\n".join(head).rstrip() + "\n\n" if "".join(head).strip() else default


def _write(path: Path, lines: list[str], default: str = HEADER) -> None:
    atomic_write(path, _header(path, default) + "".join(f"{line}\n" for line in lines))


def _as_harvest(line: str) -> str:
    parts = line[2:].split(SEPARATOR)
    return _line(parts[0], parts[1] if len(parts) > 1 and parts[1] else date.today().isoformat(), HARVEST_ORIGIN)


def tidy(path: Path) -> list[str]:
    with _locked():
        kept, dropped = _tidy(read_lines(path))
        if kept != _raw_lines(path):
            _write(path, kept)
        return dropped


def quarantine(path: Path, pending: Path, known: list[str]) -> list[str]:
    """Restores the active lines as they were before the harvest (`known`, in order) and moves every other line the model left
    there (an addition or an edited line) to the pending file, where nothing reads it as a rule."""
    with _locked():
        current = read_lines(path)
        kept, _ = _tidy(known)
        taken = {_key(rule_of(line)) for line in kept}
        queue = []
        for line in [*read_lines(pending), *(line for line in current if line not in known)]:
            key = _key(rule_of(line))
            if key not in taken:
                taken.add(key)
                queue.append(_as_harvest(line))
        queue = queue[-MAX_LESSONS:]
        if kept != _raw_lines(path):
            _write(path, kept)
        if queue != _raw_lines(pending) and (queue or pending.exists()):
            _write(pending, queue, PENDING_HEADER)
        return queue


def confirm(path: Path, pending: Path, number: int) -> str | None:
    with _locked():
        queue = read_lines(pending)
        if not 1 <= number <= len(queue):
            return None
        line = queue.pop(number - 1)
        lines = read_lines(path)
        if not any(_key(rule_of(old)) == _key(rule_of(line)) for old in lines):
            kept, _ = _tidy([*lines, line])
            _write(path, kept)
        _write(pending, queue, PENDING_HEADER)
        return line


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


def remove(path: Path, number: int, default: str = HEADER) -> str | None:
    with _locked():
        entries = [(raw, _sanitized(raw)) for raw in _raw_lines(path)]
        valid = [n for n, (_, line) in enumerate(entries) if line]
        if not 1 <= number <= len(valid):
            return None
        gone = entries.pop(valid[number - 1])[1]
        _write(path, [line or raw for raw, line in entries], default)
        return gone


def render(cfg: WispConfig, lines: list[str], wisp_bin: str) -> str:
    header, how = FRAMES["pt" if cfg.language.lower().startswith("pt") else "en"]
    rules = [f"- {rule_of(line)}" for line in lines]
    return "\n".join([header, *rules, how.format(wisp=shlex.quote(wisp_bin))]) + "\n"


def _marker(paths: WispPaths, session_id: object) -> Path | None:
    if not isinstance(session_id, str) or not session_id:
        return None
    return paths.state / SESSIONS_DIR / SAFE_SID.sub("_", session_id)[:80]


def _digest(lines: list[str]) -> str:
    return hashlib.sha256("\n".join(rule_of(line) for line in lines).encode()).hexdigest()


def _already_given(marker: Path | None, digest: str) -> bool:
    try:
        return marker is not None and marker.read_text() == digest
    except OSError:
        return False


def _mark_given(marker: Path, digest: str) -> None:
    directory = marker.parent
    directory.mkdir(parents=True, exist_ok=True)
    atomic_write(marker, digest)
    now = time.time()
    for old in directory.iterdir():
        try:
            if now - old.stat().st_mtime > STATE_MAX_AGE:
                old.unlink()
        except OSError:
            continue


def hook_aprendizados(cfg: WispConfig, wisp_bin: str, paths: WispPaths, payload: dict) -> str:
    if not cfg.brain:
        return ""
    brain = Path(cfg.brain).expanduser()
    marker = _marker(paths, payload.get("session_id"))
    if not brain.is_dir():
        return ""
    lines = read_lines(lessons_path(brain))[-MAX_LESSONS:]
    digest = _digest(lines)
    if payload.get("source") not in REINJECT_SOURCES and _already_given(marker, digest):
        return ""
    out = render(cfg, lines, wisp_bin)
    if marker:
        _mark_given(marker, digest)
    return out


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
    pending = pending_path(brain)
    if args.action in ("listar", "pendentes"):
        lines = read_lines(path if args.action == "listar" else pending)
        empty = "nada aprendido ainda" if args.action == "listar" else "nada pendente"
        print("\n".join(f"{n}. {line[2:]}" for n, line in enumerate(lines, 1)) if lines else empty)
        return 0
    if args.action == "confirmar":
        try:
            line = confirm(path, pending, args.number)
        except OSError as e:
            print(f"não confirmei: {e}", file=sys.stderr)
            return 1
        if line is None:
            print(f"não existe a pendente {args.number}; use `wisp aprender pendentes`", file=sys.stderr)
            return 1
        print(f"confirmado: {rule_of(line)}")
        return 0
    gone = remove(pending, args.number, PENDING_HEADER) if args.action == "descartar" else remove(path, args.number)
    if gone is None:
        print(f"não existe a regra {args.number}; use `wisp aprender listar`", file=sys.stderr)
        return 1
    print(f"{'descartado' if args.action == 'descartar' else 'esquecido'}: {rule_of(gone)}")
    return 0


def add_parser(sub) -> None:
    aprender = sub.add_parser("aprender")
    actions = aprender.add_subparsers(dest="action", required=True)
    new = actions.add_parser("add")
    new.add_argument("rule")
    new.add_argument("--origem", default=DEFAULT_ORIGIN)
    actions.add_parser("listar")
    actions.add_parser("pendentes")
    for name in ("confirmar", "descartar"):
        actions.add_parser(name).add_argument("number", type=int)
    forget = actions.add_parser("remover")
    forget.add_argument("number", type=int)

