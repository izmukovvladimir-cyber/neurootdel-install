#!/usr/bin/env bash
# Tests for scripts/rotate-warm.sh: the OLDEST section is chosen by the date in its header,
# not by its position, so the newest day survives whether new sections go on top or at the
# bottom. A section without a recognisable date is never archived (warning in the log).
# Run: bash tests/test_rotate_warm.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
S="${REPO}/scripts/rotate-warm.sh"

PASS=0
FAIL=0
check() {
    local name=$1; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name" >&2
    fi
}

H="${TDIR}/home"
WS="${H}/.claude-lab/jarvis/.claude"
LOG="${H}/.claude-lab/jarvis/logs/memory-cron.log"
mkdir -p "${WS}/core/warm"
DEC="${WS}/core/warm/decisions.md"
MEM="${WS}/core/MEMORY.md"
OUT="${TDIR}/out.txt"

run() { HOME="$H" AGENT_WS="$WS" ROTATE_WARM_TODAY="${TODAY:-2026-11-06}" bash "$S" >"$OUT" 2>&1; }
fresh() { rm -f "$MEM" "$LOG"; printf '# decisions.md\n\nPreamble kept.\n\n' >"$DEC"; }
sec() { printf '## %s\n- entry of %s\n\n' "$1" "$1" >>"$DEC"; }
in_dec() { grep -qx -- "## $1" "$DEC"; }
in_mem() { grep -qx -- "## $1" "$MEM"; }
not_dec() { ! in_dec "$1"; }
not_mem() { [ ! -f "$MEM" ] || ! in_mem "$1"; }

# 1) new on top (ISO dates, 2026-10-01 .. 2026-10-16): the two at the BOTTOM are the oldest
fresh
for d in $(seq 16 -1 1); do sec "2026-10-$(printf %02d "$d")"; done
run
check "top-new: 14 sections left"              test "$(grep -c '^## ' "$DEC")" -eq 14
check "top-new: oldest 10-01 archived"         in_mem 2026-10-01
check "top-new: 10-02 archived"                in_mem 2026-10-02
check "top-new: newest 10-16 kept"             in_dec 2026-10-16
check "top-new: 10-03 kept"                    in_dec 2026-10-03
check "top-new: preamble kept"                 grep -qx 'Preamble kept.' "$DEC"

# 2) new at the bottom (DD.MM.YYYY): the two at the TOP are the oldest; the old script took
#    sections[-1], i.e. it archived the NEWEST day
fresh
for d in $(seq 1 16); do sec "$(printf %02d "$d").10.2026"; done
run
check "bottom-new: 14 sections left"           test "$(grep -c '^## ' "$DEC")" -eq 14
check "bottom-new: oldest 01.10 archived"      in_mem 01.10.2026
check "bottom-new: 02.10 archived"             in_mem 02.10.2026
check "bottom-new: newest 16.10 kept"          in_dec 16.10.2026
check "bottom-new: newest not in MEMORY"       not_mem 16.10.2026
check "bottom-new: entry text moved too"       grep -qx -- '- entry of 01.10.2026' "$MEM"
check "bottom-new: entry text gone from dec"   bash -c '! grep -qx -- "- entry of 01.10.2026" "$0"' "$DEC"

# 3) a section without a date is never archived, even when it is the bottom one; warning logged
fresh
sec "Постоянное: не архивировать"
for d in $(seq 16 -1 2); do sec "$(printf %02d "$d").10"; done
sec "Без даты внизу"
run
check "undated: top undated kept"              in_dec "Постоянное: не архивировать"
check "undated: bottom undated kept"           in_dec "Без даты внизу"
check "undated: 14 sections left"              test "$(grep -c '^## ' "$DEC")" -eq 14
check "undated: oldest dated 02.10 archived"   in_mem 02.10
check "undated: 03.10 archived"                in_mem 03.10
check "undated: 04.10 archived (17 -> 14)"     in_mem 04.10
check "undated: 05.10 kept"                    in_dec 05.10
check "undated: warning in log"                grep -q 'WARN.*without a date' "$LOG"

# 4) only undated sections over the cap: nothing moves, file unchanged, warning logged
fresh
for i in $(seq 1 16); do sec "Тема ${i}"; done
cp -p "$DEC" "${TDIR}/dec.orig"
run
check "all-undated: file unchanged"            cmp -s "$DEC" "${TDIR}/dec.orig"
check "all-undated: nothing in MEMORY"         not_mem "Тема 16"
check "all-undated: warning in log"            grep -q 'WARN.*without a date' "$LOG"

# 5) year-less DD.MM, fixed clock (ROTATE_WARM_TODAY):
# 5a) across the new year, today 06.01.2027: 05.01 is this January, 20.12 is last December
fresh
for d in 20 21 22 23 24 25 26 27 28 29 30 31; do sec "${d}.12"; done
sec "01.01"; sec "02.01"; sec "05.01"
TODAY=2027-01-06 run
check "new-year: 15 -> 14"                     test "$(grep -c '^## ' "$DEC")" -eq 14
check "new-year: 20.12 archived"               in_mem 20.12
check "new-year: 05.01 kept"                   in_dec 05.01
# 5b) today 21.12.2026: 20.12 is this year, 23.12 was last year -> 23.12 is the oldest
fresh
for d in 23 24 25 26 27 28 29 30 31; do sec "${d}.12"; done
for d in 01 02 03 04 05; do sec "${d}.01"; done
sec "20.12"
TODAY=2026-12-21 run
check "dec-21: 23.12 (last year) archived"     in_mem 23.12
check "dec-21: 20.12 (this year) kept"         in_dec 20.12
# 5c) tomorrow's day without a year is last year's: today 06.11.2026, 07.11 = 2025-11-07, the oldest
fresh
sec "07.11"
for d in $(seq 1 14); do sec "2026-10-$(printf %02d "$d")"; done
TODAY=2026-11-06 run
check "tomorrow: 07.11 taken as last year"     in_mem 07.11
check "tomorrow: 2026-10-01 kept"              in_dec 2026-10-01
# 5d) 29.02 without a year in a non-leap year = 29.02.2024, the oldest; not left forever as undated
fresh
for d in $(seq 1 14); do sec "2026-10-$(printf %02d "$d")"; done
sec "29.02"
TODAY=2026-11-06 run
check "leap: 29.02 archived as 2024"           in_mem 29.02
check "leap: no undated warning"               bash -c '[ ! -f "$0" ] || ! grep -q WARN "$0"' "$LOG"

# 6) at or under 14 sections: nothing happens
fresh
for d in $(seq 1 14); do sec "2026-09-$(printf %02d "$d")"; done
cp -p "$DEC" "${TDIR}/dec14.orig"
run
check "14 sections: unchanged"                 cmp -s "$DEC" "${TDIR}/dec14.orig"
check "14 sections: no-rotation logged"        grep -q 'no rotation needed' "$LOG"

# 7) a "## " line inside a code fence is not a section header
fresh
printf '```\n## 2020-01-01 not a header\n```\n\n' >>"$DEC"
for d in $(seq 1 15); do sec "2026-08-$(printf %02d "$d")"; done
run
check "fence: fenced line stays"               grep -qx '## 2020-01-01 not a header' "$DEC"
check "fence: 2026-08-01 archived instead"     in_mem 2026-08-01

# 8) inline ```code``` is not a fence: an undated header after it stays a header and is kept
fresh
printf '## 2026-07-01\n- see ```x``` here\n\n## Без даты\n- keep me\n\n' >>"$DEC"
for d in $(seq 1 14); do sec "2026-08-$(printf %02d "$d")"; done
run
check "inline-fence: dated 07-01 archived"     in_mem 2026-07-01
check "inline-fence: undated header kept"      in_dec "Без даты"
check "inline-fence: its body kept"            grep -qx -- '- keep me' "$DEC"

# 9) an unclosed fence does not hide the headers after it
fresh
printf '## 2026-07-01\n```\nopened and never closed\n\n## Без даты\n- keep me\n\n' >>"$DEC"
for d in $(seq 1 14); do sec "2026-08-$(printf %02d "$d")"; done
run
check "unclosed-fence: undated header kept"    in_dec "Без даты"
check "unclosed-fence: 07-01 archived"         in_mem 2026-07-01

# 11) an agent writes decisions.md during the run: its write survives, nothing moved, warning
fresh
for d in $(seq 1 16); do sec "2026-09-$(printf %02d "$d")"; done
ROTATE_WARM_TEST_APPEND=$'## Без даты, записано агентом\n- live write\n' run
check "concurrent: agent's section kept"       in_dec "Без даты, записано агентом"
check "concurrent: nothing archived"           not_mem 2026-09-01
check "concurrent: oldest still in dec"        in_dec 2026-09-01
check "concurrent: warning in log"             grep -q 'WARN decisions.md changed while rotating' "$LOG"

# 12) an agent writes while the new decisions.md is being prepared: live file kept, no temp left
fresh
for d in $(seq 1 16); do sec "2026-09-$(printf %02d "$d")"; done
ROTATE_WARM_TEST_APPEND_LATE=$'## Без даты, поздняя запись\n- late write\n' run
check "late-write: agent's section kept"       in_dec "Без даты, поздняя запись"
check "late-write: oldest still in dec"        in_dec 2026-09-01
check "late-write: archive has it (dup, no loss)" in_mem 2026-09-01
check "late-write: warning in log"             grep -q 'WARN decisions.md changed after the archive' "$LOG"
check "late-write: no temp file left"          bash -c '! ls -a "$0" | grep -q "^\.rotate-warm\."' "${WS}/core/warm"

# 10) decisions.md cannot be rewritten (dir read-only): it stays whole, nothing is lost
if [ "$(id -u)" -ne 0 ]; then
    fresh
    for d in $(seq 1 16); do sec "2026-09-$(printf %02d "$d")"; done
    cp -p "$DEC" "${TDIR}/dec-ro.orig"
    chmod 555 "${WS}/core/warm"
    run || true
    chmod 755 "${WS}/core/warm"
    check "write-fail: decisions.md byte for byte" cmp -s "$DEC" "${TDIR}/dec-ro.orig"
    check "write-fail: no temp file left"          bash -c '! ls -a "$0" | grep -q "^\.rotate-warm\."' "${WS}/core/warm"
else
    echo "skip write-fail case (root ignores the read-only dir)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
