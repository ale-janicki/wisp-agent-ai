# Codex sandbox and Accessibility probe

Question: can a command run inside the sandbox Codex gives its shell (read-only or workspace-write) reach the services the Accessibility API and CGEvent need?

Run it (macOS, network for the clone, no prompt, no Apple Event, no UI action):

```
bash scripts/ax-probe/run.sh | diff - scripts/ax-probe/expected.txt && echo MATCH
```

What it does: clones `https://github.com/openai/codex` at commit `9302bb553e70512888a9053fd7aa52e23fa30d1e`, assembles the seatbelt policy in the order of `create_seatbelt_command_args_with_profile` in `codex-rs/sandboxing/src/seatbelt.rs` (`seatbelt_base_policy.sbpl`, `(allow file-read*)`, the write allow for `/private/tmp` and `/private/var/tmp` plus `WRITABLE_ROOT_0` for workspace-write, `seatbelt_preferences_policy.sbpl`, `seatbelt_read_only_platform_defaults.sbpl`, `(allow file-read* (subpath "/Applications"))`, `(deny mach-lookup (xpc-service-name-prefix ""))`, `(deny system-fcntl (fcntl-command 80 110))`, network section empty), builds `probe.c` (it calls `AXIsProcessTrusted` and `bootstrap_look_up` and nothing else) and runs it under `sandbox-exec` with each policy.

Expected result (`expected.txt`): `tccd`, `dock.server`, `windowserver.active` and `appleevents` return `kr=1100` (blocked) in both profiles; `cfprefsd.daemon` and `opendirectoryd.libinfo` stay reachable, which shows the probe runs and looks names up inside the sandbox. Unsandboxed, all six real names answer `kr=0`. The `AXIsProcessTrusted` line is left out of the comparison because the probe binary is not Wisp.

Limits: the policy is assembled by hand from the source, not emitted by a running Codex; Accessibility itself was not exercised inside the sandbox.
