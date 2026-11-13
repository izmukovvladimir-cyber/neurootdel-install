#!/usr/bin/env python3
"""Text critics gate: a text for people the two critics REJECTED does not go out as is; an unreviewed one is
journaled. Ported from a live team gate in its «record + report» form: a gate that denied every unreviewed
post was tried there and left off on purpose, it would have stopped any post.

Installed by neurootdel-install. Armed only while the editorial loop is on (EDITORIAL_ENABLED=1 in
~/.claude-lab/shared/editorial.conf); switched off it lets everything through and writes nothing.

Hook (PreToolUse on mcp__dashi-channel__reply / edit_message, argv[1] = state dir, shared by the agents:
~/.claude-lab/shared/state/critics):
  - a text for people (the same formal mark as the text standard gate: a short intro line ending with «:»
    that hands over a piece, see fact-check-gate.py part 4) or a .md/.txt attachment carrying that mark;
  - the exact piece was approved by both critics or overridden: passes;
  - the critics returned exactly this piece without two APPROVE: denied with what to do;
  - never seen by the critics: passes and is journaled as «unreviewed» (gate.jsonl; `report` sums it up).
text-critics.sh writes every finished run into the ledger (`record`), so the agent does nothing extra.

CLI:
    record   --state D --path DRAFT --file SNAPSHOT --v1 V --v2 V     (text-critics.sh)
    override --state D --file DRAFT --reason WHY   after MAX_ROUNDS rejected rounds of that draft or a critic
                                                   failure on it; journaled
    report   [--state D] [--hours H]               unreviewed sends and denies of the window
Stop: touch <state>/STOP. Any error in the hook = allow (journaled).
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

HOOKS = Path(__file__).resolve().parent
sys.path.insert(0, str(HOOKS.parent))
try:
    import guard_conf  # noqa: E402  (lives one level up, next to guard.conf)

    _CONF = guard_conf.load()
except Exception:  # noqa: BLE001 - as a hook a broken config never blocks a reply; the CLI shows the error
    if __name__ == "__main__" and len(sys.argv) == 2 and sys.argv[1] not in {"record", "override", "report"}:
        sys.exit(0)
    raise
DEFAULT_STATE = str(_CONF.lab / "shared" / "state" / "critics")
EDITORIAL_CONF = _CONF.lab / "shared" / "editorial.conf"
CRITICS = HOOKS.parent / "text-critics.sh"
MAX_ROUNDS = 4
ROUNDS_WINDOW_SEC = 24 * 3600
FAIL_WINDOW_SEC = 2 * 3600
MIN_REASON_LEN = 20
PLAIN_DOCS = {".md", ".txt"}
LEADING_MENTION = re.compile(r"^@\w+[ \t]+")
VERDICTS_OK = {"APPROVE", "REQUEST_CHANGES"}


def _fact_gate():
    """fact-check-gate.py as a module: one definition of «a finished text for people» for both gates."""
    spec = importlib.util.spec_from_file_location("fact_check_gate", HOOKS / "fact-check-gate.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@dataclass(frozen=True)
class Verdict:
    allow: bool
    reason: str = ""
    code: str = "pass"


def editorial_on(conf: Path = EDITORIAL_CONF) -> bool:
    try:
        with conf.open(encoding="utf-8") as fh:
            vals = [ln.split("=", 1)[1].strip().strip("\"'") for ln in fh if ln.startswith("EDITORIAL_ENABLED=")]
    except OSError:
        return False
    return bool(vals) and vals[-1] == "1"


def normalize(text: str) -> str:
    """Canonical form: markup added at sending time does not change the hash."""
    text = text.replace("\r\n", "\n").replace("**", "")
    lines = [line.rstrip() for line in text.split("\n")]
    text = re.sub(r"\n{2,}", "\n\n", "\n".join(lines)).strip()
    return LEADING_MENTION.sub("", text)


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def candidates(text: str, intro: str | None) -> set[str]:
    """Hashes that may match a ledger row: the whole message, and the piece after its intro line."""
    found = {sha(normalize(text))}
    if intro:
        clean = text.replace("\r\n", "\n").strip()
        for sep in ("\n\n", "\n"):
            head, _, rest = clean.partition(sep)
            if rest.strip() and intro.rstrip(":").strip() in re.sub(r"[*_`]+", "", head):
                found.add(sha(normalize(rest)))
    return found


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rows: list[dict] = []
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
    return rows


def append_jsonl(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def ledger(state: Path) -> Path:
    return state / "ledger.jsonl"


def journal(state: Path) -> Path:
    return state / "gate.jsonl"


def latest_state(rows: list[dict]) -> dict[str, bool]:
    """sha -> True (approved or overridden) / False (rejected); the LAST run or override of a text decides."""
    state: dict[str, bool] = {}
    for r in rows:
        if "sha" not in r:
            continue
        if r.get("event") == "override":
            state[r["sha"]] = True
        elif r.get("event") == "run":
            state[r["sha"]] = r.get("v1") == "APPROVE" and r.get("v2") == "APPROVE"
    return state


def approved_hashes(rows: list[dict]) -> set[str]:
    return {k for k, ok in latest_state(rows).items() if ok}


def rejected_hashes(rows: list[dict]) -> set[str]:
    return {k for k, ok in latest_state(rows).items() if not ok}


def deny_text(what: str, state: Path) -> str:
    return (f"[critics-gate] {what}: the critics returned exactly this text without two APPROVE. Fix it by their "
            f"notes, run {CRITICS} <draft file> again and send exactly the approved text (one intro line before it "
            f"is fine). After {MAX_ROUNDS} rounds or a critic failure: python3 {Path(__file__).resolve()} override "
            f"--state {state} --file <draft> --reason \"why\"; the override is journaled.")


def decide(args: dict, state: Path, people_intro) -> Verdict:
    rows = read_jsonl(ledger(state))
    approved, rejected = approved_hashes(rows), rejected_hashes(rows)
    text = str(args.get("text") or "")
    notes: list[str] = []
    intro = people_intro(text) if text else None
    if intro:
        cands = candidates(text, intro)
        if not approved & cands:
            if rejected & cands:
                return Verdict(False, deny_text("Text for people", state), "deny-text")
            notes.append("unreviewed-text")
    for raw in args.get("files") or []:
        path = Path(str(raw))
        if path.suffix.lower() not in PLAIN_DOCS:
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            notes.append(f"unreadable-file:{path.name}")
            continue
        file_intro = people_intro(content)
        if not file_intro:
            continue
        cands = candidates(content, file_intro)
        if not approved & cands:
            if rejected & cands:
                return Verdict(False, deny_text(f"File {path.name}", state), "deny-file")
            notes.append(f"unreviewed-file:{path.name}")
    if notes:
        return Verdict(True, "; ".join(notes), "unreviewed")
    return Verdict(True)


def cmd_record(ns: argparse.Namespace) -> int:
    text = Path(ns.file).read_text(encoding="utf-8")
    append_jsonl(ledger(Path(ns.state)), {"ts": time.time(), "event": "run", "path": str(Path(ns.path).resolve()),
                                          "sha": sha(normalize(text)), "v1": ns.v1, "v2": ns.v2})
    return 0


def rounds_since_clean(rows: list[dict], path: str, now: float) -> int:
    count = 0
    for row in reversed(rows):
        if row.get("path") != path or now - float(row.get("ts", 0)) > ROUNDS_WINDOW_SEC:
            continue
        if row.get("event") == "override" or (row.get("v1") == "APPROVE" and row.get("v2") == "APPROVE"):
            break
        count += 1
    return count


def critic_failed(rows: list[dict], digest: str, now: float) -> bool:
    return any(r.get("event") == "run" and r.get("sha") == digest
               and now - float(r.get("ts", 0)) <= FAIL_WINDOW_SEC
               and not {r.get("v1"), r.get("v2")} <= VERDICTS_OK for r in rows)


def cmd_override(ns: argparse.Namespace) -> int:
    state, path = Path(ns.state), Path(ns.file).resolve()
    reason = " ".join(ns.reason.split())
    if len(reason) < MIN_REASON_LEN:
        print(f"REFUSED: the reason is shorter than {MIN_REASON_LEN} chars", file=sys.stderr)
        return 2
    rows, now = read_jsonl(ledger(state)), time.time()
    digest = sha(normalize(path.read_text(encoding="utf-8")))
    rounds = rounds_since_clean(rows, str(path), now)
    failed = critic_failed(rows, digest, now)
    if rounds < MAX_ROUNDS and not failed:
        print(f"REFUSED: {rounds} of {MAX_ROUNDS} rounds, no critic failure on this text. Run {CRITICS}",
              file=sys.stderr)
        return 2
    row = {"ts": now, "event": "override", "path": str(path), "sha": digest, "reason": reason,
           "rounds": rounds, "critic_failed": failed}
    append_jsonl(journal(state), row)
    append_jsonl(ledger(state), row)
    print(f"override journaled: rounds {rounds}, critic failure: {failed}, sha256={digest}")
    return 0


def cmd_report(ns: argparse.Namespace) -> int:
    since = time.time() - ns.hours * 3600
    rows = [r for r in read_jsonl(journal(Path(ns.state))) if float(r.get("ts", 0)) >= since]
    by: dict[str, int] = {}
    for r in rows:
        by[str(r.get("event"))] = by.get(str(r.get("event")), 0) + 1
    print(f"Critics, last {ns.hours:g} h: " + (", ".join(f"{k}={v}" for k, v in sorted(by.items())) or "no events"))
    tz = ZoneInfo(_CONF.owner_timezone)
    for r in rows:
        if r.get("event") in ("unreviewed", "deny-text", "deny-file", "override"):
            when = datetime.fromtimestamp(float(r["ts"]), tz).strftime("%d.%m %H:%M")
            print(f"- {when} {r.get('event')} chat={r.get('chat', '')} sha={str(r.get('sha', ''))[:12]} "
                  f"{r.get('detail', '')}")
    return 0


def hook(state: Path) -> int:
    if (state / "STOP").exists() or not editorial_on():
        return 0
    chat, digest = "", ""
    try:
        payload = json.load(sys.stdin)
        if not str(payload.get("tool_name", "")).endswith(("__reply", "__edit_message")):
            return 0
        args = payload.get("tool_input") or {}
        chat, digest = str(args.get("chat_id", "")), sha(normalize(str(args.get("text") or "")))
        verdict = decide(args, state, _fact_gate().people_intro)
    except (ValueError, OSError, AttributeError, TypeError, ImportError) as err:
        verdict = Verdict(True, type(err).__name__, "error-fail-open")
    if verdict.code != "pass":
        try:
            append_jsonl(journal(state), {"ts": time.time(), "event": verdict.code, "chat": chat, "sha": digest,
                                          "detail": verdict.reason[:160]})
        except OSError:
            pass
    if not verdict.allow:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": verdict.reason}}, ensure_ascii=False))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 1 and argv[0] not in {"record", "override", "report"}:
        return hook(Path(argv[0]))
    parser = argparse.ArgumentParser(prog="text-critics-gate.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    rec, over, rep = sub.add_parser("record"), sub.add_parser("override"), sub.add_parser("report")
    for item in (rec, over, rep):
        item.add_argument("--state", default=DEFAULT_STATE)
    for item in (rec, over):
        item.add_argument("--file", required=True)
    rec.add_argument("--path", required=True)
    rec.add_argument("--v1", required=True)
    rec.add_argument("--v2", required=True)
    over.add_argument("--reason", required=True)
    rep.add_argument("--hours", type=float, default=24.0)
    ns = parser.parse_args(argv)
    return {"record": cmd_record, "override": cmd_override, "report": cmd_report}[ns.cmd](ns)


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] not in {"record", "override", "report"}:
        try:
            sys.exit(main(sys.argv[1:]))
        except Exception:  # noqa: BLE001 - the hook never blocks a reply on its own failure
            sys.exit(0)
    sys.exit(main(sys.argv[1:]))
