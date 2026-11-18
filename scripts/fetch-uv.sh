#!/usr/bin/env bash
# Downloads the pinned official uv release for both macOS architectures, checks the pinned sha256 of each
# archive, and writes one universal binary to app/Resources/runtime/bin/uv. Refuses on any hash mismatch.
set -euo pipefail

UV_VERSION="0.13.5"
SHA_AARCH64="743f85035a1996ecb350659e01cd9faea9709829be09b1b4b03c73eaf3c9cd73"
SHA_X86_64="b0f52b0e3945b4107d89024ea38e625683011fbfc05a0d98f9fa2d6dcee28c66"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${WISP_UV_DEST:-$root/app/Resources/runtime/bin}"
base="https://github.com/astral-sh/uv/releases/download/$UV_VERSION"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() {
  local arch="$1" expected="$2"
  local name="uv-$arch-apple-darwin"
  mkdir -p "$work/$arch"
  curl --fail --silent --show-error --location --output "$work/$arch/$name.tar.gz" "$base/$name.tar.gz"
  local actual
  actual="$(shasum -a 256 "$work/$arch/$name.tar.gz" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "fetch-uv: sha256 mismatch for $name.tar.gz (expected $expected, got $actual)" >&2
    exit 1
  fi
  tar -xzf "$work/$arch/$name.tar.gz" -C "$work/$arch"
  [ -f "$work/$arch/$name/uv" ] || { echo "fetch-uv: uv not found inside $name.tar.gz" >&2; exit 1; }
}

fetch aarch64 "$SHA_AARCH64"
fetch x86_64 "$SHA_X86_64"

mkdir -p "$dest"
lipo -create "$work/aarch64/uv-aarch64-apple-darwin/uv" "$work/x86_64/uv-x86_64-apple-darwin/uv" -output "$dest/uv"
chmod 755 "$dest/uv"
echo "fetch-uv: uv $UV_VERSION -> $dest/uv"
