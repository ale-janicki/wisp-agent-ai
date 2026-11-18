# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are in descending chronological order (newest first).

## [Unreleased] - 2026-11-17

### Added

- Release build: `scripts/build-release.sh` builds the Release app and packs `dist/Wisp.dmg` (drag to Applications) and `dist/Wisp.zip`. The default signature is ad-hoc with no notarization; `WISP_SIGN_ID` (Developer ID, hardened runtime) and `WISP_NOTARY_PROFILE` (notarization) are optional. pt-BR install guide in `docs/instalar.md`.
- First-launch setup wizard in its own window: it waits for the runtime install ("Preparando o Wisp", with "tentar de novo" on failure), then walks system (optional Homebrew), login, brain, harness, Telegram (optional), Spotify (optional) and the profile, showing each step's real command under "detalhes". It can be run again from Ajustes > "Rodar o setup de novo"; existing installs are not sent through it.
- The wizard's login step is a real terminal (SwiftTerm): the user runs their own `claude` and types `/login`; the step turns done once the login is detected, and "Pular por enquanto" skips it.
- Bundled runtime: the app ships `uv` 0.13.5 (universal, pinned sha256, `scripts/fetch-uv.sh`) and the Python sources. On first launch they are copied to `~/.local/share/wisp/runtime`, uv runs from a copy without the quarantine flag (the bundled one blocks on Gatekeeper after a download), `uv sync` and `wisp setup shim` run, and an unchanged runtime is not reinstalled.
- Ajustes > "Abrir ao ligar o Mac" (default on): Wisp registers as a login item once, only when it runs from /Applications or ~/Applications. A removal in System Settings is respected, and the switch shows the real macOS status.
- Notch notices: a reply in a conversation not on screen, a new Telegram topic message, a new alert or reminder, and an outbox message sent or marked "não enviada" grow the pill into a card under the notch; it folds after 6 s, pauses on hover, and a click opens the matching tab. Ajustes > "Avisos no notch" has one switch per kind and "Não perturbe". Wisp never uses macOS notifications.
- Telegram delivery (D15): with Telegram configured a conversation never runs locally. Every message goes into a persisted outbox first, waits "na fila" while the bot is down, survives a quit, retries after 10, 30 and 60 s, then shows "não enviada · tentar de novo · descartar".
- `wisp` CLI (Python, uv workspace `cli/` + `bot/`): `wisp doctor --json`, `wisp setup system|brain|harness|telegram|profile|shim`, each with `--json` and most with `--dry-run`.
  - `setup system [--with-homebrew]`: checks the Command Line Tools, installs Claude Code with its official installer, and optionally installs Homebrew from its signed `.pkg`.
  - `setup brain`: creates a local git brain from `vault-template/` (default `~/Wisp/brain`), keeping existing files.
  - `setup harness`: installs the generic harness into `~/.claude` with a backup first, merges `CLAUDE.md` and `settings.json`, keeps any file the user edited, and is idempotent.
  - `setup telegram --token-stdin | --discover | --skip`: validates the bot token (read from stdin, stored 0600), finds the forum group and the user, and installs the `ai.wisp.bot` launchd job.
  - `setup profile`: writes `~/.config/wisp/profile.json` (persona, user name, language, avatar).
- Generic `harness/`: a `CLAUDE.md` block, reader/operator/reviewer roles, `brain-boot` and `save-to-brain` skills, `/diagnose`, and hooks: `wisp hook boot` (date and pending items), `wisp hook brain-commit` (commits brain changes locally, holds back files that look like secrets, never pushes) and `wisp hook guard-secrets`.
- Secrets guard: `wisp hook guard-secrets` (`PreToolUse`) blocks Bash and file-tool calls that point into the Wisp secrets folder, after normalising `~`, `$HOME`, `..` and symlinks; the `permissions.deny` rules stay as a second layer.
- `wisp-bot`: the Telegram bot as its own package, configured from `wisp.json`. `solo` hosting reads Telegram on one machine; `pair` hands a conversation off between two machines over ssh. Brain sync and alerts run only when their command is configured.
- `wisp topic status|listar|novo|falar|encerrar|assumir|puxar`: the topic CLI; `falar --anexo <file>` (repeatable) sends files as photos or documents.
- Background jobs interface with a launchd implementation; Linux and Windows report "not supported yet".
- `scripts/leak-check.sh`: gitleaks, the shared secret patterns and a generic identifier list over `app`, `core`, `cli`, `bot`, `harness`, `vault-template`, `docs` and `scripts`; an optional git-ignored local list adds personal patterns.

### Changed

- The app's bundle id is `ai.wisp.app`; settings and the Spotify login from the previous id are copied over once. The bot's launchd label is `ai.wisp.bot`.
- Conversation rows show a one-line preview of the last message under the date ("Você: …", attachments as "📎 foto"/"📎 arquivo").
- Início: the "Última conversa" tile is now "Conversas": the most recent Wisp and Telegram conversations, as many as fit.
- Pill avatar takes its gradient from the theme accent, breathes, blinks and glows while the agent works; "Reduzir movimento" freezes it. The pill dot shows only for an unread notice or a conversation in error.
- Telegram with two machines: sending from Wisp while the other machine reads the bot first brings the conversation over, then sends; if that fails, one sentence explains it and nothing is sent.
- `wisp doctor --json` reports a warning and default settings when `wisp.json` is unreadable.

### Fixed

- The Claude Code installer is downloaded over HTTPS to a file and run from it instead of `curl | bash`.
- The bot's ssh helper kills its whole process group on timeout.
- Closing the conversation list slides it out as the exact reverse of opening it.
- The command runner no longer crashes when a timed-out child has already exited.
- Invalid graph settings fall back to the defaults and say so instead of resetting silently.

## [Unreleased] - 2026-11-16

### Added

- Memória graph view: Obsidian-style link graph of the vault (wiki links, embeds, aliases), hover highlights neighbours, click opens the note, local graph, folder colours.
- Música with the Spotify Web API: login with PKCE (tokens in the Keychain), playlists, search, play and add to queue, using the user's own Spotify app.
- Initial app: `core/` (WispCore, SwiftPM) and `app/` (Wisp.app, xcodegen, menu-bar agent for macOS 15+, Swift 6).
- Profile loaded from `~/.config/wisp/profile.json` (persona, agent cwd and model, block commands).
- Agent engine driving the user's installed Claude Code (`claude -p` stream-json), one long-lived session per conversation; past transcripts read from `~/.claude/projects`.
- Notch shell: a pill hugging the camera notch; the panel opens on hover, click or ⌥Space and closes with Esc or an outside click.
- Panel tabs: Início (draggable tiles), Conversa (Wisp and Telegram), Memória (vault search, recent notes), Tarefas, Lembretes, Agenda, Rotinas (launchd jobs), Música, Copiados (clipboard history that skips password managers), My Mac (system, CPU, memory, disk, temperature, battery, network, top processes) and Ajustes (themes, custom colours with a contrast guard).
- Now Playing for Spotify and Music via AppleScript; never launches a player.
- Claude plan usage: session and weekly limits from the status line, plus token totals from transcripts.
- Telegram: with the bot configured, a Wisp conversation is a Telegram topic; replies are read live from the session transcript.

### Changed

- Memória graph is a live force simulation: drag a note and its neighbours follow, pan with momentum, zoom at the cursor, labels fade in with zoom, and a Forces panel saved in settings. It draws only while something moves.
- Conversa: the conversation list slides over the sidebar; a button or ⌘N toggles between the list and the menu.
- Telegram section hides topics whose note is closed.
- My Mac scrolls inside the tab, shows real free space for network volumes, and sparklines span the tile width.
- Scroll bars are hidden in every pane.

### Removed

- Timers tab and the timer ring in the pill.

---

This changelog is maintained by hand and may skip minor changes; see the Git log for detail.
