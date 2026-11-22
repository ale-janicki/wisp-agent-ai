#!/usr/bin/env bash
set -euo pipefail

commit="9302bb553e70512888a9053fd7aa52e23fa30d1e"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/wisp-ax-probe.XXXXXX")"
trap 'rm -rf "$work"' EXIT

git clone --quiet https://github.com/openai/codex "$work/codex"
git -C "$work/codex" checkout --quiet "$commit"
src="$work/codex/codex-rs/sandboxing/src"
cc -Wno-deprecated-declarations -framework ApplicationServices -o "$work/probe" "$here/probe.c"

common="$(cat "$src/seatbelt_preferences_policy.sbpl")
$(cat "$src/seatbelt_read_only_platform_defaults.sbpl")
(allow file-read* (subpath \"/Applications\"))
(deny mach-lookup (xpc-service-name-prefix \"\"))
(deny system-fcntl (fcntl-command 80 110))"
base="$(cat "$src/seatbelt_base_policy.sbpl")"
printf '%s\n(allow file-read*)\n(allow file-write* (subpath "/private/tmp") (subpath "/private/var/tmp"))\n%s\n' "$base" "$common" > "$work/readonly.sb"
printf '%s\n(allow file-read*)\n(allow file-write* (subpath "/private/tmp") (subpath "/private/var/tmp") (subpath (param "WRITABLE_ROOT_0")))\n%s\n' "$base" "$common" > "$work/workspace.sb"
mkdir "$work/root"

names=(com.apple.tccd com.apple.dock.server com.apple.windowserver.active com.apple.coreservices.appleevents com.apple.cfprefsd.daemon com.apple.system.opendirectoryd.libinfo com.apple.nonexistent.wisp.probe)

echo "== readonly"
sandbox-exec -f "$work/readonly.sb" "$work/probe" "${names[@]}" | grep -v '^AXIsProcessTrusted'
echo "== workspace"
sandbox-exec -D "WRITABLE_ROOT_0=$work/root" -f "$work/workspace.sb" "$work/probe" "${names[@]}" | grep -v '^AXIsProcessTrusted'
