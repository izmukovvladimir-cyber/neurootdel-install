#!/usr/bin/env python3
"""Gate: the owner's correction caught by correction-detector.py is recorded before the turn ends.

Installed by neurootdel-install. correction-detector.py (UserPromptSubmit) writes a pending marker for the
session when the owner's own message looks like a correction; this script closes the loop:

  clear <ws>  PostToolUse Bash   `feedback-note.py ... add` that printed «feedback-note: wrote» removes the marker.
  stop <ws>   Stop               marker still there: blocks the turn end ONCE with «the correction is not recorded:
                                 record it, or say why it is not a correction»; the second stop (stop_hook_active)
                                 lets go and logs the miss. Never loops, never blocks twice for one marker.

Marker: ~/.claude-lab/shared/state/<agent>/correction-closed/pending-<session>.json (<agent> = the folder name
above <ws>), 6 h life. Every call is logged without message text to events.jsonl there.
Stop: touch that dir's STOP. Any error = allow.
"""
from __future__ import annotations

import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

LIB = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(LIB))
import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

_CONF = guard_conf.load()
MARKER_TTL_SEC = 6 * 3600
NOTE_TOOL = LIB / "feedback-note.py"


def state_dir(ws: str) -> Path:
    return _CONF.lab / "shared" / "state" / Path(ws).parent.name / "correction-closed"


def marker_path(ws: str, session: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", session or "nosession")[:80]
    return state_dir(ws) / f"pending-{safe}.json"


def mark(ws: str, session: str, trigger: str) -> None:
    """Called by correction-detector.py on a match; a failure here never breaks the detector."""
    mp = marker_path(ws, session)
    try:
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(json.dumps({"t": time.time(), "trigger": trigger}, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass


def log(ws: str, event: dict) -> None:
    try:
        st = state_dir(ws)
        st.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(ZoneInfo(_CONF.owner_timezone)).strftime("%Y-%m-%d %H:%M:%S")
        with (st / "events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": ts, **event}, ensure_ascii=False) + "\n")
    except OSError:
        pass


def note_written(p: dict) -> bool:
    ti = p.get("tool_input") or {}
    cmd = str(ti.get("command") or "") if isinstance(ti, dict) else ""
    if "feedback-note.py" not in cmd or not re.search(r"\badd\b", cmd):
        return False
    return "feedback-note: wrote" in json.dumps(p.get("tool_response"), ensure_ascii=False)


def mode_clear(ws: str, p: dict) -> int:
    if str(p.get("tool_name") or "") != "Bash" or not note_written(p):
        return 0
    mp = marker_path(ws, str(p.get("session_id") or ""))
    had = mp.exists()
    try:
        mp.unlink(missing_ok=True)
    except OSError:
        pass
    log(ws, {"mode": "clear", "session": p.get("session_id"), "had_marker": had})
    return 0


def mode_stop(ws: str, p: dict) -> int:
    mp = marker_path(ws, str(p.get("session_id") or ""))
    if not mp.exists():
        return 0
    try:
        data = json.loads(mp.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    if time.time() - float(data.get("t") or 0) > MARKER_TTL_SEC or p.get("stop_hook_active"):
        try:
            mp.unlink(missing_ok=True)
        except OSError:
            pass
        log(ws, {"mode": "stop", "session": p.get("session_id"), "result": "released"})
        return 0
    log(ws, {"mode": "stop", "session": p.get("session_id"), "result": "blocked"})
    reason = ("The owner's correction in this turn is not recorded. If he corrected how you work or a text, "
              f"record it now the one way: python3 {NOTE_TOOL} <memory dir> add --name <slug> --rule \"...\" "
              "--area \"...\" --source \"...\" (the correction hook printed the memory dir). If it was not a "
              "correction (a question, a bug report about something else), just finish the turn. "
              "Do not mention this hook to the owner.")
    print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[0] not in ("clear", "stop"):
        return 0
    ws = argv[1]
    if (state_dir(ws) / "STOP").exists():
        return 0
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    return (mode_clear if argv[0] == "clear" else mode_stop)(ws, payload)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception:  # noqa: BLE001 - a gate must never break the turn
        sys.exit(0)
