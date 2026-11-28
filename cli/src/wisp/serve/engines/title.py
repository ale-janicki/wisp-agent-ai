from __future__ import annotations

import os

from wisp.serve.claude_session import ClaudeNotFound, child_environment, resolve_launch
from wisp.serve.engines.process import run_command
from wisp.serve.store import TITLE_TIMEOUT, title_prompt, title_sanitize

ARGUMENTS = ["-p", "--model", "haiku", "--no-session-persistence", "--output-format", "text", "--tools", "",
             "--disable-slash-commands", "--strict-mcp-config", "--setting-sources", ""]


def generate(executable: str, user: str, reply: str, env: dict[str, str] | None = None,
             timeout: float = TITLE_TIMEOUT) -> str | None:
    try:
        prefix = resolve_launch(executable)
    except ClaudeNotFound:
        return None
    environment = dict(env if env is not None else child_environment(executable))
    environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    ran = run_command([*prefix, *ARGUMENTS], environment, timeout, stdin=title_prompt(user, reply).encode("utf-8"))
    if ran.timed_out or ran.status != 0:
        return None
    return title_sanitize(ran.stdout.decode("utf-8", "replace"))
