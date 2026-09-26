#!/bin/bash
# Per-subagent row: what it is doing - model·effort - tokens (% of its context) - elapsed - status.
# Context % turns yellow at 70 and red at 90. A running agent whose token count
# has not moved for 6 ticks is flagged "stalled?": hung on a tool, or waiting.
# The row is cut to the `columns` the input reports; the description goes first.
input=$(cat)
( umask 077; printf '%s' "$input" > "$HOME/.claude/cache/subagent_input.json" )
# One line per tick, to learn the tick interval the "stalled?" heuristic assumes.
TICKS="$HOME/.claude/cache/subagent_ticks.log"
printf '%s %s\n' "$(date +%s)" "$(echo "$input" | jq '.tasks | length')" >> "$TICKS"
[ "$(wc -l < "$TICKS")" -gt 5000 ] && tail -n 3000 "$TICKS" > "$TICKS.tmp" && mv "$TICKS.tmp" "$TICKS"

echo "$input" | jq -c --argjson now "${STATUSLINE_NOW:-$(date +%s)}" '
  def k: if . >= 1000 then "\(. / 1000 | floor)k" else tostring end;
  def dur:
    if . < 60 then "\(. | floor)s"
    elif . < 3600 then "\(. / 60 | floor)m\(. % 60 | floor)s"
    else "\(. / 3600 | floor)h\((. % 3600) / 60 | floor)m" end;
  # claude-haiku-4-5-20251001 -> haiku 4.5, claude-opus-5-5 -> opus 5.5, claude-sonnet-5 -> sonnet 5
  def short_model:
    (capture("^claude-(?<f>[a-z]+)-(?<a>[0-9]+)(-(?<b>[0-9]+))?") // null) as $m
    | if $m == null then . else $m.f + " " + $m.a + (if $m.b then "." + $m.b else "" end) end;
  (.columns // 0) as $cols |
  .tasks[]? |
  (
    if .contextWindowSize and .tokenCount and .contextWindowSize > 0
    then ((.tokenCount / .contextWindowSize * 100) | floor)
    else null
    end
  ) as $pct |
  # startTime is epoch ms (checked 2026-09-26); keep the seconds fallback
  (
    if (.startTime | type) == "number"
    then ($now - (if .startTime > 1000000000000 then .startTime / 1000 else .startTime end))
    else null
    end
  ) as $elapsed |
  (.status // "") as $status |
  ($status | IN("completed", "failed", "cancelled", "error", "done") | not) as $running |
  (
    (.tokenSamples // []) as $s
    | $running and ($s | length) >= 6 and (($s[-6:] | unique | length) == 1)
  ) as $stalled |
  (if $pct == null then "" elif $pct >= 90 then "\u001b[31m" elif $pct >= 70 then "\u001b[33m" else "" end) as $c |
  (
    " - " + ((.model // "?") | short_model) + (if .effort then "·\(.effort)" else "" end)
    + " - " + (if .tokenCount then (.tokenCount | k) else "-" end)
    + (if $pct != null then " (\($pct)%)" else "" end)
    + (if $elapsed != null and $elapsed >= 0 then " - \($elapsed | dur)" else "" end)
    + " - " + $status
    + (if $stalled then " stalled?" else "" end)
  ) as $tail_plain |
  (.description // .name // .type // "agent") as $desc |
  # cut the description, never the numbers, when the row would not fit
  (if $cols > 0 then ([$cols - ($tail_plain | length), 12] | max) else 1000 end) as $avail |
  (if ($desc | length) > $avail then ($desc[:$avail - 1] + "…") else $desc end) as $desc |
  {
    id: .id,
    content: (
      $desc
      + " - " + ((.model // "?") | short_model) + (if .effort then "·\(.effort)" else "" end)
      + " - " + (if .tokenCount then (.tokenCount | k) else "-" end)
      + (if $pct == null then "" elif $c == "" then " (\($pct)%)" else " \($c)(\($pct)%)\u001b[0m" end)
      + (if $elapsed != null and $elapsed >= 0 then " - \($elapsed | dur)" else "" end)
      + " - " + $status
      + (if $stalled then " \u001b[33mstalled?\u001b[0m" else "" end)
    )
  }
'
