#!/usr/bin/env python3
"""Gate: the owner's «зашей» (stitch this rule) ends in a check that fires, not in a promise.

Installed by neurootdel-install, ported from a live team gate (owner-specific names, people and the team
layout taken out). One script, several hook entries in the plugin settings.json of an agent:

  prompt <ws>  UserPromptSubmit  the owner's own message (same envelope rules as correction-detector.py) says
                                 «зашей / зашить / пропиши правило / добавь в правила»: writes a pending marker
                                 for the session and tells the agent what stitching means and the exact calls.
  guard <ws>   PreToolUse        reply / edit_message: «зашил / правило стоит / готово ... правило» to a person
                                 is denied while the marker is not «done».
  clear <ws>   PostToolUse       Bash `feedback-note.py ... add` that wrote a note marks «noted»; a non-empty
                                 mcp__gbrain-swarm__notify to "coder" marks «sent».
  stop <ws>    Stop              marker neither noted, sent nor done: blocks the turn end ONCE; the second stop
                                 (stop_hook_active) lets go and logs the miss, the «готово» guard stays. Never loops.
  done <ws> --session <id> --evidence "<what fired>"   run by the agent itself after a live test showed the
                                 check firing: marks THAT request «done» (the «готово» guard opens), logs evidence.
Coder side (only where Coder is installed and gets bus tasks):
  cprompt <ws> UserPromptSubmit  a bus task from jarvis titled «Зашить правило»: marker + work order.
  cclear <ws>  PostToolUse       a non-empty notify to "jarvis" clears it.
  cstop <ws>   Stop              report not sent: blocks once, then releases and logs the miss.

It never sends anything itself. Every call is logged without message text to
~/.claude-lab/shared/state/<agent>/rule-stitch/events.jsonl. Stop: touch that dir's STOP. Any error = allow.
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

LIB = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(LIB))
try:
    import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

    _CONF = guard_conf.load()
    TZ = ZoneInfo(_CONF.owner_timezone)
except Exception:  # noqa: BLE001 - a broken config or zone must not break the turn
    if __name__ == "__main__":
        sys.exit(0)
    raise
TASK_TTL_SEC = 6 * 3600
TITLE = "Зашить правило"
NOTE_TOOL = LIB / "feedback-note.py"

STITCH = re.compile(
    r"\bзаш(?:ей|ейте|ить|ивай|ивайте|ивает|ивают|ьёт|ьет|ьют|и|ил|ила|ите|ьем|ьём)\b"
    r"|\bпропиш\w*\s+(?:\w+\s+){0,2}правил"
    r"|\b(?:добав|внес|впиш|встав|постав)\w*\s+(?:\w+\s+){0,3}в\s+(?:\w+\s+)?правил", re.I)
NEG = re.compile(r"\bне\s+(?:надо\s+|нужно\s+)?(?:заш|пропис|добавл|внос)", re.I)
DONE = re.compile(r"зашил|зашит|правило\s+(?:уже\s+)?(?:стоит|записан|добавлен|внес[её]н|на месте)"
                  r"|записал[аи]?\s+(?:\w+\s+){0,2}правил|вн[её]с(?:ла|ли)?\s+(?:\w+\s+){0,3}в\s+правил"
                  r"|внес[её]н[оа]?\s+в\s+правил|готово[^.\n]{0,60}правил", re.I)
NOT_YET = re.compile(r"\b(?:не|ещё не|еще не|пока не)\s+(?:\w+\s+){0,2}?(?:заш|записал|внес|вн[её]с|добавил|стоит)",
                     re.I)
QUOTED = re.compile(r"«[^»]*»|\"[^\"]*\"|“[^”]*”")
SENT_SPLIT = re.compile(r"(?<=[.!?…])\s+|\n+")
INTER_RE = re.compile(r"\[Inter-agent from (\w[\w-]*) -> (\w[\w-]*)\]")
REPLY_TOOLS = ("mcp__dashi-channel__reply", "mcp__dashi-channel__edit_message")


def _detector():
    """correction-detector.py as a module: one definition of «the owner's own words» for both hooks."""
    spec = importlib.util.spec_from_file_location("correction_detector", Path(__file__).resolve().parent
                                                  / "correction-detector.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def state_dir(ws: str) -> Path:
    return _CONF.lab / "shared" / "state" / Path(ws).parent.name / "rule-stitch"


def now_local() -> datetime:
    return datetime.now(TZ)


def log(state: Path, event: dict) -> None:
    try:
        state.mkdir(parents=True, exist_ok=True)
        event = {"ts": now_local().strftime("%Y-%m-%d %H:%M:%S"), **event}
        with (state / "events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(event, ensure_ascii=False) + "\n")
    except OSError:
        pass


def marker_path(state: Path, session: str, side: str = "") -> Path:
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", session or "nosession")[:80]
    return state / f"{side}pending-{safe}.json"


def read_marker(mp: Path) -> dict | None:
    try:
        return json.loads(mp.read_text(encoding="utf-8")) if mp.exists() else None
    except (OSError, ValueError):
        return None


def write_marker(mp: Path, data: dict) -> None:
    try:
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass


def claims_done(text: str) -> bool:
    """A statement that the rule is in place: questions, quotes and «ещё не зашил» do not count."""
    for sent in SENT_SPLIT.split(text):
        s = QUOTED.sub(" ", sent)
        if "?" in s or NOT_YET.search(s):
            continue
        if DONE.search(s):
            return True
    return False


def asks_to_stitch(text: str) -> bool:
    return any(len(s) <= 600 and not NEG.search(s) and STITCH.search(s) for s in SENT_SPLIT.split(text))


def coder_installed() -> bool:
    return "coder" in _CONF.channel_agents


def done_cmd(ws: str, sess: str) -> str:
    return f'python3 {Path(__file__).resolve()} done {ws} --session {sess or "nosession"} --evidence "<what fired, where>"'


def instruction(ws: str, sess: str) -> str:
    d = now_local().strftime("%d.%m")
    hand = (f'Coder is on this server: the hook or script part goes to him in THIS turn: '
            f'mcp__gbrain-swarm__notify(to_agent="coder", payload={{"title": "{TITLE} {d}", "body": "{TITLE} '
            f'(слово владельца, {d}): «<the rule word for word>». Where it must fire. Backup of every file, a test '
            f'that shows it firing, report to me."}}). '
            if coder_installed() else
            "No Coder here: you build the check yourself (backup of every file first, then a test). ")
    return ("[rule-stitch] The owner asks to stitch a rule («зашей»). Stitched = it fires without your memory. "
            "In THIS turn:\n"
            f"  1) record the rule the one way: python3 {NOTE_TOOL} <memory dir> add --name <slug> --rule \"...\" "
            "--area \"...\" --source \"...\" (the correction hook prints the memory dir);\n"
            "  2) make it fire: a check inside the script that does this work, or a hook. " + hand + "\n"
            "  3) «готово / зашил» to the owner only after a live test showed the check firing; then run:\n"
            f"     {done_cmd(ws, sess)}\n"
            "Not a request to stitch a rule: do nothing, the turn ends by itself. Do not mention this hook to people.")


# ---------- main agent ----------

def mode_prompt(ws: str, p: dict) -> int:
    prompt = p.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip() or not _CONF.owner_tg_id:
        return 0
    state, sess = state_dir(ws), str(p.get("session_id") or "")
    text = _detector().owner_text(prompt)
    hit = bool(text) and asks_to_stitch(text)
    log(state, {"mode": "prompt", "session": sess, "hit": hit})
    if not hit:
        return 0
    write_marker(marker_path(state, sess), {"t": time.time(), "noted": False, "sent": False, "done": False})
    print(instruction(ws, sess))
    return 0


def deny(reason: str) -> int:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}, ensure_ascii=False))
    return 0


def fresh(m: dict | None) -> bool:
    return bool(m) and time.time() - float(m.get("t") or 0) <= TASK_TTL_SEC


def mode_guard(ws: str, p: dict) -> int:
    state, sess = state_dir(ws), str(p.get("session_id") or "")
    m = read_marker(marker_path(state, sess))
    if not fresh(m) or m.get("done") or str(p.get("tool_name") or "") not in REPLY_TOOLS:
        return 0
    ti = p.get("tool_input") or {}
    if not isinstance(ti, dict) or not claims_done(str(ti.get("text") or "")):
        return 0
    log(state, {"mode": "guard", "session": sess, "denied": "done-before-check", "sent": bool(m.get("sent"))})
    return deny("[rule-stitch] «Готово / зашил» only after a live test showed the check firing, then "
                f"`{done_cmd(ws, sess)}`. Now you can say what is done "
                "and what is still waiting (for example «принял, ставлю проверку, отпишусь после теста»).")


def _payload_text(ti: dict) -> str:
    pl = ti.get("payload")
    if isinstance(pl, str):
        try:
            pl = json.loads(pl)
        except ValueError:
            return pl
    if isinstance(pl, dict):
        return "\n".join(str(v) for v in pl.values() if isinstance(v, (str, int, float)))
    return ""


def note_written(p: dict) -> bool:
    ti = p.get("tool_input") or {}
    cmd = str(ti.get("command") or "") if isinstance(ti, dict) else ""
    if "feedback-note.py" not in cmd or not re.search(r"\badd\b", cmd):
        return False
    return "feedback-note: wrote" in json.dumps(p.get("tool_response"), ensure_ascii=False)


def tool_failed(p: dict) -> bool:
    resp = p.get("tool_response")
    if isinstance(resp, dict) and (resp.get("isError") or resp.get("is_error") or resp.get("error")):
        return True
    return bool(re.search(r'"(?:isError|is_error)"\s*:\s*true', json.dumps(resp, ensure_ascii=False)))


def mode_clear(ws: str, p: dict) -> int:
    state, sess = state_dir(ws), str(p.get("session_id") or "")
    mp = marker_path(state, sess)
    m = read_marker(mp)
    if m is None:
        return 0
    tool = str(p.get("tool_name") or "")
    ti = p.get("tool_input") or {}
    if tool == "Bash" and note_written(p):
        m["noted"] = True
    elif (tool == "mcp__gbrain-swarm__notify" and isinstance(ti, dict) and ti.get("to_agent") == "coder"
          and TITLE.lower() in _payload_text(ti).lower() and not tool_failed(p)):
        m["sent"] = True
    else:
        return 0
    write_marker(mp, m)
    log(state, {"mode": "clear", "session": sess, "noted": m.get("noted"), "sent": m.get("sent")})
    return 0


def _stop(state: Path, mp: Path, p: dict, settled, head: str, instr: str) -> int:
    m = read_marker(mp)
    if not m or settled(m) or m.get("released"):
        return 0
    if not fresh(m):
        try:
            mp.unlink(missing_ok=True)
        except OSError:
            pass
        return 0
    if p.get("stop_hook_active"):
        m["released"] = True  # no second block; the «готово» guard keeps the marker
        write_marker(mp, m)
        log(state, {"mode": "stop", "session": p.get("session_id"), "result": "released"})
        return 0
    log(state, {"mode": "stop", "session": p.get("session_id"), "result": "blocked"})
    print(json.dumps({"decision": "block", "reason": head + "\n" + instr}, ensure_ascii=False))
    return 0


def mode_stop(ws: str, p: dict) -> int:
    state = state_dir(ws)
    return _stop(state, marker_path(state, str(p.get("session_id") or "")), p,
                 lambda m: m.get("noted") or m.get("sent") or m.get("done"),
                 "Turn not closed: the owner asked to stitch a rule and nothing was recorded or handed over.",
                 instruction(ws, str(p.get("session_id") or "")))


def mode_done(ws: str, argv: list[str]) -> int:
    opts = dict(zip(argv[0::2], argv[1::2])) if len(argv) == 4 else {}
    sess, evidence = opts.get("--session", ""), opts.get("--evidence", "")
    if not sess or len(evidence.strip()) < 10:
        print('usage: rule-stitch-gate.py done <ws> --session <id> --evidence "<what fired, where>" (10+ chars)',
              file=sys.stderr)
        return 2
    state = state_dir(ws)
    mp = marker_path(state, sess)
    m = read_marker(mp)
    if not fresh(m):
        print(f"rule-stitch: no open request in session {sess}", file=sys.stderr)
        return 1
    m["done"] = True
    write_marker(mp, m)
    log(state, {"mode": "done", "session": sess, "evidence": " ".join(evidence.split())[:300]})
    print(f"rule-stitch: request of session {sess} marked done")
    return 0


# ---------- Coder ----------

def coder_instruction() -> str:
    d = now_local().strftime("%Y%m%d")
    return ("[rule-stitch] A «Зашить правило» task from jarvis. Order: 1) backup of every file before the edit "
            f"(cp -p <file> <file>.bak-{d}-coder-<topic>); 2) the check: inside the script that does the work, or a "
            "hook; 3) proof: a test or a live run that shows it firing; 4) report to jarvis in THIS turn: "
            'mcp__gbrain-swarm__notify(to_agent="jarvis", payload={"title": "Отчёт: <topic>", "body": "<files, what '
            'fired, backups, what did not work, how to stop>"}). Do not write to people.')


def jarvis_task_in(prompt: str) -> bool:
    if "<channel" not in prompt and not INTER_RE.search(prompt):
        return False
    m = INTER_RE.search(prompt)
    return bool(m) and m.group(1) == "jarvis" and TITLE.lower() in prompt.lower()


def mode_cprompt(ws: str, p: dict) -> int:
    prompt = p.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return 0
    state, sess = state_dir(ws), str(p.get("session_id") or "")
    hit = jarvis_task_in(prompt)
    log(state, {"mode": "cprompt", "session": sess, "hit": hit})
    if not hit:
        return 0
    write_marker(marker_path(state, sess, "c"), {"t": time.time(), "sent": False})
    print(coder_instruction())
    return 0


def mode_cclear(ws: str, p: dict) -> int:
    ti = p.get("tool_input") or {}
    if (not isinstance(ti, dict) or ti.get("to_agent") != "jarvis" or len(_payload_text(ti).strip()) < 20
            or tool_failed(p)):
        return 0
    state, sess = state_dir(ws), str(p.get("session_id") or "")
    mp = marker_path(state, sess, "c")
    had = mp.exists()
    try:
        mp.unlink(missing_ok=True)
    except OSError:
        pass
    log(state, {"mode": "cclear", "session": sess, "had_marker": had})
    return 0


def mode_cstop(ws: str, p: dict) -> int:
    state = state_dir(ws)
    return _stop(state, marker_path(state, str(p.get("session_id") or ""), "c"), p, lambda m: m.get("sent"),
                 "Turn not closed: the report on «Зашить правило» did not go to jarvis.", coder_instruction())


HOOK_MODES = {"prompt": mode_prompt, "guard": mode_guard, "clear": mode_clear, "stop": mode_stop,
              "cprompt": mode_cprompt, "cclear": mode_cclear, "cstop": mode_cstop}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return 0
    mode, ws = argv[0], argv[1]
    if (state_dir(ws) / "STOP").exists():
        return 0
    if mode == "done":
        return mode_done(ws, argv[2:])
    fn = HOOK_MODES.get(mode)
    if fn is None:
        return 0
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    return fn(ws, payload)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception:  # noqa: BLE001 - a gate must never break the turn
        sys.exit(0)
