#!/usr/bin/env python3
"""correction-closed.py + correction-detector.py: an owner's correction is recorded before the turn ends.

Synthetic ids only. Run: python3 tests/test_correction_closed.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DETECTOR = REPO / "lib" / "hooks" / "correction-detector.py"
CLOSER = REPO / "lib" / "hooks" / "correction-closed.py"
OWNER, STRANGER = "555", "777"
FAILS: list[str] = []


def check(name: str, cond: bool, detail: object = "") -> None:
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail!r}"[:300]))
    if not cond:
        FAILS.append(name)


TMP = Path(tempfile.mkdtemp())
HOME = TMP / "home"
WS = HOME / ".claude-lab" / "jarvis" / ".claude"
(WS / "core").mkdir(parents=True)
CONF = TMP / "guard.conf"
CONF.write_text(f'AGENT_USER="neurootdel"\nAGENT_HOME="{HOME}"\nLIB_DIR="{REPO / "lib"}"\nCHANNEL_AGENTS="jarvis"\n'
                f'OWNER_TG_ID="{OWNER}"\nOWNER_TIMEZONE="Europe/Moscow"\n', encoding="utf-8")
ENV = {**os.environ, "NEUROOTDEL_GUARD_CONF": str(CONF), "PYTHONDONTWRITEBYTECODE": "1"}
STATE = HOME / ".claude-lab" / "shared" / "state" / "jarvis" / "correction-closed"


def run(script: Path, args: list[str], payload: object) -> subprocess.CompletedProcess[str]:
    data = payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False)
    return subprocess.run([sys.executable, str(script), *args], input=data, capture_output=True, text=True,
                          env=ENV, timeout=30)


def owner_says(text: str, session: str, user: str = OWNER) -> None:
    run(DETECTOR, [str(WS)], {"prompt": f'<channel source="telegram" chat_id="{user}" user_id="{user}">{text}</channel>',
                              "session_id": session})


def stop(session: str, active: bool = False) -> str:
    return run(CLOSER, ["stop", str(WS)], {"session_id": session, "stop_hook_active": active}).stdout


def note_call(session: str, wrote: bool = True, cmd: str = "python3 /x/feedback-note.py /m add --name a") -> None:
    resp = {"stdout": "feedback-note: wrote /m/feedback-a.md" if wrote else "feedback-note: --rule ... required"}
    run(CLOSER, ["clear", str(WS)], {"session_id": session, "tool_name": "Bash", "tool_input": {"command": cmd},
                                     "tool_response": resp})


# --- correction, nothing recorded: blocked once, then released ------------------------------------
owner_says("Переделай абзац, так не говорят", "s1")
check("detector leaves a marker", (STATE / "pending-s1.json").is_file(), list(STATE.glob("*")) if STATE.exists() else [])
out = stop("s1")
check("stop: blocked once", '"decision": "block"' in out and "feedback-note.py" in out, out)
check("stop: second stop (stop_hook_active) lets go", stop("s1", active=True) == "")
check("stop: marker gone after release", not (STATE / "pending-s1.json").exists())
check("stop: third stop silent", stop("s1") == "")

# --- correction, then the note is written: the turn ends freely --------------------------------------
owner_says("убери второе предложение", "s2")
note_call("s2", wrote=False)
check("failed feedback-note keeps the marker", (STATE / "pending-s2.json").is_file())
note_call("s2", cmd="python3 /x/other.py add")
check("another script keeps the marker", (STATE / "pending-s2.json").is_file())
note_call("s2")
check("written note removes the marker", not (STATE / "pending-s2.json").exists())
check("stop after the note: silent", stop("s2") == "")

# --- no correction / not the owner / other session ----------------------------------------------------
owner_says("Привет, как дела с отчётом?", "s3")
check("neutral message: no marker, stop silent", not (STATE / "pending-s3.json").exists() and stop("s3") == "")
owner_says("переделай всё", "s4", user=STRANGER)
check("stranger's correction: no marker", not (STATE / "pending-s4.json").exists())
owner_says("переделай", "s5")
check("marker of one session does not block another", stop("s6") == "")

# --- old marker, STOP, bad input -----------------------------------------------------------------------
(STATE / "pending-old.json").write_text(json.dumps({"t": 1, "trigger": "x"}), encoding="utf-8")
check("marker older than 6 h: released silently", stop("old") == "" and not (STATE / "pending-old.json").exists())
(STATE / "STOP").touch()
check("STOP: stop silent", stop("s5") == "")
(STATE / "STOP").unlink()
r = run(CLOSER, ["stop", str(WS)], "not json")
check("bad input: exit 0, silent", r.returncode == 0 and r.stdout == "", r)
check("events logged without message text", "переделай" not in (STATE / "events.jsonl").read_text(encoding="utf-8"))

print(f"FAILS: {len(FAILS)}")
sys.exit(1 if FAILS else 0)
