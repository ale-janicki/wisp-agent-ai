#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
web="$root/app/Web/excalidraw"
out="$root/app/Resources/Excalidraw"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ "${1:-}" = "--if-missing" ] && [ -f "$out/index.html" ]; then
  stale="$(find "$web/package-lock.json" "$web/package.json" "$web/vite.config.js" "$web/index.html" "$web/src" -newer "$out/index.html" -print -quit)"
  [ -z "$stale" ] && exit 0
fi

command -v node >/dev/null && command -v npm >/dev/null || {
  echo "build-excalidraw: node and npm are required to build the drawing editor (brew install node)" >&2
  exit 1
}

cd "$web"
npm ci --ignore-scripts --no-audit --no-fund
npm run build

[ -f "$out/index.html" ] || { echo "build-excalidraw: $out/index.html missing after the build" >&2; exit 1; }
policy="$(grep -o 'Content-Security-Policy" content="[^"]*' "$out/index.html" || true)"
case "$policy" in
  *"default-src 'none'"*) ;;
  *) echo "build-excalidraw: index.html has no strict Content-Security-Policy" >&2; exit 1 ;;
esac
if grep -qE "http|\*" <<<"$policy"; then
  echo "build-excalidraw: the Content-Security-Policy names a remote origin or a wildcard" >&2
  exit 1
fi

# Hosts that appear as strings in the built files and are dead at runtime because the policy
# above blocks them: XML namespaces, links the user would have to click (navigation is cancelled),
# features that need a server (collaboration, share links, AI, library, font fallback) and
# embeddable-iframe providers (frame-src 'none').
allowed_hosts="
www.w3.org chevrotain.io langium.org rolldown.rs reactjs.org en.wikipedia.org
github.com gist.github.com mermaid.js.org docs.excalidraw.com discord.gg x.com twitter.com reddit.com
plus.excalidraw.com libraries.excalidraw.com json.excalidraw.com app.excalidraw.com
oss-collab.excalidraw.com oss-ai.excalidraw.com
us-central1-excalidraw-room-persistence.cloudfunctions.net excalidraw-room-persistence.firebaseio.com
esm.sh
www.youtube.com youtube.com player.vimeo.com www.figma.com platform.twitter.com embed.reddit.com giphy.com
"
unexpected=""
while IFS= read -r host; do
  [ -z "$host" ] && continue
  case " $(echo $allowed_hosts) " in
    *" $host "*) ;;
    *) unexpected="$unexpected $host" ;;
  esac
done < <(grep -rIhoE 'https?://[A-Za-z0-9._-]+' "$out" | sed -E 's#^https?://##' | sort -u)
if [ -n "$unexpected" ]; then
  echo "build-excalidraw: built files reference remote hosts that are not on the allowed list:$unexpected" >&2
  exit 1
fi
echo "build-excalidraw: $(du -sh "$out" | awk '{print $1}') in $out"
