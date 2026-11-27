#!/usr/bin/env python3
import json
import os
import sys

LOG = os.environ.get("FAKE_CLAUDE_LOG")
SESSION = "fake-session-1"


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(obj):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(obj) + "\n")


log({"argv": sys.argv[1:]})
emit({"type": "system", "subtype": "init", "session_id": SESSION, "model": "fake", "apiKeySource": "none",
      "permissionMode": "default"})
backlog = []


def read_json():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line) if line.strip() else read_json()


def next_user():
    while True:
        msg = backlog.pop(0) if backlog else read_json()
        if msg.get("type") == "user":
            return msg


def wait_for_control_response():
    while True:
        msg = read_json()
        if msg.get("type") == "control_response":
            return msg
        backlog.append(msg)


while True:
    msg = next_user()
    text = msg["message"]["content"]
    log({"user": text})
    emit({"type": "user", "isReplay": True, "message": {"role": "user", "content": text}})
    if os.environ.get("FAKE_CLAUDE_NO_PERMISSION") != "1":
        emit({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "touch probe"}}]}})
        emit({"type": "control_request", "request_id": "req-1", "request": {
            "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "touch probe"},
            "tool_use_id": "toolu_1"}})
        answer = wait_for_control_response()
        log({"control_response": answer})
        allowed = answer["response"]["response"]["behavior"] == "allow"
        emit({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_1", "content": "done" if allowed else "denied",
             "is_error": not allowed}]}})
    emit({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "ok: " + text}]}})
    emit({"type": "result", "subtype": "success", "is_error": False, "result": "ok: " + text,
          "session_id": SESSION, "usage": {"input_tokens": 1, "output_tokens": 2}})
