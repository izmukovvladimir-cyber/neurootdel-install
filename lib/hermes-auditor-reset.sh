#!/usr/bin/env bash
# hermes-auditor-reset.sh -- 250k session reset of the Auditor (hermes-auditor), memory saved first.
# Installed by neurootdel-install into <lib dir> with the Auditor (stage intensive), settings from
# <lib dir>/guard.conf. Runs as the agent user from /etc/cron.d/<user>-hermes-reset every 10 min.
#
# Why its own script and not a line in agents-reset.sh: a hermes session lives in SQLite
# (~/.hermes/state.db) and survives a restart, so the Claude path (measure the JSONL, restart the
# unit) does not apply. hermes-session-reset.py marks the routing entry `suspended` and asks the
# root carrier (agents-root-requests.sh) to restart hermes-auditor; the engine starts a new session on
# the next message, injects its built-in memory (MEMORY.md / USER.md, memory_enabled) and a pointer
# to the previous session for session_search. That memory is the "handoff" of a hermes agent.
#
# Order of one tick:
#   1. dry run of hermes-session-reset.py at 250k (average turn, same judge as edgelab's Sanya);
#      any message of the engine younger than 15 min (any session, above the threshold or not)
#      holds the whole tick: the restart is engine-wide; checked again right before --apply;
#   2. a session over the threshold and no save bound to the CURRENT state of the sessions ->
#      hermes-memory-flush.py asks the agent (local api_server, the same session) to write what
#      matters into its memory, then the fingerprint of the sessions (message count and newest
#      message per routed session) is stored; the tick ends there, because the flush itself is a
#      turn and the live window holds the reset;
#   3. a later tick: fingerprint unchanged (nothing said since the save) and the session quiet ->
#      --apply with --restart-mode watchdog. Any new message changes the fingerprint -> save again;
#      a user message (other than the flush prompt) that arrived DURING the save voids that save.
#      The tool waits up to 1800 s (the carrier's EXPIRE) for the restart and holds the lock that
#      long, so a request that outlives the wait is dropped by the carrier, never run later.
#      A failed save holds the reset (no reset without a save); after STUCK_AFTER failed tries in a
#      row every tick logs STUCK so the log reader sees it.
# Pending restarts of marks already set go to --apply only when the save still matches the sessions.
#
# Flags: --dry-run (decides and prints, never saves, marks or restarts);
#        --nightly-flush (the nightly memory save only, in the 03:xx hour of the owner's clock).
# Stop: touch ~/.claude-lab/shared/state/hermes-auditor-reset/STOP (home of the agent user)
# Log: ~/.claude-lab/shared/state/hermes-auditor-reset/reset.log (cron redirect).
# Tests: HAR_TEST=1 with HAR_LIB (fake tools), HAR_ST (state dir), HAR_HOME (hermes home).
set -euo pipefail

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
[[ -f "$CONF" ]] || { echo "missing: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
HHOME="${AGENT_HOME:?AGENT_HOME missing in guard.conf}/.hermes"
ST="${AGENT_HOME}/.claude-lab/shared/state/hermes-auditor-reset"
if [ "${HAR_TEST:-0}" = 1 ]; then   # tests only: fake tools, a temp state dir and a temp state.db
    LIB="${HAR_LIB:?}"; ST="${HAR_ST:?}"; HHOME="${HAR_HOME:?}"
fi
export HERMES_RESET_STATE="$ST"
FLUSHED="$ST/flushed-fp"
FAILS="$ST/flush-fails"
THRESHOLD=250000
LIVE_WINDOW=900
STUCK_AFTER=3

DRY=0
NIGHT=0
for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY=1 ;;
        --nightly-flush) NIGHT=1 ;;
        *) echo "unknown argument: $_arg" >&2; exit 2 ;;
    esac
done

say() { printf '%s [auditor-reset%s] %s\n' "$(date -Is)" "$([ "$DRY" = 1 ] && echo ' dry-run')" "$*"; }

mkdir -p "$ST"
if [ -e "$ST/STOP" ]; then say "STOP file present, nothing done"; exit 0; fi

# --nightly-flush (hourly cron): only in the 03:xx hour of the OWNER's clock (OWNER_TIMEZONE), before
# the 04:00 reset of the other agents, the day's memory is saved even when no threshold reset is due.
# It takes the same lock as the reset ticks (run.lock, waits up to 40 min), so a reset never
# restarts the engine in the middle of that save.
if [ "$NIGHT" = 1 ]; then
    hour="${HAR_HOUR:-$(TZ="${OWNER_TIMEZONE:-Europe/Moscow}" date +%-H)}"
    [ "$hour" = 3 ] || exit 0
    # The hour is judged BEFORE the wait for the lock (a reset tick may hold it up to 30 min), so a
    # night that started at 03:xx is saved even when the lock frees after 04:00 (Codex r7).
    exec 9>>"$ST/run.lock"
    flock -w 2400 9 || { say "nightly memory save: lock busy for 40 min, skipped"; exit 0; }
    if [ "$DRY" = 1 ]; then
        python3 "$LIB/hermes-memory-flush.py" --home "$HHOME" --dry-run 2>&1 | while IFS= read -r line; do say "$line"; done
        exit 0
    fi
    nrc=0
    nout="$(timeout --kill-after=10s 960 python3 "$LIB/hermes-memory-flush.py" --home "$HHOME" --timeout 900 2>&1)" || nrc=$?
    while IFS= read -r line; do [ -n "$line" ] && say "$line"; done <<< "$nout"
    say "nightly memory save rc=$nrc"
    exit 0
fi

reset_tool() {
    python3 "$LIB/hermes-session-reset.py" --home "$HHOME" --service hermes-auditor \
        --threshold "$THRESHOLD" --live-window "$LIVE_WINDOW" \
        --restart-mode watchdog --carrier-wait 1800 "$@"
}

read_num() { local v=0; [ -f "$1" ] && v="$(tr -dc '0-9' < "$1" 2>/dev/null || true)"; echo "${v:-0}"; }

# Read-only look at state.db, one python for three questions (ERR on any failure):
#   fp              fingerprint of every routed session: id, message count, newest message;
#   live <window>   LIVE if ANY message of the engine is younger than <window> s, or a session's newest
#                   message is not a finished answer (a running turn, up to 2 h), else QUIET
#                   (the restart is engine-wide, a quiet fat session must not cut a busy one);
#   routes          fingerprint of the routing only: session key + session id of every entry;
#   foreign <t0>    user messages since <t0> that are not the flush prompt (a person spoke
#                   while the memory was being saved, so the save may not cover it).
state_q() {
    python3 -I - "$HHOME/state.db" "$LIB/hermes-memory-flush.py" "$@" <<'PYF' 2>/dev/null || echo ERR
import hashlib, importlib.util, json, sqlite3, sys, time
db, flush_py, mode = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
    if mode == "fp":
        out = []
        for key, ej in c.execute("select session_key, entry_json from gateway_routing order by session_key"):
            try:
                sid = json.loads(ej).get("session_id") or ""
            except (ValueError, AttributeError):
                sid = ""
            n, newest = c.execute("select count(*), max(timestamp) from messages where session_id=?",
                                  (sid,)).fetchone()
            out.append(f"{key}|{sid}|{n}|{newest}")
        print(hashlib.sha256("\n".join(out).encode()).hexdigest())
    elif mode == "routes":
        rows = sorted(c.execute("select session_key, entry_json from gateway_routing"))
        out = []
        for key, ej in rows:
            try:
                sid = json.loads(ej).get("session_id") or ""
            except (ValueError, AttributeError):
                sid = ""
            out.append(f"{key}|{sid}")
        print(hashlib.sha256("\n".join(out).encode()).hexdigest())
    elif mode == "live":
        newest = c.execute("select max(timestamp) from messages").fetchone()[0] or 0
        # A turn inside one long tool call writes nothing for minutes: its session's newest message is not
        # a finished answer. Such a turn (younger than 2 h) counts as live too (Codex r12).
        busy = 0
        for role, finish, calls, ts in c.execute("select m.role, m.finish_reason, m.tool_calls, m.timestamp from messages m where m.rowid = (select m2.rowid from messages m2 where m2.session_id = m.session_id order by m2.timestamp desc, m2.rowid desc limit 1)"):
            done = role == "assistant" and finish != "tool_calls" and calls in (None, "", "[]")
            if not done and time.time() - (ts or 0) < 7200:
                busy += 1
        print("LIVE" if busy or time.time() - newest < float(sys.argv[4]) else "QUIET")
    elif mode == "foreign":
        spec = importlib.util.spec_from_file_location("hflush", flush_py)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        n = c.execute("select count(*) from messages where role='user' and timestamp >= ? "
                      "and (content is null or content != ?)", (float(sys.argv[4]), m.FLUSH_PROMPT)).fetchone()[0]
        print(n)
    else:
        print("ERR")
    c.close()
except (sqlite3.Error, OSError, AttributeError, ValueError, IndexError):
    print("ERR")
PYF
}

engine_quiet() {  # rc 0 only when the whole engine is quiet for LIVE_WINDOW
    local v
    v="$(state_q live "$LIVE_WINDOW")"
    [ "$v" = QUIET ] && return 0
    say "engine not quiet for ${LIVE_WINDOW}s ($v): nothing done this tick"
    return 1
}

rc=0
plan="$(reset_tool 2>&1)" || rc=$?
while IFS= read -r line; do [ -n "$line" ] && say "$line"; done <<< "$plan"
if [ "$rc" != 0 ]; then
    say "plan rc=$rc (8 = live turn, 11 = entries unreadable): nothing done this tick"
    exit 0
fi
if [[ "$plan" == *"ЖИВОЙ ход"* ]]; then
    # the restart is engine-wide: one live session holds the reset of every other one (Codex r1)
    say "a live session holds the engine-wide restart: nothing done this tick"
    exit 0
fi

marks=0; restarts=0
re='пометил бы ([0-9]+) сессий, рестартовал бы ради ([0-9]+)'
if [[ "$plan" =~ $re ]]; then
    marks="${BASH_REMATCH[1]}"; restarts="${BASH_REMATCH[2]}"
fi
if [ "$marks" = 0 ] && [ "$restarts" = 0 ]; then
    exit 0
fi
engine_quiet || exit 0

# The save must cover the CURRENT state for new marks AND for pending restarts of marks already set:
# a restart that was withdrawn (a person wrote) leaves its marks, and the words said since then must be
# saved before the engine restarts (Codex r2).
if [ "$marks" -gt 0 ] || [ "$restarts" -gt 0 ]; then
    fp_now="$(state_q fp)"
    fp_saved=""; [ -f "$FLUSHED" ] && fp_saved="$(cat "$FLUSHED" 2>/dev/null || true)"
    if [ "$fp_now" = ERR ]; then
        say "sessions fingerprint unreadable: reset held"
        exit 0
    fi
    if [ "$fp_now" != "$fp_saved" ]; then
        if [ "$DRY" = 1 ]; then
            say "would save memory first (hermes-memory-flush.py), reset at a later tick"
            exit 0
        fi
        fails="$(read_num "$FAILS")"
        t0="$(date +%s)"
        routes_before="$(state_q routes)"
        frc=0
        fout="$(timeout --kill-after=10s 960 python3 "$LIB/hermes-memory-flush.py" --home "$HHOME" \
                 --all-sessions --timeout 900 2>&1)" || frc=$?
        while IFS= read -r line; do [ -n "$line" ] && say "$line"; done <<< "$fout"
        fp_after="$(state_q fp)"
        foreign="$(state_q foreign "$t0")"
        # Read AFTER fp_after: a route switched between the save and that snapshot shows here (Codex r9).
        routes_after="$(state_q routes)"
        if [ "$frc" = 0 ] && { [ "$routes_before" = ERR ] || [ "$routes_after" != "$routes_before" ]; }; then
            say "the set of sessions changed during the memory save: save not recorded, saving again later"
        elif [ "$frc" = 0 ] && [ "$fp_after" != ERR ] && [ "$foreign" != 0 ]; then
            # a person spoke during the save: not recorded, the next tick saves again
            say "a message arrived during the memory save (foreign=$foreign): save not recorded, saving again later"
        elif [ "$frc" = 0 ] && [ "$fp_after" != ERR ]; then
            printf '%s\n' "$fp_after" > "$FLUSHED"; rm -f "${FAILS:?}"
            say "memory saved; reset follows at a later tick if nothing is said meanwhile"
        else
            echo $(( fails + 1 )) > "$FAILS"
            say "memory save failed rc=$frc fp=$fp_after (try $(( fails + 1 ))): reset held, no reset without a save"
            [ $(( fails + 1 )) -ge "$STUCK_AFTER" ] && say "STUCK: memory save failed $(( fails + 1 )) times in a row, session keeps growing"
        fi
        exit 0
    fi
fi

engine_quiet || exit 0
if [ "$DRY" = 1 ]; then
    say "would run the reset with --apply (marks=$marks, pending restarts=$restarts)"
    exit 0
fi
arc=0
aout="$(reset_tool --apply --expect-fp "$fp_saved" 2>&1)" || arc=$?
while IFS= read -r line; do [ -n "$line" ] && say "$line"; done <<< "$aout"
if [ "$arc" = 0 ] && [ "$marks" -gt 0 ]; then
    rm -f "${FLUSHED:?}" "${FAILS:?}"
fi
say "apply rc=$arc"
exit 0
