#!/usr/bin/env bash
# Xcode run-script phase: copies the Python sources and the uv binary into the app's Resources/runtime and writes
# runtime/VERSION (sha256 of uv.lock plus the sorted hashes of every copied source file).
# WISP_RUNTIME_OUT overrides the destination so the script can run outside Xcode.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${WISP_RUNTIME_OUT:-}" ]; then
  out="$WISP_RUNTIME_OUT"
else
  out="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/runtime"
fi
uv="$root/app/Resources/runtime/bin/uv"

if [ ! -x "$uv" ]; then
  echo "embed-runtime: $uv is missing; run scripts/fetch-uv.sh first" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out/src" "$out/bin"
cp "$uv" "$out/bin/uv"

# Only tracked files ship, so the VERSION hash never depends on local junk (caches, scratch files).
git -C "$root" ls-files -z -- pyproject.toml uv.lock .python-version cli bot harness vault-template \
  | { grep -zvE '^(cli|bot)/tests/' || true; } \
  | rsync -a --from0 --files-from=- "$root/" "$out/src/"

{
  echo "uv.lock $(shasum -a 256 "$out/src/uv.lock" | awk '{print $1}')"
  (cd "$out/src" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
} | shasum -a 256 | awk '{print $1}' > "$out/VERSION"
