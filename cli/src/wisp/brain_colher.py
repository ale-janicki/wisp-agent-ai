import argparse
import fcntl
import json
import os
import re
import shutil
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from wisp.config import WispConfig, _default_path, load_config
from wisp.fsops import atomic_write
from wisp.hooks import commit_brain
from wisp.paths import WispPaths
from wisp.runner import Runner, SubprocessRunner

IDLE_SECONDS = 30 * 60
DUE_SECONDS = 10 * 60
MODEL_TIMEOUT_SECONDS = 600
MIN_USER_MESSAGES = 3
MAX_PER_RUN = 3
MAX_ATTEMPTS_PER_RUN = MAX_PER_RUN * 3
MAX_CHARS = 60_000
TOOLS = "Read,Write,Edit,Glob,Grep"
GUARD_MATCHER = "Bash|Read|Edit|MultiEdit|Write|NotebookEdit|Grep|Glob"
GUARD_HOOKS = ("guard-secrets", "guard-telegram", "guard-destructive")
SCOPE_HOOK = "guard-brain-scope"
SCOPE_MATCHER = "Read|Write|Edit|MultiEdit|NotebookEdit|Glob|Grep"
SESSION_ID = re.compile(r"^[A-Za-z0-9-]{1,64}$")
FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
NOT_REAL_USER = ("<command-", "<local-command", "<system-reminder", "[contexto do bot]")

SYSTEM_PROMPT = """You maintain the user's personal knowledge base (the "brain"), your working directory.
You receive a finished conversation between the user and an assistant. Turn what is durable in it into notes.

Steps:
1. Read convencoes.md and index.md in the brain root first. Follow those conventions exactly.
2. Decide what is durable: facts about the user, decisions made, preferences, stable project knowledge.
   A chat log is not durable. Do not summarize the conversation turn by turn.
3. Write or update at most 3 notes. Prefer updating an existing note over creating a new one.
   When you create a note, add its line to index.md in the format the index already uses.
4. Real commitments the user took on (something to remember or do later) go into pendencias.md,
   appended in the format that file describes. Do not duplicate a line that is already there.
5. If the conversation has nothing durable, write nothing and answer "nothing to save".
6. Never copy secrets, tokens, passwords, API keys or private keys into any note, even if they appear in the conversation.
7. Write in the language the user and the notes already use. Touch only files inside the brain.

When done, answer with one short line saying what you wrote."""


@dataclass
class Candidate:
    sid: str
    cwd: str
    title: str


@dataclass
class Slice:
    text: str
    user_messages: int
    end: int


def state_dir() -> Path:
    return WispPaths.current().state


def raw_config() -> dict:
    try:
        data = json.loads(_default_path().read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def learning_enabled(raw: dict) -> bool:
    return raw.get("brain_learn", True) is not False


def transcript_path(sid: str, cwd: str) -> Path:
    return Path.home() / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", cwd) / f"{sid}.jsonl"


def read_json(path: Path):
    try:
        return json.loads(path.read_text("utf-8"))
    except (OSError, ValueError):
        return None


def frontmatter(text: str) -> dict:
    match = FRONTMATTER.match(text)
    out = {}
    for line in match.group(1).splitlines() if match else []:
        key, sep, value = line.partition(":")
        if sep and not line.startswith((" ", "-")):
            out[key.strip()] = value.strip().strip('"')
    return out


def closed_sessions(cfg: WispConfig) -> set[str]:
    if not cfg.brain or not cfg.telegram:
        return set()
    topics = Path(cfg.brain).expanduser() / cfg.telegram.topics_rel
    keys = {
        fm["topic_key"]
        for note in topics.glob("topico-*.md")
        for fm in [frontmatter(note.read_text("utf-8", errors="replace"))]
        if fm.get("status") == "encerrado" and fm.get("topic_key")
    }
    out = set()
    for pointers in topics.glob("sessoes-*.json"):
        data = read_json(pointers)
        for key in keys:
            entry = data.get(key) if isinstance(data, dict) else None
            if isinstance(entry, dict) and entry.get("session_id"):
                out.add(str(entry["session_id"]))
    return out


def candidates(cfg: WispConfig) -> list[Candidate]:
    found: dict[str, Candidate] = {}
    app = read_json(Path.home() / "Library/Application Support/Wisp/conversations.json")
    for record in app if isinstance(app, list) else []:
        if isinstance(record, dict) and record.get("sessionId") and record.get("cwd"):
            found.setdefault(
                str(record["sessionId"]),
                Candidate(str(record["sessionId"]), str(record["cwd"]), str(record.get("title") or "")),
            )
    state = cfg.telegram.state_dir if cfg.telegram else "~/.local/state/wisp/bot"
    bot = read_json(Path(state).expanduser() / "topics.json")
    for topic in bot.values() if isinstance(bot, dict) else []:
        if isinstance(topic, dict) and topic.get("session_id") and topic.get("cwd"):
            found.setdefault(
                str(topic["session_id"]),
                Candidate(str(topic["session_id"]), str(topic["cwd"]), str(topic.get("name") or "")),
            )
    return list(found.values())


def transcript_mtime(candidate: Candidate) -> float:
    try:
        return transcript_path(candidate.sid, candidate.cwd).stat().st_mtime
    except OSError:
        return 0.0


def text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            str(block.get("text") or "") for block in content if isinstance(block, dict) and block.get("type") == "text"
        )
    return ""


def read_slice(path: Path, offset: int) -> Slice | None:
    try:
        with path.open("rb") as handle:
            handle.seek(offset)
            data = handle.read()
    except OSError:
        return None
    complete = data[: data.rfind(b"\n") + 1]
    turns: list[str] = []
    users = 0
    for line in complete.decode("utf-8", "replace").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict) or event.get("isSidechain") or event.get("isMeta"):
            continue
        kind = event.get("type")
        if kind not in ("user", "assistant"):
            continue
        message = event.get("message")
        text = text_of(message.get("content") if isinstance(message, dict) else None).strip()
        if not text:
            continue
        if kind == "user":
            if text.startswith(NOT_REAL_USER):
                continue
            users += 1
            turns.append(f"User: {text}")
        else:
            turns.append(f"Assistant: {text}")
    return Slice("\n\n".join(turns), users, offset + len(complete))


def trim(text: str) -> str:
    return text[-MAX_CHARS:]


def try_lock(path: Path) -> int | None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def load_ledger(path: Path) -> dict:
    data = read_json(path)
    return data if isinstance(data, dict) else {}


def save_ledger(path: Path, ledger: dict) -> None:
    atomic_write(path, json.dumps(ledger, indent=2, ensure_ascii=False) + "\n", mode=0o600)


def guard_settings(wisp_bin: str) -> dict:
    quoted = "'" + wisp_bin.replace("'", "'\\''") + "'"
    hooks = [{"type": "command", "command": f"{quoted} hook {name}"} for name in GUARD_HOOKS]
    scope = [{"type": "command", "command": f"{quoted} hook {SCOPE_HOOK}"}]
    return {"hooks": {"PreToolUse": [{"matcher": GUARD_MATCHER, "hooks": hooks}, {"matcher": SCOPE_MATCHER, "hooks": scope}]}}


def claude_bin(cfg: WispConfig) -> str:
    if cfg.claude_bin and os.path.isfile(os.path.expanduser(cfg.claude_bin)):
        return os.path.expanduser(cfg.claude_bin)
    found = shutil.which("claude")
    if found:
        return found
    fallback = os.path.expanduser("~/.local/bin/claude")
    return fallback if os.path.isfile(fallback) else "claude"


def model_argv(cfg: WispConfig, settings: Path) -> list[str]:
    argv = [
        claude_bin(cfg),
        "--print",
        "--no-session-persistence",
        "--permission-mode",
        "acceptEdits",
        "--tools",
        TOOLS,
        "--append-system-prompt",
        SYSTEM_PROMPT,
        "--settings",
        str(settings),
    ]
    model = os.environ.get("WISP_BRAIN_MODEL")
    return argv + ["--model", model] if model else argv


def harvest(cfg: WispConfig, runner: Runner, brain: Path, candidate: Candidate, piece: Slice) -> str | None:
    settings = state_dir() / "brain" / "guard-settings.json"
    wisp_bin = str(Path(sys.executable).parent / "wisp")
    atomic_write(settings, json.dumps(guard_settings(wisp_bin), indent=2) + "\n")
    header = f"Conversation: {candidate.title or candidate.sid}\nWorking directory: {candidate.cwd}\n\n"
    result = runner.run(
        model_argv(cfg, settings),
        stdin=(header + trim(piece.text)).encode("utf-8"),
        timeout=MODEL_TIMEOUT_SECONDS,
        env={
            **os.environ,
            "WISP_SKIP_PULL": "1",
            "WISP_BIN": wisp_bin,
            "WISP_BRAIN_SCOPE": str(brain.resolve()),
            "WISP_RECALL_OFF": "1",
        },
        cwd=brain,
    )
    if result.timed_out:
        return f"model exceeded {MODEL_TIMEOUT_SECONDS}s"
    if result.exit != 0:
        return f"claude exited {result.exit}: {result.stderr.strip()[-300:]}"
    return None


def run(cfg: WispConfig, runner: Runner, *, now: float | None = None, if_due: bool = False, dry_run: bool = False) -> dict:
    now = time.time() if now is None else now
    colhidas: list = []
    puladas: list[dict] = []
    report = {"colhidas": colhidas, "puladas": puladas}
    if not learning_enabled(raw_config()):
        puladas.append({"sid": "-", "motivo": "brain_learn desligado"})
        return report
    brain = Path(cfg.brain).expanduser() if cfg.brain else None
    if brain is None or not brain.is_dir():
        puladas.append({"sid": "-", "motivo": "brain nao encontrado"})
        return report
    base = state_dir() / "brain"
    run_fd = try_lock(base / "colher.lock")
    if run_fd is None:
        puladas.append({"sid": "-", "motivo": "outra colheita em andamento"})
        return report
    try:
        stamp = base / "ultima-execucao"
        if if_due and not dry_run:
            last = read_json(stamp)
            if isinstance(last, (int, float)) and now - last < DUE_SECONDS:
                puladas.append({"sid": "-", "motivo": "rodou ha menos de 10 min"})
                return report
        if not dry_run:
            atomic_write(stamp, json.dumps(now))
        ledger_path = base / "colhidos.json"
        ledger = load_ledger(ledger_path)
        closed = closed_sessions(cfg)
        attempts = 0
        try:
            for candidate in sorted(candidates(cfg), key=transcript_mtime, reverse=True):
                sid = candidate.sid
                if not SESSION_ID.match(sid):
                    puladas.append({"sid": sid, "motivo": "session id invalido"})
                    continue
                if sid in closed:
                    puladas.append({"sid": sid, "motivo": "topico encerrado"})
                    continue
                path = transcript_path(sid, candidate.cwd)
                try:
                    stat = path.stat()
                except OSError:
                    puladas.append({"sid": sid, "motivo": "sem transcript"})
                    continue
                if now - stat.st_mtime < IDLE_SECONDS:
                    puladas.append({"sid": sid, "motivo": "ativa ha menos de 30 min"})
                    continue
                lock_fd = try_lock(state_dir() / "locks" / f"{sid}.lock")
                if lock_fd is None:
                    puladas.append({"sid": sid, "motivo": "sessao em uso"})
                    continue
                try:
                    entry = ledger.get(sid)
                    offset = int(entry.get("offset", 0)) if isinstance(entry, dict) else 0
                    piece = read_slice(path, offset if offset <= stat.st_size else 0)
                finally:
                    os.close(lock_fd)
                if piece is None:
                    puladas.append({"sid": sid, "motivo": "transcript ilegivel"})
                    continue
                if piece.user_messages < MIN_USER_MESSAGES:
                    puladas.append({"sid": sid, "motivo": f"so {piece.user_messages} mensagens novas"})
                    continue
                if dry_run:
                    colhidas.append({"sid": sid, "title": candidate.title, "mensagens": piece.user_messages, "chars": len(piece.text)})
                    continue
                if len(colhidas) >= MAX_PER_RUN or attempts >= MAX_ATTEMPTS_PER_RUN:
                    break
                attempts += 1
                failure = harvest(cfg, runner, brain, candidate, piece)
                if failure:
                    puladas.append({"sid": sid, "motivo": failure})
                    continue
                ledger[sid] = {"offset": piece.end, "at": now}
                colhidas.append(sid)
        finally:
            if colhidas and not dry_run and commit_brain(cfg, runner):
                save_ledger(ledger_path, ledger)
    finally:
        os.close(run_fd)
    return report


def format_report(report: dict, dry_run: bool) -> str:
    lines = []
    for item in report["colhidas"]:
        if dry_run:
            lines.append(f"elegivel {item['sid']}  {item['mensagens']} mensagens  {item['title']}")
        else:
            lines.append(f"colhida {item}")
    lines += [f"pulada {item['sid']}  {item['motivo']}" for item in report["puladas"]]
    return "\n".join(lines) if lines else "nada a colher"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="wisp brain colher")
    parser.add_argument("--if-due", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    report = run(load_config(), SubprocessRunner(), if_due=args.if_due, dry_run=args.dry_run)
    print(json.dumps(report, ensure_ascii=False) if args.json else format_report(report, args.dry_run))
    return 0
