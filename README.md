# Wisp

Wisp is a macOS app that lives in the notch: hover the camera notch and a panel opens with a chat to your own Claude Code, your notes ("brain"), tasks, reminders, agenda, music and system stats. A setup wizard installs a small Python runtime, creates a local git brain, adds a generic Claude Code harness (roles, skills, hooks) and can connect a Telegram bot so the same conversations reach your phone. Wisp does not bundle a model: it drives the Claude Code you already have, with your own login.

## Requirements

- macOS 15 (Sequoia) or newer.
- [Claude Code](https://docs.claude.com/en/docs/claude-code), logged in (the wizard can install it and open the login for you).
- Optional: a Telegram bot token, a Spotify developer app (Client ID).

## Install

Download `Wisp.dmg` and follow [docs/instalar.md](docs/instalar.md). The guide is in Brazilian Portuguese; in short: drag Wisp to Applications, open it once, then allow it in System Settings › Privacy & Security › Open Anyway (the release is ad-hoc signed and not notarized).

## Build from source

Needs Xcode (Swift 6), [xcodegen](https://github.com/yonaskolb/XcodeGen) and [uv](https://docs.astral.sh/uv/).

```sh
scripts/fetch-uv.sh                 # downloads the pinned uv binary the app embeds
cd app && xcodegen generate && cd ..
xcodebuild -project app/Wisp.xcodeproj -scheme Wisp -configuration Debug \
  -skipPackagePluginValidation build
```

`-skipPackagePluginValidation` is required on the command line because SwiftTerm ships a build plugin Xcode does not trust by default.

Release: `scripts/build-release.sh` builds the Release app and writes `dist/Wisp.dmg` and `dist/Wisp.zip`, ad-hoc signed. The disk image is laid out by [dmgbuild](https://github.com/dmgbuild/dmgbuild) (pinned, run through `uvx`, so uv must be on `PATH`). Set `WISP_SIGN_ID` to sign with a Developer ID and `WISP_NOTARY_PROFILE` to notarize.

The app icon (`app/Resources/Assets.xcassets/AppIcon.appiconset`) and the disk image background (`scripts/dmg/`) are committed renders of the real avatar; `scripts/render-art.sh` regenerates both.

## Layout

- `app/`: the macOS app (SwiftUI/AppKit), generated with xcodegen.
- `core/`: `WispCore`, a Swift package with the app logic.
- `cli/`: the `wisp` command-line tool (Python): `doctor`, `setup …`, `topic …`, hooks.
- `bot/`: `wisp-bot`, the Telegram bot (Python).
- `harness/`: the generic Claude Code harness installed into `~/.claude`.
- `vault-template/`: the starting content of a new brain.
- `scripts/`: uv download, runtime embedding, art rendering, release build and leak check.
- `docs/`: install guide, changelog and developer notes.

## Tests

```sh
cd core && swift test               # WispCore
uv run pytest                       # cli/ and bot/
```

Before publishing, `scripts/leak-check.sh` (needs `gitleaks`) scans `app`, `core`, `cli`, `bot`, `harness`, `vault-template`, `docs` and `scripts` for secrets and personal identifiers.

## Name note

Other projects use similar names, such as `marciovicente/wisp-ai` and Wispr Flow. This Wisp is unrelated to both.

## Third-party software

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), used by the setup wizard's terminal: MIT License, Copyright (c) 2019-2026 Miguel de Icaza; it also carries notices from xterm.js, SourceLair and Christopher Jeffrey (see its LICENSE, shipped in the app under Ajustes › Avisos de terceiros).
- [uv](https://github.com/astral-sh/uv) by Astral, embedded in the app to install the Python runtime: dual-licensed under MIT or Apache-2.0.

## License

Wisp is free software under the [GNU General Public License v3.0](LICENSE). Contributions are welcome through pull requests; see [CONTRIBUTING.md](CONTRIBUTING.md).
