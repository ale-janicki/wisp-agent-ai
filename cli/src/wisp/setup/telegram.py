import json
import math
import os
import re
import time
from collections.abc import Callable
from pathlib import Path

from wisp.config import TelegramConfig, WispConfig, save_config
from wisp.doctor import BOT_LABEL
from wisp.fsops import atomic_write, ensure_dir
from wisp.jobs import JobManager, JobSpec, JobState
from wisp.paths import WispPaths
from wisp.report import Detail, StepReport
from wisp.runner import Runner
from wisp.setup.profile_writer import check_writable, set_telegram_block
from wisp.telegram_api import TelegramAPI, TelegramError

STEP = "telegram"
TOKEN_SHAPE = re.compile(r"\d+:[A-Za-z0-9_-]+")
DISCOVER_S = 60
UP_WAIT_S = 30
POLL_S = 10
UP_POLL_S = 1.0
sleep = time.sleep


def _token_path(paths: WispPaths) -> Path:
    return paths.config / "secrets" / "telegram-token"


def _config_path(paths: WispPaths) -> Path:
    return paths.config / "wisp.json"


def _status_up(runner: Runner, paths: WispPaths) -> tuple[bool, Detail]:
    argv = [str(paths.runtime / "venv/bin/wisp"), "topic", "status", "--json"]
    env = {**os.environ, "WISP_CONFIG": str(_config_path(paths))}
    result = runner.run(argv, timeout=20, env=env)
    detail = Detail.capture(" ".join(argv), result.exit, result.stdout, result.stderr)
    try:
        return result.exit == 0 and json.loads(result.stdout).get("up") is True, detail
    except (ValueError, AttributeError):
        return False, detail


def _wait_up(runner: Runner, paths: WispPaths, details: list[Detail]) -> bool:
    deadline = time.monotonic() + UP_WAIT_S
    while True:
        up, detail = _status_up(runner, paths)
        if up:
            return True
        if time.monotonic() >= deadline:
            details.append(detail)
            return False
        sleep(UP_POLL_S)


def _store_token(
    paths: WispPaths, api_factory: Callable[[str], TelegramAPI], raw: bytes, restart_needed: bool
) -> StepReport:
    token = raw.decode(errors="replace").strip()
    if not TOKEN_SHAPE.fullmatch(token):
        return StepReport(STEP, "failed", "o token do Telegram está vazio ou inválido")
    try:
        bot = api_factory(token).get_me()
    except TelegramError as e:
        return StepReport(STEP, "failed", str(e))
    target = _token_path(paths)
    ensure_dir(target.parent, mode=0o700)
    os.chmod(target.parent, 0o700)
    atomic_write(target, token + "\n", mode=0o600)
    username = str(bot.get("username", ""))
    if restart_needed:
        return StepReport(STEP, "needs_user", "token trocado; reinicie o bot para ele valer", data={"bot": username})
    return StepReport(
        STEP, "needs_user",
        f"Crie um grupo, ative Tópicos, adicione @{username} como admin e mande 'oi' lá",
        data={"bot": username},
    )


def _find_forum(api: TelegramAPI) -> tuple[dict | None, str | None]:
    """Waits for a person's message in a forum supergroup, ignoring everything sent before setup started.
    Returns (found, why_not); why_not is set only if a non-forum group was seen by the deadline."""
    deadline = time.monotonic() + DISCOVER_S
    api.get_updates(0)
    non_forum_seen = False
    while (remaining := deadline - time.monotonic()) > 0:
        for update in api.get_updates(max(1, min(POLL_S, math.ceil(remaining)))):
            message = update.get("message") or {}
            chat, sender = message.get("chat") or {}, message.get("from") or {}
            if chat.get("type") not in ("group", "supergroup") or sender.get("is_bot") or "id" not in sender:
                continue
            if chat["type"] == "supergroup" and api.get_chat(chat["id"]).get("is_forum") is True:
                return {"chat_id": chat["id"], "user_id": sender["id"]}, None
            non_forum_seen = True
    return None, ("ative Tópicos nesse grupo (Editar grupo → Tópicos) e mande 'oi' de novo" if non_forum_seen else None)


def _bot_can_manage_topics(api: TelegramAPI, chat_id: int) -> bool:
    member = api.get_chat_member(chat_id, api.get_me()["id"])
    return member.get("status") == "creator" or (
        member.get("status") == "administrator" and member.get("can_manage_topics") is True
    )


def _verify(runner: Runner, paths: WispPaths, jobs: JobManager) -> StepReport:
    state = jobs.state(BOT_LABEL)
    if state == JobState.RUNNING and _status_up(runner, paths)[0]:
        return StepReport(STEP, "skipped", "o Telegram já está configurado e conectado")
    return StepReport(STEP, "failed", "o Telegram está configurado, mas o bot está parado", data={"job": state.value})


def _discover(runner, paths, cfg, api_factory, jobs: JobManager) -> StepReport:
    token_file = _token_path(paths)
    if not token_file.is_file():
        return StepReport(STEP, "failed", "falta o token do bot; envie o token primeiro")
    profile = paths.config / "profile.json"
    try:
        check_writable(profile)
    except ValueError as e:
        return StepReport(STEP, "failed", str(e))
    if jobs.state(BOT_LABEL) != JobState.NOT_INSTALLED:
        return StepReport(STEP, "failed", "pare o bot antes de procurar o grupo")
    api = api_factory(token_file.read_text().strip())
    found, why = _find_forum(api)
    if found is None:
        return StepReport(STEP, "needs_user", why or "mande 'oi' no grupo do bot e tente de novo")
    if not _bot_can_manage_topics(api, found["chat_id"]):
        return StepReport(STEP, "needs_user", "torne o bot administrador do grupo com permissão para gerenciar tópicos")

    state_dir = paths.state / "bot"
    cfg.telegram = TelegramConfig(
        chat_id=found["chat_id"], user_id=found["user_id"], token_file=str(token_file), state_dir=str(state_dir)
    )
    try:
        set_telegram_block(profile, str(paths.bin / "wisp"), str(state_dir / "anexos"))
    except ValueError as e:
        cfg.telegram = None
        return StepReport(STEP, "failed", f"não consegui atualizar o perfil: {e}")
    save_config(cfg, _config_path(paths))
    spec = JobSpec(
        label=BOT_LABEL,
        program=[str(paths.runtime / "venv/bin/wisp-bot")],
        env={"WISP_CONFIG": str(_config_path(paths)), "PATH": f"{paths.bin}:/opt/homebrew/bin:/usr/bin:/bin"},
        log_path=state_dir / "bot.log",
    )
    details = jobs.install(spec)
    if not _wait_up(runner, paths, details):
        return StepReport(STEP, "failed", "o bot foi instalado, mas não respondeu a tempo", details)
    return StepReport(STEP, "done", "Telegram conectado", details, {"chat_id": str(found["chat_id"])})


def setup_telegram(
    runner: Runner,
    paths: WispPaths,
    cfg: WispConfig,
    api_factory: Callable[[str], TelegramAPI],
    jobs: JobManager,
    *,
    token_stdin: bytes | None,
    discover: bool,
    skip: bool,
    dry_run: bool,
) -> StepReport:
    if skip:
        return StepReport(STEP, "skipped", "Telegram deixado para depois")
    if dry_run:
        return StepReport(STEP, "done", "dry run: nada foi escrito")
    try:
        if token_stdin is not None:
            restart = cfg.telegram is not None and jobs.state(BOT_LABEL) != JobState.NOT_INSTALLED
            return _store_token(paths, api_factory, token_stdin, restart)
        if cfg.telegram is not None:
            return _verify(runner, paths, jobs)
        if discover:
            return _discover(runner, paths, cfg, api_factory, jobs)
    except TelegramError as e:
        return StepReport(STEP, "failed", str(e))
    return StepReport(STEP, "failed", "escolha uma ação: enviar o token, procurar o grupo ou pular")
