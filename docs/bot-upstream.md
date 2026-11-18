# Bot provenance

`bot/src/wisp_bot/` started as a copy of a private single-user Telegram bot, generalized to a per-user `wisp.json` config. It is maintained in this repository; there is no public upstream to sync with.

What changed in the copy:

- Configuration moved from hard-coded values to `wisp.json` (token file, user, group, brain, topic folder, state folder, persona), with `solo` (one machine) as the default hosting and `pair` (two machines over ssh) as an option.
- Integrations specific to the original setup were removed (e-mail, job alerts, a market journal, power-loss handling, a brain-digest context and two machine-specific commands), with their tests. Brain sync and alerts run only when the user configures a command for them.
- The tests that exercised the original harness's topic CLI and hooks were dropped; `cli/` carries its own tests for `wisp topic`.
