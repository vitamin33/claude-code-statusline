#!/bin/bash
# Claude Code status line. Left-aligned lines; the right edge of the row is left
# to Claude Code's own notifications (MCP errors, updates, context-low), except a
# dim clock that only renders when the terminal is wide enough to keep that room.
#   line 1: model/effort · 5h/7d limits · optional health hook · clock
#   line 2: context bar · cost/duration · diff size · cache state
#   line 3: where the work is — branch/dirty, worktree, agent, PR, session
#   line 4: only when something needs attention
input=$(cat)

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; MAGENTA='\033[35m'
DIM='\033[2m'; RESET='\033[0m'
NOW=$(date +%s)

# macOS/Linux shims: file mtime, md5 of stdin, and "format this epoch"
if [ "$(uname)" = "Darwin" ]; then
  mtime() { stat -f %m "$1"; }
  md5q() { md5 -q; }
  date_at() { date -r "$@"; }
else
  mtime() { stat -c %Y "$1"; }
  md5q() { md5sum | cut -d' ' -f1; }
  date_at() { local e=$1; shift; date -d "@$e" "$@"; }
fi

color_for_pct() {
  local p=$1
  if [ "$p" -ge 90 ]; then echo "$RED"
  elif [ "$p" -ge 70 ]; then echo "$YELLOW"
  else echo "$GREEN"; fi
}

# One jq pass. Booleans go through tostring: jq's `//` treats false as null.
eval "$(echo "$input" | jq -r '
  def b: if type == "boolean" then tostring else "" end;
  def n: if . == null then "" else tostring end;
  @sh "MODEL=\(.model.display_name // "?")",
  @sh "MODEL_ID=\(.model.id // "")",
  @sh "SESSION_ID=\(.session_id // "")",
  @sh "CWD=\(.workspace.current_dir // .cwd // "")",
  @sh "HAS_RL=\(if .rate_limits then "1" else "" end)",
  @sh "EFFORT=\(.effort.level // "")",
  @sh "FAST=\(.fast_mode | b)",
  @sh "PCT=\((.context_window.used_percentage // 0) | floor)",
  @sh "TOTAL_IN=\(.context_window.total_input_tokens // 0)",
  @sh "CTX_SIZE=\(.context_window.context_window_size // 200000)",
  @sh "OVER_200K=\(.exceeds_200k_tokens | b)",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DURATION_MS=\(.cost.total_duration_ms // 0)",
  @sh "API_MS=\(.cost.total_api_duration_ms // 0)",
  @sh "CUR_IN=\(.context_window.current_usage.input_tokens // 0)",
  @sh "CUR_CREATE=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
  @sh "CUR_READ=\(.context_window.current_usage.cache_read_input_tokens // 0)",
  @sh "MISSES=\(.prompt_cache.misses // 0)",
  @sh "MISS_CAUSES=\((.prompt_cache.miss_causes // {}) | to_entries | sort_by(-.value) | map(if .value > 1 then "\(.key)×\(.value)" else .key end) | (.[0:2] | join(",")) + (if length > 2 then ",+\(length - 2)" else "" end))",
  @sh "SEVEN_D_RESET=\(.rate_limits.seven_day.resets_at | n)",
  @sh "LINES_ADD=\(.cost.total_lines_added // 0)",
  @sh "LINES_DEL=\(.cost.total_lines_removed // 0)",
  @sh "FIVE_H=\(.rate_limits.five_hour.used_percentage | n)",
  @sh "FIVE_H_RESET=\(.rate_limits.five_hour.resets_at | n)",
  @sh "SEVEN_D=\(.rate_limits.seven_day.used_percentage | n)",
  @sh "HIT_RATIO=\(if .prompt_cache.hit_ratio != null then (.prompt_cache.hit_ratio * 100 | floor | tostring) else "" end)",
  @sh "CACHE_WARM=\(.prompt_cache.warm | b)",
  @sh "CACHE_OBSERVED=\(.prompt_cache.caching_observed | b)",
  @sh "CACHE_EXPIRES=\(.prompt_cache.expires_at | n)",
  @sh "RECACHE_TOKENS=\(.prompt_cache.recache_tokens_if_cold | n)",
  @sh "LAST_MISS_AT=\(.prompt_cache.last_miss_at | n)",
  @sh "LAST_MISS_CAUSE=\((.prompt_cache.last_miss_cause.causes // []) | join(","))",
  @sh "SESSION_NAME=\(.session_name // "")",
  @sh "WORKTREE=\(.worktree.name // .workspace.git_worktree // "")",
  @sh "AGENT=\(.agent.name // "")",
  @sh "PR_NUM=\(.pr.number | n)",
  @sh "PR_URL=\(.pr.url // "")",
  @sh "PR_STATE=\(.pr.review_state // "")",
  @sh "PR_KIND=\(.pr.kind // "")",
  @sh "VIM_MODE=\(.vim.mode // "")",
  @sh "PROJECT_DIR=\(.workspace.project_dir // .cwd // "")"
')"
# jq emits floats for some counters ("12.0"); every integer test below needs ints
for v in PCT TOTAL_IN CTX_SIZE DURATION_MS API_MS CUR_IN CUR_CREATE CUR_READ MISSES SEVEN_D_RESET LINES_ADD LINES_DEL CACHE_EXPIRES RECACHE_TOKENS LAST_MISS_AT FIVE_H_RESET; do
  eval "val=\$$v"; [ -n "$val" ] && eval "$v=\${val%%.*}"
done

# When does usage hit 100% at the current burn rate? $1 used%, $2 reset epoch,
# $3 window length in seconds. The window opened at reset-length. Two noise
# filters: below 20% a few early prompts extrapolate wildly, and running dry
# in the last 5% of the window costs nothing worth a warning.
dry_at() {
  awk -v used="$1" -v reset="$2" -v len="$3" -v now="$NOW" 'BEGIN{
    start = reset - len
    elapsed = now - start
    if (used >= 20 && elapsed > 60) {
      full = start + (elapsed * 100 / used)
      if (full < reset - len / 20) printf "%d", full
    }
  }'
}

# OSC 8 hyperlink: clickable in iTerm2/Kitty/WezTerm/Warp, plain text elsewhere.
link() { printf '\033]8;;%s\a%s\033]8;;\a' "$1" "$2"; }

CACHE_DIR="$HOME/.claude/cache"
mkdir -p "$CACHE_DIR"

# 41h39m instead of 2499m15s
fmt_dur() {
  local s=$(( $1 / 1000 ))
  if [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}

# Base input $/MTok, from platform.claude.com prompt-caching pricing (checked
# 2026-09-22). Empty = unknown model, so no dollar figure rather than a wrong one.
input_price() {
  case "$1" in
    *fable*|*mythos*) echo 10 ;;
    *opus-4-[5-9]*|*opus-5*) echo 5 ;;
    *opus*) echo 15 ;;
    *sonnet-5*) echo 2 ;;
    *sonnet*) echo 3 ;;
    *haiku-4*) echo 1 ;;
    *) echo "" ;;
  esac
}

# Prune per-session logs older than 7 days, at most once an hour.
STAMP="$CACHE_DIR/.statusline_prune"
if [ ! -f "$STAMP" ] || [ $(( NOW - $(mtime "$STAMP") )) -gt 3600 ]; then
  touch "$STAMP"
  find "$CACHE_DIR/statusline_cost" "$CACHE_DIR/statusline_git" -type f -mtime +7 -delete 2>/dev/null
fi

# Rate limits are missing in some sessions. Keep the latest raw input of each
# kind (with / without rate_limits) so the two can be diffed. 0600: it holds paths.
if awk -v c="$COST" 'BEGIN{exit !(c > 0)}'; then
  snap="$CACHE_DIR/statusline_input_$([ -n "$HAS_RL" ] && echo rl || echo no_rl).json"
  ( umask 077; printf '%s' "$input" > "$snap" )
fi

# --- optional health hook ------------------------------------------------------
# Drop an executable at ~/.claude/statusline-health.sh that prints ONE short
# line (ANSI colours allowed) for line 1 — the state of whatever you watch:
# your product's AI calls, a deploy, a queue. It may be slow: it runs detached
# at most every 10 minutes and the status line only reads its last output.
AI_DOT=""
HOOK="$HOME/.claude/statusline-health.sh"
if [ -x "$HOOK" ]; then
  HC="$HOME/.claude/cache/statusline_health.txt"
  LOCK="$HOME/.claude/cache/statusline_health.lock"
  mkdir -p "$HOME/.claude/cache"
  age=999999
  [ -f "$HC" ] && age=$(( NOW - $(mtime "$HC") ))
  # a refresh that died leaves its lock behind; reclaim it after 5 minutes
  if [ -d "$LOCK" ] && [ $(( NOW - $(mtime "$LOCK") )) -gt 300 ]; then rmdir "$LOCK" 2>/dev/null; fi
  if [ "$age" -gt 600 ] && mkdir "$LOCK" 2>/dev/null; then
    # fully detached: must not hold our stdout, or Claude Code waits on it
    ( cd "${PROJECT_DIR:-$HOME}" && "$HOOK" > "$HC.tmp" 2>/dev/null && [ -s "$HC.tmp" ] && mv "$HC.tmp" "$HC"
      rm -f "$HC.tmp"; rmdir "$LOCK" ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null
  fi
  if [ -f "$HC" ]; then
    if [ "$age" -gt 1800 ]; then AI_DOT="${DIM}$(head -n 1 "$HC" | sed $'s/\033\\[[0-9;]*m//g')?${RESET}"   # too old to vouch for
    else AI_DOT="$(head -n 1 "$HC")"; fi
  fi
fi

# --- line 1: model + rate limits + AI health ---------------------------------
LINE1="${CYAN}[$MODEL"
[ -n "$EFFORT" ] && LINE1="$LINE1 ${DIM}·${RESET}${CYAN} $EFFORT"
[ "$FAST" = "true" ] && LINE1="$LINE1 ⚡"
LINE1="${LINE1}]${RESET}"

if [ -n "$FIVE_H" ]; then
  fh=$(printf '%.0f' "$FIVE_H")
  c=$(color_for_pct "$fh")
  LINE1="$LINE1 | ${c}5h ${fh}%${RESET}"
  if [ -n "$FIVE_H_RESET" ]; then
    reset_hhmm=$(date_at "$FIVE_H_RESET" +%H:%M 2>/dev/null)
    [ -n "$reset_hhmm" ] && LINE1="$LINE1${DIM}→${reset_hhmm}${RESET}"

    DRY_AT=$(dry_at "$FIVE_H" "$FIVE_H_RESET" 18000)
    if [ -n "$DRY_AT" ]; then
      dry_hhmm=$(date_at "$DRY_AT" +%H:%M 2>/dev/null)
      if [ -n "$dry_hhmm" ]; then
        mins_out=$(( (DRY_AT - NOW) / 60 ))
        if [ "$mins_out" -lt 60 ]; then
          LINE1="$LINE1 ${RED}⚠dry~${dry_hhmm}${RESET}"
        else
          LINE1="$LINE1 ${DIM}dry~${dry_hhmm}${RESET}"
        fi
      fi
    fi
  fi
fi
# 7d is the limit that locks you out for days. Show it from 30%, and project
# it like the 5h window; the day of the week is what matters at this scale.
if [ -n "$SEVEN_D" ]; then
  sd=$(printf '%.0f' "$SEVEN_D")
  if [ "$sd" -ge 30 ]; then
    c=$(color_for_pct "$sd")
    LINE1="$LINE1 ${c}7d ${sd}%${RESET}"
    if [ -n "$SEVEN_D_RESET" ]; then
      LINE1="$LINE1${DIM}→$(date_at "$SEVEN_D_RESET" +%a 2>/dev/null)${RESET}"
      DRY7=$(dry_at "$SEVEN_D" "$SEVEN_D_RESET" 604800)
      if [ -n "$DRY7" ]; then
        if [ $(( (DRY7 - NOW) / 3600 )) -lt 24 ]; then
          LINE1="$LINE1 ${RED}⚠dry~$(date_at "$DRY7" +%a\ %H:%M)${RESET}"
        else
          LINE1="$LINE1 ${DIM}dry~$(date_at "$DRY7" +%a)${RESET}"
        fi
      fi
    fi
  fi
fi
[ -n "$AI_DOT" ] && LINE1="$LINE1 | $AI_DOT"

# Right side: vim mode + clock, kept clear of the notification area. Claude Code
# sets COLUMNS for us (tput cannot see the terminal from here). Reserve 45 cols
# for notifications; skip entirely on narrow terminals rather than collide.
RIGHT="$(date +%H:%M)"
[ -n "$VIM_MODE" ] && RIGHT="$VIM_MODE $RIGHT"
COLS=${COLUMNS:-0}
if [ "$COLS" -ge 110 ]; then
  visible=$(printf '%b' "$LINE1" | sed -e $'s/\033\\[[0-9;]*m//g' | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
  target=$(( COLS - 45 - ${#RIGHT} ))
  gap=$(( target - visible ))
  if [ "$gap" -ge 3 ]; then
    printf -v PAD "%${gap}s" ""
    LINE1="$LINE1$PAD${DIM}$RIGHT${RESET}"
  fi
fi
printf '%b\n' "$LINE1"

# --- width-aware lines --------------------------------------------------------
# Each line is a list of segments with a priority; when the line would not fit
# COLUMNS, the highest-numbered priorities are dropped first, whole, so nothing
# is cut mid-word by the terminal's own "…".
COLS=${COLUMNS:-0}
vis_width() { printf '%b' "$1" | sed -e $'s/\033\\[[0-9;]*m//g' -e $'s/\033]8;;[^\a]*\a//g' | LC_ALL=en_US.UTF-8 wc -m | tr -d ' '; }
SEG_T=(); SEG_P=(); SEG_S=()
seg() { SEG_S+=("$1"); SEG_P+=("$2"); SEG_T+=("$3"); }   # separator, priority, text
seg_reset() { SEG_T=(); SEG_P=(); SEG_S=(); }
render_segs() {
  local out i first
  while :; do
    out=""; first=1
    for i in "${!SEG_T[@]}"; do
      [ -z "${SEG_T[$i]}" ] && continue
      if [ "$first" = 1 ]; then out="${SEG_T[$i]}"; first=0
      else out="$out${SEG_S[$i]}${SEG_T[$i]}"; fi
    done
    [ "$COLS" -le 0 ] && break
    [ "$(vis_width "$out")" -le "$((COLS - 1))" ] && break
    # drop every segment of the lowest priority still present
    local worst=-1
    for i in "${!SEG_T[@]}"; do
      [ -n "${SEG_T[$i]}" ] && [ "${SEG_P[$i]}" -gt "$worst" ] && worst=${SEG_P[$i]}
    done
    [ "$worst" -le 0 ] && break
    for i in "${!SEG_T[@]}"; do [ "${SEG_P[$i]}" = "$worst" ] && SEG_T[$i]=""; done
  done
  [ -n "$out" ] && printf '%b\n' "$out"
}
BAR_SEP=" ${DIM}|${RESET} "; DOT_SEP=" ${DIM}·${RESET} "

# --- line 2: context + money ------------------------------------------------
# On a 1M window percentages come far too late: at 70% every request already
# re-reads ~700k tokens at long-context rates. Grade big windows by tokens.
if [ "$CTX_SIZE" -gt 200000 ]; then
  if [ "$TOTAL_IN" -ge 500000 ]; then CTX_LEVEL=red
  elif [ "$TOTAL_IN" -ge 300000 ]; then CTX_LEVEL=yellow
  else CTX_LEVEL=green; fi
else
  if [ "$PCT" -ge 85 ]; then CTX_LEVEL=red
  elif [ "$PCT" -ge 70 ]; then CTX_LEVEL=yellow
  else CTX_LEVEL=green; fi
fi
case "$CTX_LEVEL" in red) BAR_COLOR=$RED ;; yellow) BAR_COLOR=$YELLOW ;; *) BAR_COLOR=$GREEN ;; esac
BAR_WIDTH=10
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR=""
[ "$FILLED" -gt 0 ] && printf -v FILL "%${FILLED}s" "" && BAR="${FILL// /█}"
[ "$EMPTY" -gt 0 ] && printf -v PAD "%${EMPTY}s" "" && BAR="${BAR}${PAD// /░}"

TOKENS_LEFT=$((CTX_SIZE - TOTAL_IN))
[ "$TOKENS_LEFT" -lt 0 ] && TOKENS_LEFT=0
TOKENS_LEFT_K=$((TOKENS_LEFT / 1000))

seg_reset
seg "" 0 "${BAR_COLOR}${BAR}${RESET} ${PCT}% ${DIM}${TOKENS_LEFT_K}k left${RESET}"
# the bar reads ~20% here on a 1M window, which hides that requests past 200k
# are slower and bill at the long-context rate
[ "$OVER_200K" = "true" ] && seg " " 1 "${YELLOW}>200k${RESET}"

# Cost: total, what the last request cost, and the spend over the last hour.
# A per-session log of (time, cumulative cost) gets a line whenever cost moves.
if awk -v c="$COST" 'BEGIN{exit !(c > 0)}'; then
  seg "$BAR_SEP" 0 "${YELLOW}$(printf '$%.2f' "$COST")${RESET}"
  if [ -n "$SESSION_ID" ]; then
    CLOG="$CACHE_DIR/statusline_cost/$SESSION_ID.log"
    mkdir -p "$CACHE_DIR/statusline_cost"
    last_logged=$(tail -n 1 "$CLOG" 2>/dev/null | cut -d' ' -f2)
    [ "$last_logged" != "$COST" ] && echo "$NOW $COST" >> "$CLOG"
    # prints: <last request delta> <spend in the last hour, or empty>
    read -r LAST_DELTA HOUR_SPEND <<<"$(awk -v now="$NOW" -v cost="$COST" -v dur="$DURATION_MS" '
      { t[NR] = $1; c[NR] = $2 }
      END {
        d = (NR >= 2) ? c[NR] - c[NR-1] : 0     # one reading = no delta yet
        base = ""
        for (i = NR; i >= 1; i--) if (t[i] <= now - 3600) { base = c[i]; break }
        if (base == "" && dur < 3600000) base = 0      # whole session fits in the hour
        printf "%.2f %s\n", d, (base == "" ? "" : sprintf("%.2f", cost - base))
      }' "$CLOG")"
    # keep the file small: last 2h plus the one entry before that window
    if [ "$(wc -l < "$CLOG")" -gt 400 ]; then
      awk -v cut=$((NOW - 7200)) '{ l[NR] = $0; t[NR] = $1 } END { s = 1; for (i = NR; i >= 1; i--) if (t[i] < cut) { s = i; break } for (i = s; i <= NR; i++) print l[i] }' "$CLOG" > "$CLOG.tmp" && mv "$CLOG.tmp" "$CLOG"
    fi
    awk -v d="$LAST_DELTA" 'BEGIN{exit !(d >= 0.01)}' && seg " " 3 "${DIM}last${RESET} \$${LAST_DELTA}"
    # an idle session reads $0/h, which says nothing worth a slot
    [ -n "$HOUR_SPEND" ] && [ "${HOUR_SPEND%.*}" != "0" ] && seg "$DOT_SEP" 3 "\$${HOUR_SPEND%.*}/h"
  fi
  # wall time mostly measures how long the tab stayed open; api time is the
  # work. Under 2h the two are close enough that one number will do.
  if [ "$API_MS" -gt 0 ] && [ "$DURATION_MS" -ge 7200000 ]; then
    seg " " 2 "${DIM}api $(fmt_dur "$API_MS")/$(fmt_dur "$DURATION_MS")${RESET}"
  else
    seg " " 2 "${DIM}$(fmt_dur "$DURATION_MS")${RESET}"
  fi
fi
if [ "$LINES_ADD" -gt 0 ] || [ "$LINES_DEL" -gt 0 ]; then
  seg "$BAR_SEP" 2 "${GREEN}+${LINES_ADD}${RESET}/${RED}−${LINES_DEL}${RESET}"
fi
render_segs

# --- line 3: where the work is + cache -----------------------------------------
seg_reset
# Branch + uncommitted files (modified ● / untracked +), cached 30s per
# directory. Guards against a concurrent session switching the branch under
# you. No ahead/behind: local refs go stale and a stale count misleads.
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  GDIR="$CACHE_DIR/statusline_git"; mkdir -p "$GDIR"
  GC="$GDIR/$(printf '%s' "$CWD" | md5q)"
  if [ ! -f "$GC" ] || [ $(( NOW - $(mtime "$GC") )) -gt 30 ]; then
    if br=$(git -C "$CWD" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null || git -C "$CWD" rev-parse --short HEAD 2>/dev/null); then
      read -r mod untr <<<"$(git -C "$CWD" --no-optional-locks status --porcelain 2>/dev/null | awk '/^\?\?/ { u++; next } { m++ } END { printf "%d %d", m, u }')"
      echo "$br $mod $untr" > "$GC"
    else
      : > "$GC"
    fi
  fi
  read -r BRANCH MOD UNTR < "$GC"
  if [ -n "$BRANCH" ]; then
    b="${CYAN}${BRANCH}${RESET}"
    [ "${MOD:-0}" -gt 0 ] && b="$b ${YELLOW}●${MOD}${RESET}"
    [ "${UNTR:-0}" -gt 0 ] && b="$b ${DIM}+${UNTR}${RESET}"
    seg "$DOT_SEP" 0 "$b"
  fi
fi
[ -n "$WORKTREE" ] && seg "$DOT_SEP" 0 "${MAGENTA}⎇ ${WORKTREE}${RESET}"
[ -n "$AGENT" ] && seg "$DOT_SEP" 0 "${CYAN}@${AGENT}${RESET}"
if [ -n "$PR_NUM" ]; then
  label="PR #${PR_NUM}"; [ "$PR_KIND" = "mr" ] && label="MR !${PR_NUM}"
  [ -n "$PR_URL" ] && label=$(link "$PR_URL" "$label")
  case "$PR_STATE" in
    approved)          st="${GREEN}✓approved${RESET}" ;;
    changes_requested) st="${RED}✗changes${RESET}" ;;
    draft)             st="${DIM}draft${RESET}" ;;
    pending)           st="${YELLOW}…review${RESET}" ;;
    *)                 st="" ;;
  esac
  seg "$DOT_SEP" 0 "${label}${st:+ $st}"
fi
if [ -n "$SESSION_NAME" ]; then
  sn="$SESSION_NAME"
  [ ${#sn} -gt 40 ] && sn="${sn:0:39}…"
  seg "$DOT_SEP" 2 "${DIM}${sn}${RESET}"
fi

# Cache: the lifetime hit ratio while warm; when cold, what the next message
# costs to re-cache instead (Claude Code already says how many tokens).
if [ "$CACHE_WARM" = "false" ] && [ "$CACHE_OBSERVED" = "true" ] && [ -n "$RECACHE_TOKENS" ] && [ "$RECACHE_TOKENS" -gt 20000 ]; then
  price=$(input_price "$MODEL_ID")
  cold="${YELLOW}cache ❄ cold"
  if [ -n "$price" ]; then
    # 1h TTL writes bill at 2x base input, 5m writes at 1.25x
    mult=2; case "$LAST_MISS_CAUSE" in *5m*) mult=1.25 ;; esac
    cold="$cold · next msg ≈\$$(awk -v t="$RECACHE_TOKENS" -v p="$price" -v m="$mult" 'BEGIN{printf "%.2f", t * p * m / 1000000}')"
  fi
  seg "$BAR_SEP" 0 "${cold}${RESET}"
  [ -n "$LAST_MISS_CAUSE" ] && seg " " 4 "${DIM}(${LAST_MISS_CAUSE})${RESET}"
elif [ -n "$HIT_RATIO" ]; then
  # Lifetime ratio, then what THIS request did: the lifetime number stays at
  # 98% long after the cache went cold. A low per-request figure means the
  # last request paid to rebuild the prefix.
  CACHE_STR="${DIM}cache ${HIT_RATIO}%${RESET}"
  cur_total=$((CUR_IN + CUR_CREATE + CUR_READ))
  if [ "$cur_total" -gt 20000 ]; then
    cur_pct=$((CUR_READ * 100 / cur_total))
    if [ "$cur_pct" -lt 50 ]; then CACHE_STR="$CACHE_STR ${YELLOW}req ${cur_pct}%${RESET}"
    else CACHE_STR="$CACHE_STR ${DIM}req ${cur_pct}%${RESET}"; fi
  fi
  seg "$BAR_SEP" 1 "$CACHE_STR"
  # TTL countdown: how long a pause can last before the next message re-caches
  if [ "$CACHE_WARM" = "true" ] && [ -n "$CACHE_EXPIRES" ]; then
    ttl_m=$(( (CACHE_EXPIRES - NOW) / 60 ))
    if [ "$ttl_m" -ge 0 ]; then
      if [ "$ttl_m" -lt 5 ]; then seg " " 1 "${YELLOW}ttl${ttl_m}m${RESET}"
      else seg " " 2 "${DIM}ttl${ttl_m}m${RESET}"; fi
    fi
  fi
  # a miss is news only briefly; once the next request re-cached it, it's paid
  if [ -n "$LAST_MISS_AT" ] && [ -n "$LAST_MISS_CAUSE" ] && [ $(( NOW - LAST_MISS_AT )) -lt 120 ]; then
    seg " " 3 "${YELLOW}miss:${LAST_MISS_CAUSE}${RESET}"
  fi
  [ "$MISSES" -gt 0 ] && seg "$DOT_SEP" 4 "${DIM}${MISSES} miss (${MISS_CAUSES})${RESET}"
fi
render_segs

# --- line 4: only rendered when something needs attention --------------------
WARN=""
# A model switch rebuilds the whole 1h cache at the new model's write rate;
# at 300k+ that is real money, and it is about to be charged, not past.
if [ "$TOTAL_IN" -ge 300000 ] && [ -n "$LAST_MISS_AT" ] && [ $(( NOW - LAST_MISS_AT )) -lt 600 ] && [[ "$LAST_MISS_CAUSE" == *model_changed* ]]; then
  price=$(input_price "$MODEL_ID")
  est=""; [ -n "$price" ] && est=" ≈\$$(awk -v t="$TOTAL_IN" -v p="$price" 'BEGIN{printf "%.0f", t * p * 2 / 1000000}')"
  WARN="${YELLOW}model switch at $((TOTAL_IN / 1000))k re-caches everything${est} — /clear first if the task allows${RESET}"
fi
if [ -n "$WARN" ]; then :
elif [ -n "$FIVE_H" ] && [ "$(printf '%.0f' "$FIVE_H")" -ge 85 ]; then
  WARN="${RED}⚠ 5h limit $(printf '%.0f' "$FIVE_H")% — work stops at 100%${RESET}"
elif [ "$CTX_LEVEL" = red ]; then
  if [ "$CTX_SIZE" -gt 200000 ]; then
    WARN="${RED}⚠ context $((TOTAL_IN / 1000))k — each request re-reads all of it; /clear at the next task boundary${RESET}"
  else
    WARN="${RED}⚠ context ${PCT}% — /compact now, or /clear if switching task${RESET}"
  fi
elif [ "$CTX_LEVEL" = yellow ]; then
  if [ "$CTX_SIZE" -gt 200000 ]; then
    WARN="${YELLOW}context $((TOTAL_IN / 1000))k — past 300k; plan a /clear at next task boundary${RESET}"
  else
    WARN="${YELLOW}context ${PCT}% — plan a /clear at next task boundary${RESET}"
  fi
fi
[ -n "$WARN" ] && printf '%b\n' "$WARN"

exit 0
