#!/usr/bin/env bash
# precompact-flush.sh -- PreCompact hook of the agents (installed by neurootdel-install).
# Snapshot of handoff/recent before compaction plus a fresh
# agent-handoff-flush.py run, so the compacted session and the next one see the
# latest "Last 15 actions" in core/hot/handoff.md.
#
# Usage: precompact-flush.sh <agent>   (runs as the agent user, from the agent's hook)
#   channel agents (guard.conf CHANNEL_AGENTS): handoff-flush + snapshot; richard (SDK, no handoff-flush support): snapshot only.
# Snapshots: <agent>/.claude/core/hot/pre-compact/{handoff,recent}-<UTC ts>-<pid>.md, newest 10 of each
#   kept (rotation by the timestamp in the name). Budget: flush <= 20 s (+3 s kill), whole hook well
#   under the 40 s hook timeout. Never blocks compaction: every path exits 0. Log holds status only.
# Stop: touch ~/.claude-lab/shared/state/precompact/STOP
set -uo pipefail

LIB="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
# shellcheck disable=SC1091
. "${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}" 2>/dev/null || exit 0
agent="${1:-}"
[[ "$agent" =~ ^[a-z0-9-]+$ ]] || exit 0
case " ${CHANNEL_AGENTS:-jarvis} richard " in *" $agent "*) ;; *) exit 0 ;; esac

# Drain the hook JSON from stdin (not needed), bounded so a tty never hangs us.
timeout -k 1 2 cat >/dev/null 2>&1 || true

umask 077
ST="$AGENT_HOME/.claude-lab/shared/state/precompact"
mkdir -p "$ST" 2>/dev/null || exit 0
[[ -e "$ST/STOP" ]] && exit 0
LOG="$ST/precompact.log"
KEEP=10

log() { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$agent" "$*" >>"$LOG" 2>/dev/null || true; }

# One run per agent at a time; a parallel compaction just skips.
exec 8>"$ST/$agent.lock" || exit 0
flock -n 8 || { log "busy, skipped"; exit 0; }

HOT="$AGENT_HOME/.claude-lab/$agent/.claude/core/hot"
SNAP="$HOT/pre-compact"

if [[ "$agent" != richard ]]; then
    t0=$SECONDS
    timeout -k 3 20 python3 "$LIB/agent-handoff-flush.py" "$agent" >/dev/null 2>&1
    rc=$?
    log "flush rc=$rc in $((SECONDS - t0))s"
fi

[[ -d "$HOT" ]] || { log "no hot dir"; exit 0; }
mkdir -p "$SNAP" 2>/dev/null || { log "cannot create snapshot dir"; exit 0; }
ts="$(date -u +%Y%m%d-%H%M%S)-$$"
for f in handoff recent; do
    [[ -s "$HOT/$f.md" ]] || continue
    tmp="$SNAP/.$f-$ts.tmp"
    if cp -- "$HOT/$f.md" "$tmp" && mv -f -- "$tmp" "$SNAP/$f-$ts.md"; then
        log "snapshot $f-$ts.md ($(wc -c <"$SNAP/$f-$ts.md") bytes)"
    else
        rm -f -- "$tmp"
        log "snapshot $f FAIL"
        continue
    fi
    # Rotate by the timestamp in the name (fixed format, no spaces): newest $KEEP stay.
    find "$SNAP" -maxdepth 1 -type f -name "$f-*.md" -printf '%f\n' | LC_ALL=C sort -r \
        | tail -n +"$((KEEP + 1))" | while IFS= read -r old; do
            rm -f -- "${SNAP:?}/$old" && log "rotated out $old"
        done
done
exit 0
