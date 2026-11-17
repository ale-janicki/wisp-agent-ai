import argparse
import sys
from collections.abc import Sequence

from wisp import __version__
from wisp.report import StepReport


def emit(report: StepReport) -> int:
    print(report.to_json())
    return report.exit_code()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wisp")
    parser.add_argument("--version", action="version", version=f"wisp {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("doctor", "setup", "topic", "hook"):
        sub.add_parser(name)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(sys.argv[1:] if argv is None else argv)
    print(f"wisp {args.command}: not implemented yet", file=sys.stderr)
    return 1
