#!/usr/bin/env python3
"""claude-usage-digest.py — daily/period отчёт по claude usage.

Читает SQLite от collector'а, считает токены и $-эквивалент по моделям и печатает
короткий текст. Ставится установщиком; никуда не отправляет (ежедневной сводки владельцу нет).

Параметры:
    --since-hours N    период отчёта (default 24)
    --no-send          принимается для совместимости, печать всё равно единственный вывод
"""

from __future__ import annotations

import argparse
import logging
import os
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import guard_conf  # noqa: E402

USAGE_DIR = Path(os.environ.get("NEUROOTDEL_USAGE_DIR")
                 or guard_conf.load().agent_home / ".claude-lab" / "shared" / "state" / "claude-usage")
LOG_FILE = USAGE_DIR / "digest.log"
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("usage-digest")

DB_PATH = USAGE_DIR / "usage.db"

# Pricing per 1M tokens, USD. Источник: anthropic.com на 2026-05-24.
# Используется как API-эквивалент: при подписке платёж фиксирован, числа показывают,
# сколько эта работа стоила бы при покупке по API.
PRICING = {
    "claude-opus-4-7":   {"input": 15.0, "output": 75.0, "cache_read": 1.50,
                          "cache_write_5m": 18.75, "cache_write_1h": 30.0},
    "claude-sonnet-4-6": {"input": 3.0,  "output": 15.0, "cache_read": 0.30,
                          "cache_write_5m": 3.75,  "cache_write_1h": 6.0},
    "claude-haiku-4-5":  {"input": 1.0,  "output": 5.0,  "cache_read": 0.10,
                          "cache_write_5m": 1.25,  "cache_write_1h": 2.0},
}
# Fallback для незнакомых моделей — берём Sonnet baseline
FALLBACK_PRICING = PRICING["claude-sonnet-4-6"]


def get_pricing(model: str) -> dict:
    if not model:
        return FALLBACK_PRICING
    # Прямое совпадение
    if model in PRICING:
        return PRICING[model]
    # Загрубление по подстроке (на случай суффиксов типа -20251001)
    for key in PRICING:
        short = key.replace("claude-", "")
        if short in model or key in model:
            return PRICING[key]
    if "opus" in model:
        return PRICING["claude-opus-4-7"]
    if "haiku" in model:
        return PRICING["claude-haiku-4-5"]
    return FALLBACK_PRICING


def calc_cost(row: dict, model: str) -> float:
    p = get_pricing(model)
    return (
        row["input_tokens"]         * p["input"]          / 1_000_000
        + row["output_tokens"]        * p["output"]         / 1_000_000
        + row["cache_read_tokens"]    * p["cache_read"]     / 1_000_000
        + row["cache_write_5m_tokens"] * p["cache_write_5m"] / 1_000_000
        + row["cache_write_1h_tokens"] * p["cache_write_1h"] / 1_000_000
    )


def fetch_period(con: sqlite3.Connection, since: datetime) -> list[dict]:
    since_iso = since.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    cur = con.execute(
        """
        SELECT agent, model,
               COUNT(*) AS calls,
               SUM(input_tokens) AS input_tokens,
               SUM(output_tokens) AS output_tokens,
               SUM(cache_read_tokens) AS cache_read_tokens,
               SUM(cache_write_5m_tokens) AS cache_write_5m_tokens,
               SUM(cache_write_1h_tokens) AS cache_write_1h_tokens
        FROM calls
        WHERE ts_utc >= ?
        GROUP BY agent, model
        ORDER BY agent, model
        """,
        (since_iso,),
    )
    rows = []
    for r in cur.fetchall():
        rows.append({
            "agent": r[0],
            "model": r[1] or "unknown",
            "calls": r[2] or 0,
            "input_tokens": r[3] or 0,
            "output_tokens": r[4] or 0,
            "cache_read_tokens": r[5] or 0,
            "cache_write_5m_tokens": r[6] or 0,
            "cache_write_1h_tokens": r[7] or 0,
        })
    return rows


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.0f}k"
    return str(n)


def fmt_money(usd: float) -> str:
    if usd >= 1:
        return f"${usd:.2f}"
    if usd >= 0.01:
        return f"${usd:.3f}"
    return f"${usd:.4f}"


def short_model(m: str) -> str:
    if not m:
        return "?"
    return (
        m.replace("claude-opus-4-7", "opus47")
         .replace("claude-sonnet-4-6", "sonnet46")
         .replace("claude-haiku-4-5", "haiku45")
    )


def build_report(rows: list[dict], hours: int) -> str:
    if not rows:
        return f"Usage за {hours}h: ноль вызовов."

    by_agent = defaultdict(list)
    for r in rows:
        by_agent[r["agent"]].append(r)

    total_calls = sum(r["calls"] for r in rows)
    total_in    = sum(r["input_tokens"] for r in rows)
    total_out   = sum(r["output_tokens"] for r in rows)
    total_cr    = sum(r["cache_read_tokens"] for r in rows)
    total_cw    = sum(r["cache_write_5m_tokens"] + r["cache_write_1h_tokens"] for r in rows)
    total_cost  = sum(calc_cost(r, r["model"]) for r in rows)

    lines = [f"Usage за {hours}h  (UTC last {hours}h)\n"]
    lines.append(
        f"ИТОГО: {total_calls} calls · "
        f"in {fmt_tokens(total_in)} · out {fmt_tokens(total_out)} · "
        f"cache_r {fmt_tokens(total_cr)} · cache_w {fmt_tokens(total_cw)} · "
        f"~{fmt_money(total_cost)} API-эквивалент"
    )
    if total_cr + total_cw > 0 and total_in > 0:
        cache_ratio = total_cr / (total_in + total_cr) * 100
        lines.append(f"  cache hit ratio: {cache_ratio:.0f}% (от read+input)")
    lines.append("")
    lines.append("По агентам:")
    for agent in sorted(by_agent.keys()):
        agent_rows = by_agent[agent]
        agent_calls = sum(r["calls"] for r in agent_rows)
        agent_cost = sum(calc_cost(r, r["model"]) for r in agent_rows)
        models_used = sorted({short_model(r["model"]) for r in agent_rows})
        lines.append(
            f"  * {agent}: {agent_calls} calls · "
            f"{fmt_money(agent_cost)} · models={','.join(models_used)}"
        )
        if len(agent_rows) > 1:
            for r in agent_rows:
                lines.append(
                    f"      - {short_model(r['model'])}: {r['calls']} · "
                    f"in {fmt_tokens(r['input_tokens'])} / "
                    f"out {fmt_tokens(r['output_tokens'])} / "
                    f"c_r {fmt_tokens(r['cache_read_tokens'])} = "
                    f"{fmt_money(calc_cost(r, r['model']))}"
                )

    lines.append("")
    if hours == 24:
        lines.append(f"Прогноз на месяц при таком темпе: ~{fmt_money(total_cost * 30)} API-эквивалент.")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since-hours", type=int, default=24)
    ap.add_argument("--no-send", action="store_true")
    args = ap.parse_args()

    if not DB_PATH.exists():
        log.error("db not found: %s — run collector first", DB_PATH)
        return 1

    since = datetime.now(timezone.utc) - timedelta(hours=args.since_hours)
    con = sqlite3.connect(DB_PATH)
    try:
        rows = fetch_period(con, since)
    finally:
        con.close()

    report = build_report(rows, args.since_hours)
    print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
