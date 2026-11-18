# Contributing to Wisp

Thanks for wanting to help. Wisp is maintained by one person, so every change goes through review.

## How to contribute

1. Fork the repo and create a branch from `main`.
2. Make your change. Keep it focused: one fix or feature per pull request.
3. Run the tests before opening the PR:
   - `cd core && swift test`
   - `uv run pytest -q` (from the repo root)
   - `scripts/leak-check.sh`
4. Open a pull request against `main` and describe what changed and why. For UI changes, add a screenshot.

The maintainer reviews every pull request and decides whether it is merged. Nothing reaches `main` without that approval.

## Reporting bugs

Open an issue with what you did, what you expected and what happened, plus your macOS version. A screenshot helps.

## Never include

Tokens, passwords, Telegram ids, personal paths or anything from your own setup. `scripts/leak-check.sh` catches the common cases.

## License

By contributing, you agree that your contribution is licensed under the GNU General Public License v3.0 (see `LICENSE`).
