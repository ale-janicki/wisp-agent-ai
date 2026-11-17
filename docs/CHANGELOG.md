# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**:date: ORDER**: Entries are organized in **descending chronological order** (newest first).

## [Unreleased] - 2026-11-17

### Added

- Python core `wisp` as a uv workspace (`cli/` + `bot/`): per-OS paths, config, runner, step report and file ops, with `wisp --version`.
- `wisp doctor --json`: reports system, Claude Code and login, brain, harness, Telegram and profile as one JSON object, never exposing the login email.
- Os-neutral jobs interface (`JobManager`) with a launchd implementation; Linux and Windows raise a clear "not supported yet".
- `wisp setup brain [--path] [--dry-run] --json`: creates the brain from `vault-template/` as a local git folder (default `~/Wisp/brain`), keeps files that already exist, commits without a global git identity, warns for macOS-protected folders and asks for the Command Line Tools first.
- Secrets scan and `scripts/leak-check.sh`: gitleaks, the shared secret patterns and a generic identifier list; a git-ignored local list adds personal patterns.
- Generic `harness/` content (CLAUDE.md block, reader/operator/reviewer roles, `brain-boot` and `save-to-brain` skills, `/diagnose`, settings fragment) and `wisp hook boot|brain-commit`: the boot hook prints the date and the pendências, the Stop hook commits brain changes locally, holds back files that look like secrets and never pushes.
- `wisp setup harness [--dry-run] --json`: installs the generic harness into `~/.claude` with a backup first (`~/.local/state/wisp/backups`), merges `CLAUDE.md` (one marked block) and `settings.json` (user values and order kept, ours appended), keeps any file the user edited and reports it as a conflict, refuses a symlinked harness, and leaves a second run byte-identical.
- `wisp setup system [--with-homebrew] [--dry-run] --json`: checks the Command Line Tools (opens Apple's installer), installs Claude Code with its official installer and saves its path; with `--with-homebrew` downloads Homebrew's signed `.pkg`, checks its signature and opens it.
- `wisp-bot`: the Telegram bot as a package of its own, configured per user from `wisp.json` (token from its 0600 file, user, group, brain, topic folder, state folder, persona); `solo` hosting reads Telegram on one machine with no ssh, `pair` keeps the Mac and PC hand-off; brain sync and alerts run only when their command is configured.

### Changed

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
