---
description: Diagnose-only mode. Find the cause of a problem and explain it, with evidence, without touching anything
---

# /diagnose — find the cause, change nothing

`$ARGUMENTS` = what is wrong, in {{USER_NAME}}'s words.

## The hard rule

**No edits, no writes, no commits, no restarts** for the rest of this command. Allowed: reading files, reading logs, and running read-only commands. Nothing that creates a file, changes data, installs, restarts a service, or stages anything. {{USER_NAME}} decides the fix after reading the diagnosis. If a probe would need a write, stop and say so instead of doing it.

If in doubt whether a command is read-only, it is not: leave it out and name it as the next probe.

## Method

1. **Restate the symptom** in {{USER_NAME}}'s words, in one line. If `$ARGUMENTS` is too vague to locate anything, ask one question; otherwise go.
2. **Check what is already running before touching anything.** Never start, stop or restart a service; one that is down may be down on purpose.
3. **Find the evidence**: the log line, the failing request, the file, the value. No evidence yet means keep looking, not start guessing.
4. **Trace the path by reading the statements**: what is assigned, what is called, the real values. A comment, docstring or name is a hint about intent, never evidence. When a comment contradicts the code, the code is what happens; report the divergence.
5. **Form one hypothesis and test it with a read-only probe** (a grep, a log filter, a read of the data). A hypothesis that survives no probe stays labelled a hypothesis.
6. **Large search space?** Dispatch a `reader` subagent with a precise question (files, patterns, what to return with `path:line`) instead of flooding this window.

## Output

Short, in {{LANGUAGE}}, in this order:

1. **The problem** — one line, in {{USER_NAME}}'s terms.
2. **The cause** — the mechanism, with `file:line` and the evidence (log line, command output, value). Quote what you saw, not what you expected.
3. **Confidence** — verified or hypothesis. If hypothesis, say what would confirm it.
4. **Fix options** — 1 to 3 options, each with what it changes and its risk. Recommend one.
5. **Your call** — "tell me which option and I will go ahead".

## When the cause is not found

Do not guess. Report what was ruled out (with the probe that ruled it out), what is still open, and the single next probe that would narrow it, including any that needs a write or a permission {{USER_NAME}} must grant.
