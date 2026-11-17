#!/usr/bin/env bash
# Scans the shipped folders for secrets and personal identifiers. Exit 1 on any hit.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "leak-check: gitleaks is not installed (brew install gitleaks)" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  dirs=("$@")
else
  dirs=(cli bot harness vault-template)
  for d in "${dirs[@]}"; do
    if [ ! -d "$d" ]; then
      echo "leak-check: shipped folder is missing: $d" >&2
      exit 1
    fi
  done
fi

patterns="$(mktemp)"
trap 'rm -f "$patterns"' EXIT
for f in scripts/leak-patterns.txt scripts/leak-patterns.local.txt; do
  [ -f "$f" ] && grep -vE '^[[:space:]]*(#|$)' "$f" >> "$patterns"
done

status=0
for d in "${dirs[@]}"; do
  gitleaks dir "$d" --no-banner --redact --exit-code 1 || status=1
done
uv run python -m wisp.secrets_scan "${dirs[@]}" || status=1
grep -rInE -i -f "$patterns" "${dirs[@]}" \
  --exclude-dir=.venv --exclude-dir=__pycache__ --exclude-dir=.pytest_cache --exclude-dir=.git
[ "$?" -ne 1 ] && status=1

exit "$status"
