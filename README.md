# Wisp

Wisp is a macOS notch agent: an assistant that lives in the notch, and the start of a whole personal-agent harness. macOS first.

## Requirements

Wisp does not bundle a model. It requires your own Claude Code installed and logged in, or an API key.

## Layout

- `core/`: `WispCore`, a Swift package with the app logic.
- `app/`: the macOS app target, generated with xcodegen (`cd app && xcodegen generate`).

## Name note

Other projects use similar names: `marciovicente/wisp-ai` and Wispr Flow. Wisp here is unrelated to both.

## Third-party software

The setup wizard's terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT License, Copyright (c) 2019-2026 Miguel de Icaza; it also carries notices from xterm.js, SourceLair and Christopher Jeffrey, see its LICENSE).

## Status

Private repo for now.
