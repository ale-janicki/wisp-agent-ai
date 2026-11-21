# Harness manifest

What Wisp installs into a new user's `~/.claude`, and what it leaves out. Sources are real files only (no symlinks) in the author's harness and in the author's mini-agent kit. Placeholders rendered at install: `{{PERSONA_NAME}}`, `{{USER_NAME}}`, `{{BRAIN_DIR}}`, `{{LANGUAGE}}`.

## Included

| Source | Destination | Scrubbed |
|---|---|---|
| `kit/CLAUDE.md` + `harness/CLAUDE.md` (memory rules) | `claude-md-block.md` | Rewritten in English; persona, user, brain path and language became placeholders; markers `wisp:begin/end` added; dropped the marketing and finance routing, the fixed vault name, and the author's routing table |
| (new) | `settings.json` | Fragment with only `permissions` and `hooks`; hooks call `wisp hook` (`guard-secrets`, `guard-telegram`, `guard-destructive`, `boot`, `recall`, `aprendizados`, `brain-commit`), never an interpreter. The three guards also run without this harness: the app and the bot pass them to every `claude` they start with `--settings` |
| `harness/agents/reader.md` | `agents/reader.md` | Owner and ecosystem name became `{{PERSONA_NAME}}'s harness` |
| `harness/agents/operator.md` | `agents/operator.md` | Same; dropped the engineering-standard path; owner became `{{USER_NAME}}` |
| `harness/agents/reviewer.md` | `agents/reviewer.md` | Same; dropped the pointer to the end-to-end reviewer |
| the author's persona-boot skill (`SKILL.md`) | `skills/brain-boot/SKILL.md` | Persona, brain path and language placeholders; loads pendências, index and conventions instead of the author's soul and memory notes; dropped the finance CLI, daily note and observation log |
| `harness/skills/save-to-brain/SKILL.md` | `skills/save-to-brain/SKILL.md` | Files into `{{BRAIN_DIR}}/arquivos/`; dropped the iCloud, PC-only, tax, company and chat-attachment specifics |
| `harness/commands/diagnose.md` | `commands/diagnose.md` | Owner became `{{USER_NAME}}`; dropped the author's stack-status tool, the plugin reference and the Portuguese trigger phrases |

## Excluded

| Item | Reason |
|---|---|
| The 122 linked skills and 12 linked hooks | Symlinks into another organisation's shared skills repository; not the author's to redistribute |
| `general/` skills of the other organisation's shared skills repository | NEEDS-ALE, not shipped: ask whether any may ship |
| `agents/reviewer-e2e.md` | Needs a browser tool and a login store; only used at commit time |
| `hooks/status-gate`, `hooks/vault-gate` and every other hook | Depend on the author's binaries and vault layout; Wisp has its own hooks |
| `commands/commit-push`, `check`, `e2e`, `e2e-video`, `repo-sync`, `run-migration`, `deploy-status`, `update-changelog`, `task-new`, `tasks`, `show-tasks`, `start`, `soul`, `open-code` | Coding workflow for developers |
| `commands/daily-start`, `me-avisa`, `topico`, `create-context` | Call the author's own binaries (calendar, mail, alerts, topic CLI) |
| `skills/marketeiro`, `skills/finance` and the kit's skills | Personal brand and finance data of the author; not generic |
| `harness/CLAUDE.md` routing table and behavioural rules | Names the author's notes, clients and binaries; only the memory rules were kept |
| `settings.json` of the source | Carries the author's model, plugins, statusline, hooks and permissions; only the fragment above ships |
| `bin/`, `coordination/`, `launchd/`, `systemd/`, `mailbox/`, `people.json`, `slack-as-ale.json`, `state/`, `tools/`, `projects/`, `workspace/` | Personal binaries, state and private data |
