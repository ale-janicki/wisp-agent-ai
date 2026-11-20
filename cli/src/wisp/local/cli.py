import argparse
import asyncio
import json
import sys
import time
from collections.abc import Callable
from pathlib import Path

from wisp.config import load_config
from wisp.local.approver import clean
from wisp.local import catalog as catalogs
from wisp.local import modelos, ollama
from wisp.local.guardrails import MODES, GuardrailsError
from wisp.local.modelos import ModelosError
from wisp.paths import WispPaths
from wisp.setup.folder import wisp_root

DISK_CHECK_INTERVAL = 1.0


def emit(event: dict) -> None:
    print(clean(json.dumps(event, ensure_ascii=False)), flush=True)


def add_parser(sub) -> None:
    local = sub.add_parser("local")
    steps = local.add_subparsers(dest="action", required=True)
    steps.add_parser("catalog")
    chat = steps.add_parser("chat")
    chat.add_argument("--message", required=True, help="the user's message, or - to read it from stdin")
    chat.add_argument("--conversation")
    chat.add_argument("--model")
    chat.add_argument("--mode", choices=MODES, default="default")
    chat.add_argument("--surface", choices=["app", "telegram"], default="app")
    chat.add_argument("--thread", type=int)
    chat.add_argument("--no-record", action="store_true")
    chat.add_argument("--approvals", choices=["tty", "stdio"], default="tty")
    pull = steps.add_parser("pull")
    pull.add_argument("tag")
    steps.add_parser("install-ollama")
    use = steps.add_parser("use")
    use.add_argument("tag")


def _status(folder: Path, client: ollama.OllamaClient, catalog: catalogs.Catalog) -> dict:
    state = modelos.read(folder)
    running = client.running()
    present = client.tags() if running else None
    installed = [t for t in state.instalados if present is None or t in present]
    return {
        **catalogs.to_json(catalog),
        "ollama": {"installed": ollama.find_cli() is not None, "running": running},
        "installed": installed,
        "active": state.ativo if state.ativo in installed else "",
    }


def _pull(folder: Path, client: ollama.OllamaClient, catalog: catalogs.Catalog, tag: str) -> int:
    entry = catalog.find(tag)
    if entry is None:
        emit({"type": "error", "message": f"{tag} não está no catálogo do Wisp"})
        return 1
    problem = ollama.room_problem(entry.size_bytes, ollama.free_bytes(Path.home()), catalog.disk_margin_bytes)
    if problem:
        emit({"type": "error", "message": problem})
        return 1
    client.ensure_running()
    stream = client.pull(tag)
    last: dict = {}
    checked = time.monotonic()
    try:
        for chunk in stream:
            last = chunk
            emit({"type": "progress", "status": chunk.get("status", ""), "completed": chunk.get("completed", 0), "total": chunk.get("total", 0)})
            if chunk.get("completed") and time.monotonic() - checked >= DISK_CHECK_INTERVAL:
                checked = time.monotonic()
                free = ollama.free_bytes(Path.home())
                if free < catalog.disk_margin_bytes:
                    emit({"type": "error", "message": f"o disco ficou com {free / 1e9:.1f} GB livres, abaixo da folga de {catalog.disk_margin_bytes / 1e9:.1f} GB; parei o download"})
                    return 1
    finally:
        stream.close()
    if last.get("status") != "success":
        emit({"type": "error", "message": f"o download de {tag} não terminou; nada foi instalado"})
        return 1
    modelos.write(folder, modelos.with_installed(modelos.read(folder), tag))
    emit({"type": "done", "tag": tag})
    return 0


def _use(folder: Path, client: ollama.OllamaClient, catalog: catalogs.Catalog, tag: str) -> int:
    if tag not in _status(folder, client, catalog)["installed"]:
        emit({"type": "error", "message": f"{tag} não está instalado neste Mac"})
        return 1
    modelos.write(folder, modelos.with_active(modelos.read(folder), tag))
    emit({"type": "done", "tag": tag})
    return 0


def _install(catalog: catalogs.Catalog) -> int:
    cli = ollama.find_cli()
    if cli is None:
        cli = ollama.install(lambda chunk: emit({"type": "progress", **chunk}), margin=catalog.disk_margin_bytes)
    emit({"type": "done", "path": str(cli)})
    return 0


def _chat(folder: Path, client: ollama.OllamaClient, args: argparse.Namespace) -> int:
    from wisp.local.approver import StdioApprover, TtyApprover
    from wisp.local.engine import EngineError, LocalEngine, record_turn

    if args.approvals == "stdio" and args.message == "-":
        raise EngineError("com --approvals stdio a mensagem vem em --message, o stdin é só das respostas de aprovação")
    text = sys.stdin.read() if args.message == "-" else args.message
    approver = StdioApprover(emit, sys.stdin) if args.approvals == "stdio" else TtyApprover()
    engine = LocalEngine(folder, load_config(), WispPaths.current(), client, approver=approver, thread=args.thread)
    exists = bool(args.conversation) and (folder / "conversas" / f"{args.conversation}.jsonl").is_file()
    session = engine.resume(args.conversation, args.model, args.mode) if exists else engine.start(args.conversation, args.model, args.mode)
    result = asyncio.run(engine.send(session, text, emit))
    if not args.no_record:
        record_turn(folder, session, args.surface, text, result)
    return 1 if result.is_error else 0


def run(args: argparse.Namespace, make_client: Callable[[], ollama.OllamaClient] = ollama.OllamaClient) -> int:
    from wisp.local.engine import EngineError

    try:
        folder = wisp_root(load_config())
        catalog = catalogs.load()
        client = make_client()
        if args.action == "catalog":
            emit(_status(folder, client, catalog))
            return 0
        if args.action == "pull":
            return _pull(folder, client, catalog, args.tag)
        if args.action == "use":
            return _use(folder, client, catalog, args.tag)
        if args.action == "install-ollama":
            return _install(catalog)
        return _chat(folder, client, args)
    except (EngineError, GuardrailsError, ModelosError, ollama.OllamaError) as e:
        emit({"type": "error", "message": str(e)})
        return 1
