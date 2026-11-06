#!/usr/bin/env bash
# rotate-warm.sh -- move oldest sections from warm/decisions.md into cold/MEMORY.md.
# Runs daily at 04:30 via cron. No LLM calls, deterministic.
#
# Heuristic: if decisions.md has > 14 "## " sections, the OLDEST section is
# appended to MEMORY.md with a "(rotated from decisions.md)" marker, and
# removed from decisions.md. Repeats until <= 14 sections.
# OLDEST = earliest DATE at the start of the header ("## 2026-11-06", "## 06.11.2026",
# "## 06.11.26", "## 06.11"; a year-less date is put in the latest year that is not in
# the future), never the position: agents add new days on top OR at the bottom.
# A section whose header starts with no such date is never archived (WARN in the log).
set -euo pipefail

AGENT_WS="${AGENT_WS:-$HOME/.claude-lab/jarvis/.claude}"
DECISIONS="$AGENT_WS/core/warm/decisions.md"
MEMORY="$AGENT_WS/core/MEMORY.md"
LOG_DIR="$HOME/.claude-lab/jarvis/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [rotate-warm] $*" >> "$LOG_FILE" 2>/dev/null || true
}

if [ ! -f "$DECISIONS" ]; then
    log "decisions.md missing, skip"
    exit 0
fi

# MEMORY.md might not exist on fresh install -- create it.
if [ ! -f "$MEMORY" ]; then
    printf '# MEMORY.md\n\nLong-term notes.\n' > "$MEMORY"
fi

SECTIONS=$(grep -c '^## ' "$DECISIONS" 2>/dev/null || true)
SECTIONS=${SECTIONS:-0}
if [ "$SECTIONS" -le 14 ]; then
    log "decisions.md has ${SECTIONS} sections, no rotation needed"
    exit 0
fi

python3 - "$DECISIONS" "$MEMORY" "$LOG_FILE" <<'PY'
import os, re, sys, tempfile
from datetime import date, datetime, timezone

dec_path, mem_path, log_path = sys.argv[1], sys.argv[2], sys.argv[3]
MAX_SECTIONS = 14
# ROTATE_WARM_TODAY=YYYY-MM-DD pins "today" (tests only)
today = (date.fromisoformat(os.environ["ROTATE_WARM_TODAY"]) if os.environ.get("ROTATE_WARM_TODAY")
         else datetime.now(timezone.utc).date())
ISO = re.compile(r"(\d{4})-(\d{2})-(\d{2})(?!\d)")
DMY = re.compile(r"(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})(?![\d.])")
DM = re.compile(r"(\d{2})\.(\d{2})(?![\d.])")


def warn(msg):
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(f"[{stamp}] [rotate-warm] WARN {msg}\n")
    except OSError:
        pass
    print(f"WARN {msg}")


def header_date(header):
    """Date at the start of a '## ' header, or None."""
    text = header[3:].lstrip(" \t*_[")
    try:
        m = ISO.match(text)
        if m:
            return date(int(m[1]), int(m[2]), int(m[3]))
        m = DMY.match(text)
        if m:
            y = int(m[3])
            return date(y + 2000 if y < 100 else y, int(m[2]), int(m[1]))
        m = DM.match(text)
        if m:
            # no year written: the latest year in which this day exists and is not in the future
            # (29.02 goes back to the last leap year)
            for y in range(today.year, today.year - 9, -1):
                try:
                    d = date(y, int(m[2]), int(m[1]))
                except ValueError:
                    continue
                if d <= today:
                    return d
            return None
    except ValueError:  # 31.02, 2026-13-01: not a date
        return None
    return None


def sections_of(content):
    """[(start, end, header)] of '## ' sections; '## ' lines inside closed ``` / ~~~ fences are text.

    An opening fence is a line of 3+ ` or ~ (a ` fence has no ` after it, so ```x``` is inline
    code); it closes on a line of the same char, at least as long, nothing else. An opening
    fence that never closes is treated as plain text, so it can never hide the headers after it.
    """
    lines = content.splitlines(keepends=True)
    not_fence = set()
    while True:
        heads, fence, opened, pos = [], None, None, 0
        for n, line in enumerate(lines):
            s = line.rstrip("\n")
            fm = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", s)
            if fence is None and fm and n not in not_fence and not (fm[1][0] == "`" and "`" in fm[2]):
                fence, opened = fm[1], n
            elif fence is not None:
                if fm and fm[1][0] == fence[0] and len(fm[1]) >= len(fence) and not fm[2].strip():
                    fence = None
            elif s.startswith("## "):
                heads.append((pos, s))
            pos += len(line)
        if fence is None:
            break
        not_fence.add(opened)  # unclosed: rescan with that line as text
    return [(st, heads[i + 1][0] if i + 1 < len(heads) else len(content), h)
            for i, (st, h) in enumerate(heads)]


def write_atomic(path, text, still_ok):
    """Write via a temp file in the same dir + fsync + rename: the old file stays whole on failure.
    still_ok() is checked after the temp file is ready, right before the rename; False = the temp
    file is dropped, the live file is left as is, returns False."""
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".rotate-warm.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        if os.environ.get("ROTATE_WARM_TEST_APPEND_LATE"):  # tests only: agent writes now
            with open(path, "a", encoding="utf-8") as f:
                f.write(os.environ["ROTATE_WARM_TEST_APPEND_LATE"])
        if not still_ok():
            os.unlink(tmp)
            return False
        os.replace(tmp, path)
        return True
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


with open(dec_path, encoding="utf-8") as f:
    content = f.read()
snapshot = content
if os.environ.get("ROTATE_WARM_TEST_APPEND"):  # tests only: an agent writes right after our read
    with open(dec_path, "a", encoding="utf-8") as f:
        f.write(os.environ["ROTATE_WARM_TEST_APPEND"])


def unchanged():
    """decisions.md still holds exactly what was read: agents edit it without a lock, so a
    concurrent write is detected and the run gives up instead of overwriting it."""
    with open(dec_path, encoding="utf-8") as f:
        return f.read() == snapshot


rotated = []
sections = sections_of(content)
while len(sections) > MAX_SECTIONS:
    dated = [(header_date(h), i) for i, (_s, _e, h) in enumerate(sections)]
    dated = [(d, i) for d, i in dated if d is not None]
    if not dated:
        break
    _d, i = min(dated)
    st, en, _h = sections[i]
    rotated.append(content[st:en].rstrip("\n") + "\n")
    content = content[:st] + content[en:]
    sections = sections_of(content)
undated = [h for _s, _e, h in sections if header_date(h) is None]
if undated and (rotated or len(sections) > MAX_SECTIONS):
    warn(f"{len(undated)} section(s) without a date in the header kept, never archived "
         f"({len(sections)} left, cap {MAX_SECTIONS}): {'; '.join(h[:60] for h in undated)}")
if rotated and not unchanged():
    warn("decisions.md changed while rotating (agent writing?), nothing moved, next run retries")
    rotated = []
elif rotated:
    # the archive is on disk BEFORE decisions.md loses the sections (a crash between = a duplicate,
    # never a loss); decisions.md is replaced atomically
    with open(mem_path, "a", encoding="utf-8") as f:
        for text in rotated:
            f.write("\n---\n(rotated from decisions.md)\n" + text + "\n")
        f.flush()
        os.fsync(f.fileno())
    # checked again after the temp file is ready, right before the rename (the gap left is
    # one read + rename: agents write without a lock, no shared lock exists to take)
    if not write_atomic(dec_path, content.rstrip("\n") + "\n", unchanged):
        warn("decisions.md changed after the archive was written: left as is, the archived "
             "sections are now in both files (duplicate, nothing lost)")
        rotated = []
print(f"rotated: {len(rotated)} section(s) to MEMORY.md")
PY

log "rotate-warm complete"
