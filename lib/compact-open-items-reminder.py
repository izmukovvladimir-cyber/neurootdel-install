#!/usr/bin/env python3
"""SessionStart hook (matchers "compact" and "startup"): remind the agent of paid/running things mentioned before compaction.

Compaction silently drops threads (22.09.2026: a rented vast.ai GPU fell out of the summary and kept
billing). The transcript file still holds the pre-compaction messages, so this hook greps them for
money / rental / promise words and hands the hits back to the agent with one instruction: every item
that is still open must be a line in handoff.md. Never fails the session: any error prints nothing.
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

WINDOW = timedelta(hours=36)
PER_FILE = 5  # latest hits per session file, so one chatty session cannot hide an older one
MAX_FILES = 4  # the current transcript plus the latest sessions before a reset
SNIPPET = 220
MSK = timezone(timedelta(hours=3))

# Only words for things that keep billing or running by themselves. Payments, subscriptions and promises
# are left to the instruction text: in funnel agents' transcripts those words are everywhere (measured
# 22.09 on a funnel agent: 15 of 15 hits were noise).
STRONG = re.compile(
    r"аренд|списыва|инстанс|vast\.ai|runpod|\binstance|\brent|billing|"
    r"в час\b|/час|/hr\b|per hour|автопродлен",
    re.IGNORECASE,
)
NOISE = re.compile(
    r"<system-reminder>.*?</system-reminder>|<untrusted_metadata.*?</untrusted_metadata>", re.DOTALL
)


def _text_of(entry: dict) -> str:
    """User/assistant prose only; tool calls and tool results are skipped."""
    msg = entry.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            parts.append(block.get("text", ""))
        elif block.get("type") == "tool_use" and "reply" in str(block.get("name", "")):
            parts.append(str((block.get("input") or {}).get("text", "")))
    return "\n".join(parts)


def _snippet(text: str, match: re.Match[str]) -> str:
    start = max(0, match.start() - SNIPPET // 2)
    chunk = text[start:start + SNIPPET]
    return " ".join(chunk.split())


def _recent_transcripts(transcript: Path, now: datetime) -> list[Path]:
    """This session plus sibling sessions touched inside the window (a reset starts a new file)."""
    cutoff = (now - WINDOW).timestamp()
    siblings = [p for p in transcript.parent.glob("*.jsonl") if p != transcript and p.stat().st_mtime >= cutoff]
    siblings.sort(key=lambda p: p.stat().st_mtime)
    # On "startup" the new session's own file may not exist yet: the previous sessions are the point then.
    current = [transcript] if transcript.is_file() else []
    return siblings[-(MAX_FILES - len(current)):] + current


def _hits_in(path: Path, now: datetime, seen: set[str]) -> list[str]:
    hits: list[str] = []
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("type") not in ("user", "assistant") or entry.get("isCompactSummary"):
                continue
            try:
                ts = datetime.fromisoformat(str(entry.get("timestamp", "")).replace("Z", "+00:00"))
            except ValueError:
                continue
            if now - ts > WINDOW:
                continue
            text = NOISE.sub("", _text_of(entry))
            match = STRONG.search(text)
            if not match:
                continue
            snip = _snippet(text, match)
            if snip in seen:
                continue
            seen.add(snip)
            who = "человек" if entry["type"] == "user" else "я"
            hits.append(f"- {ts.astimezone(MSK):%d.%m %H:%M} МСК, {who}: {snip}")
    return hits[-PER_FILE:]


def collect(transcript: Path, now: datetime) -> list[str]:
    seen: set[str] = set()
    return [hit for path in _recent_transcripts(transcript, now) for hit in _hits_in(path, now, seen)]


def main() -> None:
    try:
        payload = json.load(sys.stdin)
        transcript = Path(payload["transcript_path"])
        cwd = Path(payload.get("cwd") or ".")
    except (json.JSONDecodeError, KeyError, TypeError, ValueError):
        return
    if not transcript.parent.is_dir():
        return
    try:
        hits = collect(transcript, datetime.now(timezone.utc))
    except OSError:
        return
    # Channel agents run from <workspace>/.claude/dashi-plugin-claude-code/plugin, so the workspace
    # handoff is found by walking up from cwd.
    candidates = [base / rel for base in (cwd, *cwd.parents) for rel in ("core/hot/handoff.md", ".claude/core/hot/handoff.md")]
    handoff = next((p for p in candidates if p.is_file()), None)
    where = str(handoff) if handoff else "свой handoff.md (файл открытых дел)"
    lines = [
        "ПОСЛЕ СЖАТИЯ ИЛИ СБРОСА ПАМЯТИ: всё платное и каждое открытое обещание живёт строкой в handoff.",
        "Сжатие теряет нити. Прежде чем продолжать, проверь: всё, что стоит денег или продолжает работать",
        "(аренда, сервер, подписка, покупка, фоновая задача), и каждое обещание человеку, если оно ещё",
        f"не закрыто, обязано стоять строкой в {where}. Нет строки — допиши её в этом же ходе:",
        "что это, где, кто платит, как остановить. Закрытое не трогай.",
    ]
    if hits:
        lines.append("Упоминания за последние 36 часов (сверь каждое):")
        lines.extend(hits)
    out = {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "\n".join(lines)}}
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 - a reminder hook must never break session start
        pass
