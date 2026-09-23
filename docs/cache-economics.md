# What 68,700 Claude Code requests say about the prompt cache

I run Claude Code most of the day, often in sessions that live for days and
grow past 600k tokens. Claude Code keeps every one of its transcripts as JSONL
under `~/.claude/projects/`, with the API's usage block on every assistant
message. That is a complete, per-request record of what the cache did. This
is what 53 days of it showed, and what I changed in my status line because of
it.

**TL;DR**

- The cache hit ratio was **97.5%** before I changed anything. Claude Code's
  caching works; the ratio is the wrong thing to watch.
- The money is in the other 2.5%: **1,119 cache rebuilds cost $4,612 at list
  price — 24% of all spend** ($87 a day).
- **57% of that came from one habit**: leaving a big session idle for over an
  hour, then sending one more message. Average prefix rebuilt: 487k tokens.
- **Switching models mid-session** was the second cause: 350 rebuilds, $1,114.
- **53% of all requests ran above 200k tokens**, where a rebuild costs most.
  84% of rebuild dollars came from prefixes of 300k tokens or more.
- Three days after adding warnings for these, the numbers are inside the
  daily noise. It is too early to claim an effect; the section at the end
  says what would count as one.

## Data

- **Period:** 2026-08-01 to 2026-09-23, 53 days.
- **Volume:** 68,700 API requests across 116 sessions, one record per
  `requestId` (streaming writes several rows per request; the last one wins).
- **Models:** mostly Opus 5 (49k requests), Fable 5 / 5.1 (13k), Sonnet 5 (4k),
  a little Opus 5.5 and Haiku 4.5.
- **Prices:** public list rates from platform.claude.com on 2026-09-22.
  Base input $/MTok: Fable 10, Opus 5, Sonnet 5 2, Haiku 4.5 1. 1h cache
  write = 2× base, 5m write = 1.25×, cache read = 0.1× (0.025× on Fable 5.1).
  Output = 5× base.
- **A "cold rebuild"** is a request whose `cache_creation_input_tokens` is
  50k or more. Normal turns write a few thousand tokens (the new messages);
  a write of 50k+ means the prefix was rebuilt.
- I am on a subscription, so none of these dollars were billed. They are
  what the same traffic costs on the API, which is the number worth
  optimising either way: it is proportional to what the limits measure.

The script that produces every number here is `analyze_cache.py` in this
repo; run it on your own transcripts.

## 1. The hit ratio is already fine

```
period        reqs  sess    hit   cold   cold $  >200k    cost $  write $
before       62577    99  97.5%  1060  $4393.74 32112 $17778.72 $5786.56
```

Daily hit ratio ranged from 91.4% to 99.0%, median about 97.5%. The
tokens-from-cache share is not where the leverage is, and it is the number
most status lines show. A lifetime ratio also hides the current state
entirely: my screenshot from 09-22 showed `cache 99%` on one line and
"cache cold — next message re-processes 598k tokens" on the next. Both were
true.

## 2. Rebuilds are a quarter of the bill

Cache writes were $6,115 of $19,292 total (32%). Most writes are small and
unavoidable — every new message is written once. The avoidable part is the
1,119 rebuilds: $4,612, or 24% of everything.

## 3. Why rebuilds happen

For each rebuild I looked at the request before it in the same session: how
long ago, and on which model.

```
cold rebuild cause                          n  share         $  $ share  avg prefix
idle > 1h (TTL expired)                   403    36%  $2643.96      57%       487k
model switch                              350    31%  $1114.48      24%       248k
context edited (compact/tools/rewrite)    260    23%  $ 490.22      11%       169k
idle 5m-1h                                 78     7%  $ 327.39       7%       335k
session start / resume                     28     3%  $  36.30       1%       129k
```

**Idle over an hour** is the big one. Claude Code uses the 1-hour cache TTL.
Walk away from a 487k-token session for 61 minutes, come back, type "ok
continue", and that message costs $4.87 on Opus (487k × $5/MTok × 2) before it
does anything. I did this 403 times.

**Model switches** surprised me. `/model` mid-session invalidates the whole
prefix because the cache is per model. 350 times, average 248k tokens. The
typical pattern: start on Opus, hit something hard, switch to Fable "just for
this step" — and pay to rebuild the prefix at Fable's $20/MTok write rate,
then again on the way back.

**Context edited** covers compaction, an MCP server reconnecting (the tool
list changes, so the prefix changes), and Claude Code rewriting an earlier
message. Cheaper on average (169k) because compaction tends to happen on
smaller windows.

The "idle 5m-1h" row is small because Claude Code uses the 1-hour TTL, not
the 5-minute one; a pause under an hour normally costs nothing. I have not
traced what those 78 were.

## 4. Size is the multiplier

```
rebuilt prefix size    n         $
<100k                388  $ 207.31
<300k                247  $ 531.18
<600k                259  $1615.68
>=600k               225  $2258.18
```

A third of rebuilds were small and cost almost nothing. The 484 rebuilds of
300k+ tokens cost $3,874 — 84% of rebuild dollars from 43% of events. And
53% of all requests in the period ran above 200k tokens, so most of my
sessions live where a rebuild hurts.

This is also why a percentage-based context warning is wrong on a 1M window.
"70% used" fires at 700k tokens; every request before that already re-read
up to 700k tokens, and every rebuild already cost $7–14.

## 5. What I changed

Each finding maps to one segment of the status line in this repo:

| Finding | Status-line response |
|---|---|
| Idle > 1h is 57% of rebuild $ | `ttl59m` countdown, yellow under 5 min; when cold, `cache ❄ cold · next msg ≈$4.87` — a price, not a token count |
| Model switch is 24% | `model switch at 708k re-caches everything ≈$14 — /clear first if the task allows`, shown for 10 minutes after a switch above 300k |
| Size is the multiplier | Context graded by tokens on 1M windows: yellow at 300k, red at 500k, with "each request re-reads all of it" |
| Lifetime ratio hides current state | `req 98%` — cache share of the *last* request, yellow under 50% |
| No feel for what a turn costs | `last $0.08` and `$6/h` from a per-session cost log |

The idea in every case is the same: show the dollar amount of the thing you
are about to do, at the moment you can still not do it.

## 6. Did it work? Not measurable yet

```
period        reqs  sess    hit  cold   cold $  >200k    cost $  write $
before       62577    99  97.5% 1060  $4393.74 32112 $17778.72 $5786.56
              per day: 1252 reqs, 21.2 cold ($87.87), $355.57 total over 50 days
after         6123    17  98.8%   59  $ 218.61  4148 $ 1513.08 $ 328.86
              per day: 2041 reqs, 19.7 cold ($72.87), $504.36 total over 3 days
```

Three days after the warnings went in: rebuilds per day 21.2 → 19.7, rebuild
dollars per day $88 → $73, hit ratio 97.5 → 98.8%. Every one of these is
inside the day-to-day range of the 50-day baseline (daily rebuild cost ran
from $20 to $201). Three days is not a sample; I have been wrong before by
calling a change inside the noise a result.

What would count: two weeks of `cold $` per day sitting below the baseline's
lower quartile, with the cause table showing the "idle > 1h" row shrinking
specifically — that is the row the warnings target. I will update this file
when there are 14 days. `python3 analyze_cache.py --split 2026-09-21 --causes`
reproduces the comparison.

## Method notes and limits

- The 50k threshold for "rebuild" is a judgment. Lowering it to 20k adds many
  small events and few dollars; raising it to 100k drops a third of events and
  6% of dollars. The dollar conclusions do not move.
- Cause attribution is a heuristic on gap and model. A rebuild after both a
  long gap and a model switch is counted as a model switch. The
  `prompt_cache.miss_causes` field Claude Code now sends to the status line
  is the authoritative version going forward.
- Subagent requests are included. They have small prefixes and rarely rebuild.
- Prices are list; Anthropic changes them. `PRICES` in the script is the
  single place to edit.
- One user, one style of work (long-lived sessions, big contexts, lots of
  MCP tools). Someone who `/clear`s every hour will see a different table —
  run the script and find out.
