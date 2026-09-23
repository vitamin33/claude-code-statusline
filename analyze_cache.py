#!/usr/bin/env python3
"""Cache economics from your own Claude Code transcripts.

Reads every ~/.claude/projects/**/*.jsonl, takes one usage record per API
request, and prints per-day and per-period figures: requests, cache hit ratio,
cold rebuilds (a request that wrote a big prefix instead of reading it), and
what those rebuilds cost at list price.

    python3 analyze_cache.py                 # last 60 days, daily table
    python3 analyze_cache.py --since 2026-08-01 --split 2026-09-21
    python3 analyze_cache.py --json > usage.json

Prices are USD per MTok from platform.claude.com (checked 2026-09-22). A
subscription is not billed per token; the dollars are what the same traffic
would cost on the API, which is the number worth optimising either way.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

# base input $/MTok, and the cache-read multiplier (Fable/Mythos 5.1 read at 0.025x)
PRICES = [
    ("fable-5-1", 10.0, 0.025),
    ("mythos-5-1", 10.0, 0.025),
    ("fable", 10.0, 0.1),
    ("mythos", 10.0, 0.1),
    ("opus-4-5", 5.0, 0.1),
    ("opus-4-6", 5.0, 0.1),
    ("opus-4-7", 5.0, 0.1),
    ("opus-4-8", 5.0, 0.1),
    ("opus-5", 5.0, 0.1),
    ("opus", 15.0, 0.1),
    ("sonnet-5", 2.0, 0.1),
    ("sonnet", 3.0, 0.1),
    ("haiku-4", 1.0, 0.1),
    ("haiku", 0.8, 0.1),
]
OUTPUT_MULT = 5.0  # output is 5x base input on every current model
WRITE_5M, WRITE_1H = 1.25, 2.0
COLD_WRITE = 50_000  # a write this big is a prefix rebuild, not new context


def price(model: str) -> tuple[float, float]:
    m = model or ""
    for key, base, read_mult in PRICES:
        if key in m:
            return base, read_mult
    return 0.0, 0.1


def cost(u: dict, model: str) -> tuple[float, float]:
    """(total $, cache-write $) for one request."""
    base, read_mult = price(model)
    cc = u.get("cache_creation") or {}
    w5 = cc.get("ephemeral_5m_input_tokens", 0)
    w1 = cc.get("ephemeral_1h_input_tokens", 0)
    if not cc:
        w1 = u.get("cache_creation_input_tokens", 0)
    write = (w5 * WRITE_5M + w1 * WRITE_1H) * base / 1e6
    total = write
    total += u.get("input_tokens", 0) * base / 1e6
    total += u.get("cache_read_input_tokens", 0) * base * read_mult / 1e6
    total += u.get("output_tokens", 0) * base * OUTPUT_MULT / 1e6
    return total, write


def load(root: Path, since: date):
    """One record per requestId (streaming writes several rows per request)."""
    by_req: dict[str, dict] = {}
    for f in root.glob("**/*.jsonl"):
        try:
            if datetime.fromtimestamp(f.stat().st_mtime).date() < since:
                continue
            with f.open() as fh:
                for line in fh:
                    if '"usage"' not in line:
                        continue
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if row.get("type") != "assistant":
                        continue
                    msg = row.get("message") or {}
                    u = msg.get("usage")
                    if not u:
                        continue
                    rid = row.get("requestId") or f"{f.name}:{row.get('uuid')}"
                    ts = row.get("timestamp")
                    if not ts:
                        continue
                    by_req[rid] = {
                        "ts": ts,
                        "model": msg.get("model", ""),
                        "u": u,
                        "session": row.get("sessionId", ""),
                        "agent": bool(row.get("isSidechain")),
                    }
        except OSError:
            continue
    out = []
    for r in by_req.values():
        d = datetime.fromisoformat(r["ts"].replace("Z", "+00:00")).astimezone(
            timezone.utc
        )
        if d.date() < since:
            continue
        r["day"] = d.date()
        out.append(r)
    out.sort(key=lambda r: r["ts"])
    return out


def summarize(rows):
    s = defaultdict(float)
    sessions = set()
    for r in rows:
        u = r["u"]
        inp = u.get("input_tokens", 0)
        cre = u.get("cache_creation_input_tokens", 0)
        rd = u.get("cache_read_input_tokens", 0)
        total, write = cost(u, r["model"])
        s["requests"] += 1
        s["input"] += inp
        s["write"] += cre
        s["read"] += rd
        s["output"] += u.get("output_tokens", 0)
        s["cost"] += total
        s["write_cost"] += write
        if cre >= COLD_WRITE:
            s["cold"] += 1
            s["cold_cost"] += write
        if inp + cre + rd > 200_000:
            s["long"] += 1
        sessions.add(r["session"])
    s["sessions"] = len(sessions)
    denom = s["input"] + s["write"] + s["read"]
    s["hit"] = s["read"] / denom if denom else 0.0
    return s


def causes(rows):
    """Why each cold rebuild happened, judged from the request before it in the
    same session: a gap over the TTL, a model switch, or neither (context was
    edited: compaction, tool list changed, a message rewritten)."""
    prev: dict[str, dict] = {}
    buckets = defaultdict(lambda: [0, 0.0, 0])  # n, $, prefix tokens
    by_model = defaultdict(lambda: [0, 0.0])
    by_size = defaultdict(lambda: [0, 0.0])
    for r in rows:
        u = r["u"]
        total, write = cost(u, r["model"])
        by_model[r["model"]][0] += 1
        by_model[r["model"]][1] += total
        cre = u.get("cache_creation_input_tokens", 0)
        p = prev.get(r["session"])
        if cre >= COLD_WRITE:
            if p is None:
                why = "session start / resume"
            else:
                gap = (
                    datetime.fromisoformat(r["ts"].replace("Z", "+00:00"))
                    - datetime.fromisoformat(p["ts"].replace("Z", "+00:00"))
                ).total_seconds()
                if p["model"] != r["model"]:
                    why = "model switch"
                elif gap > 3600:
                    why = "idle > 1h (TTL expired)"
                elif gap > 300:
                    why = "idle 5m-1h"
                else:
                    why = "context edited (compact/tools/rewrite)"
            b = buckets[why]
            b[0] += 1
            b[1] += write
            b[2] += cre
            size = (
                "<100k"
                if cre < 100_000
                else "<300k"
                if cre < 300_000
                else "<600k"
                if cre < 600_000
                else ">=600k"
            )
            by_size[size][0] += 1
            by_size[size][1] += write
        prev[r["session"]] = r
    n_all = sum(b[0] for b in buckets.values())
    d_all = sum(b[1] for b in buckets.values())
    print()
    print(
        f"{'cold rebuild cause':<40} {'n':>5} {'share':>6} {'$':>9} {'$ share':>8} {'avg prefix':>11}"
    )
    for why, (n, d, tok) in sorted(buckets.items(), key=lambda kv: -kv[1][1]):
        print(
            f"{why:<40} {n:>5} {n / n_all * 100:>5.0f}% ${d:>8.2f} {d / d_all * 100:>7.0f}% {tok / n / 1000:>9.0f}k"
        )
    print()
    print(f"{'rebuilt prefix size':<12} {'n':>5} {'$':>9}")
    for size in ("<100k", "<300k", "<600k", ">=600k"):
        n, d = by_size[size]
        print(f"{size:<12} {n:>5} ${d:>8.2f}")
    print()
    print(f"{'model':<28} {'reqs':>6} {'cost $':>9}")
    for m, (n, d) in sorted(by_model.items(), key=lambda kv: -kv[1][1]):
        print(f"{m or '?':<28} {n:>6} ${d:>8.2f}")


def fmt_row(label, s):
    return (
        f"{label:<12} {int(s['requests']):>6} {int(s['sessions']):>5} "
        f"{s['hit'] * 100:>5.1f}% {int(s['cold']):>5} ${s['cold_cost']:>7.2f} "
        f"{int(s['long']):>5} ${s['cost']:>8.2f} ${s['write_cost']:>7.2f}"
    )


HEADER = (
    f"{'day':<12} {'reqs':>6} {'sess':>5} {'hit':>6} {'cold':>5} {'cold $':>8} "
    f"{'>200k':>5} {'cost $':>9} {'write $':>8}"
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(Path.home() / ".claude" / "projects"))
    ap.add_argument("--since", default=str(date.today() - timedelta(days=60)))
    ap.add_argument("--split", help="YYYY-MM-DD: compare before vs from this day")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--causes", action="store_true", help="why each cold rebuild happened")
    a = ap.parse_args()

    since = date.fromisoformat(a.since)
    rows = load(Path(a.root), since)
    if not rows:
        sys.exit("no usage records found")

    days = defaultdict(list)
    for r in rows:
        days[r["day"]].append(r)

    if a.json:
        print(
            json.dumps(
                {str(d): summarize(v) for d, v in sorted(days.items())}, indent=1
            )
        )
        return

    print(HEADER)
    for d, v in sorted(days.items()):
        print(fmt_row(str(d), summarize(v)))
    print()
    print("cold = requests that wrote a >=50k-token prefix (a cache rebuild);")
    print("cold $ = what those writes cost; hit = cache_read / all input tokens.")

    if a.causes:
        causes(rows)

    if a.split:
        cut = date.fromisoformat(a.split)
        before = [r for r in rows if r["day"] < cut]
        after = [r for r in rows if r["day"] >= cut]
        print()
        print(HEADER.replace("day", "period"))
        for label, part in (("before", before), ("after", after)):
            if not part:
                continue
            s = summarize(part)
            ndays = len({r["day"] for r in part})
            print(fmt_row(label, s))
            print(
                f"{'':<12} per day: {s['requests'] / ndays:.0f} reqs, "
                f"{s['cold'] / ndays:.1f} cold (${s['cold_cost'] / ndays:.2f}), "
                f"${s['cost'] / ndays:.2f} total over {ndays} days"
            )


if __name__ == "__main__":
    main()
