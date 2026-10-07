#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals read by sourced install.sh functions
# Tests for the starter agent rules in the global CLAUDE.md, no root needed:
#   fresh install writes the block, an old file without it gets it appended
#   (owner text kept, backup made), a re-run adds nothing, the block equals
#   templates/AGENT-RULES-STARTER.md byte for byte.
# Run: bash tests/test_starter_rules.sh
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
count_is() { [[ "$(grep -cF -- "$2" "$1")" -eq "$3" ]]; }

# A copy of install.sh whose home and user point into the sandbox.
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
SRC="${REPO}/templates/AGENT-RULES-STARTER.md"
BEGIN='<!-- agent-rules-starter:begin -->'
END='<!-- agent-rules-starter:end -->'
block_of() { awk -v b="$BEGIN" -v e="$END" '$0==e{f=0} f{print} $0==b{f=1}' "$1"; }
baks() { find "${FAKE_HOME}/.claude" -maxdepth 1 -name 'CLAUDE.md.bak-*-starter-rules' | wc -l; }

# --- source file: nothing private leaks into the public installer ---------------
check "source: exists"                    test -s "$SRC"
check "source: has rule 4 retell"         count_is "$SRC" "Понял так" 1
check "source: no private paths/ids"      bash -c "! grep -qE '/home/|edgelab|[0-9]{6,}|t\\.me/|@[A-Za-z_]{4,}' '$SRC'"

# --- fresh install: file absent ------------------------------------------------
setup_global_claude >/dev/null 2>&1
check "fresh: file written"               test -s "$GMD"
check "fresh: grep -c 'Понял так' >= 1"   test "$(grep -c "Понял так" "$GMD")" -ge 1
check "fresh: one begin marker"           count_is "$GMD" "$BEGIN" 1
check "fresh: one end marker"             count_is "$GMD" "$END" 1
check "fresh: block == source file"       diff -q <(block_of "$GMD") "$SRC"
check "fresh: template rendered"          grep -qF "**Name:** Tester" "$GMD"
check "fresh: hook threshold rule"        grep -qF "must never block before the automatic session reset" "$GMD"
check "fresh: no placeholders left"       bash -c "! grep -q '{{' '$GMD'"
check "fresh: no backup made"             test "$(baks)" -eq 0
printf 'fresh install: grep -c "Понял так" = %s\n' "$(grep -c "Понял так" "$GMD")"

# --- re-run on the fresh file: nothing changes ----------------------------------
cp "$GMD" "${TDIR}/fresh.copy"
setup_global_claude >/dev/null 2>&1
check "fresh re-run: file unchanged"      cmp -s "$GMD" "${TDIR}/fresh.copy"
check "fresh re-run: no backup"           test "$(baks)" -eq 0

# --- old install: owner file without the block ----------------------------------
printf '# My own rules\n\nOwner line that must survive.' >"$GMD"   # no final newline
chmod 0640 "$GMD"
cp "$GMD" "${TDIR}/old.copy"
setup_global_claude >/dev/null 2>&1
check "old: block appended"               count_is "$GMD" "$BEGIN" 1
check "old: grep -c 'Понял так' >= 1"     test "$(grep -c "Понял так" "$GMD")" -ge 1
check "old: owner text kept as prefix"    cmp -s <(head -c "$(stat -c %s "${TDIR}/old.copy")" "$GMD") "${TDIR}/old.copy"
check "old: owner last line intact"       grep -qxF "Owner line that must survive." "$GMD"
check "old: block == source file"         diff -q <(block_of "$GMD") "$SRC"
check "old: one backup"                   test "$(baks)" -eq 1
BAK="$(find "${FAKE_HOME}/.claude" -maxdepth 1 -name 'CLAUDE.md.bak-*-starter-rules' | head -1)"
check "old: backup == original"           cmp -s "$BAK" "${TDIR}/old.copy"
check "old: mode kept"                    test "$(stat -c %a "$GMD")" = "640"

# --- re-run on the upgraded file: no duplicate ----------------------------------
cp "$GMD" "${TDIR}/upgraded.copy"
setup_global_claude >/dev/null 2>&1
check "old re-run: file unchanged"        cmp -s "$GMD" "${TDIR}/upgraded.copy"
check "old re-run: still one marker"      count_is "$GMD" "$BEGIN" 1
check "old re-run: still one backup"      test "$(baks)" -eq 1

# --- owner already has the retell rule in own words: left alone ----------------
rm -f "${FAKE_HOME:?}"/.claude/CLAUDE.md.bak-*-starter-rules
printf 'Own rule: Понял так: делаю X.\n' >"$GMD"
cp "$GMD" "${TDIR}/own.copy"
setup_global_claude >/dev/null 2>&1
check "own rule: untouched"               cmp -s "$GMD" "${TDIR}/own.copy"
check "own rule: no backup"               test "$(baks)" -eq 0

# --- markers present, phrase edited out by the owner: left alone --------------
printf 'text\n%s\nowner edited the rules\n%s\n' "$BEGIN" "$END" >"$GMD"
cp "$GMD" "${TDIR}/markers.copy"
setup_global_claude >/dev/null 2>&1
check "markers only: untouched"           cmp -s "$GMD" "${TDIR}/markers.copy"
check "markers only: no backup"           test "$(baks)" -eq 0

# --- symlinked CLAUDE.md: target updated, link kept -----------------------------
REAL="${TDIR}/real-CLAUDE.md"
printf 'linked owner text\n' >"$REAL"
rm -f "${GMD:?}"
ln -s "$REAL" "$GMD"
setup_global_claude >/dev/null 2>&1
check "symlink: link kept"                test -L "$GMD"
check "symlink: target got block"         count_is "$REAL" "$BEGIN" 1

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
