# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**:date: ORDER**: Entries are organized in **descending chronological order** (newest first).

## [Unreleased] - 2026-11-17

### Added

- Ajustes > "Abrir ao ligar o Mac" (default on): Wisp registers itself as a login item (`SMAppService.mainApp`) once, when the setup wizard finishes or on the first launch after it, and only from an app in /Applications or ~/Applications (a DerivedData build never does). A removal in System Settings is respected; the switch shows macOS's real status, can register again on purpose, and points to Login Items when macOS asks for approval. The decision is `LoginItemPolicy` in WispCore.
- Notch notices: a reply in a conversation not on screen (local or Telegram), a new message in a Telegram topic, a new alert/lembrete and an outbox message finally sent or marked "não enviada" grow the pill into a card under the notch (avatar or icon, title, two-line preview, time, +N when more wait, ×); it folds after 6 s, pauses while hovered, a click opens the panel on the conversation, topic or Lembretes, and with the panel open on another tab a floating copy shows instead. Queue, dedupe by source, "already on screen" and timing live in WispCore `NoticeQueue`; alerts and topics are read every 60 s while the panel is closed. Ajustes > "Avisos no notch": one switch per kind and "Não perturbe". Never the macOS Notification Center. DEBUG `-WispDemoNotice` fires three samples.
- Release build: `scripts/build-release.sh` builds the Release app, signs the embedded uv and the app (ad-hoc by default; `WISP_SIGN_ID` for a Developer ID with the hardened runtime and the apple-events entitlement; notarizes only with `WISP_NOTARY_PROFILE`), verifies the signature and packs `dist/Wisp.zip`; pt-BR install guide in `docs/instalar.md`. The runtime installer runs a copy of uv without the quarantine flag, because the bundled uv blocks on Gatekeeper when the app came from a download.
- Setup wizard Login step is a real terminal (SwiftTerm, MIT): the user runs her own `claude` and types /login; `claude_login` is polled every 2 s, the step turns done on login, `/exit` is sent after 1.5 s and the child is ended (SIGTERM, SIGKILL after 3 s) when the step is left, the window closes or the app quits; "abrir de novo" when it ends first, and "Pular por enquanto" in Release too. DEBUG `-WispSetupStep <step>` opens the wizard on a step with the real HOME.
- First-launch setup wizard (820x600 window, not the notch panel): it waits for the runtime install ("Preparando o Wisp", one sentence plus "tentar de novo" when it fails), then walks system, login, brain, harness, Telegram, Spotify and "Teu wisp" with each step's real commands under "detalhes"; the Telegram token goes over stdin only. It opens when `SetupGate` says so (existing installs are untouched) and again from Ajustes > "Rodar o setup de novo"; `ThemePicker` is now shared with Ajustes. DEBUG `-WispSetupHome <dir> [-WispSetupAutorun]` walks it against a fake HOME.
- App bundles `uv` 0.13.5 (universal, pinned sha256, `scripts/fetch-uv.sh`) and the Python sources (`scripts/embed-runtime.sh`); on first launch `RuntimeInstaller` copies them to `~/.local/share/wisp/runtime`, runs `uv sync` and `wisp setup shim`, and writes `VERSION` last. An unchanged runtime is not reinstalled.
- WispCore D15 delivery: `DeliveryPolicy` (local only without Telegram, else Telegram or hold), a persisted `Outbox` of held messages (oldest first, corrupt file kept as `outbox.json.bad`) and the conversation phase `held`.
- WispCore setup models (`SetupReport`, `DoctorReport`, `SetupState`), the wizard gate, the runtime bootstrap layout and a capturing `CommandRunner` (process spawning shared with `BlockCommand` through `ProcessCore`); `Persona.user` names the user in attachment blocks (fallback "o usuario") and the CLI contract fixtures are decoded by the Swift parsers.
- `wisp setup profile --name … [--user-name] [--language] [--avatar] --json` writes `~/.config/wisp/profile.json` (persona with the user's name, brain blocks, existing blocks kept), copies the avatar and re-renders the CLAUDE.md block (an edited block stays a conflict); `wisp setup shim` writes `~/.local/bin/wisp` and refuses a file that is not ours.
- Python core `wisp` as a uv workspace (`cli/` + `bot/`): per-OS paths, config, runner, step report and file ops, with `wisp --version`.
- `wisp doctor --json`: reports system, Claude Code and login, brain, harness, Telegram and profile as one JSON object, never exposing the login email.
- Os-neutral jobs interface (`JobManager`) with a launchd implementation; Linux and Windows raise a clear "not supported yet".
- `wisp setup brain [--path] [--dry-run] --json`: creates the brain from `vault-template/` as a local git folder (default `~/Wisp/brain`), keeps files that already exist, commits without a global git identity, warns for macOS-protected folders and asks for the Command Line Tools first.
- Secrets scan and `scripts/leak-check.sh`: gitleaks, the shared secret patterns and a generic identifier list; a git-ignored local list adds personal patterns.
- Generic `harness/` content (CLAUDE.md block, reader/operator/reviewer roles, `brain-boot` and `save-to-brain` skills, `/diagnose`, settings fragment) and `wisp hook boot|brain-commit`: the boot hook prints the date and the pendências, the Stop hook commits brain changes locally, holds back files that look like secrets and never pushes.
- `wisp setup harness [--dry-run] --json`: installs the generic harness into `~/.claude` with a backup first (`~/.local/state/wisp/backups`), merges `CLAUDE.md` (one marked block) and `settings.json` (user values and order kept, ours appended), keeps any file the user edited and reports it as a conflict, refuses a symlinked harness, and leaves a second run byte-identical.
- `wisp setup system [--with-homebrew] [--dry-run] --json`: checks the Command Line Tools (opens Apple's installer), installs Claude Code with its official installer and saves its path; with `--with-homebrew` downloads Homebrew's signed `.pkg`, checks its signature and opens it.
- `wisp-bot`: the Telegram bot as a package of its own, configured per user from `wisp.json` (token from its 0600 file, user, group, brain, topic folder, state folder, persona); `solo` hosting reads Telegram on one machine with no ssh, `pair` keeps the Mac and PC hand-off; brain sync and alerts run only when their command is configured.
- `wisp topic status|listar|novo|falar|encerrar|assumir|puxar`: the topic CLI with the same JSON contract as the owner's, so a profile swaps only the binary; `listar` marks Geral and the configured system topics `fixed`, `assumir` is immediate in `solo`, and `puxar` (pair only) brings a topic's session to this terminal.
- `wisp setup telegram --token-stdin | --discover | --skip [--dry-run] --json`: validates the bot token from stdin (0600 file, never on argv), finds the forum group and the user from the first message, checks the bot can manage topics, writes the Telegram block of the profile (absolute `wisp` shim, `{anexos}` kept in the send template) and installs the `ai.wisp.bot` launchd job; refuses to look for the group while the bot job exists, so one token is never polled twice.
- `wisp topic falar --anexo <file>` (repeatable) and the bot's `falar` op with `anexos`: files from the bot's attachments folder are checked first, then posted as photos or documents, and the agent gets the same file block as a phone upload (user name from `wisp.json`).

### Changed

- Conversa with Telegram configured never falls back to a local session: every message (with its attachments) goes into the outbox first and waits "na fila" while the bot is down, survives a quit, retries after 10, 30 and 60 s when a send fails, then shows "não enviada · tentar de novo · descartar"; it goes out in order through the same hand-off, create and send once the bot is back, a timed-out send is never resent on its own, and the Conversa list marks conversations with held messages; the notice reads "Telegram fora do ar — as mensagens ficam na fila".
- `wisp doctor --json` prints one JSON object with a `warning` and default settings when `wisp.json` is unreadable; the bot's launchd label is `ai.wisp.bot`.
- Telegram: the machine where the last Wisp message was sent reads the bot. Sending from Wisp while the other machine reads first brings the conversation over ("Trazendo a conversa do PC…"), then creates or sends; if the hand-off fails, one sentence explains it and nothing is sent. The Conversa list says when the PC is reading.

### Fixed

- The command runner no longer crashes when a timed-out child has already exited.
- Invalid graph settings now fall back to the defaults and say so in a notice instead of resetting silently.

## [Unreleased] - 2026-11-16

### Changed

- Memória graph is now a live force simulation like Obsidian's: drag a note and its neighbours follow, pan with momentum, zoom at the cursor, animated hover dimming, labels that fade in with zoom, a Forces panel (center, repel, link force and distance, node size, link thickness, text fade) saved in settings, an "Animar" button, and an animated switch to the local graph. It draws only while something moves and stops when the panel closes, also mid-drag.
- Clicking the Conversa row while the menu is showing brings the conversation list back; ⌘N does too.
- My Mac scrolls inside the tab; network volumes show their real free space.
- Scroll bars are hidden in every pane.

### Added

- Memória graph view: Obsidian-style link graph of the vault (wiki links, embeds, aliases), force layout cached between opens, hover highlights neighbours, click opens the note, local graph, folder colours.
- Música with the Spotify Web API: login with PKCE through a loopback callback (tokens in the Keychain), the user's playlists, search, play and add to queue; setup steps for the user's own Spotify app.

### Changed

- Conversa: the conversation list slides over the sidebar to give the chat more room; a button toggles between the list and the menu.
- Telegram section hides topics whose note is closed; the Conversa count is the number of listed conversations.
- My Mac sparklines span the tile width; the top-processes list refreshes every 10 s.

### Removed

- Timers tab and the timer ring in the pill.

### Added (initial)

- Project scaffold: `core/` (WispCore, SwiftPM) and `app/` (Wisp.app, xcodegen, menu-bar agent app for macOS 15+, Swift 6).
- Profile loading from `~/.config/wisp/profile.json` (persona, agent cwd/model, block commands).
- Agent engine that drives the user's installed Claude Code (`claude -p` stream-json): locator with the login-shell PATH, line buffer, stream decoder, reply formatter, long-lived session per conversation, conversation reducer.
- Conversation store in Application Support with corrupt-file recovery, delete, and past transcripts read from `~/.claude/projects`.
- Notch shell: pill hugging the camera notch (fixed width and position; active state drops a one-line strip below the notch), panel on hover/click/⌥Space, Esc and outside click close, click-through outside the pill.
- Design system (`Theme`): dark surfaces, accent colors, type scale, radii; Wisp avatar mascot.
- Panel tabs: Início (dashboard with draggable tiles: music, Claude plan limits, notifications, last conversation), Conversa (Wisp and Telegram sections), Memória (vault search, recent notes), Tarefas (pendências file), Lembretes (alerts), Agenda (today's events), Rotinas (launchd jobs: status, log, persistent on/off), Música, Copiados (clipboard history with password-manager filter), My Mac (system, CPU, memory, disk, temperature, battery, network, top processes), Ajustes (theme presets, custom hex colors, contrast guard).
- Now Playing for Spotify and Music via AppleScript, with an Automation permission request button; never launches a player.
- Claude plan usage: session and weekly limit % read from the status line's `rate_limits`, plus token totals from transcripts.
- Telegram: with the bot configured, a Wisp conversation is a Telegram topic; messages go through the bot and replies are read live from the session transcript.
- Profile-declared block commands run off the main thread with a timeout and process-group kill.
- DEBUG-only snapshot renderer (`-WispSnapshot <dir>`) for visual checks without Screen Recording permission.

---

**Note**: This changelog is maintained manually and may not include all minor changes. For detailed commit history, please refer to the Git log.
