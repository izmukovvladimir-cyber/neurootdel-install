#!/usr/bin/env bash
# trim-hot.sh -- trim hot memory (recent.md + handoff.md) by size and age.
# Runs daily at 05:00 via cron. No LLM calls, deterministic.
#
# Behavior:
#   - recent.md > 12KB: keep last 50 "### " entries, shrink until < 12KB (min 10).
#   - handoff.md: never cut or overwritten; over 15KB only a warning line in the log.
set -euo pipefail

AGENT_WS="${AGENT_WS:-$HOME/.claude-lab/jarvis/.claude}"
RECENT="$AGENT_WS/core/hot/recent.md"
HANDOFF="$AGENT_WS/core/hot/handoff.md"
LOG_DIR="$HOME/.claude-lab/jarvis/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [trim-hot] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# -------- recent.md: size cap --------
RECENT_LIMIT=12288  # 12KB
if [ -f "$RECENT" ]; then
    SIZE=$(wc -c < "$RECENT" | tr -d ' ')
    if [ "$SIZE" -gt "$RECENT_LIMIT" ]; then
        cp "$RECENT" "${RECENT}.pre-trim"
        python3 - "$RECENT" "$RECENT_LIMIT" <<'PY'
import re, sys
path = sys.argv[1]
limit = int(sys.argv[2])
content = open(path, encoding='utf-8').read()
header_match = re.match(r'^#[^#].*\n', content)
header = header_match.group(0) if header_match else "# Hot memory -- rolling journal\n\n"
entries = list(re.finditer(r'^### ', content, re.MULTILINE))
total = len(entries)
if total > 50:
    keep_from = entries[-50].start()
    trimmed = header + "\n" + content[keep_from:]
    entries = list(re.finditer(r'^### ', trimmed, re.MULTILINE))
else:
    trimmed = content
while len(trimmed.encode('utf-8')) > limit and len(entries) > 10:
    # Drop the oldest entry and re-slice from the next-oldest. Entry offsets
    # must be recomputed against the CURRENT `trimmed`, otherwise the second
    # and later iterations cut at stale indices and corrupt the file.
    next_start = entries[1].start()
    trimmed = header + "\n" + trimmed[next_start:]
    entries = list(re.finditer(r'^### ', trimmed, re.MULTILINE))
open(path, 'w', encoding='utf-8').write(trimmed)
final = len(list(re.finditer(r'^### ', trimmed, re.MULTILINE)))
print(f"recent trimmed: {total} -> {final} entries, {len(trimmed.encode('utf-8'))}B")
PY
        log "recent.md trimmed from ${SIZE}B"
    else
        log "recent.md ok (${SIZE}B)"
    fi
fi

# -------- handoff.md: DO NOT CUT, only warn (memory scheme parity, 06.11.2026) --------
# Before: a blind tail cut to 4 KB and a stub overwrite when mtime was older than 6 h. Both
# destroyed open items: the tail is where the newest entries and the auto block live, and the
# stub replaced the whole file (logged here as "stale ... cleared"). handoff.md holds ONLY open
# items and is cleaned by its owner agent by meaning (rule 5b); a script cannot tell an open item
# from a closed one, so it only names the size. The nightly weight guard
# (memory_weight_watch.py) wakes the owner when the file stays over the cap.
HANDOFF_WARN_LIMIT=15360   # 15 KB, the journal cap of rule 5b

if [ -f "$HANDOFF" ]; then
    SIZE=$(wc -c < "$HANDOFF" | tr -d ' ')
    if [ "$SIZE" -gt "$HANDOFF_WARN_LIMIT" ]; then
        log "handoff.md ${SIZE}B > ${HANDOFF_WARN_LIMIT}B - owner must compress by meaning (file not touched)"
    else
        log "handoff.md ok (${SIZE}B)"
    fi
fi

log "trim-hot complete"
