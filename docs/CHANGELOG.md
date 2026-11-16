# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**:date: ORDER**: Entries are organized in **descending chronological order** (newest first).

## [Unreleased] - 2026-11-16

### Added

- Project scaffold: `core/` (WispCore, SwiftPM) and `app/` (Wisp.app, xcodegen, menu-bar agent app for macOS 15+, Swift 6).
- Profile loading from `~/.config/wisp/profile.json` (persona, agent cwd/model, block commands).
- Agent engine that drives the user's installed Claude Code (`claude -p` stream-json): locator with the login-shell PATH, line buffer, stream decoder, reply formatter, long-lived session per conversation, conversation reducer.
- Conversation store in Application Support with corrupt-file recovery, delete, and past transcripts read from `~/.claude/projects`.
- Notch shell: pill hugging the camera notch (fixed width and position; active state drops a one-line strip below the notch), panel on hover/click/⌥Space, Esc and outside click close, click-through outside the pill.
- Design system (`Theme`): dark surfaces, accent colors, type scale, radii; Wisp avatar mascot.
- Panel tabs: Início (dashboard with draggable tiles: music, Claude plan limits, notifications, last conversation), Conversa (Wisp and Telegram sections), Memória (vault search, recent notes), Tarefas (pendências file), Lembretes (alerts), Agenda (today's events), Rotinas (launchd jobs: status, log, persistent on/off), Timers, Música, Copiados (clipboard history with password-manager filter), My Mac (system, CPU, memory, disk, temperature, battery, network, top processes), Ajustes (theme presets, custom hex colors, contrast guard).
- Now Playing for Spotify and Music via AppleScript, with an Automation permission request button; never launches a player.
- Claude plan usage: session and weekly limit % read from the status line's `rate_limits`, plus token totals from transcripts.
- Telegram: with the bot configured, a Wisp conversation is a Telegram topic; messages go through the bot and replies are read live from the session transcript.
- Profile-declared block commands run off the main thread with a timeout and process-group kill.
- DEBUG-only snapshot renderer (`-WispSnapshot <dir>`) for visual checks without Screen Recording permission.

---

**Note**: This changelog is maintained manually and may not include all minor changes. For detailed commit history, please refer to the Git log.
