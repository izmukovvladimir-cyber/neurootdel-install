#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals read by sourced install.sh functions
# Tests for «Агент за вечер» (--solo) rules and Superpowers, no root needed:
#   --solo: the starter block keeps rules 0 and 5-8, rules 1-4 are cut, the owner-work
#   rules 9-13 stand once right after it; the full install keeps the starter block whole and
#   gets no owner-work block; an old --solo CLAUDE.md with rules 0-8 is converted once (backup
#   next to it, owner text kept), a repeat changes nothing; a block pasted by hand is not
#   duplicated; Superpowers is switched off reversibly (backup, idempotent);
#   --azv-owner-rules runs only these two steps.
# Run: bash tests/test_owner_work_rules.sh
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
no_line() { ! grep -qF -- "$2" "$1"; }

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
AZV_AGENT_DIR="${FAKE_HOME}/.claude-lab/jarvis/.claude/azv"
fix_owner() { :; }
# No sudo in the sandbox (the test user is the agent user); calls are logged.
AS_AGENT_LOG="${TDIR}/as_agent.log"
as_agent() { printf '%s\n' "$*" >>"$AS_AGENT_LOG"; "$@"; }

OPERATOR_NAME="Tester"
TG_USER_ID="42"
OPERATOR_LANGUAGE="ru"
OPERATOR_TIMEZONE="UTC+3"

GMD="${FAKE_HOME}/.claude/CLAUDE.md"
SRC="${REPO}/templates/AGENT-RULES-OWNER-WORK.md"
BEGIN='<!-- agent-rules-owner-work:begin -->'
END='<!-- agent-rules-owner-work:end -->'
PROBE='Тест глазами живого человека'
block_of() { awk -v b="$BEGIN" -v e="$END" '$0==e{f=0} f{print} $0==b{f=1}' "$1"; }
baks() { find "${FAKE_HOME}/.claude" -maxdepth 1 -name 'CLAUDE.md.bak-*-owner-work' | wc -l; }
# rule headings present in the file, in order: "0 5 6 7 8 9 10 11 12 13"
rules_of() { grep -oE '^## [0-9]+\. ' "$1" | grep -oE '[0-9]+' | tr '\n' ' ' | sed 's/ $//'; }
reset_home() { rm -rf "${FAKE_HOME:?}/.claude"; mkdir -p "${FAKE_HOME}/.claude"; }

# --- source file: nothing private leaks into the public installer ---------------
check "source: exists"                    test -s "$SRC"
check "source: probe once"                count_is "$SRC" "$PROBE" 1
check "source: rules 9-13"                test "$(rules_of "$SRC")" = "9 10 11 12 13"
check "source: no private paths/ids"      bash -c "! grep -qE '/home/|edgelab|[0-9]{6,}|t\\.me/|@[A-Za-z_]{4,}' '$SRC'"
check "source: no placeholders"           bash -c "! grep -qF '{{' '$SRC'"
check "source: no markers inside"         no_line "$SRC" "agent-rules-owner-work"

# --- full install: unchanged, starter 0-8 whole, no owner-work block -------------
reset_home
SOLO=0
setup_global_claude >/dev/null 2>&1
check "full: rules 0-8 only"              test "$(rules_of "$GMD")" = "0 1 2 3 4 5 6 7 8"
check "full: no owner-work block"         no_line "$GMD" "$BEGIN"
check "full: no probe"                    no_line "$GMD" "$PROBE"
cp "$GMD" "${TDIR}/full.copy"
setup_global_claude >/dev/null 2>&1
check "full re-run: unchanged"            cmp -s "$GMD" "${TDIR}/full.copy"

# --- fresh --solo install: 0,5-8 + 9-13 ----------------------------------------
reset_home
SOLO=1
setup_global_claude >/dev/null 2>&1
check "solo fresh: rules 0,5-8 then 9-13" test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"
check "solo fresh: one begin marker"      count_is "$GMD" "$BEGIN" 1
check "solo fresh: one end marker"        count_is "$GMD" "$END" 1
check "solo fresh: block == source"       diff -q <(block_of "$GMD") "$SRC"
check "solo fresh: no 'Понял так'"        no_line "$GMD" "Понял так"
check "solo fresh: starter markers kept"  count_is "$GMD" "$STARTER_RULES_BEGIN" 1
check "solo fresh: block after starter"   test "$(grep -nF "$BEGIN" "$GMD" | cut -d: -f1)" -gt "$(grep -nF "$STARTER_RULES_END" "$GMD" | cut -d: -f1)"
check "solo fresh: RED block kept"        count_is "$GMD" "$RED_SECRETS_BEGIN" 1
check "solo fresh: template rendered"     grep -qF "**Name:** Tester" "$GMD"
check "solo fresh: no backup"             test "$(baks)" -eq 0
cp "$GMD" "${TDIR}/solo.copy"
setup_global_claude >/dev/null 2>&1
check "solo re-run: unchanged"            cmp -s "$GMD" "${TDIR}/solo.copy"
check "solo re-run: no backup"            test "$(baks)" -eq 0

# --- old --solo install: starter 0-8, owner text around it ------------------------
reset_home
{
    printf '# My own rules\n\nOwner line that must survive.\n'
    _starter_rules_block
    cat "${REPO}/templates/RED-SECRETS-RULE.md"
    printf 'last owner line'     # no final newline
} >"$GMD"
chmod 0640 "$GMD"
cp "$GMD" "${TDIR}/old.copy"
check "old: starts with 0-8"              test "$(rules_of "$GMD")" = "0 1 2 3 4 5 6 7 8"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "old: 0,5-8 + 9-13"                 test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"
check "old: block once"                   count_is "$GMD" "$BEGIN" 1
check "old: block == source"              diff -q <(block_of "$GMD") "$SRC"
check "old: owner head kept"              grep -qxF "Owner line that must survive." "$GMD"
check "old: owner last line kept"         test "$(tail -n1 "$GMD")" = "last owner line"
check "old: RED block kept"               count_is "$GMD" "$RED_SECRETS_BEGIN" 1
check "old: one backup"                   test "$(baks)" -eq 1
BAK="$(find "${FAKE_HOME}/.claude" -maxdepth 1 -name 'CLAUDE.md.bak-*-owner-work' | head -1)"
check "old: backup == original"           cmp -s "$BAK" "${TDIR}/old.copy"
check "old: mode kept"                    test "$(stat -c %a "$GMD")" = "640"
# Nothing but rules 1-4 removed and the block added: the rest is the original, byte for byte.
check "old: only 1-4 and block differ"    python3 - "${TDIR}/old.copy" "$GMD" "$BEGIN" "$END" <<'PY'
import sys
old = open(sys.argv[1], encoding="utf-8").read()
new = open(sys.argv[2], encoding="utf-8").read()
i, j = old.index("\n## 1. ") + 1, old.index("\n## 5. ") + 1
b = new.index("\n" + sys.argv[3] + "\n")
e = new.index(sys.argv[4] + "\n") + len(sys.argv[4]) + 1
sys.exit(0 if old[:i] + old[j:] == new[:b] + new[e:] else 1)
PY
cp "$GMD" "${TDIR}/old2.copy"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "old repeat: unchanged"             cmp -s "$GMD" "${TDIR}/old2.copy"
check "old repeat: still one backup"      test "$(baks)" -eq 1

# --- pasted by hand without markers: not added again, 1-4 still cut ---------------
reset_home
{ _starter_rules_block; printf '\nowner text\n'; cat "$SRC"; } >"$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "manual: probe still once"          count_is "$GMD" "$PROBE" 1
check "manual: no marker added"           no_line "$GMD" "$BEGIN"
check "manual: 1-4 cut"                   test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"
cp "$GMD" "${TDIR}/manual.copy"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "manual repeat: unchanged"          cmp -s "$GMD" "${TDIR}/manual.copy"

# --- the phrase alone in owner notes is not the block: block still added ---------
reset_home
{ _starter_rules_block; printf '\nmy note: Тест глазами живого человека later\n'; } >"$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "phrase only: block added"          count_is "$GMD" "$BEGIN" 1
check "phrase only: 0,5-8 + 9-13"         test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"

# --- begin marker without end: block added whole ----------------------------------
reset_home
{ _starter_rules_block; printf '%s\n' "$BEGIN"; } >"$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "half marker: end marker added"     count_is "$GMD" "$END" 1
check "half marker: rules 9-13 present"   test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"

# --- the file is read through as_agent, never by root directly -------------------
reset_home
_starter_rules_block >"$GMD"
: >"$AS_AGENT_LOG"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "read: CLAUDE.md via as_agent cat"  grep -qxF "cat -- ${GMD}" "$AS_AGENT_LOG"
check "read: converted"                   test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"
# A read the agent user cannot do stops the change (the case of a swap to a root-only file).
reset_home
_starter_rules_block >"$GMD"
cp "$GMD" "${TDIR}/unread.copy"
( as_agent() { return 1; }; ensure_azv_owner_rules "$GMD" ) >/dev/null 2>&1; rc=$?
check "unreadable: stops"                 test "$rc" -ne 0
check "unreadable: file untouched"        cmp -s "$GMD" "${TDIR}/unread.copy"
check "unreadable: no backup"             test "$(baks)" -eq 0

# --- CLAUDE.md linked to someone else's file: stops, nothing written --------------
reset_home
FOREIGN="$(find /etc -maxdepth 1 -type f -user root -readable -name 'host*' | head -1)"
ln -s "$FOREIGN" "$GMD"
cp "$FOREIGN" "${TDIR}/foreign.copy"
( ensure_azv_owner_rules "$GMD" ) >/dev/null 2>&1; rc=$?
check "foreign: stops"                    test "$rc" -ne 0
check "foreign: target untouched"         cmp -s "$FOREIGN" "${TDIR}/foreign.copy"
check "foreign: no backup"                test "$(baks)" -eq 0

# --- no starter block at all: block appended at the end ---------------------------
reset_home
printf 'just owner text' >"$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "no starter: owner text kept"       grep -qxF "just owner text" "$GMD"
check "no starter: block once"            count_is "$GMD" "$BEGIN" 1
check "no starter: rules 9-13"            test "$(rules_of "$GMD")" = "9 10 11 12 13"

# --- backup name planted as a symlink: replaced, its target never written ----------
reset_home
_starter_rules_block >"$GMD"
VICTIM="${TDIR}/victim"
printf 'victim\n' >"$VICTIM"
PLANT="${GMD}.bak-20260101-000000-owner-work"
ln -s "$VICTIM" "$PLANT"
( date() { printf '20260101-000000\n'; }
  ensure_azv_owner_rules "$GMD" ) >/dev/null 2>&1
check "plant: victim untouched"           grep -qxF victim "$VICTIM"
check "plant: backup is a regular file"   test -f "$PLANT" -a ! -L "$PLANT"

# --- symlinked CLAUDE.md: target updated, link kept ------------------------------
reset_home
REAL="${TDIR}/real-CLAUDE.md"
_starter_rules_block >"$REAL"
ln -s "$REAL" "$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "symlink: link kept"                test -L "$GMD"
check "symlink: target converted"         test "$(rules_of "$REAL")" = "0 5 6 7 8 9 10 11 12 13"

# --- Superpowers off ---------------------------------------------------------------
reset_home
SP="${FAKE_HOME}/.claude/plugins/superpowers/.claude-plugin"
SETTINGS="${FAKE_HOME}/.claude/settings.json"
CFG="${FAKE_HOME}/.claude/plugins/config.json"
sp_setup() {
    mkdir -p "$SP"
    printf '{"name":"spm","plugins":[{"name":"superpowers"}]}\n' >"${SP}/marketplace.json"
}
sp_baks() { find "${FAKE_HOME}/.claude" -name '*.bak-*-superpowers-off' | wc -l; }
sp_setup
printf '{"model":"x","enabledPlugins":{"superpowers@spm":true,"other@m":true},"hooks":{"a":1}}\n' >"$SETTINGS"
printf '{"plugins":{"superpowers":{"enabled":true,"path":"/p"},"x":{"enabled":true}}}\n' >"$CFG"
cp "$SETTINGS" "${TDIR}/settings.orig"
disable_superpowers >/dev/null 2>&1
check "sp: settings flag false"           test "$(jq -r '.enabledPlugins["superpowers@spm"]' "$SETTINGS")" = "false"
check "sp: other plugin kept on"          test "$(jq -r '.enabledPlugins["other@m"]' "$SETTINGS")" = "true"
check "sp: other keys kept"               test "$(jq -c '{model,hooks}' "$SETTINGS")" = '{"model":"x","hooks":{"a":1}}'
check "sp: config.json off"               test "$(jq -r '.plugins.superpowers.enabled' "$CFG")" = "false"
check "sp: config path kept"              test "$(jq -r '.plugins.superpowers.path' "$CFG")" = "/p"
check "sp: config other kept"             test "$(jq -r '.plugins.x.enabled' "$CFG")" = "true"
check "sp: checkout not deleted"          test -f "${SP}/marketplace.json"
check "sp: two backups"                   test "$(sp_baks)" -eq 2
SB="$(find "${FAKE_HOME}/.claude" -maxdepth 1 -name 'settings.json.bak-*-superpowers-off' | head -1)"
check "sp: settings backup == original"   cmp -s "$SB" "${TDIR}/settings.orig"
cp "$SETTINGS" "${TDIR}/settings.off"; cp "$CFG" "${TDIR}/cfg.off"
disable_superpowers >/dev/null 2>&1
check "sp repeat: settings unchanged"     cmp -s "$SETTINGS" "${TDIR}/settings.off"
check "sp repeat: config unchanged"       cmp -s "$CFG" "${TDIR}/cfg.off"
check "sp repeat: no new backup"          test "$(sp_baks)" -eq 2
# write of the result fails after the backup: rc 1, not reported off
printf '{"enabledPlugins":{"superpowers@spm":true}}\n' >"$SETTINGS"
rm -f "${CFG:?}"
out=$( write_as_user() { [[ "$2" == *.bak-* ]] || return 1; install -m "$3" "$1" "$2"; }
       disable_superpowers 2>&1 ); rc=$?
check "sp: write fails -> rc 1"           test "$rc" -eq 1
check "sp: write fails -> no 'off' line"  bash -c '! grep -qF "Superpowers switched off in" <<<"$0"' "$out"
check "sp: write fails -> still on"       test "$(jq -r '.enabledPlugins["superpowers@spm"]' "$SETTINGS")" = "true"
rm -f "${SETTINGS:?}" "${CFG:?}"
find "${FAKE_HOME}/.claude" -maxdepth 1 -name 'settings.json.bak-*-superpowers-off' -delete
disable_superpowers >/dev/null 2>&1; rc=$?
check "sp: no files -> rc 0, none made"   test "$rc" -eq 0 -a ! -e "$SETTINGS" -a ! -e "$CFG"
printf 'not json' >"$SETTINGS"
disable_superpowers >/dev/null 2>&1; rc=$?
check "sp: broken settings left as is"    test "$(cat "$SETTINGS")" = "not json"
check "sp: broken settings -> rc 1"       test "$rc" -eq 1
rm -f "${SETTINGS:?}"
printf '{"enabledPlugins":{"superpowers@spm":true}}\n' >"${TDIR}/real-settings.json"
ln -s "${TDIR}/real-settings.json" "$SETTINGS"
disable_superpowers >/dev/null 2>&1; rc=$?
check "sp: symlinked settings -> rc 1"    test "$rc" -eq 1
check "sp: symlink target untouched"      test "$(jq -r '.enabledPlugins["superpowers@spm"]' "${TDIR}/real-settings.json")" = "true"
out=$( { mkdir -p "$AZV_AGENT_DIR"; _starter_rules_block >"$GMD"; azv_owner_rules_only; } 2>&1 )
check "sp: not off -> not reported off"   bash -c '! grep -qF "Superpowers выключен." <<<"$0"' "$out"
rm -f "${SETTINGS:?}"

# --- --azv-owner-rules: only these two steps ---------------------------------------
reset_home
parse_args --azv-owner-rules >/dev/null 2>&1
check "flag: parsed"                      test "$AZV_OWNER_RULES_ONLY" = "1"
AZV_OWNER_RULES_ONLY=0
parse_args --solo >/dev/null 2>&1
check "flag: off without it"              test "$AZV_OWNER_RULES_ONLY" = "0"

_starter_rules_block >"$GMD"
rm -rf "${AZV_AGENT_DIR:?}"
( azv_owner_rules_only ) >/dev/null 2>&1; rc=$?
check "only: not an AZV server -> stops"  test "$rc" -ne 0
check "only: not AZV -> file untouched"   test "$(rules_of "$GMD")" = "0 1 2 3 4 5 6 7 8"
mkdir -p "$AZV_AGENT_DIR"
rm -f "${GMD:?}"
( azv_owner_rules_only ) >/dev/null 2>&1; rc=$?
check "only: no CLAUDE.md -> stops"       test "$rc" -ne 0
check "only: no CLAUDE.md -> none made"   test ! -e "$GMD"

{ printf '# owner\n'; _starter_rules_block; } >"$GMD"
sp_setup
printf '{"enabledPlugins":{"superpowers@spm":true}}\n' >"$SETTINGS"
( azv_owner_rules_only ) >/dev/null 2>&1; rc=$?
check "only: rc 0"                        test "$rc" -eq 0
check "only: rules 0,5-8 + 9-13"          test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"
check "only: superpowers off"             test "$(jq -r '.enabledPlugins["superpowers@spm"]' "$SETTINGS")" = "false"
check "only: RED not added"               no_line "$GMD" "$RED_SECRETS_BEGIN"
check "only: CLAUDE.md backup"            test "$(baks)" -eq 1
cp "$GMD" "${TDIR}/only.copy"; cp "$SETTINGS" "${TDIR}/only.settings"
( azv_owner_rules_only ) >/dev/null 2>&1; rc=$?
check "only: repeat rc 0"                 test "$rc" -eq 0
check "only: repeat CLAUDE.md unchanged"  cmp -s "$GMD" "${TDIR}/only.copy"
check "only: repeat settings unchanged"   cmp -s "$SETTINGS" "${TDIR}/only.settings"
check "only: repeat no new backup"        test "$(baks)" -eq 1

# main with the flag: preflight, then only this step (the rest of main never runs).
out=$( preflight() { :; }
       banner() { echo BANNER; }
       install_apt_deps() { echo APT; }
       main --azv-owner-rules 2>&1 ); rc=$?
check "main flag: rc 0"                   test "$rc" -eq 0
check "main flag: no banner, no apt"      bash -c '! grep -qE "^(BANNER|APT)$" <<<"$0"' "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
