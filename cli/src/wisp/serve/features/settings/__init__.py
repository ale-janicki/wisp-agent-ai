import asyncio
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from wisp import __version__, aprendizados
from wisp.engines import read_active
from wisp.paths import WispPaths

from . import automations, store, updates, wisp_cli
from .wisp_cli import run_report, run_wisp

ENGINES = ("claude", "codex", "local")
SETUP_STEPS = ("system", "brain", "harness", "profile", "shim")
PATH_KEYS = ("wisp_dir", "brain")
LESSON_ACTIONS = ("confirm", "discard", "forget")
DOCTOR_TIMEOUT = 40
TELEGRAM_FAILED = "Não consegui falar com o Telegram. Tente de novo."
PROFILE_FAILED = "Não consegui salvar o perfil."
CHECK_FAILED = "Não consegui conferir agora."


async def body(request: Request) -> dict:
    try:
        value = await request.json()
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def bad(message: str) -> Response:
    return JSONResponse({"error": message}, status_code=400)


async def off_loop(fn, *args):
    return await asyncio.to_thread(fn, *args)


def first_upper(text: str) -> str:
    return text[:1].upper() + text[1:]


def doctor_report(only: str = "", timeout: float = DOCTOR_TIMEOUT) -> dict | None:
    result = run_wisp(["doctor", "--json", *(["--only", only] if only else [])], timeout=timeout)
    parsed = wisp_cli.last_json(result.stdout) if result.exit == 0 and not result.timed_out else None
    return parsed if parsed and isinstance(parsed.get("checks"), list) else None


def lessons_payload(brain: str | None) -> dict:
    root = Path(brain).expanduser() if brain else None
    if root is None or not root.is_dir():
        return {"lessons": [], "pending": []}

    def parse(lines: list[str]) -> list[dict]:
        out = []
        for number, line in enumerate(lines, 1):
            parts = line[2:].split(aprendizados.SEPARATOR)
            origin = parts[2].strip() if len(parts) > 2 else None
            out.append({"number": number, "rule": parts[0].strip(), "date": parts[1].strip() if len(parts) > 1 else None,
                        "origin": origin, "learned_alone": origin == aprendizados.HARVEST_ORIGIN})
        return out

    return {"lessons": parse(aprendizados.read_lines(aprendizados.lessons_path(root))),
            "pending": parse(aprendizados.read_lines(aprendizados.pending_path(root)))}


def state_payload() -> dict:
    cfg = store.config()
    profile = store.read_profile() or {}
    persona = profile.get("persona") if isinstance(profile.get("persona"), dict) else {}
    brain = cfg.brain
    default_brain = cfg.wisp_dir.rstrip("/\\") + "/brain"
    raw = {}
    try:
        raw = json.loads(Path(WispPaths.current().config, "wisp.json").read_text("utf-8"))
    except (OSError, ValueError):
        pass
    missing = not brain or not Path(brain).expanduser().is_dir()
    return {
        "version": __version__, "platform": sys.platform,
        "engine": read_active(Path(cfg.wisp_dir).expanduser()),
        "permission": store.permission(),
        "paths": {"wisp_dir": cfg.wisp_dir, "has_wisp_dir": isinstance(raw.get("wisp_dir"), str),
                  "brain": brain, "brain_default": default_brain, "brain_missing": missing, "brain_learn": cfg.brain_learn},
        "profile": {"name": persona.get("name") or "Wisp", "user": persona.get("user") or "", "avatar": persona.get("avatar")},
        "notices": store.notices(),
        "blocks": {name: bool(store.blocks().get(name)) for name in ("routines", "hooks", "commands")},
        "setup_finished": store.setup_finished(),
    }


async def get_state(request: Request) -> Response:
    return JSONResponse(await off_loop(state_payload))


async def get_doctor(request: Request) -> Response:
    only = request.query_params.get("only", "")
    report = await off_loop(doctor_report, only)
    if report is None:
        return JSONResponse({"error": CHECK_FAILED}, status_code=502)
    return JSONResponse(report)


async def post_engine(request: Request) -> Response:
    engine = (await body(request)).get("engine")
    if engine not in ENGINES:
        return bad("motor desconhecido")
    return JSONResponse(await off_loop(lambda: run_report(["config", "set", "engine", engine, "--json"], step="config")))


async def post_path(request: Request) -> Response:
    data = await body(request)
    key, value = data.get("key"), data.get("value")
    if key not in PATH_KEYS or not isinstance(value, str) or not value.strip():
        return bad("caminho inválido")
    return JSONResponse(await off_loop(lambda: run_report(["config", "set", key, value, "--json"], step="config", timeout=120)))


async def post_permission(request: Request) -> Response:
    problem = await off_loop(store.set_permission, (await body(request)).get("choice"))
    return JSONResponse({"ok": problem is None, "error": problem, "permission": await off_loop(store.permission)})


async def post_learn(request: Request) -> Response:
    on = (await body(request)).get("on")
    if not isinstance(on, bool):
        return bad("on (bool) is required")
    try:
        await off_loop(store.set_brain_learn, on)
    except (OSError, ValueError) as error:
        return JSONResponse({"ok": False, "error": f"Não consegui salvar no wisp.json: {error}"})
    return JSONResponse({"ok": True})


def create_brain() -> dict:
    for step in ("brain", "profile"):
        report = run_report(["setup", step, "--json"], step=step, timeout=120)
        if report["status"] in ("failed", "needs_user"):
            return {"ok": False, "error": first_upper(report["summary"]), "report": report}
    return {"ok": True}


async def post_brain_create(request: Request) -> Response:
    return JSONResponse(await off_loop(create_brain))


async def get_lessons(request: Request) -> Response:
    return JSONResponse(await off_loop(lambda: lessons_payload(store.config().brain)))


def change_lesson(action: str, number: int) -> dict:
    brain = store.config().brain
    root = Path(brain).expanduser() if brain else None
    if root is None or not root.is_dir():
        return {"ok": False, "error": "O brain ainda não existe."}
    path, pending = aprendizados.lessons_path(root), aprendizados.pending_path(root)
    try:
        if action == "confirm":
            done = aprendizados.confirm(path, pending, number)
        elif action == "discard":
            done = aprendizados.remove(pending, number, aprendizados.PENDING_HEADER)
        else:
            done = aprendizados.remove(path, number)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": f"Não consegui salvar no wisp.json: {error}"}
    return {"ok": done is not None, "error": None if done is not None else "Essa regra não existe mais."}


async def post_lesson(request: Request) -> Response:
    action, number = request.path_params["action"], (await body(request)).get("number")
    if action not in LESSON_ACTIONS or not isinstance(number, int) or isinstance(number, bool):
        return bad("ação inválida")
    return JSONResponse(await off_loop(change_lesson, action, number))


async def post_profile(request: Request) -> Response:
    data = await body(request)
    name, user = data.get("name"), data.get("user_name")
    if not isinstance(name, str) or not name.strip() or not isinstance(user, str) or not user.strip():
        return bad("name e user_name são obrigatórios")
    args = ["setup", "profile", "--name", name, "--user-name", user]
    if isinstance(data.get("avatar"), str) and data["avatar"]:
        args += ["--avatar", data["avatar"]]
    report = await off_loop(lambda: run_report([*args, "--json"], step="profile"))
    if report["summary"] in (wisp_cli.NO_ANSWER, wisp_cli.COULD_NOT_RUN, wisp_cli.TIMED_OUT):
        report = {**report, "summary": PROFILE_FAILED}
    return JSONResponse({**report, "summary": first_upper(report["summary"])})


TELEGRAM_ARGS = {"connect": ["--token-stdin"], "discover": ["--discover"], "disconnect": ["--skip"]}


def telegram_status() -> dict:
    report = doctor_report("telegram", 20)
    check = next((c for c in (report or {}).get("checks", []) if c.get("id") == "telegram"), {})
    return {"configured": isinstance(check.get("data"), dict) and "job" in check["data"]}


def telegram_run(action: str, token: str | None) -> dict:
    stdin = token.strip().encode() if action == "connect" and token else None
    result = run_wisp(["setup", "telegram", *TELEGRAM_ARGS[action], "--json"], stdin=stdin, timeout=150 if action == "discover" else 60)
    report = wisp_cli.report_of(result, "telegram")
    if report["summary"] in (wisp_cli.NO_ANSWER, wisp_cli.COULD_NOT_RUN, wisp_cli.TIMED_OUT):
        return {"ok": False, "message": TELEGRAM_FAILED, "token_stored": False, **telegram_status()}
    return {"ok": report["status"] != "failed", "message": first_upper(report["summary"]),
            "token_stored": action == "connect" and report["status"] == "needs_user", **telegram_status()}


async def get_telegram(request: Request) -> Response:
    return JSONResponse(await off_loop(telegram_status))


async def post_telegram(request: Request) -> Response:
    data = await body(request)
    action = data.get("action")
    if action not in TELEGRAM_ARGS or (action == "connect" and not (isinstance(data.get("token"), str) and data["token"].strip())):
        return bad("ação inválida")
    return JSONResponse(await off_loop(telegram_run, action, data.get("token")))


def launch_login(kind: str) -> dict:
    report = doctor_report("claude" if kind == "claude" else "codex", 40)
    check = next((c for c in (report or {}).get("checks", []) if c.get("id") == kind), None)
    path = (check or {}).get("data", {}).get("path") if check and check.get("ok") else None
    if not path:
        return {"ok": False, "error": f"O {kind.capitalize()} não está instalado."}
    argv = [path, "auth", "login"] if kind == "claude" else [path, "login"]
    flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
    try:
        subprocess.Popen(argv, creationflags=flags, stdin=None, close_fds=True)  # noqa: S603
    except OSError:
        return {"ok": False, "error": "Não consegui abrir o terminal do login."}
    return {"ok": True, "command": " ".join(argv)}


async def post_setup_step(request: Request) -> Response:
    step = request.path_params["step"]
    if step not in SETUP_STEPS:
        return JSONResponse({"error": "not found"}, status_code=404)
    timeout = 1200 if step == "system" else 180
    return JSONResponse(await off_loop(lambda: run_report(["setup", step, "--json"], step=step, timeout=timeout)))


async def post_login(request: Request) -> Response:
    kind = (await body(request)).get("engine", "claude")
    if kind not in ("claude", "codex"):
        return bad("motor desconhecido")
    return JSONResponse(await off_loop(launch_login, kind))


async def post_setup_finish(request: Request) -> Response:
    await off_loop(store.finish_setup, datetime.now(timezone.utc).isoformat())
    return JSONResponse({"ok": True})


async def post_notices(request: Request) -> Response:
    return JSONResponse(await off_loop(store.set_notices, await body(request)))


async def get_routines(request: Request) -> Response:
    return JSONResponse(await off_loop(automations.routines))


async def post_routine_toggle(request: Request) -> Response:
    data = await body(request)
    if not isinstance(data.get("label"), str) or not isinstance(data.get("on"), bool):
        return bad("label e on são obrigatórios")
    return JSONResponse(await off_loop(automations.toggle_routine, data["label"], data["on"]))


async def get_routine_log(request: Request) -> Response:
    label = request.query_params.get("label", "")
    index = int(request.query_params["index"]) if request.query_params.get("index", "").isdigit() else 0
    return JSONResponse(await off_loop(automations.routine_log, label, index))


async def get_hooks(request: Request) -> Response:
    return JSONResponse(await off_loop(automations.hooks))


async def post_hook_toggle(request: Request) -> Response:
    data = await body(request)
    if not isinstance(data.get("id"), str) or not isinstance(data.get("on"), bool):
        return bad("id e on são obrigatórios")
    return JSONResponse(await off_loop(automations.toggle_hook, data["id"], data["on"]))


async def get_commands(request: Request) -> Response:
    return JSONResponse(await off_loop(automations.commands))


async def get_mcp(request: Request) -> Response:
    return JSONResponse(await off_loop(automations.mcp_servers))


async def get_clis(request: Request) -> Response:
    return JSONResponse(await off_loop(automations.clis, request.query_params.get("force") == "1"))


async def get_update_check(request: Request) -> Response:
    return JSONResponse(await off_loop(updates.check, request.query_params.get("current", "")))


async def post_update_install(request: Request) -> Response:
    return JSONResponse(await off_loop(updates.install))


async def post_open(request: Request) -> Response:
    url = (await body(request)).get("url")
    if not isinstance(url, str) or not updates.open_url(url):
        return bad("endereço não permitido")
    return JSONResponse({"ok": True})


routes = [
    Route("/state", get_state, methods=["GET"]),
    Route("/doctor", get_doctor, methods=["GET"]),
    Route("/engine", post_engine, methods=["POST"]),
    Route("/path", post_path, methods=["POST"]),
    Route("/permission", post_permission, methods=["POST"]),
    Route("/learn", post_learn, methods=["POST"]),
    Route("/brain/create", post_brain_create, methods=["POST"]),
    Route("/lessons", get_lessons, methods=["GET"]),
    Route("/lessons/{action}", post_lesson, methods=["POST"]),
    Route("/profile", post_profile, methods=["POST"]),
    Route("/telegram", get_telegram, methods=["GET"]),
    Route("/telegram", post_telegram, methods=["POST"]),
    Route("/setup/finish", post_setup_finish, methods=["POST"]),
    Route("/setup/login", post_login, methods=["POST"]),
    Route("/setup/{step}", post_setup_step, methods=["POST"]),
    Route("/notices", post_notices, methods=["POST"]),
    Route("/routines", get_routines, methods=["GET"]),
    Route("/routines/toggle", post_routine_toggle, methods=["POST"]),
    Route("/routines/log", get_routine_log, methods=["GET"]),
    Route("/hooks", get_hooks, methods=["GET"]),
    Route("/hooks/toggle", post_hook_toggle, methods=["POST"]),
    Route("/commands", get_commands, methods=["GET"]),
    Route("/mcp", get_mcp, methods=["GET"]),
    Route("/clis", get_clis, methods=["GET"]),
    Route("/updates/check", get_update_check, methods=["GET"]),
    Route("/updates/install", post_update_install, methods=["POST"]),
    Route("/open", post_open, methods=["POST"]),
]
