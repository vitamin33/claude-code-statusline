#!/bin/bash
# Per-subagent row: name - model·effort - tokens in k (% of its context) - elapsed - status.
# Context % turns yellow at 70 and red at 90, so a subagent about to compact or
# a stuck one burning tokens stands out from the rest.
input=$(cat)
# startTime's unit is undocumented; keep one raw input so it can be checked.
( umask 077; printf '%s' "$input" > "$HOME/.claude/cache/subagent_input.json" )

echo "$input" | jq -c --argjson now "$(date +%s)" '
  def k: if . >= 1000 then "\(. / 1000 | floor)k" else tostring end;
  def dur:
    if . < 60 then "\(. | floor)s"
    elif . < 3600 then "\(. / 60 | floor)m\(. % 60 | floor)s"
    else "\(. / 3600 | floor)h\((. % 3600) / 60 | floor)m" end;
  .tasks[]? |
  (
    if .contextWindowSize and .tokenCount and .contextWindowSize > 0
    then ((.tokenCount / .contextWindowSize * 100) | floor)
    else null
    end
  ) as $pct |
  # startTime unit is not documented; epoch ms is > 1e12, epoch s is not
  (
    if (.startTime | type) == "number"
    then ($now - (if .startTime > 1000000000000 then .startTime / 1000 else .startTime end))
    else null
    end
  ) as $elapsed |
  (if $pct == null then "" elif $pct >= 90 then "\u001b[31m" elif $pct >= 70 then "\u001b[33m" else "" end) as $c |
  {
    id: .id,
    content: (
      (.name // .type // "agent")
      + " - " + (.model // "?") + (if .effort then "·\(.effort)" else "" end)
      + " - " + (if .tokenCount then (.tokenCount | k) else "-" end)
      + (if $pct != null then " \($c)(\($pct)%)\u001b[0m" else "" end)
      + (if $elapsed != null and $elapsed >= 0 then " - \($elapsed | dur)" else "" end)
      + " - " + (.status // "")
    )
  }
'
