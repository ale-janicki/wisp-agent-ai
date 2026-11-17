import argparse
import json
import sys
from collections.abc import Sequence
from dataclasses import asdict

from wisp import __version__
from wisp.config import load_config
from wisp.doctor import run_doctor
from wisp.paths import WispPaths
from wisp.report import StepReport
from wisp.runner import SubprocessRunner


def emit(report: StepReport) -> int:
    print(report.to_json())
    return report.exit_code()


def _doctor(args: argparse.Namespace) -> int:
    only = {part for part in args.only.split(",") if part} or None
    checks = run_doctor(SubprocessRunner(), WispPaths.current(), load_config(), only)
    print(json.dumps({"version": 1, "checks": [asdict(check) for check in checks]}, ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wisp")
    parser.add_argument("--version", action="version", version=f"wisp {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)
    doctor = sub.add_parser("doctor")
    doctor.add_argument("--json", action="store_true")
    doctor.add_argument("--only", default="")
    for name in ("setup", "topic", "hook"):
        sub.add_parser(name)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(sys.argv[1:] if argv is None else argv)
    if args.command == "doctor":
        return _doctor(args)
    print(f"wisp {args.command}: not implemented yet", file=sys.stderr)
    return 1
