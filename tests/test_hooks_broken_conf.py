#!/usr/bin/env python3
"""The #1884 hooks never break a turn on a broken guard.conf: exit 0, nothing on stdout or stderr.

Run: python3 tests/test_hooks_broken_conf.py
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HOOKS = REPO / "lib" / "hooks"
FAILS: list[str] = []

TMP = Path(tempfile.mkdtemp())
UNREADABLE = TMP / "conf-is-a-dir"
UNREADABLE.mkdir()
BAD_TZ = TMP / "bad-tz.conf"
BAD_TZ.write_text(f'AGENT_HOME="{TMP}"\nOWNER_TG_ID="555"\nOWNER_TIMEZONE="Nowhere/Bad"\nCHANNEL_AGENTS="jarvis"\n',
                  encoding="utf-8")
CALLS = [("correction-closed.py", ["stop", str(TMP / "ws")]), ("rule-stitch-gate.py", ["stop", str(TMP / "ws")]),
         ("paragraph-gate.py", [str(TMP / "st")]), ("text-critics-gate.py", [str(TMP / "st")])]
PAYLOAD = '{"session_id": "a", "tool_name": "mcp__dashi-channel__reply", "tool_input": {"text": "x"}}'

for conf in (UNREADABLE, BAD_TZ):
    for script, args in CALLS:
        r = subprocess.run([sys.executable, str(HOOKS / script), *args], input=PAYLOAD, capture_output=True,
                           text=True, timeout=30,
                           env={**os.environ, "NEUROOTDEL_GUARD_CONF": str(conf), "PYTHONDONTWRITEBYTECODE": "1"})
        name = f"{script} with {conf.name}: exit 0, silent"
        ok = r.returncode == 0 and r.stdout == "" and r.stderr == ""
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  rc={r.returncode} err={r.stderr[-200:]!r}"))
        if not ok:
            FAILS.append(name)

print(f"FAILS: {len(FAILS)}")
sys.exit(1 if FAILS else 0)
