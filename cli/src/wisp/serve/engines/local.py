from __future__ import annotations

import json
import sys

from wisp.serve.engines import DISPLAY
from wisp.serve.engines.process import run_command

MAX_MESSAGE_WINDOWS = 30000
TOO_LARGE = "a mensagem é grande demais para a IA local no Windows; mande em partes menores"
NO_BINARY = "não achei o comando do Wisp, que roda a IA local"


class Readiness:
    def __init__(self, ready: bool, missing: str | None = None):
        self.ready = ready
        self.missing = missing

    def note(self) -> str:
        return (f"a {DISPLAY['local']} não está pronta ({self.missing or 'sem detalhe'}); esta conversa roda no "
                "Claude. Ajustes > Modelo resolve.")


def parse_readiness(data: bytes) -> Readiness | None:
    for line in data.decode("utf-8", "replace").splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict) or not isinstance(obj.get("type"), str):
            continue
        if obj["type"] == "ready" and isinstance(obj.get("ready"), bool):
            missing = obj.get("missing")
            return Readiness(obj["ready"], missing if isinstance(missing, str) else None)
        if obj["type"] == "error":
            message = obj.get("message")
            return Readiness(False, message if isinstance(message, str) else None)
    return None


def check(wisp_binary: str | None, env: dict[str, str]) -> Readiness:
    if not wisp_binary:
        return Readiness(False, "não achei o comando do Wisp")
    ran = run_command([wisp_binary, "local", "ready"], env, 45)
    if not ran.started:
        return Readiness(False, "não consegui rodar o comando do Wisp")
    if ran.timed_out:
        return Readiness(False, "o servidor local não respondeu a tempo")
    return parse_readiness(ran.stdout) or Readiness(False, "não consegui conferir a IA local")


def arguments(text: str, conversation: str, mode: str) -> list[str]:
    args = ["local", "chat", f"--message={text}", "--approvals", "stdio", "--no-record", "--recorded", "--surface", "app",
            "--mode", mode]
    return args + ["--conversation", conversation] if conversation else args


def too_large(text: str, platform: str | None = None) -> bool:
    return (platform or sys.platform) == "win32" and len(text) > MAX_MESSAGE_WINDOWS
