#!/bin/bash
# Installs both scripts into ~/.claude and points settings.json at them.
# Re-run to update; the previous scripts and settings are backed up first.
set -e
command -v jq >/dev/null || { echo "jq is required (brew install jq / apt install jq)"; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)
DST="$HOME/.claude"; mkdir -p "$DST/cache"
stamp=$(date +%Y%m%d%H%M%S)
for f in statusline.sh subagent-statusline.sh; do
  [ -f "$DST/$f" ] && cp "$DST/$f" "$DST/$f.bak-$stamp"
  cp "$SRC/$f" "$DST/$f"; chmod +x "$DST/$f"
done
S="$DST/settings.json"
[ -f "$S" ] || echo '{}' > "$S"
cp "$S" "$S.bak-$stamp"
jq '.statusLine = {type:"command", command:"~/.claude/statusline.sh", refreshInterval:60}
  | .subagentStatusLine = {type:"command", command:"~/.claude/subagent-statusline.sh"}' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
echo "installed. Backups: *.bak-$stamp. Open a new Claude Code session, or wait for the next refresh."
echo "optional: put an executable at ~/.claude/statusline-health.sh (see README)."
