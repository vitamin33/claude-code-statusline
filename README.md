# claude-code-statusline

A status line for [Claude Code](https://code.claude.com) that shows what a
long session actually costs — and warns *before* the expensive thing happens,
not after.

```
[Fable 5.1 · high] | 5h 22%→22:00 dry~20:31 | ai●                        17:45
█░░░░░░░░░ 16% 836k left | $294.66 last $0.08 · $6/h api 3h58m/3d2h | +3177/−103
work ●92 +85 · Image generation rendering analysis | cache 98% req 98% ttl59m
```

![warm session](docs/img/warm.png)

When the prompt cache has expired, the cache segment turns into a price:

![cache cold](docs/img/cache-cold.png)

And on a 1M-token window, a warning by token count rather than by percentage
(70% of 1M is already 700k tokens re-read on every request):

![long context](docs/img/long-context.png)

## Why

Over 53 days and 68,700 requests of my own transcripts, the prompt-cache hit
ratio was already **97.5%** — Claude Code's caching works. What cost money was
the other 2.5%: **1,119 cache rebuilds, $4,612 at list price, 24% of all spend.**
57% of that came from one cause: leaving a 400k+ session idle for over an hour,
then sending one more message. Another 24% came from switching models mid-session.

Both are avoidable if you can see them coming. Full numbers and method:
[docs/cache-economics.md](docs/cache-economics.md).

## What each number means

**Line 1 — model, limits, health, clock**

| Segment | Meaning |
|---|---|
| `[Fable 5.1 · high ⚡]` | model, effort level, ⚡ = fast mode |
| `5h 22%→22:00` | 5-hour rate limit used, and when it resets |
| `dry~20:31` | at the current burn rate you hit 100% at 20:31 — red if within the hour. Hidden below 20% used, or when it lands in the last 15 min before reset |
| `7d 45%→Tue dry~Thu` | weekly limit, shown from 30%; same projection, in days |
| `ai●` | output of your optional health hook (see below) |
| `17:45` | clock, right-aligned, kept 45 columns clear of Claude Code's own notifications |

**Line 2 — context and money**

| Segment | Meaning |
|---|---|
| `█░░░░░░░░░ 16% 836k left` | context used; bar colour by tokens on a 1M window (yellow 300k, red 500k), by % on 200k |
| `>200k` | past 200k tokens: slower requests, long-context pricing |
| `$294.66` | session cost at API list price (what the same traffic would cost without a subscription) |
| `last $0.08` | cost of the last request — what one message costs at *this* context size |
| `$6/h` | spend over the last hour of wall time; hidden when idle |
| `api 3h58m/3d2h` | time the model actually worked / time the session has existed |
| `+3177/−103` | lines added / removed this session |

**Line 3 — where the work is, and the cache**

| Segment | Meaning |
|---|---|
| `work ●92 +85` | branch, modified files, untracked files (cached 30s). Catches another session switching the branch under you |
| `⎇ name` / `@agent` / `PR #12 ✓approved` | worktree, agent, PR with review state (clickable link) — only when set |
| `cache 98%` | lifetime share of input tokens served from cache |
| `req 98%` | the same for the **last request** — turns yellow under 50%, meaning that request paid to rebuild the prefix |
| `ttl59m` | how long a pause can last before the next message re-caches; yellow under 5 min |
| `2 miss (ttl_expired_1h×2,model_changed)` | cumulative misses and why |
| `cache ❄ cold · next msg ≈$6.59` | cache expired; what the next message will cost to rebuild, at the model's 1h write rate |

**Line 4 — only when something needs attention**

- `⚠ 5h limit 87% — work stops at 100%`
- `⚠ context 657k — each request re-reads all of it; /clear at the next task boundary`
- `model switch at 708k re-caches everything ≈$14 — /clear first if the task allows`

Lines are trimmed to the terminal width by priority: the least important
segments (miss causes, `last`, `$/h`, session name) drop first, whole. Branch,
total cost and a cold cache are never dropped.

**Subagent rows** (`subagent-statusline.sh`): `researcher - haiku·low - 154k (77%) - 12m34s - running`,
with the context % yellow at 70 and red at 90.

## Install

Requires `bash`, `jq`, and Claude Code ≥ 2.1. macOS and Linux.

```bash
git clone https://github.com/vitamin33/claude-code-statusline
cd claude-code-statusline && ./install.sh
```

`install.sh` copies both scripts to `~/.claude/`, backs up the previous ones
and your `settings.json`, and sets:

```json
"statusLine":         { "type": "command", "command": "~/.claude/statusline.sh", "refreshInterval": 60 },
"subagentStatusLine": { "type": "command", "command": "~/.claude/subagent-statusline.sh" }
```

The script runs in ~50 ms. It writes only under `~/.claude/cache/`
(per-session cost logs, a 30-second git cache, one raw input snapshot for
debugging), and prunes anything older than 7 days.

## Health hook (optional)

Put an executable at `~/.claude/statusline-health.sh` that prints **one short
line** (ANSI colours allowed). It can be slow — it runs detached at most every
10 minutes, and the status line only reads its last output. Output older than
30 minutes is shown dimmed with a `?`.

I use it to watch my product's AI calls in production (all calls of a feature
failing in the last hour = Anthropic credit exhausted, which is an HTTP 400):

```bash
#!/bin/bash
cd ~/src/myproduct && out=$(python ops/ai_health.py --hours 1 --json) || exit 1
echo "$out" | jq -r 'if (.dark_features|length) > 0 then "\u001b[31mai✗\u001b[0m" else "\u001b[32mai●\u001b[0m" end'
```

A deploy status, a queue depth, or a CI run work the same way.

## Measure your own cache

```bash
python3 analyze_cache.py                                    # last 60 days, per day
python3 analyze_cache.py --since 2026-08-01 --causes        # why each rebuild happened
python3 analyze_cache.py --split 2026-09-21                 # before / after a change
```

It reads `~/.claude/projects/**/*.jsonl`, takes one usage record per request,
and prices it at the public list rates (edit `PRICES` when they change). See
[docs/cache-economics.md](docs/cache-economics.md) for what the columns mean
and what mine showed.

## Fields used

Everything comes from the JSON Claude Code pipes to the status line:
`model`, `effort`, `fast_mode`, `context_window` (incl. `current_usage`),
`exceeds_200k_tokens`, `cost`, `rate_limits`, `prompt_cache` (`warm`,
`expires_at`, `hit_ratio`, `misses`, `miss_causes`, `last_miss_cause`,
`recache_tokens_if_cold`), `worktree`, `agent`, `pr`, `session_name`, `vim`.
Documented at <https://code.claude.com/docs/en/statusline>.

## License

MIT
