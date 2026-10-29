#!/usr/bin/env bash
# agents-reset.sh -- reset bloated Claude sessions of the channel agents.
# Installed by neurootdel-install into <lib dir>; settings come from <lib dir>/guard.conf.
# Order of checks:
#   0. handoff-flush for every agent ("Last 15 actions" into core/hot/handoff.md), per agent;
#      an agent whose flush failed is NOT reset (the reset would lose its day);
#   1. hold-file, live turn (transcript timestamps, 15 min window), background job in the unit;
#   2. context = cache_read of the last turn of the newest session; reset only above the threshold
#      (250k; an agent with a task in progress on the board gets 350k in the daytime run);
#   3. second look at turn time and background job right before the restart;
#   4. reset = sudo systemctl restart channel-<agent>, with a QUIET marker so channel-confirm.sh
#      skips the resume-nudge: an automatic reset must never send anything to a person.
#
# Cron (/etc/cron.d/<user>-agents-reset, runs as the agent user): */10 * * * * --auto.
# --auto picks the run by the OWNER's clock (guard.conf OWNER_TIMEZONE), whatever the
# server timezone: nightly at 04:00-04:09, --daytime 06:00-22:59, nothing otherwise.
# Flags: --auto, --daytime, --dry-run (decides and logs into $LOG; never writes handoff, streak/hold
# files or the quiet marker, never restarts). The log line is the point of a dry run.
# Stop: touch ~/.claude-lab/shared/state/agents-reset/STOP
# Hold one agent through a date (owner timezone): echo 2026-10-30 > .../agents-reset/hold/<agent>
# Richard (claude-richard, SDK sessions) is NOT reset here.
set -euo pipefail

DAYTIME=0
DRY=0
AUTO=0
for _arg in "$@"; do
    case "$_arg" in
        --auto) AUTO=1 ;;
        --daytime) DAYTIME=1 ;;
        --dry-run) DRY=1 ;;
        *) echo "unknown argument: $_arg" >&2; exit 2 ;;
    esac
done

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
[ -f "$CONF" ] || { echo "missing: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
STATE="$AGENT_HOME/.claude-lab/shared/state/agents-reset"
LOG="$STATE/agents-reset.log"
HOLD_DIR="$STATE/hold"
STREAK_DIR="$STATE/skip-streak"
QUIET_DIR="$AGENT_HOME/.claude-lab/shared/state/quiet-restart"
PROJECTS_DIR="$AGENT_HOME/.claude/projects"
OWNER_TZ="${OWNER_TIMEZONE:-Europe/Moscow}"
if [ "$AUTO" = 1 ]; then
    _h="$(TZ="$OWNER_TZ" date +%-H)"; _m="$(TZ="$OWNER_TZ" date +%-M)"
    if [ "$_h" -eq 4 ] && [ "$_m" -lt 10 ]; then
        DAYTIME=0
    elif [ "$_h" -ge 6 ] && [ "$_h" -le 22 ]; then
        DAYTIME=1
    else
        exit 0
    fi
fi
mkdir -p "$STATE" "$HOLD_DIR" "$STREAK_DIR" "$QUIET_DIR"

read -r -a AGENTS <<< "${CHANNEL_AGENTS:-jarvis}"
CTX_THRESHOLD=250000
DAY_CTX_BUSY_THRESHOLD=350000
LIVE_TURN_WINDOW=900
JOB_ERR_MAX_STREAK=6
STREAK_ALERT=3

tag=night; [ "$DAYTIME" = 1 ] && tag=day; [ "$DRY" = 1 ] && tag="$tag dry-run"
log() {
    echo "$(date -Is) [$tag] $*" >> "$LOG"
    if [ "$DRY" = 1 ] || [ -t 2 ]; then echo "$(date -Is) [$tag] $*" >&2; fi
}

if [ -e "$STATE/STOP" ]; then
    log "STOP file present, nothing done"
    exit 0
fi

note_skip() {
    local f="$STREAK_DIR/$1" n=0
    [ -f "$f" ] && n="$(tr -dc '0-9' < "$f" 2>/dev/null || true)"
    n=$(( ${n:-0} + 1 ))
    [ "$DRY" = 1 ] || echo "$n" > "$f" 2>/dev/null || true
    echo "$n"
}
note_reset() { [ "$DRY" = 1 ] || rm -f "${STREAK_DIR:?}/$1" 2>/dev/null || true; }

on_hold() {
    local f="$HOLD_DIR/$1" through today norm
    [ -f "$f" ] || return 1
    through="$(tr -d '[:space:]' < "$f" 2>/dev/null || true)"
    [[ "$through" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    norm="$(TZ="$OWNER_TZ" date -d "$through" +%F 2>/dev/null || true)"
    [ "$norm" = "$through" ] || return 1
    today="$(TZ="$OWNER_TZ" date +%F)"
    if [[ "$today" > "$through" ]]; then
        [ "$DRY" = 1 ] || rm -f "$f" 2>/dev/null || true
        return 1
    fi
    return 0
}

# rc 0 = has progress tasks, 1 = none, 2 = unknown (treated as none).
# Only with a task board client (gbrain-call.py) next to this script; without it: rc 2.
has_active_tasks() {
    local agent="$1" out n
    [ -f "$LIB/gbrain-call.py" ] || return 2
    out="$(timeout 30 python3 "$LIB/gbrain-call.py" "$agent" tasks task_list \
            "{\"assignee\":\"$agent\",\"status\":\"progress\"}" 2>/dev/null)" || return 2
    n="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    print("ERR"); raise SystemExit(0)
if isinstance(d, dict):
    d = d.get("result") or d.get("tasks") or []
print(len(d) if isinstance(d, list) else "ERR")
' <<< "$out")"
    [[ "$n" =~ ^[0-9]+$ ]] || return 2
    [ "$n" -gt 0 ]
}

# Claude Code project dir prefix of an agent workspace (cwd path, non-alphanumerics as "-").
project_prefix() {
    printf '%s' "$AGENT_HOME/.claude-lab/$1/.claude" | sed 's/[^A-Za-z0-9]/-/g'
}

# Newest content timestamp inside the agent's transcripts (unix s), 0 = no turns, ERR = unreadable.
# Judged by "timestamp" inside JSONL, not by mtime: the CLI touches the file on a timer.
newest_turn_ts() {
    local out
    out="$(python3 - "$(project_prefix "$1")" "$PROJECTS_DIR" "$LIVE_TURN_WINDOW" 2>>"$LOG" <<'PY' || true
import glob, json, os, sys, time
from datetime import datetime, timezone

prefix, projects, window = sys.argv[1], sys.argv[2], int(sys.argv[3])
pat = os.path.join(projects, f"{prefix}*", "*.jsonl")
TAIL = 262144
FUTURE_LIMIT = 86400
try:
    files = glob.glob(pat)
except OSError:
    print("ERR"); raise SystemExit(0)
if not files:
    print(0); raise SystemExit(0)
now = time.time()


def parse(ts):
    if not isinstance(ts, str):
        return 0.0
    try:
        d = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return 0.0
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.timestamp()


def scan(chunk):
    best = 0.0
    for raw in chunk.split(b"\n"):
        if not raw.strip():
            continue
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if isinstance(o, dict):
            best = max(best, parse(o.get("timestamp")))
    return best


def newest_in(path):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TAIL:
                fh.seek(size - TAIL)
            best = scan(fh.read())
            if size > TAIL and now - best >= window:
                fh.seek(0)
                best = max(best, scan(fh.read()))
    except OSError:
        return None
    return best


best = 0.0
seen_error = False
for p in files:
    try:
        if os.path.getmtime(p) < now - FUTURE_LIMIT:
            continue
    except OSError:
        seen_error = True
        continue
    got = newest_in(p)
    if got is None:
        seen_error = True
        continue
    best = max(best, got)
if best > now + FUTURE_LIMIT:
    print("ERR"); raise SystemExit(0)
if seen_error and now - best >= window:
    print("ERR"); raise SystemExit(0)
print(int(best))
PY
)"
    [[ "$out" =~ ^[0-9]+$ ]] && { printf '%s\n' "$out"; return 0; }
    echo ERR
}

# ERR counts as live: not knowing must never allow a restart.
ts_is_live() {
    local ts="$1" age
    [[ "$ts" =~ ^[0-9]+$ ]] || return 0
    [ "$ts" -gt 0 ] || return 1
    age=$(( $(date +%s) - ts ))
    [ "$age" -lt "$LIVE_TURN_WINDOW" ]
}

# Explicit sign of a running turn in the agent's TUI (Codex r1): "esc to interrupt" is shown
# while a turn runs, "Continuing automatically" while a usage-limit pause waits to resume.
# rc 0 = busy, 1 = idle, 2 = pane unreadable (treated as busy by the caller).
pane_busy() {
    local unit="channel-$1" vis
    vis="$(tmux -L "$unit" capture-pane -t "$unit" -p 2>/dev/null)" || return 2
    [ -n "$vis" ] || return 2
    grep -qiE 'esc to interrupt|Continuing automatically' <<< "$vis" && return 0
    return 1
}

job_err_hold() {
    local f="$STREAK_DIR/$1.joberr" n=0
    [ -f "$f" ] && n="$(tr -dc '0-9' < "$f" 2>/dev/null || true)"
    n=$(( ${n:-0} + 1 ))
    if [ "$DRY" != 1 ] && ! echo "$n" > "$f" 2>/dev/null; then
        log "[$1] WARN: sensor error counter not written ($f), not holding"
        return 1
    fi
    [ "$n" -le "$JOB_ERR_MAX_STREAK" ]
}
job_err_clear() { [ "$DRY" = 1 ] || rm -f "${STREAK_DIR:?}/$1.joberr" 2>/dev/null || true; }
running_job() {
    python3 "$LIB/agent_running_job.py" ${2:+"$2"} "$1" 2>>"$LOG" || echo "ERR helper failed"
}

# Context of the CURRENT session only (29.10.2026, reset loop): the newest-by-mtime file was
# the OLD transcript right after a restart (the new session had no transcript yet and the dying
# CLI appended untimed records to the old one), so the same ctx restarted the agent every run.
# Prints "<ctx>\t<path>", NODATA, NOSESSION, SAME\t<ctx>\t<path> or ERR (agent_context_size.py).
LAST_RESET_DIR="$STATE/last-reset"
[ "$DRY" = 1 ] || mkdir -p "$LAST_RESET_DIR"
service_start_epoch() {
    local raw
    raw="$(systemctl show -p ExecMainStartTimestamp --value "channel-$1.service" 2>/dev/null)" || return 1
    [ -n "$raw" ] || return 1
    raw="$(date -d "$raw" +%s 2>/dev/null)" || return 1
    # +1: %s drops the fraction, so the whole start second is excluded (an old-session record
    # in that second must not pass as the new session; the CLI never writes within 1 s of start)
    echo $(( raw + 1 ))
}
agent_context_size() {
    local start
    start="$(service_start_epoch "$1")" || { echo ERR; return 0; }
    python3 "$LIB/agent_context_size.py" "$(project_prefix "$1")" "$PROJECTS_DIR" "$start" \
        "$LAST_RESET_DIR/$1" 2>>"$LOG" || echo ERR
}

# Restart with a quiet marker: channel-confirm.sh sees it, deletes it and skips the resume-nudge.
send_reset() {
    local agent="$1" unit="channel-$1" i
    if [ "$DRY" = 1 ]; then
        log "[$agent] DRY-RUN: would write $QUIET_DIR/$unit and run sudo -n /usr/bin/systemctl restart $unit"
        return 0
    fi
    date +%s > "$QUIET_DIR/$unit" || return 1
    if ! sudo -n /usr/bin/systemctl restart "$unit" 2>>"$LOG"; then
        rm -f "${QUIET_DIR:?}/$unit"
        return 1
    fi
    for i in $(seq 1 18); do
        sleep 5
        systemctl is-active --quiet "$unit.service" && return 0
    done
    rm -f "${QUIET_DIR:?}/$unit"
    return 1
}

log "=== agents-reset start ==="

declare -A FLUSH_OK RESULT
for agent in "${AGENTS[@]}"; do
    if [ "$DRY" = 1 ]; then
        out="$(python3 "$LIB/agent-handoff-flush.py" --dry-run "$agent" 2>&1)" && FLUSH_OK[$agent]=1 || FLUSH_OK[$agent]=0
    else
        out="$(python3 "$LIB/agent-handoff-flush.py" "$agent" 2>&1)" && FLUSH_OK[$agent]=1 || FLUSH_OK[$agent]=0
    fi
    log "handoff-flush: $out"
done

for agent in "${AGENTS[@]}"; do
    if on_hold "$agent"; then
        note_reset "$agent"
        RESULT[$agent]="skipped: hold"
        log "[$agent] SKIP: hold file"
        continue
    fi
    if [ "${FLUSH_OK[$agent]:-0}" -ne 1 ]; then
        RESULT[$agent]="skipped: flush failed (streak $(note_skip "$agent"))"
        log "[$agent] SKIP: flush failed, a reset would lose the day"
        continue
    fi
    seen_turn_ts="$(newest_turn_ts "$agent")"
    if [ "$seen_turn_ts" = ERR ]; then
        RESULT[$agent]="skipped: turn time unreadable (streak $(note_skip "$agent"))"
        log "[$agent] SKIP: turn time unreadable"
        continue
    fi
    if ts_is_live "$seen_turn_ts"; then
        RESULT[$agent]="skipped: live turn (streak $(note_skip "$agent"))"
        log "[$agent] SKIP: live turn (< ${LIVE_TURN_WINDOW}s)"
        continue
    fi

    pane_rc=0; pane_busy "$agent" || pane_rc=$?
    if [ "$pane_rc" != 1 ]; then
        RESULT[$agent]="skipped: turn running in TUI (pane rc=$pane_rc, streak $(note_skip "$agent"))"
        log "[$agent] SKIP: TUI shows a running turn or pane unreadable (rc=$pane_rc)"
        continue
    fi

    job="$(running_job "$agent")"
    job_err_cap=0
    if [[ "$job" == ERR* ]]; then
        if ! job_err_hold "$agent"; then
            log "[$agent] background job sensor failed > ${JOB_ERR_MAX_STREAK} runs, no longer holding: $job"
            job=NONE
            job_err_cap=1
        fi
    elif [[ "$job" == JOB\ * ]]; then
        job_err_clear "$agent"
    fi
    case "$job" in
        JOB\ *|ERR*)
            RESULT[$agent]="skipped: background job (streak $(note_skip "$agent"))"
            log "[$agent] SKIP: background job: $job"
            continue ;;
        STALE\ *)
            log "[$agent] background process older than 3h does not hold the reset: $job" ;;
    esac

    measured="$(agent_context_size "$agent")"
    case "$measured" in
        NOSESSION)
            note_reset "$agent"
            RESULT[$agent]="skipped: current session has no transcript yet"
            log "[$agent] SKIP: no transcript of the current session yet (started after restart)"
            continue ;;
        SAME$'\t'*)
            note_reset "$agent"
            RESULT[$agent]="skipped: same transcript as last reset"
            log "[$agent] SKIP: transcript and ctx unchanged since last reset: ${measured#SAME$'\t'}"
            continue ;;
    esac
    ctx="${measured%%$'\t'*}"
    transcript="${measured#*$'\t'}"
    if ! [[ "$ctx" =~ ^[0-9]+$ ]]; then
        ctx="$measured"
        RESULT[$agent]="skipped: context not measured ($ctx, streak $(note_skip "$agent"))"
        log "[$agent] SKIP: context not measured: $ctx"
        continue
    fi

    limit="$CTX_THRESHOLD"
    busy_rc=0; has_active_tasks "$agent" || busy_rc=$?
    if [ "$busy_rc" = 0 ] && [ "$DAYTIME" = 1 ]; then
        limit="$DAY_CTX_BUSY_THRESHOLD"
    fi
    if [ "$ctx" -lt "$limit" ]; then
        note_reset "$agent"
        RESULT[$agent]="skipped: ctx $ctx < $limit"
        log "[$agent] SKIP: ctx=$ctx < $limit (busy_rc=$busy_rc)"
        continue
    fi
    log "[$agent] ctx=$ctx >= $limit (busy_rc=$busy_rc), resetting ($transcript)"

    now_turn_ts="$(newest_turn_ts "$agent")"
    if [ "$now_turn_ts" = ERR ]; then
        RESULT[$agent]="skipped: turn time unreadable before restart (streak $(note_skip "$agent"))"
        log "[$agent] SKIP: turn time unreadable before restart"
        continue
    fi
    if [ "$now_turn_ts" != "$seen_turn_ts" ] || ts_is_live "$now_turn_ts"; then
        RESULT[$agent]="skipped: turn started during checks (streak $(note_skip "$agent"))"
        log "[$agent] SKIP: activity appeared between check and restart"
        continue
    fi
    job_now="$(running_job "$agent" --no-min-age)"
    if [[ "$job_now" == ERR* ]] && [ "$job_err_cap" = 0 ] && ! job_err_hold "$agent"; then
        log "[$agent] background job sensor failed > ${JOB_ERR_MAX_STREAK} runs, no longer holding: $job_now"
    elif [[ "$job_now" == ERR* ]] && [ "$job_err_cap" = 0 ]; then
        RESULT[$agent]="skipped: background job not measured before restart (streak $(note_skip "$agent"))"
        log "[$agent] SKIP: background job not measured before restart: $job_now"
        continue
    fi
    [[ "$job_now" == ERR* ]] || job_err_clear "$agent"
    if [[ "$job_now" == JOB\ * ]]; then
        RESULT[$agent]="skipped: background job started during checks (streak $(note_skip "$agent"))"
        log "[$agent] SKIP: background job appeared before restart: $job_now"
        continue
    fi

    pane_rc=0; pane_busy "$agent" || pane_rc=$?
    if [ "$pane_rc" != 1 ]; then
        RESULT[$agent]="skipped: turn started in TUI before restart (pane rc=$pane_rc, streak $(note_skip "$agent"))"
        log "[$agent] SKIP: TUI shows a running turn right before restart (rc=$pane_rc)"
        continue
    fi

    if send_reset "$agent"; then
        note_reset "$agent"
        if [ "$DRY" = 1 ]; then
            RESULT[$agent]="would reset (dry-run)"
        else
            RESULT[$agent]="reset"
            # atomic (tmp + mv): a damaged record reads as ERR and holds resets until fixed
            { printf '%s\t%s\n' "$transcript" "$ctx" > "$LAST_RESET_DIR/.$agent.tmp" \
                && mv -f "$LAST_RESET_DIR/.$agent.tmp" "$LAST_RESET_DIR/$agent"; } 2>>"$LOG" \
                || log "[$agent] WARN: last-reset record not written"
            log "[$agent] restart OK (quiet, no resume-nudge)"
        fi
    else
        RESULT[$agent]="error: restart failed or not ready in 90s (streak $(note_skip "$agent"))"
        log "[$agent] ERR: restart failed"
    fi
done

for agent in "${AGENTS[@]}"; do
    log "result ${agent}: ${RESULT[$agent]:-no data}"
    n=0; [ -f "$STREAK_DIR/$agent" ] && n="$(tr -dc '0-9' < "$STREAK_DIR/$agent" 2>/dev/null || true)"
    [ "${n:-0}" -ge "$STREAK_ALERT" ] && log "STUCK ${agent}: skipped ${n} runs in a row, session keeps growing"
done

# Nightly memory weight line (journal cap 15 KB, turn weight); log only, nobody is messaged.
if [ "$DAYTIME" != 1 ]; then
    if w="$(python3 "$LIB/include_weight.py" "$AGENT_HOME/.claude-lab" 2>&1)"; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then log "memory-weight: $line"; fi
        done <<< "$w"
    else
        log "memory-weight: FAILED"
    fi
fi
log "=== agents-reset end ==="
