#!/usr/bin/env python3
"""Paragraph gate: a solid wall of text does not go out to Telegram.

Installed by neurootdel-install (ported from a live team gate). PreToolUse on mcp__dashi-channel__reply /
edit_message, argv[1] = state dir (~/.claude-lab/shared/state/<agent>/paragraph-gate).

Deny when the outgoing text is longer than MIN_TOTAL chars and has a continuous block
(no blank line inside) of more than MAX_LINES lines or more than MAX_BLOCK_CHARS chars.
No auto-splitting: the agent gets a reason and resends.

Not measured: fenced code blocks (```), attachments (only the text field is read).
Lists: a block of list items (after at most MAX_INTRO_LINES intro lines) passes when every item is at most
SHORT_ITEM chars (any count), or when it has at most MAX_LIST_ITEMS items of at most MAX_ITEM_CHARS chars.

guard.conf: PARAGRAPH_GATE="0" switches it off for every agent; PARAGRAPH_GATE_MIN_TOTAL (default 300) is
the length from which a message is measured.
Every call is logged without message text to <state>/events.jsonl.
Stop: touch <state>/STOP (one agent) or touch <state>/../../paragraph-gate.STOP (all). Any error = allow.
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

_RAW = guard_conf.read_raw()



def _int(key: str, default: int) -> int:
    try:
        val = int(_RAW.get(key, "") or default)
    except ValueError:
        return default
    return val if val > 0 else default


GATE_ON = _RAW.get("PARAGRAPH_GATE", "1").strip() != "0"
MIN_TOTAL = _int("PARAGRAPH_GATE_MIN_TOTAL", 300)
MAX_LINES = 4
MAX_BLOCK_CHARS = 350
MAX_LIST_ITEMS = 8
MAX_ITEM_CHARS = 200
MAX_INTRO_CHARS = 250
MAX_INTRO_LINES = 2
SHORT_LINE = 60
SHORT_ITEM = 80
MSK = timezone(timedelta(hours=3))

REASON = ("Текст сплошной: разбей на абзацы по мысли, 1-3 строки, пустая строка между ними, "
          "и отправь заново")

FENCE = re.compile(r"```.*?(?:```|\Z)", re.S)
BLANK_SPLIT = re.compile(r"\n[ \t]*\n")
# A list line starts with a non-word mark (bullet, arrow, emoji, «—»), a number "1." / "2)" / "1️⃣",
# a time "18:09", or a letter item "а)". Quotes, brackets, @mention and #tag are not marks.
# A line of at most SHORT_LINE chars also counts as an item (an unmarked list).
LIST_ITEM = re.compile(r"^\s*(?:[^\w\s«\"'(\[*@#]|\d{1,2}(?:[.):]|️⃣)|[a-zа-я]\)\s)", re.I)


@dataclass(frozen=True)
class Verdict:
    allow: bool
    total: int = 0
    worst_lines: int = 0
    worst_chars: int = 0
    blocks: int = 0
    why: str = ""


def blocks_of(text: str) -> list[list[str]]:
    """Blank-line separated blocks (code fences cut out, they act as a break)."""
    bare = FENCE.sub("\n\n", text.replace("\r\n", "\n"))
    out: list[list[str]] = []
    for chunk in BLANK_SPLIT.split(bare):
        lines = [ln.rstrip() for ln in chunk.split("\n") if ln.strip()]
        if lines:
            out.append(lines)
    return out


def is_item(line: str) -> bool:
    return bool(LIST_ITEM.match(line)) or len(line.strip()) <= SHORT_LINE


def list_items(lines: list[str]) -> list[str] | None:
    """Items of a list block (indented lines continue the previous item), or None if not a list."""
    start = next((i for i, ln in enumerate(lines) if is_item(ln)), None)
    if start is None or start > MAX_INTRO_LINES or sum(len(ln) for ln in lines[:start]) > MAX_INTRO_CHARS:
        return None
    items: list[str] = []
    for ln in lines[start:]:
        if is_item(ln):
            items.append(ln.strip())
        elif items and ln[:1] in (" ", "\t"):
            items[-1] += " " + ln.strip()
        else:
            return None
    return items if len(items) >= 2 else None


def block_fails(lines: list[str]) -> tuple[bool, int, int, str]:
    chars = sum(len(ln) for ln in lines)
    items = list_items(lines)
    if items is not None:
        longest = max(len(i) for i in items)
        if longest <= SHORT_ITEM:
            return False, len(lines), chars, ""
        if len(items) > MAX_LIST_ITEMS:
            return True, len(lines), chars, "list_items"
        if longest > MAX_ITEM_CHARS:
            return True, len(lines), chars, "list_item_long"
        return False, len(lines), chars, ""
    if len(lines) > MAX_LINES:
        return True, len(lines), chars, "lines"
    if chars > MAX_BLOCK_CHARS:
        return True, len(lines), chars, "chars"
    return False, len(lines), chars, ""


def decide(text: str) -> Verdict:
    blocks = blocks_of(text)
    total = sum(len(ln) for b in blocks for ln in b)
    if total <= MIN_TOTAL:
        return Verdict(True, total, blocks=len(blocks))
    worst = (0, 0)
    why = ""
    for b in blocks:
        bad, n, c, w = block_fails(b)
        worst = max(worst, (n, c), key=lambda x: x[1])
        if bad and not why:
            why = w
    return Verdict(not why, total, worst[0], worst[1], len(blocks), why)


def log(state: Path, row: dict) -> None:
    try:
        state.mkdir(parents=True, exist_ok=True)
        row = {"ts": datetime.now(MSK).strftime("%Y-%m-%d %H:%M:%S"), **row}
        with (state / "events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError:
        pass


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    state = Path(sys.argv[1])
    if not GATE_ON or (state.parent.parent / "paragraph-gate.STOP").exists() or (state / "STOP").exists():
        return 0
    payload = json.load(sys.stdin)
    tool = str(payload.get("tool_name", ""))
    if not tool.endswith(("__reply", "__edit_message")):
        return 0
    args = payload.get("tool_input") or {}
    text = str(args.get("text") or "")
    v = decide(text)
    log(state, {"tool": tool.rsplit("__", 1)[-1], "len": len(text), "measured": v.total,
                "blocks": v.blocks, "worst_lines": v.worst_lines, "worst_chars": v.worst_chars,
                "files": len(args.get("files") or []), "verdict": "allow" if v.allow else "deny",
                "why": v.why})
    if not v.allow:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": f"[paragraph-gate] {REASON}"}},
                         ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 - a gate failure must never block a reply
        sys.exit(0)
