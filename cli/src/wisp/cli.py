import argparse
import json
import sys
from collections.abc import Callable, Sequence
from dataclasses import asdict
from pathlib import Path

from wisp import __version__
from wisp.config import WispConfig, load_config
from wisp.doctor import run_doctor
from wisp.fsops import OutsideHome
from wisp.hooks import hook_boot, hook_brain_commit
from wisp.paths import WispPaths
from wisp.report import StepReport
from wisp.runner import SubprocessRunner
from wisp.setup.brain import setup_brain
from wisp.setup.harness import setup_harness
from wisp.setup.system import setup_system
from wisp.topic import add_parser as add_topic_parser, run as run_topic


def emit(report: StepReport) -> int:
    print(report.to_json())
    return report.exit_code()


def _load_config_or_default() -> tuple[WispConfig, str | None]:
    try:
        return load_config(), None
    except (ValueError, TypeError, OSError) as e:
        return WispConfig(), f"wisp.json could not be read ({type(e).__name__}); using defaults"


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


def _hook(args: argparse.Namespace) -> int:
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
    add_topic_parser(sub)
    hook = sub.add_parser("hook")
    hook.add_argument("which", choices=["boot", "brain-commit"])
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
    if args.command == "hook":
        return _hook(args)
    if args.command == "topic":
        return run_topic(args)
    print(f"wisp {args.command}: not implemented yet", file=sys.stderr)
    return 1
