#!/usr/bin/env python3
import json
import os
import sys

LOG = os.environ.get("FAKE_WISP_LOG")


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(obj):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(obj) + "\n")


args = sys.argv[1:]
if args[:2] == ["codex", "check"]:
    log({"codex_check": args[2:]})
    project = (os.environ.get("FAKE_WISP_CODEX_PROBLEM") or None) if "--workspace" in args else None
    ready = project is None
    print(json.dumps({"ready": ready, "problem": None, "project": project, "owned": []}))
    sys.exit(0 if ready else 1)
if args[:2] == ["local", "ready"]:
    missing = os.environ.get("FAKE_WISP_LOCAL_MISSING")
    emit({"type": "ready", "ready": not missing, **({"missing": missing} if missing else {})})
    sys.exit(0)
if args[:2] == ["local", "chat"]:
    message = next(a for a in args if a.startswith("--message="))[len("--message="):]
    log({"local_chat": args[2:]})
    emit({"type": "system", "subtype": "init", "session_id": "local-conv", "model": "qwen-local", "apiKeySource": "none",
          "permissionMode": "default"})
    if os.environ.get("FAKE_WISP_LOCAL_ASK"):
        emit({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "lt1", "name": "Bash", "input": {"command": "date"}}]}})
        emit({"type": "control_request", "request_id": "lreq-1", "request": {
            "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "date"}, "tool_use_id": "lt1"}})
        answer = json.loads(sys.stdin.readline())
        log({"control_response": answer})
        allowed = answer["response"]["response"]["behavior"] == "allow"
        emit({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "lt1", "content": "ok" if allowed else "negado",
             "is_error": not allowed}]}})
    if os.environ.get("FAKE_WISP_LOCAL_FAIL"):
        emit({"type": "error", "message": "o servidor local caiu"})
        sys.exit(1)
    emit({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "local: " + message}]}})
    emit({"type": "result", "subtype": "success", "is_error": False, "result": "local: " + message,
          "session_id": "local-conv", "usage": {}})
    sys.exit(0)
sys.exit(2)
