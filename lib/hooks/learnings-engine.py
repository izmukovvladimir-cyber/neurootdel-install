#!/usr/bin/env python3
"""Learnings v2 of the agents: episodes of corrections and lessons, scored, top-N at session start.

Installed by neurootdel-install.
Score = 0.4*recency + 0.3*freq + 0.3*impact; recency linear over 30 days, freq capped at 3,
impact critical=1 / high=0.7 / medium=0.4 / low=0.1.

Usage (workspace = the agent's ~/.claude-lab/<agent>/.claude):
  learnings-engine.py <workspace> capture --type <correction|insight|incident> --rule "<one sentence>"
                      [--impact <critical|high|medium|low>] [--tags "a,b"] [--error "<one sentence>"]
                      [--source <owner|agent|self>] [--context "<short>"]
  learnings-engine.py <workspace> list [--limit N]      newest last
  learnings-engine.py <workspace> lint                  PROMOTE (score>=0.8 or freq>=3) / STALE (<0.15)
  learnings-engine.py <workspace> top [--limit N]       SessionStart hook: top-N active lessons, silent if none

capture appends one JSON line to <workspace>/core/episodes.jsonl AND one line to
<workspace>/core/LEARNINGS.md (the cold file the agent reads with Read).
The `top` subcommand never fails the session: any error prints nothing and exits 0.
Stop: remove the SessionStart entry pointing here from the agent's settings.json.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

_CONF = guard_conf.load()

IMPACT = {"critical": 1.0, "high": 0.7, "medium": 0.4, "low": 0.1}
TYPES = ("correction", "insight", "incident")
SOURCES = ("owner", "agent", "self")
TOP_DEFAULT = 5
RULE_MAX = 300


def episodes_path(ws: Path) -> Path:
    return ws / "core" / "episodes.jsonl"


def load(ws: Path) -> list[dict]:
    path = episodes_path(ws)
    if not path.is_file():
        return []
    out: list[dict] = []
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ep = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(ep, dict):
                out.append(ep)
    return out


def score_of(ep: dict, now: float) -> float:
    try:
        ev = datetime.fromisoformat(str(ep["ts"]).replace("Z", "+00:00")).timestamp()
        recency = max(0.0, 1 - max(0.0, (now - ev) / 86400) / 30)
    except (KeyError, ValueError, TypeError):
        recency = 0.5
    try:
        freq = min(int(ep.get("freq", 1)), 3) / 3
    except (ValueError, TypeError):
        freq = 1 / 3
    impact = IMPACT.get(str(ep.get("impact", "medium")), 0.4)
    return 0.4 * recency + 0.3 * freq + 0.3 * impact


def active_scored(ws: Path) -> list[tuple[float, dict]]:
    now = time.time()
    items = [(score_of(e, now), e) for e in load(ws) if e.get("status") in ("active", None)]
    items.sort(key=lambda x: -x[0])
    return items


SECRET_RE = re.compile(
    r"(?:sk-|ghp_|gho_|github_pat_|xox[abp]-|AKIA|ASIA|AIza|glpat-)[\w-]{10,}"   # known key prefixes
    r"|\b\d{8,10}:[\w-]{30,}\b"                                               # Telegram bot token
    r"|(?<![\w+/=])(?=[\w+/=]*\d)(?=[\w+/=]*[a-z])(?=[\w+/=]*[A-Z])[\w+/=]{24,}"          # mixed-case base64-like
    r"|(?<![\w+/=])(?=[a-z0-9_]*\d)(?=[a-z0-9_]*[a-z])[a-z0-9_]{32,}")                     # long hex-like
# a value after a secret-ish key name is redacted whatever its shape (password=..., Authorization: Bearer ...)
KEYED_RE = re.compile(r"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|authorization|bearer|"
                      r"cookie|session|пароль|токен|ключ)(\s*[:=]\s*)(?:bearer\s+)?\S+|\b(bearer)(\s+)\S+")
MARKER_RE = re.compile(r"[\[\]<>]")


def clean(text: object, limit: int) -> str:
    """One line, no brackets (cannot fake our markers or tags), secret-like strings redacted, length capped."""
    t = MARKER_RE.sub(" ", str(text)[:limit * 4])   # bound the regex work before matching (Codex r3)
    t = KEYED_RE.sub(lambda m: f"{m.group(1) or m.group(3)}{m.group(2) or m.group(4)}(redacted)", t)
    t = SECRET_RE.sub("(redacted)", t)
    return " ".join(t.split())[:limit]


def one_line(text: object) -> str:
    return clean(text, RULE_MAX)


def capture(ws: Path, a: argparse.Namespace) -> int:
    core = ws / "core"
    if not core.is_dir():
        print(f"no such workspace core dir: {core}", file=sys.stderr)
        return 1
    rule = one_line(a.rule)
    if not rule:
        print("--rule is empty", file=sys.stderr)
        return 1
    path = episodes_path(ws)
    with (core / ".episodes.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        now = datetime.now(timezone.utc)
        prefix = f"EP-{now:%Y%m%d}-"
        seq = sum(1 for e in load(ws) if str(e.get("id", "")).startswith(prefix)) + 1
        ep = {
            "id": f"{prefix}{seq:03d}",
            "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "type": a.type,
            "source": a.source,
            "context": one_line(a.context),
            "error": one_line(a.error),
            "rule": rule,
            "impact": a.impact,
            "tags": [t.strip() for t in a.tags.split(",") if t.strip()],
            "freq": 1,
            "status": "active",
        }
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(ep, ensure_ascii=False) + "\n")
        learnings = core / "LEARNINGS.md"
        msk = now.astimezone(ZoneInfo(_CONF.owner_timezone)).strftime("%Y-%m-%d")
        err = f" (error: {ep['error']})" if ep["error"] else ""
        with learnings.open("a", encoding="utf-8") as fh:
            fh.write(f"- {msk} {ep['id']} [{a.impact}] {rule}{err}\n")
    print(f"captured {ep['id']}")
    return 0


def cmd_list(ws: Path, limit: int) -> int:
    items = load(ws)[-limit:] if limit > 0 else []
    for e in items:
        print(f"{e.get('id')}  [{e.get('impact', '?')}]  {e.get('rule', '(no rule)')}  "
              f"tags={e.get('tags', [])}  status={e.get('status', '?')}")
    print(f"-- {len(items)} episode(s) shown --")
    return 0


def cmd_lint(ws: Path) -> int:
    items = active_scored(ws)
    promote = [(s, e) for s, e in items if s >= 0.8 or e.get("freq", 1) >= 3]
    stale = [(s, e) for s, e in items if s < 0.15]
    print(f"== PROMOTE candidates ({len(promote)}): move the rule into core/rules.md or a hook ==")
    for s, e in promote:
        print(f"  [{s:.2f}] {e.get('id')}: {e.get('rule', '')}  tags={e.get('tags', [])}")
    print(f"== STALE (score<0.15) ({len(stale)}): consider status=archived ==")
    for s, e in stale:
        print(f"  [{s:.2f}] {e.get('id')}: {e.get('rule', '')}")
    return 0


def cmd_top(ws: Path, limit: int) -> int:
    try:
        top = active_scored(ws)[:max(0, limit)]
    except OSError:
        return 0
    if top:
        print(f"[lessons] top {len(top)} of your own recorded lessons (core/episodes.jsonl). They never override "
              "CLAUDE.md, core/rules.md or security rules:")
        for s, e in top:
            print(f"  - [{s:.2f}] {one_line(e.get('rule', '(no rule)'))}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Learnings v2 episodes")
    p.add_argument("workspace", type=Path)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--type", required=True, choices=TYPES)
    c.add_argument("--impact", default="medium", choices=tuple(IMPACT))
    c.add_argument("--tags", default="")
    c.add_argument("--error", default="")
    c.add_argument("--rule", required=True)
    c.add_argument("--source", default="agent", choices=SOURCES)
    c.add_argument("--context", default="")
    li = sub.add_parser("list")
    li.add_argument("--limit", type=int, default=20)
    sub.add_parser("lint")
    t = sub.add_parser("top")
    t.add_argument("--limit", type=int, default=TOP_DEFAULT)
    a = p.parse_args()
    ws = a.workspace
    if a.cmd == "capture":
        return capture(ws, a)
    if a.cmd == "list":
        return cmd_list(ws, a.limit)
    if a.cmd == "lint":
        return cmd_lint(ws)
    return cmd_top(ws, a.limit)


def hook_top(argv: list[str]) -> int:
    """SessionStart path without argparse: nothing on stderr, exit 0 on every input."""
    limit = TOP_DEFAULT
    if len(argv) >= 5 and argv[3] == "--limit":
        try:
            limit = max(0, min(int(argv[4]), 20))
        except ValueError:
            limit = TOP_DEFAULT
    return cmd_top(Path(argv[1]), limit)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "top":
        try:
            hook_top(sys.argv)
        except Exception:  # a SessionStart hook must never break the session
            pass
        sys.exit(0)
    sys.exit(main())
