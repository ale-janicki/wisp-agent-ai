from __future__ import annotations

from wisp.serve.engines import codex, local


def desired(active: str, wisp_binary: str | None, env: dict[str, str], preferred_cwd: str | None,
            wisp_dir: str) -> tuple[str, str | None]:
    if active == "local":
        readiness = local.check(wisp_binary, env)
        return ("local", None) if readiness.ready else ("claude", readiness.note())
    if active != "codex":
        return "claude", None
    root = codex.workspace(preferred_cwd, wisp_dir)
    readiness = codex.check(None, wisp_binary, env, root)
    if not readiness.ready:
        return "claude", readiness.note()
    if root is None:
        return "claude", codex.NO_WORKSPACE
    return "codex", None


def overview(active: str, wisp_binary: str | None, env: dict[str, str], claude_found: bool) -> dict:
    codex_state = codex.check(None, wisp_binary, env, None)
    local_state = local.check(wisp_binary, env)
    return {"active": active, "engines": [
        {"id": "claude", "name": "Claude", "ready": claude_found,
         "note": None if claude_found else "Claude Code não encontrado"},
        {"id": "codex", "name": "Codex", "ready": codex_state.ready,
         "note": None if codex_state.ready else codex_state.note()},
        {"id": "local", "name": "IA local", "ready": local_state.ready,
         "note": None if local_state.ready else local_state.note()},
    ]}
