#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals read by sourced install.sh functions
# Rule zero in the global CLAUDE.md, no root needed: the old "Autonomous bug
# fixing / just fix it" section is gone from every template, and a fresh
# install writes a global file whose bug-fixing rule agrees with the starter
# rules ("fixing on your own initiative is forbidden").
# Run: bash tests/test_rule_zero.sh
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
# Absent means grep exit 1 exactly; exit 2 (unreadable file, bad pattern) fails.
absent() { local rc=0; grep "$@" >/dev/null 2>&1 || rc=$?; [[ "$rc" -eq 1 ]]; }

SRC="${REPO}/templates/global-CLAUDE.md"
OLD_RE='Autonomous bug fixing|just fix it'

# --- sources: the old wording is nowhere in what the installer ships --------
check "templates: no autofix wording"   absent -rqiE "$OLD_RE" "${REPO}/templates" "${REPO}/skills" "${REPO}/docs" "${REPO}/README.md"
check "source: rule section present"    grep -qF "### Bug fixing: do not fix what already works" "$SRC"
check "source: one-line-and-wait rule"  grep -qF "bring it to {{USER_NAME}} as ONE line and wait for the word" "$SRC"
check "source: own initiative banned"   grep -qF "Fixing it on your own initiative is forbidden" "$SRC"
check "source: live trace required"     grep -qF "find a LIVE TRACE" "$SRC"
check "source: owner bug still fixed"   grep -qF "You fix on your own only two things: a bug {{USER_NAME}} sent you, and a breakage inside the" "$SRC"
check "source: own task + live trace"   grep -qF "task you were given that has a live trace." "$SRC"

# --- fresh install through the real installer function ----------------------
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

GMD="${FAKE_HOME}/.claude/CLAUDE.md"
setup_global_claude >/dev/null 2>&1
check "fresh: file written"             test -s "$GMD"
check "fresh: no autofix wording"       absent -qiE "$OLD_RE" "$GMD"
check "fresh: rule rendered with owner" grep -qF "bring it to Tester as ONE line and wait for the word" "$GMD"
check "fresh: exceptions rendered"      grep -qF "only two things: a bug Tester sent you, and a breakage inside the" "$GMD"
check "fresh: exception limits kept"    grep -qF "task you were given that has a live trace." "$GMD"
check "fresh: starter ban kept"         grep -qF "Чинить по своей инициативе" "$GMD"
check "fresh: no placeholders left"     absent -qF "{{" "$GMD"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
