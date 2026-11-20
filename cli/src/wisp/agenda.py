from __future__ import annotations

import argparse
import os
import platform
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

HELPER = "wisp-agenda"
HELPER_IN_APP = Path("Contents/Helpers") / HELPER
ENV_OVERRIDE = "WISP_AGENDA_BIN"
SO_NO_MAC = "a agenda nativa só existe no Mac"
ESSE_NAO_EXISTE = "{var} aponta para {path}, que não existe ou não pode ser executado; atualize o Wisp ou desfaça essa variável"
INTERROMPIDO = "o ajudante da agenda foi interrompido pelo sistema (sinal {signal}); tente de novo"
NAO_ACHEI = "não achei o ajudante da agenda (wisp-agenda) dentro do Wisp.app; abra o app Wisp, instale ou atualize o Wisp e tente de novo"


def candidates(env: Mapping[str, str], home: Path) -> list[Path]:
    found = [Path(env[ENV_OVERRIDE])] if env.get(ENV_OVERRIDE) else []
    return found + [root / "Wisp.app" / HELPER_IN_APP for root in (Path("/Applications"), home / "Applications")]


def find_helper(env: Mapping[str, str], home: Path) -> Path | None:
    return next((path for path in candidates(env, home) if path.is_file() and os.access(path, os.X_OK)), None)


def run_helper(args: Sequence[str], *, system: str | None = None, env: Mapping[str, str] | None = None, home: Path | None = None) -> int:
    if (system or platform.system()) != "Darwin":
        print(SO_NO_MAC, file=sys.stderr)
        return 1
    env = os.environ if env is None else env
    forced = env.get(ENV_OVERRIDE)
    if forced and not (Path(forced).is_file() and os.access(forced, os.X_OK)):
        print(ESSE_NAO_EXISTE.format(var=ENV_OVERRIDE, path=forced), file=sys.stderr)
        return 1
    helper = find_helper(env, home or Path.home())
    if helper is None:
        print(NAO_ACHEI, file=sys.stderr)
        return 1
    code = subprocess.run([str(helper), *args], check=False).returncode
    if code < 0:
        print(INTERROMPIDO.format(signal=-code), file=sys.stderr)
        return 1
    return code


def add_parser(sub) -> argparse.ArgumentParser:
    agenda = sub.add_parser("agenda", help="Calendar and Reminders of the Mac (run without a command to see all)")
    agenda.add_argument("rest", nargs=argparse.REMAINDER)
    return agenda


def run(args: argparse.Namespace) -> int:
    return run_helper(args.rest)
