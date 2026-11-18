#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$root/dist"
repo="ale-janicki/wisp-agent-ai"
app="$root/build/Build/Products/Release/Wisp.app"

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: publish-release.sh <version, e.g. 0.2.0> [notes-file]" >&2; exit 1; }
tag="v$version"

for file in "$dist/Wisp.dmg" "$dist/appcast.xml"; do
  [ -f "$file" ] || { echo "publish-release: $file missing; run scripts/build-release.sh first" >&2; exit 1; }
done
built="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
[ "$built" = "$version" ] || { echo "publish-release: dist/ holds $built, not $version" >&2; exit 1; }
grep -q "sparkle:shortVersionString>$version<" "$dist/appcast.xml" \
  || { echo "publish-release: dist/appcast.xml has no entry for $version" >&2; exit 1; }
grep -q "releases/download/$tag/Wisp.dmg" "$dist/appcast.xml" \
  || { echo "publish-release: dist/appcast.xml does not point at $tag/Wisp.dmg" >&2; exit 1; }

cd "$root"
[ -z "$(git status --porcelain)" ] || { echo "publish-release: the working tree is not clean" >&2; exit 1; }
git fetch --quiet origin
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')" \
  || { echo "publish-release: the branch has no upstream" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$upstream")" ] \
  || { echo "publish-release: HEAD is not pushed to $upstream" >&2; exit 1; }
[ -f "$dist/BUILD_COMMIT" ] || { echo "publish-release: dist/BUILD_COMMIT missing; rebuild" >&2; exit 1; }
[ "$(sed -n 1p "$dist/BUILD_COMMIT")" = "$(git rev-parse HEAD)" ] && [ "$(sed -n 2p "$dist/BUILD_COMMIT")" = "clean" ] \
  || { echo "publish-release: dist/ was not built from a clean HEAD; run scripts/build-release.sh again" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "$tag" >/dev/null; then
  echo "publish-release: tag $tag already exists" >&2
  exit 1
fi

notes="${2:-}"
if [ -z "$notes" ]; then
  notes="$(mktemp -t wisp-notes)"
  trap 'rm -f "$notes"' EXIT
  awk '/^## /{ if (found) exit; if ($0 ~ /Unreleased/) { found=1; next } } found' "$root/docs/CHANGELOG.md" > "$notes"
fi
[ -s "$notes" ] || { echo "publish-release: the release notes are empty" >&2; exit 1; }

git tag -a "$tag" -m "Wisp $version"
git push origin "$tag"
gh release create "$tag" "$dist/Wisp.dmg" "$dist/appcast.xml" --repo "$repo" --title "Wisp $version" \
  --notes-file "$notes" --verify-tag --latest
echo "publish-release: https://github.com/$repo/releases/tag/$tag"
