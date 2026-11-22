#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="$root/build"
dist="$root/dist"
self_signed_id="Wisp Self-Signed"
if [ -n "${WISP_SIGN_ID:-}" ]; then
  sign_id="$WISP_SIGN_ID"
elif identities="$(security find-identity -v -p codesigning || true)"; grep -qF "\"$self_signed_id\"" <<<"$identities"; then
  sign_id="$self_signed_id"
else
  sign_id="-"
fi
app="$build/Build/Products/Release/Wisp.app"
uv="$app/Contents/Resources/runtime/bin/uv"
agenda="$app/Contents/Helpers/wisp-agenda"
mac="$app/Contents/Helpers/wisp-mac"
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sparkle_bin="$build/SourcePackages/artifacts/sparkle/Sparkle/bin"
repo_url="https://github.com/ale-janicki/wisp-agent-ai"
dmgbuild_version="2.0.0"

[ -x "$root/app/Resources/runtime/bin/uv" ] || "$root/scripts/fetch-uv.sh"

"$root/scripts/build-excalidraw.sh"

(cd "$root/app" && xcodegen generate)

rm -rf "$build"
xcodebuild -project "$root/app/Wisp.xcodeproj" -scheme Wisp -configuration Release \
  -derivedDataPath "$build" -skipPackagePluginValidation build

[ -x "$uv" ] || { echo "build-release: $uv missing from the built app" >&2; exit 1; }
[ -x "$agenda" ] || { echo "build-release: $agenda missing from the built app" >&2; exit 1; }
[ -x "$mac" ] || { echo "build-release: $mac missing from the built app" >&2; exit 1; }

developer_id=false
[ "$sign_id" = "-" ] || [ "$sign_id" = "$self_signed_id" ] || developer_id=true
sign_args=(--force --sign "$sign_id")
[ "$sign_id" = "-" ] || sign_args+=(--timestamp)
if $developer_id; then
  sign_args+=(--options runtime)
fi
codesign "${sign_args[@]}" "$uv"
if $developer_id; then
  codesign "${sign_args[@]}" --entitlements "$root/scripts/agenda.entitlements" "$agenda"
else
  codesign "${sign_args[@]}" "$agenda"
fi
codesign "${sign_args[@]}" "$mac"
codesign "${sign_args[@]}" "$sparkle/XPCServices/Installer.xpc"
codesign "${sign_args[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
codesign "${sign_args[@]}" "$sparkle/Autoupdate"
codesign "${sign_args[@]}" "$sparkle/Updater.app"
codesign "${sign_args[@]}" "$app/Contents/Frameworks/Sparkle.framework"
if $developer_id; then
  codesign "${sign_args[@]}" --entitlements "$root/scripts/wisp.entitlements" "$app"
else
  codesign "${sign_args[@]}" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
echo "build-release: signed with ${sign_id/#-/ad-hoc}"

rm -rf "$dist"
mkdir -p "$dist"
{ git -C "$root" rev-parse HEAD; [ -z "$(git -C "$root" status --porcelain)" ] && echo clean || echo dirty; } > "$dist/BUILD_COMMIT"
ditto -c -k --keepParent "$app" "$dist/Wisp.zip"

if [ -n "${WISP_NOTARY_PROFILE:-}" ]; then
  $developer_id || { echo "build-release: notarizing needs WISP_SIGN_ID (a Developer ID)" >&2; exit 1; }
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

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
[ -x "$sparkle_bin/generate_appcast" ] || { echo "build-release: $sparkle_bin/generate_appcast missing" >&2; exit 1; }
archives="$build/appcast"
rm -rf "$archives"
mkdir -p "$archives"
cp "$dist/Wisp.dmg" "$archives/Wisp.dmg"
printf '<p>O que mudou nesta versão: <a href="%s/releases/tag/v%s">notas da versão %s no GitHub</a>.</p>\n' \
  "$repo_url" "$version" "$version" > "$archives/Wisp.html"
"$sparkle_bin/generate_appcast" \
  --download-url-prefix "$repo_url/releases/download/v$version/" \
  --full-release-notes-url "$repo_url/releases/tag/v$version" \
  --link "$repo_url" \
  --embed-release-notes \
  "$archives"
cp "$archives/appcast.xml" "$dist/appcast.xml"

echo "build-release: $dist/Wisp.dmg ($(du -h "$dist/Wisp.dmg" | awk '{print $1}')), $dist/Wisp.zip ($(du -h "$dist/Wisp.zip" | awk '{print $1}')), $dist/appcast.xml ($version)"
