#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived="$root/build/art"

[ -x "$root/app/Resources/runtime/bin/uv" ] || "$root/scripts/fetch-uv.sh"
(cd "$root/app" && xcodegen generate)
xcodebuild -project "$root/app/Wisp.xcodeproj" -scheme Wisp -configuration Debug \
  -derivedDataPath "$derived" -skipPackagePluginValidation build -quiet

"$derived/Build/Products/Debug/Wisp.app/Contents/MacOS/Wisp" \
  -WispRenderIcon "$root/app/Resources/Assets.xcassets/AppIcon.appiconset" \
  -WispRenderDMG "$root/scripts/dmg"
