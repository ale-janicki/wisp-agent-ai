import argparse
import json
import os
import platform
import sys
from collections.abc import Callable, Sequence
from dataclasses import asdict
from pathlib import Path

from wisp import __version__
from wisp.aprendizados import add_parser as add_aprender_parser, hook_aprendizados, run as run_aprender
from wisp.brain_colher import main as run_brain_colher
from wisp.arquivos import add_parser as add_arquivos_parser, run as run_arquivos
from wisp.agenda import add_parser as add_agenda_parser, run as run_agenda
from wisp.config import WispConfig, is_unreadable, load_config, save_config
from wisp.doctor import run_doctor
from wisp.engines import ENGINES, write_active
from wisp.local.backend import stop_server
from wisp.fsops import OutsideHome, ensure_dir
from wisp.local.cli import add_parser as add_local_parser, run as run_local
from wisp.jobs import NotSupportedHere, manager_for
from wisp.guard_brain_scope import hook_guard_brain_scope
from wisp.mac import add_parser as add_mac_parser, run as run_mac
from wisp.guard_agenda import hook_guard_agenda, render as render_agenda_decision
from wisp.guard_destructive import hook_guard_destructive
from wisp.guard_lessons import hook_guard_lessons
from wisp.guard_outbound import hook_guard_outbound
from wisp.hooks import hook_boot, hook_brain_commit, hook_guard_secrets, hook_guard_telegram
from wisp.paths import WispPaths
from wisp.recall import hook_recall
from wisp.reuniao import add_parser as add_reuniao_parser, run as run_reuniao
from wisp.report import StepReport
from wisp.runner import SubprocessRunner
from wisp.setup.brain import setup_brain
from wisp.setup.codex import gate_problem, project_config_problem, sync_codex, user_owned_servers
from wisp.migrate_folder import migrate_folder, migrate_meetings
from wisp.setup.folder import UNREADABLE, seed_folder, setup_folder, wisp_root
from wisp.setup.harness import setup_harness
from wisp.setup.profile import setup_profile
from wisp.setup.shim import setup_shim
from wisp.setup.system import setup_system
from wisp.setup.telegram import setup_telegram
from wisp.telegram_api import TelegramAPI
from wisp.topic import add_parser as add_topic_parser, run as run_topic


def emit(report: StepReport) -> int:
    print(report.to_json())
    return report.exit_code()


def _load_config_or_default() -> tuple[WispConfig, str | None]:
    try:
        return load_config(), None
    except (ValueError, TypeError, OSError):
        return WispConfig(), "não consegui ler o wisp.json; o Wisp usou os valores padrão"


def _doctor(args: argparse.Namespace) -> int:
    only = {part for part in args.only.split(",") if part} or None
    out: dict = {"version": 1}
    cfg, warning = _load_config_or_default()
    if warning:
        out["warning"] = warning
    checks = run_doctor(SubprocessRunner(), WispPaths.current(), cfg, only)
    out["checks"] = [asdict(check) for check in checks]
    print(json.dumps(out, ensure_ascii=False))
    return 0


def _run_step(step: str, run: Callable[[WispConfig], StepReport]) -> int:
    cfg, warning = _load_config_or_default()
    try:
        report = run(cfg)
    except OutsideHome as e:
        report = StepReport(step, "failed", f"o Wisp só escreve dentro da sua pasta pessoal: {e}")
    except OSError as e:
        report = StepReport(step, "failed", f"não consegui escrever no disco: {e.strerror or type(e).__name__}")
    except ValueError as e:
        report = StepReport(step, "failed", f"um valor inválido impediu o passo: {e}")
    if warning:
        report.data["warning"] = warning if "warning" not in report.data else f"{report.data['warning']}; {warning}"
    return emit(report)


def _setup_brain(args: argparse.Namespace) -> int:
    path = Path(args.path) if args.path else None
    return _run_step("brain", lambda cfg: setup_brain(SubprocessRunner(), WispPaths.current(), cfg, path=path, dry_run=args.dry_run))


def _setup_folder(args: argparse.Namespace) -> int:
    path = Path(args.path) if args.path else None
    return _run_step("folder", lambda cfg: setup_folder(SubprocessRunner(), WispPaths.current(), cfg, path=path, dry_run=args.dry_run))


def _folder_migrate(args: argparse.Namespace) -> int:
    def run(cfg: WispConfig) -> StepReport:
        if is_unreadable():
            return StepReport("folder-migrate", "failed", UNREADABLE)
        if not args.reunioes:
            return migrate_folder(WispPaths.current(), cfg)

        def progress(done: int, total: int, name: str) -> None:
            print(json.dumps({"type": "progress", "done": done, "total": total, "item": name}, ensure_ascii=False), flush=True)

        return migrate_meetings(WispPaths.current(), cfg, progress)

    return _run_step("folder-migrate", run)


def _harness_and_codex(cfg: WispConfig, dry_run: bool) -> StepReport:
    paths = WispPaths.current()
    report = setup_harness(SubprocessRunner(), paths, cfg, dry_run=dry_run)
    if report.status == "failed":
        return report
    synced = sync_codex(paths, cfg, dry_run=dry_run)
    report.details += synced.details
    if synced.state != "skipped":
        report.data["codex"] = synced.state
    return report


def _setup_harness(args: argparse.Namespace) -> int:
    return _run_step("harness", lambda cfg: _harness_and_codex(cfg, args.dry_run))


def _usable_dir(path: Path) -> bool:
    """An existing directory, or a missing path whose nearest existing ancestor is a directory."""
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    return probe.is_dir()


def _set_engine(cfg: WispConfig, engine: str) -> StepReport:
    if engine not in ENGINES:
        return StepReport("config", "failed", f"motor desconhecido: {engine}", data={"key": "engine"})
    folder = wisp_root(cfg)
    seed_folder(folder)
    write_active(folder, engine)
    if engine != "local":
        stop_server()
    synced = _harness_and_codex(cfg, False)
    data = {"key": "engine", "engine": engine, "sync": synced.status}
    if synced.status == "failed":
        return StepReport("config", "failed", f"motor salvo, mas o harness não sincronizou: {synced.summary}", synced.details, data)
    return StepReport("config", "done", "motor salvo", synced.details, data)


def _config_set(args: argparse.Namespace) -> int:
    runner, paths = SubprocessRunner(), WispPaths.current()

    def run(cfg: WispConfig) -> StepReport:
        if is_unreadable():
            return StepReport("config", "failed", UNREADABLE, data={"key": args.key})
        if args.key == "engine":
            return _set_engine(cfg, args.value)
        if not args.value.startswith(("/", "~")):
            return StepReport("config", "failed", "use um caminho completo (começando com / ou ~)", data={"key": args.key})
        target = Path(args.value).expanduser().resolve(strict=False)
        if not _usable_dir(target):
            return StepReport("config", "failed", "esse caminho não é uma pasta que o Wisp possa usar", data={"key": args.key})
        ensure_dir(target)
        if args.key == "wisp_dir":
            report = setup_folder(runner, paths, cfg, path=target, dry_run=False)
        else:
            cfg.brain = str(target)
            save_config(cfg)
            report = StepReport("brain", "done", "caminho salvo")
        if report.status == "failed":
            return report
        synced = _harness_and_codex(cfg, False)
        data = {"key": args.key, "path": str(target), "sync": synced.status}
        if synced.status == "failed":
            return StepReport("config", "failed", f"caminho salvo, mas o harness não sincronizou: {synced.summary}", synced.details, data)
        return StepReport("config", "done", "caminho salvo", synced.details, data)

    return _run_step("config", run)


def _setup_system(args: argparse.Namespace) -> int:
    return _run_step("system", lambda cfg: setup_system(SubprocessRunner(), WispPaths.current(), cfg, with_homebrew=args.with_homebrew, dry_run=args.dry_run))


def _setup_telegram(args: argparse.Namespace) -> int:
    token = sys.stdin.buffer.read() if args.token_stdin else None
    runner, paths = SubprocessRunner(), WispPaths.current()

    def run(cfg: WispConfig) -> StepReport:
        try:
            jobs = manager_for(platform.system(), paths, runner, os.getuid())
        except NotSupportedHere:
            return StepReport("telegram", "failed", "o Telegram ainda não roda neste sistema")
        return setup_telegram(
            runner, paths, cfg, TelegramAPI, jobs,
            token_stdin=token, discover=args.discover, skip=args.skip, dry_run=args.dry_run,
        )

    return _run_step("telegram", run)


def _setup_profile(args: argparse.Namespace) -> int:
    paths = WispPaths.current()

    def run(cfg: WispConfig) -> StepReport:
        user = args.user_name
        if not user and not cfg.user_name:
            user = SubprocessRunner().run(["id", "-F"]).stdout.strip() or None
        avatar = Path(args.avatar).expanduser() if args.avatar else None
        return setup_profile(paths, cfg, name=args.name, user_name=user, language=args.language, avatar=avatar, dry_run=args.dry_run)

    return _run_step("profile", run)


def _guard_secrets() -> int:
    try:
        payload = json.load(sys.stdin)
        reason = hook_guard_secrets(payload if isinstance(payload, dict) else {}, WispPaths.current())
    except Exception as e:
        print(f"wisp-guard: hook guard-secrets failed ({type(e).__name__})", file=sys.stderr)
        return 2
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


def _guard_telegram() -> int:
    try:
        payload = json.load(sys.stdin)
        cfg, _ = _load_config_or_default()
        reason = hook_guard_telegram(payload if isinstance(payload, dict) else {}, WispPaths.current(), cfg)
    except Exception as e:
        print(f"wisp-guard: hook guard-telegram failed ({type(e).__name__})", file=sys.stderr)
        return 2
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


def _guard_destructive() -> int:
    try:
        payload = json.load(sys.stdin)
        cfg, _ = _load_config_or_default()
        reason = hook_guard_destructive(payload if isinstance(payload, dict) else {}, WispPaths.current(), cfg)
    except Exception as e:
        print(f"wisp-guard: hook guard-destructive failed ({type(e).__name__})", file=sys.stderr)
        return 2
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


def _guard_lessons() -> int:
    try:
        payload = json.load(sys.stdin)
        cfg, _ = _load_config_or_default()
        reason = hook_guard_lessons(payload if isinstance(payload, dict) else {}, WispPaths.current(), cfg)
    except Exception as e:
        print(f"wisp-guard: hook guard-lessons failed ({type(e).__name__})", file=sys.stderr)
        return 2
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


def _guard_outbound() -> int:
    try:
        payload = json.load(sys.stdin)
        reason = hook_guard_outbound(payload if isinstance(payload, dict) else {}, WispPaths.current())
    except Exception as e:
        print(f"wisp-guard: hook guard-outbound failed ({type(e).__name__})", file=sys.stderr)
        return 2
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


def _guard_brain_scope() -> int:
    try:
        payload = json.load(sys.stdin)
        reason = hook_guard_brain_scope(payload if isinstance(payload, dict) else {}, os.environ)
    except Exception as e:
        print(f"wisp-guard: hook guard-brain-scope failed ({type(e).__name__})", file=sys.stderr)
        return 2
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


def _recall() -> int:
    try:
        payload = json.load(sys.stdin)
        cfg, _ = _load_config_or_default()
        out = hook_recall(cfg, WispPaths.current(), payload if isinstance(payload, dict) else {})
        if out:
            sys.stdout.write(out)
    except Exception:
        pass
    return 0


def _aprendizados() -> int:
    try:
        payload = json.load(sys.stdin)
        cfg, _ = _load_config_or_default()
        out = hook_aprendizados(cfg, str(Path(sys.executable).parent / "wisp"), WispPaths.current(), payload if isinstance(payload, dict) else {})
        if out:
            sys.stdout.write(out)
    except Exception:
        pass
    return 0


def _brain_colher(args: argparse.Namespace) -> int:
    flags = [flag for flag, on in (("--if-due", args.if_due), ("--dry-run", args.dry_run), ("--json", args.json)) if on]
    return run_brain_colher(flags)


def _guard_agenda() -> int:
    try:
        payload = json.load(sys.stdin)
        decision = hook_guard_agenda(payload if isinstance(payload, dict) else {})
    except Exception as e:
        print(f"wisp-guard: hook guard-agenda failed ({type(e).__name__})", file=sys.stderr)
        return 2
    if decision:
        print(render_agenda_decision(decision))
    return 0


def _hook(args: argparse.Namespace) -> int:
    if args.which == "recall":
        return _recall()
    if args.which == "aprendizados":
        return _aprendizados()
    if args.which == "guard-secrets":
        return _guard_secrets()
    if args.which == "guard-telegram":
        return _guard_telegram()
    if args.which == "guard-destructive":
        return _guard_destructive()
    if args.which == "guard-lessons":
        return _guard_lessons()
    if args.which == "guard-brain-scope":
        return _guard_brain_scope()
    if args.which == "guard-agenda":
        return _guard_agenda()
    if args.which == "guard-outbound":
        return _guard_outbound()
    try:
        cfg, _ = _load_config_or_default()
        if args.which == "boot":
            print(hook_boot(cfg, WispPaths.current()), end="")
        else:
            hook_brain_commit(cfg, SubprocessRunner())
    except Exception as e:
        print(f"wisp hook {args.which}: {type(e).__name__}", file=sys.stderr)
    return 0


def _email(args: argparse.Namespace) -> int:
    from wisp.email.mail_app import MailApp, MailError    # lazy: only the email commands pay for it

    mail = MailApp(SubprocessRunner())
    try:
        if args.action == "list":
            result = mail.list(args.mailbox, args.limit)
        elif args.action == "search":
            result = mail.search(args.query, args.limit)
        else:
            result = mail.read(args.id)
    except MailError as e:
        print(str(e), file=sys.stderr)
        return 1
    print(json.dumps([asdict(r) for r in result] if isinstance(result, list) else asdict(result), ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wisp")
    parser.add_argument("--version", action="version", version=f"wisp {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)
    doctor = sub.add_parser("doctor")
    doctor.add_argument("--json", action="store_true")
    doctor.add_argument("--only", default="")
    setup = sub.add_parser("setup")
    steps = setup.add_subparsers(dest="step", required=True)
    brain = steps.add_parser("brain")
    brain.add_argument("--path")
    brain.add_argument("--dry-run", action="store_true")
    brain.add_argument("--json", action="store_true")
    folder = steps.add_parser("folder")
    folder.add_argument("--path")
    folder.add_argument("--dry-run", action="store_true")
    folder.add_argument("--json", action="store_true")
    harness = steps.add_parser("harness")
    harness.add_argument("--dry-run", action="store_true")
    harness.add_argument("--json", action="store_true")
    system = steps.add_parser("system")
    system.add_argument("--with-homebrew", action="store_true")
    system.add_argument("--dry-run", action="store_true")
    system.add_argument("--json", action="store_true")
    telegram = steps.add_parser("telegram")
    action = telegram.add_mutually_exclusive_group(required=True)
    action.add_argument("--token-stdin", action="store_true")
    action.add_argument("--discover", action="store_true")
    action.add_argument("--skip", action="store_true")
    telegram.add_argument("--dry-run", action="store_true")
    telegram.add_argument("--json", action="store_true")
    profile = steps.add_parser("profile")
    profile.add_argument("--name", required=True)
    profile.add_argument("--user-name")
    profile.add_argument("--language", default="pt-BR")
    profile.add_argument("--avatar")
    profile.add_argument("--dry-run", action="store_true")
    profile.add_argument("--json", action="store_true")
    shim = steps.add_parser("shim")
    shim.add_argument("--json", action="store_true")
    harness_group = sub.add_parser("harness")
    harness_steps = harness_group.add_subparsers(dest="action", required=True)
    sync = harness_steps.add_parser("sync")
    sync.add_argument("--dry-run", action="store_true")
    sync.add_argument("--json", action="store_true")
    folder_group = sub.add_parser("folder")
    folder_steps = folder_group.add_subparsers(dest="action", required=True)
    migrate = folder_steps.add_parser("migrate")
    migrate.add_argument("--reunioes", action="store_true")
    migrate.add_argument("--json", action="store_true")
    config = sub.add_parser("config")
    config_steps = config.add_subparsers(dest="action", required=True)
    config_set = config_steps.add_parser("set")
    config_set.add_argument("key", choices=["wisp_dir", "brain", "engine"])
    config_set.add_argument("value")
    config_set.add_argument("--json", action="store_true")
    codex = sub.add_parser("codex")
    codex_steps = codex.add_subparsers(dest="action", required=True)
    codex_check = codex_steps.add_parser("check")
    codex_check.add_argument("--workspace")
    mcp = sub.add_parser("mcp")
    mcp.add_argument("server", choices=["email", "brain", "mac"])
    email = sub.add_parser("email")
    email_steps = email.add_subparsers(dest="action", required=True)
    email_list = email_steps.add_parser("list")
    email_list.add_argument("--mailbox", default="INBOX")
    email_list.add_argument("--limit", type=int, default=20)
    email_read = email_steps.add_parser("read")
    email_read.add_argument("id")
    email_search = email_steps.add_parser("search")
    email_search.add_argument("query")
    email_search.add_argument("--limit", type=int, default=20)
    add_topic_parser(sub)
    add_aprender_parser(sub)
    brain_cmd = sub.add_parser("brain")
    brain_steps = brain_cmd.add_subparsers(dest="brain_action", required=True)
    colher = brain_steps.add_parser("colher")
    colher.add_argument("--if-due", action="store_true")
    colher.add_argument("--dry-run", action="store_true")
    colher.add_argument("--json", action="store_true")
    add_arquivos_parser(sub)
    add_mac_parser(sub)
    add_agenda_parser(sub)
    add_local_parser(sub)
    add_reuniao_parser(sub)
    hook = sub.add_parser("hook")
    hook.add_argument("which", choices=["boot", "recall", "aprendizados", "brain-commit", "guard-secrets", "guard-telegram", "guard-destructive", "guard-lessons", "guard-outbound", "guard-brain-scope", "guard-agenda"])
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(sys.argv[1:] if argv is None else argv)
    if args.command == "doctor":
        return _doctor(args)
    if args.command == "setup" and args.step == "brain":
        return _setup_brain(args)
    if args.command == "setup" and args.step == "folder":
        return _setup_folder(args)
    if args.command == "folder" and args.action == "migrate":
        return _folder_migrate(args)
    if args.command == "setup" and args.step == "harness":
        return _setup_harness(args)
    if args.command == "setup" and args.step == "system":
        return _setup_system(args)
    if args.command == "setup" and args.step == "telegram":
        return _setup_telegram(args)
    if args.command == "setup" and args.step == "profile":
        return _setup_profile(args)
    if args.command == "setup" and args.step == "shim":
        return _run_step("shim", lambda cfg: setup_shim(WispPaths.current()))
    if args.command == "harness" and args.action == "sync":
        return _setup_harness(args)
    if args.command == "codex" and args.action == "check":
        paths = WispPaths.current()
        problem = gate_problem(paths)
        project = project_config_problem(Path(args.workspace).expanduser(), paths.home) if args.workspace else None
        ready = problem is None and project is None
        print(json.dumps({"ready": ready, "problem": problem, "project": project, "owned": sorted(user_owned_servers(paths))}, ensure_ascii=False))
        return 0 if ready else 1
    if args.command == "config" and args.action == "set":
        return _config_set(args)
    if args.command == "hook":
        return _hook(args)
    if args.command == "brain":
        return _brain_colher(args)
    if args.command == "email":
        return _email(args)
    if args.command == "mcp" and args.server == "brain":
        from wisp.brain_server import run_server as run_brain_server

        return run_brain_server(_load_config_or_default()[0], WispPaths.current())
    if args.command == "mcp" and args.server == "mac":
        from wisp.mac_server import run_server as run_mac_server

        run_mac_server()
        return 0
    if args.command == "mcp":
        from wisp.email.mail_app import MailApp      # lazy: the mcp package loads only for the server
        from wisp.email.server import run_server

        run_server(MailApp(SubprocessRunner()))
        return 0
    if args.command == "topic":
        return run_topic(args)
    if args.command == "aprender":
        return run_aprender(args, _load_config_or_default()[0])
    if args.command == "arquivos":
        return run_arquivos(args)
    if args.command == "mac":
        return run_mac(args)
    if args.command == "agenda":
        return run_agenda(args)
    if args.command == "local":
        return run_local(args)
    if args.command == "reuniao":
        return run_reuniao(args, _load_config_or_default()[0])
    print(f"wisp {args.command}: not implemented yet", file=sys.stderr)
    return 1
