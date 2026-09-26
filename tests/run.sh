#!/bin/bash
# Golden tests. Each tests/cases/<name>/input.json is piped through the script
# with a frozen clock (STATUSLINE_NOW), UTC, a throwaway HOME and a fixed width;
# the colour-stripped output must equal <name>/expected.txt.
#   tests/run.sh            run
#   UPDATE=1 tests/run.sh   rewrite the expected files (review the diff!)
# Optional per case: `cards` (session registry cards, blank-line separated; PID
# is replaced by a live pid), `lock` (a run-lock file placed in the case's
# project dir) and `columns` (width, default 100: below the clock threshold).
set -u
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
export TZ=UTC LC_ALL=en_US.UTF-8 STATUSLINE_NOW=1790440000
strip() { sed -e $'s/\033\\[[0-9;]*m//g' -e $'s/\033]8;;[^\a]*\a//g'; }
fail=0; n=0
for dir in cases/*/; do
  name=$(basename "$dir"); n=$((n + 1)); proj=""
  tmp=$(mktemp -d); export HOME="$tmp"; mkdir -p "$HOME/.claude/cache"
  export COLUMNS=$(cat "$dir/columns" 2>/dev/null || echo 100)
  if [ -f "$dir/cards" ]; then
    mkdir -p "$HOME/.claude/cache/statusline_sessions"
    awk -v pid=$$ -v out="$HOME/.claude/cache/statusline_sessions" 'BEGIN{RS=""} {gsub(/PID/, pid); print $0 > (out "/c" NR ".card")}' "$dir/cards"
  fi
  input=$(cat "$dir/input.json")
  if [ -f "$dir/lock" ]; then
    proj="$HOME/project"; mkdir -p "$proj/.claude/run-locks"; cp "$dir/lock" "$proj/.claude/run-locks/run.lock"
    input=$(echo "$input" | jq --arg p "$proj" '.workspace.project_dir=$p | .workspace.current_dir=$p | .cwd=$p')
  fi
  if echo "$input" | jq -e '.tasks' >/dev/null 2>&1; then script="$ROOT/subagent-statusline.sh"; else script="$ROOT/statusline.sh"; fi
  got=$(echo "$input" | bash "$script" 2>&1 | strip)
  [ -n "$proj" ] && got=${got//$proj/<project>}
  rm -r "$tmp"
  if [ -n "${UPDATE:-}" ]; then printf '%s\n' "$got" > "$dir/expected.txt"; echo "updated $name"; continue; fi
  if [ "$got" = "$(cat "$dir/expected.txt" 2>/dev/null)" ]; then echo "ok   $name"
  else echo "FAIL $name"; diff <(cat "$dir/expected.txt" 2>/dev/null) <(printf '%s\n' "$got") | sed 's/^/     /'; fail=1; fi
done
echo "$n cases"; exit $fail
