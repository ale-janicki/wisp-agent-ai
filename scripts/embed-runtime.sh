#!/usr/bin/env bash
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

case "$out" in
  */runtime) ;;
  *) echo "embed-runtime: refusing to replace $out (expected a path ending in /runtime)" >&2; exit 1 ;;
esac
rm -rf "$out"
mkdir -p "$out/src" "$out/bin"
cp "$uv" "$out/bin/uv"

git -C "$root" ls-files -z --cached --others --exclude-standard -- pyproject.toml uv.lock .python-version cli bot harness vault-template \
  | { grep -zvE '^(cli|bot)/tests/' || true; } \
  | (cd "$root" && while IFS= read -r -d '' f; do if [ -f "$f" ]; then printf '%s\0' "$f"; fi; done) \
  | rsync -a --from0 --files-from=- "$root/" "$out/src/"

{
  echo "uv.lock $(shasum -a 256 "$out/src/uv.lock" | awk '{print $1}')"
  echo "uv $(shasum -a 256 "$out/bin/uv" | awk '{print $1}')"
  (cd "$out/src" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
} | shasum -a 256 | awk '{print $1}' > "$out/VERSION"
