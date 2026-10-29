#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals read by sourced install.sh functions
# Tests for the hard numbers gate wiring, no root needed: a fresh install puts
# fact-number-gate.py into ~/.claude/hooks and one PreToolUse entry with the
# owner id; a re-run adds nothing; a new owner id updates the entry in place;
# other hooks are kept; the gate itself is tested by tests/test_fact_number_gate.py.
# Run: bash tests/test_fact_number_gate.sh
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
gate_count() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))).count("fact-number-gate.py"))' "$1"; }

FAKE_HOME="${TDIR}/home"
mkdir -p "$FAKE_HOME"
ME="$(id -un)"
cp "${REPO}/install.sh" "${TDIR}/install.sh"

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${TDIR}/install.sh"
set +e    # the checks below report failures themselves
AGENT_HOME="$FAKE_HOME"
AGENT_USER="$ME"
fix_owner() { :; }

OPERATOR_NAME="Tester"
TG_USER_ID="42"
OPERATOR_LANGUAGE="ru"
OPERATOR_TIMEZONE="UTC+3"

SJ="${FAKE_HOME}/.claude/settings.json"
GATE="${FAKE_HOME}/.claude/hooks/fact-number-gate.py"
TPL="${REPO}/templates/fact-number-gate.py"

check "source: template exists"          test -s "$TPL"
check "source: template has no private"  bash -c "! grep -qE '/home/|edgelab|Владимир|[0-9]{6,}|t\\.me/[A-Za-z]|@[A-Za-z_]{4,}' '$TPL'"
check "source: template compiles"        python3 -m py_compile "$TPL"

setup_global_claude >/dev/null 2>&1
check "fresh: gate installed"            test -x "$GATE"
check "fresh: gate == template"          cmp -s "$GATE" "$TPL"
check "fresh: hook once"                 test "$(gate_count "$SJ")" -eq 1
check "fresh: hook carries owner id"     grep -qF -- "fact-number-gate.py agent --owner 42" "$SJ"
check "fresh: matcher covers edit"       grep -qF -- 'mcp__dashi-channel__reply|mcp__dashi-channel__edit_message' "$SJ"
check "fresh: secret guard still there"  grep -qF -- 'secret-outbound-guard.py' "$SJ"

setup_global_claude >/dev/null 2>&1
check "rerun: hook still once"           test "$(gate_count "$SJ")" -eq 1

TG_USER_ID="77"
setup_global_claude >/dev/null 2>&1
check "new owner: still one hook"        test "$(gate_count "$SJ")" -eq 1
check "new owner: id updated"            grep -qF -- "fact-number-gate.py agent --owner 77" "$SJ"
check "new owner: backup made"           test -f "${SJ}.bak-install"

rm -rf "${FAKE_HOME:?}/.claude"
mkdir -p "${FAKE_HOME}/.claude"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"mine"}]}]}}\n' > "$SJ"
TG_USER_ID=""
setup_global_claude >/dev/null 2>&1
check "old: own hook kept"               grep -qF -- '"mine"' "$SJ"
check "old: gate added once"             test "$(gate_count "$SJ")" -eq 1
check "old: no owner -> no --owner flag" bash -c "grep -qF -- 'fact-number-gate.py agent\"' '$SJ'"

BAD="${TDIR}/bad.json"
printf '{"hooks":{"PreToolUse":{}}}\n' > "$BAD"
ensure_fact_gate_hook "$BAD" "$GATE" "42" >/dev/null 2>&1
check "bad: non-array PreToolUse fails"  test $? -ne 0
check "bad: file untouched"              grep -qxF '{"hooks":{"PreToolUse":{}}}' "$BAD"

python3 "${REPO}/tests/test_fact_number_gate.py" >/dev/null 2>&1
check "gate behaviour suite passes"      test $? -eq 0

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
