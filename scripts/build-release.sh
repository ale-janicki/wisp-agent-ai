#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="$root/build"
dist="$root/dist"
sign_id="${WISP_SIGN_ID:--}"
app="$build/Build/Products/Release/Wisp.app"
uv="$app/Contents/Resources/runtime/bin/uv"
dmgbuild_version="2.0.0"

[ -x "$root/app/Resources/runtime/bin/uv" ] || "$root/scripts/fetch-uv.sh"

(cd "$root/app" && xcodegen generate)

rm -rf "$build"
xcodebuild -project "$root/app/Wisp.xcodeproj" -scheme Wisp -configuration Release \
  -derivedDataPath "$build" -skipPackagePluginValidation build

[ -x "$uv" ] || { echo "build-release: $uv missing from the built app" >&2; exit 1; }

sign_args=(--force --sign "$sign_id")
if [ "$sign_id" != "-" ]; then
  sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$uv"
if [ "$sign_id" != "-" ]; then
  codesign "${sign_args[@]}" --entitlements "$root/scripts/wisp.entitlements" "$app"
else
  codesign "${sign_args[@]}" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

rm -rf "$dist"
mkdir -p "$dist"
ditto -c -k --keepParent "$app" "$dist/Wisp.zip"

if [ -n "${WISP_NOTARY_PROFILE:-}" ]; then
  [ "$sign_id" != "-" ] || { echo "build-release: notarizing needs WISP_SIGN_ID (a Developer ID)" >&2; exit 1; }
  xcrun notarytool submit "$dist/Wisp.zip" --wait --keychain-profile "$WISP_NOTARY_PROFILE"
  xcrun stapler staple "$app"
  rm -f "$dist/Wisp.zip"
  ditto -c -k --keepParent "$app" "$dist/Wisp.zip"
fi

volume_icon="$app/Contents/Resources/AppIcon.icns"
[ -f "$volume_icon" ] || { echo "build-release: $volume_icon missing from the built app" >&2; exit 1; }
uvx --from "dmgbuild==$dmgbuild_version" dmgbuild -s "$root/scripts/dmg-settings.py" \
  -D app="$app" -D background="$root/scripts/dmg/background.png" -D icon="$volume_icon" \
  "Wisp" "$dist/Wisp.dmg" >/dev/null
[ "$sign_id" = "-" ] || codesign --force --sign "$sign_id" --timestamp "$dist/Wisp.dmg"

echo "build-release: $dist/Wisp.dmg ($(du -h "$dist/Wisp.dmg" | awk '{print $1}')), $dist/Wisp.zip ($(du -h "$dist/Wisp.zip" | awk '{print $1}'))"
