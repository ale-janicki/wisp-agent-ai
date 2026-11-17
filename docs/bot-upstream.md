# Bot upstream

`bot/src/wisp_bot/` is a copy of the owner's Telegram bot, generalized to a per-user config. Until the owner migrates, fixes land upstream first and are ported here by hand.

- Upstream: the owner's `Wisp` repository, folder `telegram/Wisp_bot/` (code, tests and `fixtures/`).
- Upstream commit at copy time: `26dbd58db1d5bf820b06ab9d77009aeef52630fc`
- `git status --short telegram` at copy time: clean (no modified or untracked files).
- Copied: 18 modules, 15 test files, 5 fixtures. Baseline in the copy: 444 tests collected, 443 passed and 1 skipped (that test read a transcript from the owner's home, which the isolated test HOME does not have).
