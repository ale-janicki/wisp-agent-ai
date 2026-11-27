#!/usr/bin/env bash
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "leak-check: gitleaks is not installed (brew install gitleaks)" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  dirs=("$@")
else
  dirs=(app core cli bot harness vault-template docs scripts win .github)
  for d in "${dirs[@]}"; do
    if [ ! -d "$d" ]; then
      echo "leak-check: scanned folder is missing: $d" >&2
      exit 1
    fi
  done
fi

patterns="$(mktemp)"
stage="$(mktemp -d)"
trap 'rm -rf "$patterns" "$stage"' EXIT
main_checkout="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd -P)"
for f in scripts/leak-patterns.txt scripts/leak-patterns.local.txt \
  "${main_checkout:-.}/scripts/leak-patterns.local.txt" "${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/wisp/leak-patterns.local.txt"; do
  [ -f "$f" ] && grep -vE '^[[:space:]]*(#|$)' "$f" >> "$patterns"
done
sort -u "$patterns" -o "$patterns"

status=0
for d in "${dirs[@]}"; do
  name="$(basename "$d")"
  mkdir -p "$stage/$name"
  rsync -a \
    --exclude='build/' --exclude='dist/' --exclude='node_modules/' --exclude='.venv/' --exclude='.git/' --exclude='DerivedData/' \
    --exclude='.claude/' --exclude='.build/' --exclude='.swiftpm/' --exclude='__pycache__/' --exclude='.pytest_cache/' --exclude='src-tauri/target/' \
    "$d/" "$stage/$name/" 2>/dev/null || { echo "leak-check: cannot read $d" >&2; status=1; }
done
rm -rf "$stage/app/Resources/runtime" "$stage/app/Resources/Excalidraw" "$stage/scripts/leak-patterns.txt" "$stage/scripts/leak-patterns.local.txt"

fixture_homes='/Users/(test|dev|ana|bob|rita|u|x|Maria Silva)([^A-Za-z0-9_]|$)'
while IFS= read -r -d '' file; do
  sed -E -i '' "s#${fixture_homes}#/fixture-home\\2#g" "$file"
done < <(grep -rIl --null -E "$fixture_homes" "$stage")

project="$PWD"
(cd "$stage" && gitleaks dir . --no-banner --redact --exit-code 1) || status=1
(cd "$stage" && uv run --project "$project" python -m wisp.secrets_scan .) || status=1
(cd "$stage" && grep -rInE -i -f "$patterns" .)
[ "$?" -ne 1 ] && status=1

exit "$status"
