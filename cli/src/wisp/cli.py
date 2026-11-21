import argparse
import json
import os
import platform
import sys
from collections.abc import Callable, Sequence
from dataclasses import asdict
from pathlib import Path

from wisp import __version__
from wisp.brain_colher import main as run_brain_colher
from wisp.config import WispConfig, load_config
from wisp.doctor import run_doctor
from wisp.fsops import OutsideHome
from wisp.jobs import NotSupportedHere, manager_for
from wisp.guard_brain_scope import hook_guard_brain_scope
from wisp.guard_destructive import hook_guard_destructive
from wisp.hooks import hook_boot, hook_brain_commit, hook_guard_secrets, hook_guard_telegram
from wisp.paths import WispPaths
from wisp.recall import hook_recall
from wisp.report import StepReport
from wisp.runner import SubprocessRunner
from wisp.setup.brain import setup_brain
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


def _setup_harness(args: argparse.Namespace) -> int:
    return _run_step("harness", lambda cfg: setup_harness(SubprocessRunner(), WispPaths.current(), cfg, dry_run=args.dry_run))


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


def _brain_colher(args: argparse.Namespace) -> int:
    flags = [flag for flag, on in (("--if-due", args.if_due), ("--dry-run", args.dry_run), ("--json", args.json)) if on]
    return run_brain_colher(flags)


def _hook(args: argparse.Namespace) -> int:
    if args.which == "recall":
        return _recall()
    if args.which == "guard-secrets":
        return _guard_secrets()
    if args.which == "guard-telegram":
        return _guard_telegram()
    if args.which == "guard-destructive":
        return _guard_destructive()
    if args.which == "guard-brain-scope":
        return _guard_brain_scope()
    try:
        cfg, _ = _load_config_or_default()
        if args.which == "boot":
            print(hook_boot(cfg, WispPaths.current()), end="")
        else:
            hook_brain_commit(cfg, SubprocessRunner())
    except Exception as e:
        print(f"wisp hook {args.which}: {type(e).__name__}", file=sys.stderr)
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
    add_topic_parser(sub)
    brain_cmd = sub.add_parser("brain")
    brain_steps = brain_cmd.add_subparsers(dest="brain_action", required=True)
    colher = brain_steps.add_parser("colher")
    colher.add_argument("--if-due", action="store_true")
    colher.add_argument("--dry-run", action="store_true")
    colher.add_argument("--json", action="store_true")
    hook = sub.add_parser("hook")
    hook.add_argument("which", choices=["boot", "recall", "brain-commit", "guard-secrets", "guard-telegram", "guard-destructive", "guard-brain-scope"])
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(sys.argv[1:] if argv is None else argv)
    if args.command == "doctor":
        return _doctor(args)
    if args.command == "setup" and args.step == "brain":
        return _setup_brain(args)
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
    if args.command == "hook":
        return _hook(args)
    if args.command == "brain":
        return _brain_colher(args)
    if args.command == "topic":
        return run_topic(args)
    print(f"wisp {args.command}: not implemented yet", file=sys.stderr)
    return 1
