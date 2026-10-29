#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Tests for report_claude_plan: prints the Claude plan, warns on "pro", never prints tokens.
# Run: bash tests/test_claude_plan.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT

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

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e
AGENT_USER=agentuser
AGENT_HOME="${TDIR}"

cred() { printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-SECRETACCESS","refreshToken":"sk-ant-ort01-SECRETREFRESH","subscriptionType":%s}}' "$1" > "${TDIR}/c.json"; }

cred '"max"'
OUT=$(report_claude_plan "${TDIR}/c.json" 2>&1)
check "max: plan printed"            grep -q "Claude account plan: max" <<<"$OUT"
check "max: no warning"              bash -c '! grep -q "too small" <<<"$1"' _ "$OUT"
check "max: no token in output"      bash -c '! grep -q SECRET <<<"$1"' _ "$OUT"

cred '"pro"'
OUT=$(report_claude_plan "${TDIR}/c.json" 2>&1)
check "pro: plan printed"            grep -q "Claude account plan: pro" <<<"$OUT"
check "pro: warned"                  grep -q "too small" <<<"$OUT"
check "pro: no token in output"      bash -c '! grep -q SECRET <<<"$1"' _ "$OUT"

cred 'null'
OUT=$(report_claude_plan "${TDIR}/c.json" 2>&1)
check "missing field: unknown"       grep -q "plan: unknown" <<<"$OUT"

cred '"pro$(touch /tmp/x)\u001b[31m"'
OUT=$(report_claude_plan "${TDIR}/c.json" 2>&1)
check "odd value: control chars stripped" bash -c '! grep -q $'"'"'\x1b\[31'"'"' <<<"$1"' _ "$OUT"

OUT=$(report_claude_plan "${TDIR}/none.json" 2>&1)
check "not logged in: says so"       grep -q "not logged in yet" <<<"$OUT"
check "not logged in: shows the check command" grep -q "subscriptionType" <<<"$OUT"
check "main calls the report"        grep -q '^    report_claude_plan$' "${REPO}/install.sh"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
