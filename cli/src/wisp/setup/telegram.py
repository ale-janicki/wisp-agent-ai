import json
import math
import os
import re
import sys
import time
from collections.abc import Callable
from pathlib import Path

from wisp.config import TelegramConfig, WispConfig, save_config
from wisp.doctor import BOT_LABEL
from wisp.fsops import atomic_write, ensure_dir
from wisp.jobs import JobManager, JobSpec, JobState
from wisp.layout import layout_of
from wisp.paths import WispPaths, exe, venv_bin
from wisp.report import Detail, StepReport
from wisp.runner import Runner
from wisp.setup.profile_writer import (
    check_writable, has_telegram_block, remove_telegram_block, render_telegram_block, set_telegram_block,
)
from wisp.telegram_api import TelegramAPI, TelegramError

STEP = "telegram"
TOKEN_SHAPE = re.compile(r"\d+:[A-Za-z0-9_-]+")
DISCOVER_S = 60
UP_WAIT_S = 30
POLL_S = 10
UP_POLL_S = 1.0
sleep = time.sleep
now = time.time


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


def _job_path(paths: WispPaths) -> str:
    if sys.platform == "win32":
        return f"{paths.bin};{os.environ.get('PATH', '')}"
    brew = ":/opt/homebrew/bin" if sys.platform == "darwin" else ""
    return f"{paths.bin}{brew}:/usr/bin:/bin"


def _job_spec(paths: WispPaths, cfg: WispConfig) -> JobSpec:
    return JobSpec(
        label=BOT_LABEL,
        program=[str(venv_bin(paths.runtime / "venv") / exe("wisp-bot"))],
        env={"WISP_CONFIG": str(_config_path(paths)), "PATH": _job_path(paths)},
        log_path=layout_of(cfg, paths.home).logs / "bot.log",
    )


def _start_bot(runner: Runner, paths: WispPaths, jobs: JobManager, cfg: WispConfig) -> tuple[bool, list[Detail]]:
    details = jobs.install(_job_spec(paths, cfg))
    return _wait_up(runner, paths, details), details


def _store_token(
    runner: Runner, paths: WispPaths, cfg: WispConfig, api_factory: Callable[[str], TelegramAPI], jobs: JobManager, raw: bytes
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
    cfg.telegram_token_at = int(now())
    save_config(cfg, _config_path(paths))
    username = str(bot.get("username", ""))
    if cfg.telegram is not None:
        up, details = _start_bot(runner, paths, jobs, cfg)
        if not up:
            return StepReport(STEP, "failed", "troquei o token, mas o bot não respondeu a tempo", details, {"bot": username})
        return StepReport(STEP, "done", "token trocado e bot reiniciado", details, {"bot": username})
    return StepReport(
        STEP, "needs_user",
        f"Crie um grupo, ative Tópicos, adicione @{username} como admin e mande 'oi' lá",
        data={"bot": username},
    )


def _find_forum(api: TelegramAPI, since: int) -> tuple[dict | None, str | None]:
    deadline = time.monotonic() + DISCOVER_S
    non_forum_seen = False
    while (remaining := deadline - time.monotonic()) > 0:
        for update in api.get_updates(max(1, min(POLL_S, math.ceil(remaining)))):
            message = update.get("message") or {}
            chat, sender = message.get("chat") or {}, message.get("from") or {}
            if chat.get("type") not in ("group", "supergroup") or sender.get("is_bot") or "id" not in sender:
                continue
            if not isinstance(message.get("date"), int) or message["date"] < since:
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


def _verify(runner: Runner, paths: WispPaths, cfg: WispConfig, jobs: JobManager) -> StepReport:
    state = jobs.state(BOT_LABEL)
    if state == JobState.RUNNING and _status_up(runner, paths)[0]:
        return StepReport(STEP, "skipped", "o Telegram já está configurado e conectado")
    if not Path(cfg.telegram.token_file).expanduser().is_file():
        return StepReport(STEP, "failed", "falta o token do bot; envie o token de novo", data={"job": state.value})
    up, details = _start_bot(runner, paths, jobs, cfg)
    if not up:
        return StepReport(STEP, "failed", "reiniciei o bot, mas ele não respondeu a tempo", details, {"job": state.value})
    return StepReport(STEP, "done", "o bot voltou a rodar", details)


def _discover(runner, paths, cfg, api_factory, jobs: JobManager) -> StepReport:
    token_file = _token_path(paths)
    if not token_file.is_file():
        return StepReport(STEP, "failed", "falta o token do bot; envie o token primeiro")
    profile = paths.config / "profile.json"
    block_args = (profile, str(paths.bin / "wisp"), str(layout_of(cfg, paths.home).anexos))
    names = {"name": cfg.persona or "Wisp", "language": cfg.language or "pt-BR"}
    try:
        render_telegram_block(*block_args, **names)
    except ValueError as e:
        return StepReport(STEP, "failed", f"não consegui atualizar o perfil: {e}")
    if jobs.state(BOT_LABEL) != JobState.NOT_INSTALLED:
        return StepReport(STEP, "failed", "pare o bot antes de procurar o grupo")
    api = api_factory(token_file.read_text().strip())
    found, why = _find_forum(api, cfg.telegram_token_at or int(token_file.stat().st_mtime))
    if found is None:
        return StepReport(STEP, "needs_user", why or "mande 'oi' no grupo do bot e tente de novo")
    if not _bot_can_manage_topics(api, found["chat_id"]):
        return StepReport(STEP, "needs_user", "torne o bot administrador do grupo com permissão para gerenciar tópicos")

    cfg.telegram = TelegramConfig(
        chat_id=found["chat_id"], user_id=found["user_id"], token_file=str(token_file), state_dir=str(paths.state / "bot")
    )
    save_config(cfg, _config_path(paths))
    up, details = _start_bot(runner, paths, jobs, cfg)
    problem = None if up else "o bot não respondeu a tempo; nada ficou configurado, tente de novo"
    if up:
        try:
            set_telegram_block(*block_args, **names)
        except (ValueError, OSError) as e:
            problem = f"não consegui atualizar o perfil: {e}"
    if problem:
        details += jobs.remove(BOT_LABEL)
        cfg.telegram = None
        save_config(cfg, _config_path(paths))
        return StepReport(STEP, "failed", problem, details)
    return StepReport(STEP, "done", "Telegram conectado", details, {"chat_id": str(found["chat_id"])})


def _disconnect(paths: WispPaths, cfg: WispConfig, jobs: JobManager) -> StepReport:
    profile = paths.config / "profile.json"
    plist = paths.launch_agents / f"{BOT_LABEL}.plist" if paths.launch_agents else None
    has_block = has_telegram_block(profile)
    if cfg.telegram is None and not has_block and not (plist and plist.exists()):
        return StepReport(STEP, "skipped", "Telegram deixado para depois")
    try:
        check_writable(profile)
        if has_block:
            remove_telegram_block(profile)
    except ValueError as e:
        return StepReport(STEP, "failed", str(e))
    details = jobs.remove(BOT_LABEL)
    cfg.telegram = None
    save_config(cfg, _config_path(paths))
    return StepReport(STEP, "skipped", "Telegram desconectado", details)


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
    if dry_run:
        return StepReport(STEP, "done" if not skip else "skipped", "dry run: nada foi escrito")
    try:
        if skip:
            return _disconnect(paths, cfg, jobs)
        if token_stdin is not None:
            return _store_token(runner, paths, cfg, api_factory, jobs, token_stdin)
        if cfg.telegram is not None:
            return _verify(runner, paths, cfg, jobs)
        if discover:
            return _discover(runner, paths, cfg, api_factory, jobs)
    except TelegramError as e:
        return StepReport(STEP, "failed", str(e))
    return StepReport(STEP, "failed", "escolha uma ação: enviar o token, procurar o grupo ou pular")
