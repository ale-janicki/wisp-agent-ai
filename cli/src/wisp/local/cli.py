import argparse
import asyncio
import json
import sys
from collections.abc import Callable
from dataclasses import replace
from pathlib import Path
from urllib.parse import urlsplit

from wisp.config import load_config
from wisp.local.approver import clean
from wisp.local import catalog as catalogs
from wisp.local import arch
from wisp.local import backend as backends
from wisp.local import fetch, mlxchild, modelos, proxy, recomendar, storage
from wisp.local.guardrails import MODES, GuardrailsError
from wisp.local.modelos import ModelosError
from wisp.paths import WispPaths
from wisp.setup.folder import wisp_root



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
    chat.add_argument("--recorded", action="store_true", help="the host already wrote this message in the transcript")
    steps.add_parser("ready")
    advise = steps.add_parser("recomendar")
    advise.add_argument("--json", action="store_true")
    advise.add_argument("--chip")
    advise.add_argument("--memory-bytes", type=int)
    advise.add_argument("--available-bytes", type=int)
    advise.add_argument("--free-disk-bytes", type=int)
    pull = steps.add_parser("pull")
    pull.add_argument("tag")
    steps.add_parser("stop")
    think = steps.add_parser("pensar")
    think.add_argument("state", choices=["on", "off"])
    serve = steps.add_parser("serve")
    serve.add_argument("--model-dir", required=True)
    serve.add_argument("--port", type=int, required=True)
    serve.add_argument("--key-file", required=True)
    serve.add_argument("--idle-minutes", type=float, required=True)
    serve.add_argument("--state-dir", required=True)
    serve.add_argument("--marker", default="")
    serve.add_argument("--child-json")
    child = steps.add_parser("mlx-child")
    child.add_argument("--model-dir", required=True)
    child.add_argument("--socket", required=True)
    delete = steps.add_parser("delete")
    delete.add_argument("tag")
    use = steps.add_parser("use")
    use.add_argument("tag")
    where = steps.add_parser("backend")
    kinds = where.add_subparsers(dest="kind", required=True)
    kinds.add_parser("mlx")
    server = kinds.add_parser("openai")
    server.add_argument("--url", required=True)
    server.add_argument("--model", required=True)


def _backend(folder: Path, catalog: catalogs.Catalog, make: Callable | None) -> tuple[backends.Backend, modelos.LocalState]:
    state = modelos.read(folder)
    return (make(folder, state, catalog) if make else backends.make_backend(folder, state, catalog)), state


def _status(folder: Path, backend: backends.Backend, state: modelos.LocalState, catalog: catalogs.Catalog) -> dict:
    running = backend.running()
    downloading: list[str] = []
    resumable: list[str] = []
    if backend.kind == "mlx":
        installed = backend.available()
        for model in catalog.models:
            kind = fetch.state_of(folder, model.tag)
            if kind == "downloading":
                downloading.append(model.tag)
            elif kind == "partial":
                resumable.append(model.tag)
    else:
        installed = [state.ativo] if running and state.ativo else []
    return {
        **catalogs.to_json(catalog),
        "backend": {"kind": backend.kind, "available": backend.runtime_missing() is None and (backend.kind != "mlx" or arch.host_is_apple_silicon()), "running": running, "url": state.url},
        "installed": installed,
        "downloading": downloading,
        "resumable": resumable,
        "active": state.ativo if state.ativo in installed else "",
        "pensar": state.pensar,
    }


def _pull(folder: Path, catalog: catalogs.Catalog, tag: str) -> int:
    if not arch.host_is_apple_silicon():
        emit({"type": "error", "message": arch.NEEDS_APPLE_SILICON})
        return 1
    entry = catalog.find(tag)
    if entry is None:
        emit({"type": "error", "message": f"{tag} não está no catálogo do Wisp"})
        return 1
    try:
        fetch.download(folder, entry, lambda chunk: emit({"type": "progress", **chunk}), margin=catalog.disk_margin_bytes)
    except fetch.FetchError as e:
        emit({"type": "error", "message": str(e)})
        return 1
    modelos.write(folder, modelos.with_installed(modelos.read(folder), tag))
    emit({"type": "done", "tag": tag})
    return 0


def _use(folder: Path, backend: backends.Backend, state: modelos.LocalState, catalog: catalogs.Catalog, tag: str) -> int:
    if tag not in _status(folder, backend, state, catalog)["installed"]:
        emit({"type": "error", "message": f"{tag} não está instalado neste Mac"})
        return 1
    modelos.write(folder, modelos.with_active(state, tag))
    emit({"type": "done", "tag": tag})
    return 0


def _delete(folder: Path, state: modelos.LocalState, catalog: catalogs.Catalog, tag: str) -> int:
    if catalog.find(tag) is None:
        emit({"type": "error", "message": f"{tag} não está no catálogo do Wisp"})
        return 1
    if state.ativo == tag:
        backends.stop_server()
    fetch.remove(folder, tag)
    modelos.write(folder, replace(state, ativo="" if state.ativo == tag else state.ativo, instalados=tuple(t for t in state.instalados if t != tag)))
    emit({"type": "done", "tag": tag})
    return 0


def _plain(text: str) -> bool:
    return not any(c in text for c in ('"', "\\", "\n", "\r"))


def _set_backend(folder: Path, args: argparse.Namespace) -> int:
    state = modelos.read(folder)
    if args.kind == "mlx":
        modelos.write(folder, replace(state, backend="mlx", url="", ativo=state.ativo if state.backend == "mlx" else ""))
    else:
        url, model = args.url.strip(), args.model.strip()
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.hostname or not _plain(url):
            emit({"type": "error", "message": f"endereço do servidor inválido: {url}"})
            return 1
        if not model or not _plain(model):
            emit({"type": "error", "message": "nome de modelo inválido"})
            return 1
        modelos.write(folder, replace(state, backend="openai", url=url, ativo=model))
    backends.stop_server()
    emit({"type": "done", "backend": args.kind})
    return 0


def _ready(backend: backends.Backend, state: modelos.LocalState) -> int:
    missing = backend.readiness(state.ativo)
    emit({"type": "ready", "ready": missing is None, **({"missing": missing} if missing else {})})
    return 0


def _recomendar(catalog: catalogs.Catalog, args: argparse.Namespace) -> int:
    hardware = recomendar.Hardware(
        args.chip if args.chip is not None else recomendar.read_chip(),
        args.memory_bytes if args.memory_bytes is not None else recomendar.read_memory(),
        args.free_disk_bytes if args.free_disk_bytes is not None else storage.free_bytes(Path.home()),
        args.available_bytes if args.available_bytes is not None else (recomendar.read_available() if args.memory_bytes is None else 0),
    )
    emit(recomendar.recommend(hardware, catalog))
    return 0


def _chat(folder: Path, backend: backends.Backend, args: argparse.Namespace, servers: list | None = None) -> int:
    from wisp.local.approver import StdioApprover, TtyApprover
    from wisp.local.engine import EngineError, LocalEngine, record_turn

    if args.approvals == "stdio" and args.message == "-":
        raise EngineError("com --approvals stdio a mensagem vem em --message, o stdin é só das respostas de aprovação")
    text = sys.stdin.read() if args.message == "-" else args.message
    approver = StdioApprover(emit, sys.stdin) if args.approvals == "stdio" else TtyApprover()
    engine = LocalEngine(folder, load_config(), WispPaths.current(), backend, approver=approver, thread=args.thread, servers=servers)
    exists = bool(args.conversation) and (folder / "conversas" / f"{args.conversation}.jsonl").is_file()
    session = engine.resume(args.conversation, args.model, args.mode) if exists else engine.start(args.conversation, args.model, args.mode)
    if args.recorded:
        while session.messages and session.messages[-1].get("role") == "user":
            session.messages.pop()
    result = asyncio.run(engine.send(session, text, emit))
    if not args.no_record:
        record_turn(folder, session, args.surface, text, result)
    return 1 if result.is_error else 0


def run(args: argparse.Namespace, make: Callable | None = None, servers: list | None = None) -> int:
    from wisp.local.engine import EngineError

    try:
        folder = wisp_root(load_config())
        catalog = catalogs.load()
        if args.action == "mlx-child":
            return mlxchild.serve(args.model_dir, args.socket)
        if args.action == "serve":
            return proxy.serve(
                model=args.model_dir, port=args.port, key=Path(args.key_file).read_text("utf-8").strip(), idle_minutes=args.idle_minutes,
                info_path=Path(args.state_dir) / "server.json", child_argv=json.loads(args.child_json) if args.child_json else None,
                marker=args.marker)
        if args.action == "pensar":
            modelos.write(folder, replace(modelos.read(folder), pensar=args.state == "on"))
            emit({"type": "done", "pensar": args.state == "on"})
            return 0
        if args.action == "stop":
            emit({"type": "done", "stopped": backends.stop_server()})
            return 0
        if args.action == "pull":
            return _pull(folder, catalog, args.tag)
        if args.action == "backend":
            return _set_backend(folder, args)
        if args.action == "recomendar":
            return _recomendar(catalog, args)
        backend, state = _backend(folder, catalog, make)
        if args.action == "catalog":
            emit(_status(folder, backend, state, catalog))
            return 0
        if args.action == "use":
            return _use(folder, backend, state, catalog, args.tag)
        if args.action == "delete":
            return _delete(folder, state, catalog, args.tag)
        if args.action == "ready":
            return _ready(backend, state)
        return _chat(folder, backend, args, servers)
    except (EngineError, GuardrailsError, ModelosError, backends.BackendError, fetch.FetchError) as e:
        emit({"type": "error", "message": str(e)})
        return 1
