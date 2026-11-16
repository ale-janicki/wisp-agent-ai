#!/bin/bash
# Process-mechanics stand-in only. Not a model of the real CLI.
echo '{"type":"system","subtype":"init","session_id":"fake-1","model":"fake","apiKeySource":"none"}'
if [ "$FAKE_CRASH" = "1" ]; then
  exit 3
fi
reply() {
  local content
  content=$(printf '%s' "$1" | sed 's/.*"content":"\([^"]*\)".*/\1/')
  echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"$content\",\"session_id\":\"fake-1\",\"num_turns\":1}"
}
if [ "$FAKE_WAIT2" = "1" ]; then
  # Busy mode: hold both answers until two lines have arrived.
  IFS= read -r first || exit 0
  IFS= read -r second || exit 0
  reply "$first"
  reply "$second"
fi
while IFS= read -r line; do
  reply "$line"
done
