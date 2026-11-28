#!/usr/bin/env python3
import json
import os
import sys

LOG = os.environ.get("FAKE_CODEX_LOG")
THREAD = "codex-thread-1"


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(obj):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(obj) + "\n")


if sys.argv[1:3] == ["login", "status"]:
    sys.exit(1 if os.environ.get("FAKE_CODEX_LOGGED_OUT") else 0)

prompt = sys.stdin.read()
log({"argv": sys.argv[1:], "prompt": prompt, "env": {k: os.environ.get(k) for k in ("WISP_BIN", "WISP_APPROVAL_SOCKET")}})
if "resume" in sys.argv and os.environ.get("FAKE_CODEX_LOST"):
    sys.stderr.write("session not found\n")
    sys.exit(1)
if os.environ.get("FAKE_CODEX_HANG"):
    emit({"type": "thread.started", "thread_id": THREAD})
    emit({"type": "turn.started"})
    import time
    time.sleep(60)
emit({"type": "thread.started", "thread_id": THREAD})
emit({"type": "turn.started"})
emit({"type": "item.started", "item": {"id": "item_0", "type": "command_execution", "command": "ls", "status": "in_progress"}})
emit({"type": "item.completed", "item": {"id": "item_0", "type": "command_execution", "command": "ls",
                                          "aggregated_output": "a.txt\n", "exit_code": 0, "status": "completed"}})
emit({"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": "codex: " + prompt.strip().splitlines()[-1]}})
emit({"type": "turn.completed", "usage": {"input_tokens": 1, "output_tokens": 2}})
