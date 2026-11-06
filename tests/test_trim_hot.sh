#!/usr/bin/env bash
# Tests for scripts/trim-hot.sh: handoff.md is never cut or overwritten, whatever its age
# or size; over 15 KB the script only writes a warning line. recent.md trimming still works.
# Run: bash tests/test_trim_hot.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
S="${REPO}/scripts/trim-hot.sh"

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
mkdir -p "${WS}/core/hot"
HO="${WS}/core/hot/handoff.md"
RE="${WS}/core/hot/recent.md"

run() { HOME="$H" AGENT_WS="$WS" bash "$S"; }

# 1) old (7 h) and large (20 KB) handoff: the old script wiped it as "stale"
{ echo '# handoff.md'; for i in $(seq 1 800); do echo "- open item ${i}: keep me"; done; } >"$HO"
touch -d '7 hours ago' "$HO"
cp -p "$HO" "${TDIR}/ho.orig"
run
check "stale+big handoff kept byte for byte" cmp -s "$HO" "${TDIR}/ho.orig"
check "no 'cleared' in log"                  bash -c '! grep -q "cleared" "$0"' "$LOG"
check "no 'trimmed' for handoff in log"      bash -c '! grep -q "handoff.md trimmed" "$0"' "$LOG"
check "size warning logged"                  grep -q "handoff.md [0-9]*B > 15360B" "$LOG"

# 2) small fresh handoff: untouched, logged ok
printf '# handoff.md\n- one open item\n' >"$HO"
cp -p "$HO" "${TDIR}/ho2.orig"
run
check "small handoff kept"                   cmp -s "$HO" "${TDIR}/ho2.orig"
check "ok line logged"                       grep -q "handoff.md ok (" "$LOG"

# 3) recent.md over 12 KB is still trimmed
{ echo '# Hot memory'; for i in $(seq 1 120); do printf '### e%s\n%s\n' "$i" "$(head -c 200 /dev/zero | tr '\0' x)"; done; } >"$RE"
run
check "recent.md trimmed under 12 KB"        test "$(wc -c <"$RE")" -le 12288
check "recent.md keeps newest entry"         grep -q '^### e120$' "$RE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
