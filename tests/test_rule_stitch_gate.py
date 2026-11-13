#!/usr/bin/env python3
"""rule-stitch-gate.py: the owner's «зашей» ends in a recorded rule and a check, «готово» only after the test.

Synthetic ids only. Run: python3 tests/test_rule_stitch_gate.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GATE = REPO / "lib" / "hooks" / "rule-stitch-gate.py"
OWNER, STRANGER = "555", "777"
FAILS: list[str] = []


def check(name: str, cond: bool, detail: object = "") -> None:
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail!r}"[:300]))
    if not cond:
        FAILS.append(name)


TMP = Path(tempfile.mkdtemp())
HOME = TMP / "home"
WS = HOME / ".claude-lab" / "jarvis" / ".claude"
CWS = HOME / ".claude-lab" / "coder" / ".claude"
for w in (WS, CWS):
    (w / "core").mkdir(parents=True)


def conf(agents: str) -> Path:
    path = TMP / f"guard-{agents.replace(' ', '_')}.conf"
    path.write_text(f'AGENT_USER="neurootdel"\nAGENT_HOME="{HOME}"\nLIB_DIR="{REPO / "lib"}"\n'
                    f'CHANNEL_AGENTS="{agents}"\nOWNER_TG_ID="{OWNER}"\nOWNER_TIMEZONE="Europe/Moscow"\n',
                    encoding="utf-8")
    return path


def run(mode: str, payload: object, ws: Path = WS, agents: str = "jarvis", extra: list[str] | None = None
        ) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "NEUROOTDEL_GUARD_CONF": str(conf(agents)), "PYTHONDONTWRITEBYTECODE": "1"}
    data = payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False)
    return subprocess.run([sys.executable, str(GATE), mode, str(ws), *(extra or [])], input=data,
                          capture_output=True, text=True, env=env, timeout=30)


def owner(text: str, session: str, user: str = OWNER, agents: str = "jarvis") -> str:
    msg = f'<channel source="telegram" chat_id="{user}" user_id="{user}">{text}</channel>'
    return run("prompt", {"prompt": msg, "session_id": session}, agents=agents).stdout


def reply(text: str, session: str) -> str:
    return run("guard", {"session_id": session, "tool_name": "mcp__dashi-channel__reply",
                         "tool_input": {"chat_id": OWNER, "text": text}}).stdout


def stop(session: str, active: bool = False) -> str:
    return run("stop", {"session_id": session, "stop_hook_active": active}).stdout


STATE = HOME / ".claude-lab" / "shared" / "state" / "jarvis" / "rule-stitch"

# --- detection ------------------------------------------------------------------------------------------
for text in ("Зашей это правило", "зашить надо, чтобы больше не повторялось", "Пропиши это в правила",
             "добавь это в свои правила"):
    check(f"owner: «{text}» caught", "[rule-stitch]" in owner(text, "d"), text)
for text in ("не надо зашивать, это разово", "Как дела с постом?", "зашёл в кабинет, всё ок"):
    check(f"owner: «{text}» silent", owner(text, "n") == "", text)
check("stranger's «зашей»: silent", owner("зашей правило", "x", user=STRANGER) == "")
check("no envelope: silent", run("prompt", {"prompt": "зашей правило", "session_id": "y"}).stdout == "")
out = owner("Зашей правило про подписи", "w1")
check("instruction: workshop (no Coder) builds the check itself", "No Coder here" in out and "feedback-note.py" in out, out)
out = owner("Зашей правило про подписи", "w2", agents="jarvis coder")
check("instruction: with Coder hands the hook to him", 'to_agent="coder"' in out and "Зашить правило" in out, out)

# --- stop: nothing done -> blocked once; noted / sent -> free -----------------------------------------------
owner("Зашей это", "s1")
out = stop("s1")
check("stop: nothing recorded -> blocked once", '"decision": "block"' in out, out)
check("stop: second stop releases", stop("s1", active=True) == "")
owner("Зашей это", "s2")
run("clear", {"session_id": "s2", "tool_name": "Bash", "tool_input": {"command": "python3 /l/feedback-note.py /m add --name a"},
              "tool_response": {"stdout": "feedback-note: wrote /m/feedback-a.md"}})
check("stop: after a written note -> free", stop("s2") == "")
owner("Зашей это", "s3")
run("clear", {"session_id": "s3", "tool_name": "mcp__gbrain-swarm__notify",
              "tool_input": {"to_agent": "coder", "payload": {"title": "Зашить правило", "body": "правило"}}})
check("stop: after a task to Coder -> free", stop("s3") == "")
owner("Зашей это", "s4")
run("clear", {"session_id": "s4", "tool_name": "mcp__gbrain-swarm__notify",
              "tool_input": {"to_agent": "coder", "payload": {"title": "", "body": ""}}})
check("stop: an empty notify does not count", '"decision": "block"' in stop("s4"))

# --- «готово» only after done --evidence ----------------------------------------------------------------------
owner("Зашей правило", "g1")
out = reply("Готово, правило зашил.", "g1")
check("guard: «зашил» before the test denied", '"permissionDecision": "deny"' in out, out)
check("guard: an honest status passes", reply("Принял, ставлю проверку, отпишусь после теста.", "g1") == "")
check("guard: other session not affected", reply("Готово, правило зашил.", "g9") == "")
r = run("done", "", extra=["--evidence", "short"])
check("done: evidence too short refused", r.returncode == 2, r)
r = run("done", "", extra=["--evidence", "хук отказал на тестовом сообщении, лог events.jsonl"])
check("done: marks pending", r.returncode == 0 and "marked done" in r.stdout, r)
check("guard: «зашил» after done passes", reply("Готово, правило зашил: хук срабатывает.", "g1") == "")
check("done: evidence logged", "хук отказал" in (STATE / "events.jsonl").read_text(encoding="utf-8"))

# --- old marker, STOP, bad input -----------------------------------------------------------------------------
(STATE / "pending-old.json").write_text(json.dumps({"t": time.time() - 7 * 3600, "noted": False, "sent": False,
                                                    "done": False}), encoding="utf-8")
check("old marker: guard silent", reply("Зашил.", "old") == "")
check("old marker: stop silent", stop("old") == "")
owner("Зашей", "st")
(STATE / "STOP").touch()
check("STOP: stop silent", stop("st") == "")
(STATE / "STOP").unlink()
r = run("stop", "not json")
check("bad input: exit 0 silent", r.returncode == 0 and r.stdout == "", r)
check("log has no message text", "Зашей" not in (STATE / "events.jsonl").read_text(encoding="utf-8"))

# --- Coder side ---------------------------------------------------------------------------------------------
CSTATE = HOME / ".claude-lab" / "shared" / "state" / "coder" / "rule-stitch"
task = "[Inter-agent from jarvis -> coder] Зашить правило 13.11: подписи без эмодзи"
out = run("cprompt", {"prompt": task, "session_id": "c1"}, ws=CWS).stdout
check("coder: task from jarvis -> work order", "report to jarvis" in out, out)
check("coder: task from someone else silent",
      run("cprompt", {"prompt": task.replace("from jarvis", "from smm"), "session_id": "c2"}, ws=CWS).stdout == "")
out = run("cstop", {"session_id": "c1"}, ws=CWS).stdout
check("coder: no report -> blocked once", '"decision": "block"' in out, out)
check("coder: second stop releases", run("cstop", {"session_id": "c1", "stop_hook_active": True}, ws=CWS).stdout == "")
run("cprompt", {"prompt": task, "session_id": "c3"}, ws=CWS)
run("cclear", {"session_id": "c3", "tool_input": {"to_agent": "jarvis", "payload": {"title": "Отчёт", "body": "ok"}}},
    ws=CWS)
check("coder: after the report -> free", run("cstop", {"session_id": "c3"}, ws=CWS).stdout == "")

print(f"FAILS: {len(FAILS)}")
sys.exit(1 if FAILS else 0)
