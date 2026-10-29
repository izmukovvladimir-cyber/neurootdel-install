#!/usr/bin/env python3
"""Context size of the CURRENT session of a channel agent (used by agents-reset.sh).

Why (29.10.2026, reset loop): the old version took the newest *.jsonl by mtime.
Right after a restart the new session has not written its transcript yet, and the dying CLI
even appends timestamp-less records (mode, cost-state) to the old file, so the OLD transcript
stayed "newest" and every run measured the same ctx and restarted the agent again, in a loop.

Rules:
  * only a transcript holding a record with "timestamp" >= the service start counts as the
    current session (content time, not mtime: the CLI touches files without content);
  * no such transcript -> NOSESSION (the new session has not spoken yet): no reset;
  * the chosen (path, ctx) equals the one recorded at the last reset -> SAME: no reset;
  * an unreadable or damaged last-reset record -> ERR (it must not unlock a restart).

Usage: agent_context_size.py <project_prefix> <projects_dir> <service_start_epoch> [last_reset_file]
  project_prefix  Claude Code project dir name of the agent workspace (cwd with non-alphanumerics
                  as "-"); every dir "<prefix>*" under projects_dir is searched, top-level *.jsonl.
stdout, one line:
  "<ctx>\t<path>"      measured
  NODATA               no transcripts at all
  NOSESSION            no transcript of the current session yet
  SAME\t<ctx>\t<path>  same transcript and ctx as at the last reset
  ERR                  unreadable / bad arguments
"""
from __future__ import annotations

import glob
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def parse_ts(ts: object) -> float:
    if not isinstance(ts, str):
        return 0.0
    try:
        d = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return 0.0
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.timestamp()


def scan(path: Path) -> tuple[float, int]:
    """Return (newest content timestamp, cache_read of the last turn) of one transcript."""
    newest = 0.0
    last = 0
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            newest = max(newest, parse_ts(o.get("timestamp")))
            msg = o.get("message")
            u = (msg.get("usage") if isinstance(msg, dict) else None) or o.get("usage")
            if not isinstance(u, dict):
                continue
            cr = u.get("cache_read_input_tokens", 0) or 0
            if isinstance(cr, int) and cr:
                last = cr
    return newest, last


def read_last_reset(path: Path | None) -> tuple[str, int] | None:
    if path is None:
        return None
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    # any other read error propagates: an unreadable record must not unlock a restart
    parts = raw.split("\t")
    if len(parts) != 2 or not parts[0] or not parts[1].isdigit():
        # a damaged record is unknown state, not "no record": it must not unlock a restart
        raise ValueError("damaged last-reset record")
    return parts[0], int(parts[1])


def measure(prefix: str, projects: str, start: float, last_reset_file: Path | None) -> str:
    pat = os.path.join(glob.escape(projects), f"{glob.escape(prefix)}*", "*.jsonl")
    files = [Path(p) for p in glob.glob(pat)]
    if not files:
        return "NODATA"
    best: tuple[float, int, Path] | None = None
    for p in files:
        try:
            # mtime never lags behind content, so an older mtime cannot hold a newer record
            if p.stat().st_mtime < start:
                continue
            newest, ctx = scan(p)
        except FileNotFoundError:
            continue  # rotated away between glob and open
        except OSError:
            return "ERR"
        if newest < start:
            continue
        if best is None or newest > best[0]:
            best = (newest, ctx, p)
    if best is None:
        return "NOSESSION"
    _, ctx, path = best
    try:
        prev = read_last_reset(last_reset_file)
    except (OSError, ValueError):  # UnicodeDecodeError is a ValueError
        return "ERR"
    if prev is not None and prev == (str(path), ctx):
        return f"SAME\t{ctx}\t{path}"
    return f"{ctx}\t{path}"


def main(argv: list[str]) -> int:
    if len(argv) not in (4, 5):
        print("ERR")
        return 0
    prefix, projects, start_raw = argv[1], argv[2], argv[3]
    if not prefix or "/" in prefix:
        print("ERR")
        return 0
    try:
        start = float(start_raw)
    except ValueError:
        print("ERR")
        return 0
    if not start > 0:
        print("ERR")
        return 0
    last_reset_file = Path(argv[4]) if len(argv) == 5 else None
    print(measure(prefix, projects, start, last_reset_file))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
