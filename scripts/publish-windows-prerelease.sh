#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 <tag windows-vX.Y.Z-...> <installer.exe> <notes.md>" >&2; exit 2; }
[ $# -eq 3 ] || usage
tag="$1" exe="$2" notes="$3"

case "$tag" in windows-v*) ;; *) echo "publish-windows-prerelease: tag must start with windows-v" >&2; exit 1 ;; esac
[ -f "$exe" ] || { echo "publish-windows-prerelease: installer not found: $exe" >&2; exit 1; }
[ -f "$notes" ] || { echo "publish-windows-prerelease: notes not found: $notes" >&2; exit 1; }

root="$(git rev-parse --show-toplevel)"
common="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
patterns=""
for f in "$root/scripts/leak-patterns.local.txt" "$common/../scripts/leak-patterns.local.txt" "${XDG_CONFIG_HOME:-$HOME/.config}/wisp/leak-patterns.local.txt"; do
  [ -f "$f" ] && { patterns="$f"; break; }
done
[ -n "$patterns" ] || { echo "publish-windows-prerelease: leak-patterns.local.txt not found; refusing to publish" >&2; exit 1; }
rules() { grep -vE '^[[:space:]]*(#|$)' "$patterns"; }

title="Wisp for Windows ${tag#windows-v}"
if printf '%s\n' "$title" | cat - "$notes" | grep -iqE -f <(rules); then
  echo "publish-windows-prerelease: the title or notes contain a private name; reword them" >&2
  exit 1
fi
if ! printf '%s\n' "$title" | cat - "$notes" | gitleaks stdin --redact --no-banner >/dev/null 2>&1; then
  echo "publish-windows-prerelease: gitleaks found a secret in the title or notes" >&2
  exit 1
fi
if strings -a "$exe" | grep -iqE -f <(rules); then
  echo "publish-windows-prerelease: the installer contains a private name; rebuild from a clean tree" >&2
  exit 1
fi
(cd "$root" && ./scripts/leak-check.sh >/dev/null) || { echo "publish-windows-prerelease: leak-check failed on the tree" >&2; exit 1; }

before="$(gh api "repos/{owner}/{repo}/releases/latest" --jq .tag_name)"
gh release create "$tag" "$exe" --target "$(git rev-parse --abbrev-ref HEAD)" --prerelease --latest=false \
  --title "$title" --notes-file "$notes"
after="$(gh api "repos/{owner}/{repo}/releases/latest" --jq .tag_name)"
if [ "$before" != "$after" ]; then
  echo "publish-windows-prerelease: latest moved from $before to $after; the Mac updater reads latest" >&2
  exit 1
fi
echo "publish-windows-prerelease: $tag published; latest is still $after"
