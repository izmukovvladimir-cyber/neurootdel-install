#!/usr/bin/env python3
"""Nightly run of lib/agents-reset.sh resets EVERY agent regardless of context; daytime keeps the threshold.

Runs a copy of agents-reset.sh in a temp sandbox: guard.conf points AGENT_HOME into a temp dir, the
sensors and the restart are replaced by stubs right before the main part, sleep is a no-op. Nothing
real is touched. Every behaviour check has a control against a mutated source.
Run: python3 tests/test_night_reset.py
"""
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESET = REPO / "lib" / "agents-reset.sh"
INSTALL = REPO / "install.sh"
WATCHDOG = REPO / "lib" / "cron-manifest-watchdog.sh"
AGENTS = ["jarvis", "coder", "secretary"]

PASS = 0
FAIL = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name} {detail}")


# Stubs: ctx of every agent is 1000 (far below 250k). BUSY_<agent>=N makes the agent's turn look
# live for its first N looks (newest_turn_ts is asked twice per pass when idle, once when live).
# FLUSHFAIL_<agent>=N makes the first N flushes of the agent fail.
STUBS = r'''
on_hold() { return 1; }
has_active_tasks() { return 1; }
pane_busy() { return 1; }
running_job() { echo NONE; }
agent_context_size() { printf '1000\t/tmp/%s.jsonl\n' "$1"; }
newest_turn_ts() {
    local f="$SANDBOX/looks.$1" n=0 busy
    [ -f "$f" ] && n="$(cat "$f")"
    n=$(( n + 1 )); echo "$n" > "$f"
    busy="$(eval echo "\${BUSY_$1:-0}")"
    if [ "$n" -le "$busy" ]; then date +%s; else echo 1000; fi
}
send_reset() { echo "$1" >> "$SANDBOX/resets"; return 0; }
sleep() { echo "$1" >> "$SANDBOX/sleeps"; if [ -n "${STOP_ON_SLEEP:-}" ]; then touch "$STATE/STOP"; fi; }
'''

FLUSH = '''import os, sys, pathlib
agent = sys.argv[-1]
sb = pathlib.Path({sb!r})
with (sb / "flushes").open("a") as fh:
    fh.write(agent + "\\n")
cnt = sb / ("flushcount." + agent)
n = int(cnt.read_text()) + 1 if cnt.exists() else 1
cnt.write_text(str(n))
if n <= int(os.environ.get("FLUSHFAIL_" + agent, "0")):
    print("flush failed", agent)
    raise SystemExit(1)
print("flushed", agent)
'''

# `date +%-H` / `date +%-M` answer the owner-clock question of --auto; everything else is real date.
FAKE_DATE = '''#!/bin/bash
for a in "$@"; do
    case "$a" in
        +%-H) echo "${FAKE_HOUR:?}"; exit 0 ;;
        +%-M) echo "${FAKE_MIN:?}"; exit 0 ;;
    esac
done
exec /bin/date "$@"
'''


def build(src: str, sandbox: Path) -> Path:
    lib = sandbox / "lib"
    lib.mkdir()
    (lib / "agent-handoff-flush.py").write_text(FLUSH.format(sb=str(sandbox)), encoding="utf-8")
    (lib / "include_weight.py").write_text("print('w')\n", encoding="utf-8")
    (lib / "guard.conf").write_text(
        f'AGENT_HOME="{sandbox}/home"\nCHANNEL_AGENTS="{" ".join(AGENTS)}"\nOWNER_TIMEZONE="UTC"\n',
        encoding="utf-8")
    anchor = 'log "=== agents-reset start ==="'
    assert anchor in src
    src = src.replace(anchor, f"SANDBOX={sandbox}\n{STUBS}\n{anchor}", 1)
    script = lib / "agents-reset.sh"
    script.write_text(src, encoding="utf-8")
    fb = sandbox / "fakebin"
    fb.mkdir()
    (fb / "date").write_text(FAKE_DATE, encoding="utf-8")
    (fb / "date").chmod(0o755)
    return script


def run(src: str, args: list[str], env: dict[str, str] | None = None) -> dict[str, object]:
    sandbox = Path(tempfile.mkdtemp(prefix="tnight-"))
    try:
        script = build(src, sandbox)
        p = subprocess.run(["bash", str(script), *args], capture_output=True, text=True, timeout=120,
                           env={"PATH": f"{sandbox}/fakebin:/usr/local/bin:/usr/bin:/bin", **(env or {})})

        def lines(name: str) -> list[str]:
            f = sandbox / name
            return f.read_text().split() if f.exists() else []

        log = sandbox / "home" / ".claude-lab" / "shared" / "state" / "agents-reset" / "agents-reset.log"
        return {"rc": p.returncode, "resets": lines("resets"), "flushes": lines("flushes"),
                "sleeps": lines("sleeps"), "log": log.read_text() if log.exists() else "",
                "err": p.stderr[-500:]}
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def main() -> None:
    src = RESET.read_text(encoding="utf-8")
    everyone = sorted(AGENTS)

    print("== 1. at night everyone is reset, in the daytime only above the threshold ==")
    r = run(src, ["--night"])
    check("--night: every agent reset at ctx 1000", sorted(r["resets"]) == everyone, str(r))
    check("--night: every agent flushed before the reset", sorted(r["flushes"]) == everyone, str(r["flushes"]))
    check("--night: no waiting when nobody is busy", r["sleeps"] == [], str(r["sleeps"]))
    check("--night: log tag night-all", "[night-all]" in r["log"], r["log"][-300:])
    r = run(src, ["--daytime"])
    check("--daytime: nobody at ctx 1000", r["resets"] == [] and r["rc"] == 0, str(r))
    r = run(src, [])
    check("no flag (manual run): 250k threshold as before", r["resets"] == [] and r["rc"] == 0, str(r))
    r = run(src, ["--night", "--daytime"])
    check("--night with --daytime: refused rc 2", r["rc"] == 2 and r["resets"] == [], str(r))
    r = run(src, ["--auto", "--night"])
    check("--auto with --night: refused rc 2", r["rc"] == 2 and r["resets"] == [], str(r))

    print("== 2. --auto picks the run by the owner's clock ==")
    r = run(src, ["--auto"], {"FAKE_HOUR": "4", "FAKE_MIN": "0"})
    check("--auto 04:00: night-all, every agent reset", sorted(r["resets"]) == everyone and "[night-all]" in r["log"],
          str(r))
    r = run(src, ["--auto"], {"FAKE_HOUR": "12", "FAKE_MIN": "0"})
    check("--auto 12:00: daytime, nobody at ctx 1000", r["resets"] == [] and "[day]" in r["log"], str(r))
    r = run(src, ["--auto"], {"FAKE_HOUR": "4", "FAKE_MIN": "10"})
    check("--auto 04:10: outside every window, nothing runs", r["resets"] == [] and r["log"] == "", str(r))

    print("== 3. a busy agent is not torn at night: wait and retry ==")
    r = run(src, ["--night"], {"BUSY_jarvis": "2"})
    check("busy jarvis reset on a retry", r["resets"].count("jarvis") == 1, str(r["resets"]))
    check("the others reset exactly once", all(r["resets"].count(a) == 1 for a in everyone), str(r["resets"]))
    check("jarvis reset last (after the wait)", r["resets"][-1:] == ["jarvis"], str(r["resets"]))
    check("two waits of 600 s", r["sleeps"] == ["600", "600"], str(r["sleeps"]))
    check("jarvis flushed again before each retry", r["flushes"].count("jarvis") == 3, str(r["flushes"]))
    r = run(src, ["--night"], {"BUSY_jarvis": "999"})
    check("always busy: not reset", "jarvis" not in r["resets"], str(r["resets"]))
    check("always busy: 6 retries, then gives up", len(r["sleeps"]) == 6 and "gave up" in r["log"], str(r["sleeps"]))
    check("always busy: the others still reset", sorted(r["resets"]) == sorted(a for a in AGENTS if a != "jarvis"),
          str(r["resets"]))
    r = run(src, ["--night"], {"FLUSHFAIL_coder": "1"})
    check("failed flush: retried and reset after a good flush",
          r["resets"].count("coder") == 1 and r["sleeps"] == ["600"], str(r))
    r = run(src, ["--night"], {"BUSY_jarvis": "999", "STOP_ON_SLEEP": "1"})
    check("STOP during the wait: no more retries", len(r["sleeps"]) == 1 and "no more retries" in r["log"], str(r))
    r = run(src, ["--night", "--dry-run"], {"BUSY_jarvis": "999"})
    check("--dry-run: no wait, logs «would wait»",
          r["sleeps"] == [] and "would wait" in r["log"] and sorted(r["flushes"]) == everyone, str(r))
    r = run(src, ["--daytime"], {"BUSY_jarvis": "999"})
    check("--daytime: a busy agent is never waited for", r["sleeps"] == [], str(r["sleeps"]))

    print("== 4. cron and the schedule watchdog agree ==")
    inst = INSTALL.read_text(encoding="utf-8")
    m = re.search(r'_install_cron_file "\$\{AGENT_USER\}-agents-reset" "\$\(cat <<CRON\n(.*?)\nCRON', inst, re.S)
    cron = m.group(1) if m else ""
    jobs = [ln for ln in cron.splitlines() if ln and not ln.startswith("#") and "agents-reset.sh" in ln]
    check("one */10 cron line, run picked by --auto", len(jobs) == 1 and jobs[0].startswith("*/10 * * * *")
          and "agents-reset.sh --auto >>" in jobs[0], str(jobs))
    wd = WATCHDOG.read_text(encoding="utf-8")
    needles = re.findall(r'"\$CD/\$\{U\}-agents-reset::(.*?)::', wd)
    check("watchdog needles for the reset slot are all in the cron line",
          bool(needles) and all(n in (jobs[0] if jobs else "") for n in needles), str(needles))

    print("== 5. controls ==")
    mut = src.replace("    CTX_THRESHOLD=0\n", "", 1)
    r = run(mut, ["--night"])
    check("control: without the zero threshold nobody would be reset", sorted(r["resets"]) != everyone,
          str(r["resets"]))
    mut = src.replace('[ "$NIGHT_ALL" = 1 ] || break', "break", 1)
    r = run(mut, ["--night"], {"BUSY_jarvis": "2"})
    check("control: without the retry loop the busy one stays", "jarvis" not in r["resets"], str(r["resets"]))
    mut = src.replace("        NIGHT_ALL=1\n    elif", "    elif", 1)
    r = run(mut, ["--auto"], {"FAKE_HOUR": "4", "FAKE_MIN": "0"})
    check("control: --auto night window without night-all resets nobody", r["resets"] == [], str(r["resets"]))
    check("control: the mutants differ from the source",
          re.search(r"^    CTX_THRESHOLD=0$", src, re.M) is not None and '[ "$NIGHT_ALL" = 1 ] || break' in src
          and "        NIGHT_ALL=1\n    elif" in src)

    print(f"\n{PASS} passed, {FAIL} failed")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
