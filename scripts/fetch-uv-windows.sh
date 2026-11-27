#!/usr/bin/env bash
set -euo pipefail

UV_VERSION="0.13.5"
SHA_X86_64_WINDOWS="a38b8d1902b7cfbc76b423ba1bb456f623f42064cdc72628b6075b89afd1019a"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${WISP_UV_DEST:-$root/app/Resources/runtime/bin}"
base="https://github.com/astral-sh/uv/releases/download/$UV_VERSION"
name="uv-x86_64-pc-windows-msvc"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

py="$(command -v python3 || command -v python || true)"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    "$py" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  fi
}

extract_zip() {
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$1" -d "$2"
  else
    "$py" -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
  fi
}

if [ -z "$py" ] && { ! command -v shasum >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; }; then
  echo "fetch-uv-windows: need python (or shasum and unzip)" >&2
  exit 1
fi

curl --fail --silent --show-error --location --output "$work/$name.zip" "$base/$name.zip"
actual="$(sha256_of "$work/$name.zip")"
if [ "$actual" != "$SHA_X86_64_WINDOWS" ]; then
  echo "fetch-uv-windows: sha256 mismatch for $name.zip (expected $SHA_X86_64_WINDOWS, got $actual)" >&2
  exit 1
fi
mkdir -p "$work/x"
extract_zip "$work/$name.zip" "$work/x"
[ -f "$work/x/uv.exe" ] || { echo "fetch-uv-windows: uv.exe not found inside $name.zip" >&2; exit 1; }

mkdir -p "$dest"
cp "$work/x/uv.exe" "$dest/uv.exe"
echo "fetch-uv-windows: sha256 ok ($actual); uv $UV_VERSION -> $dest/uv.exe"
