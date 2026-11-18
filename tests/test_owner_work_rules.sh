#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals read by sourced install.sh functions
# Tests for «Агент за вечер» (--solo) rules and Superpowers, no root needed:
#   --solo: the starter block keeps rules 0 and 5-8, rules 1-4 are cut, the owner-work
#   rules 9-13 stand once right after it; the full install keeps the starter block whole and
#   gets no owner-work block; an old --solo CLAUDE.md with rules 0-8 is converted once (backup
#   next to it, owner text kept), a repeat changes nothing; a block pasted by hand is not
#   duplicated; Superpowers is switched off reversibly (backup, idempotent);
#   team-rules.md and the core/rules.md stub get the solo texts (correction -> core/rules.md, no
#   «Skills first»), the final notes lose the Superpowers lines; --azv-owner-rules runs only these steps.
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
GUARD_LIB_DIR="${TDIR}/lib"
INSTALLER_ROOT="$REPO"
# No root here: install(1) without -o/-g (the hook refresh writes into the root-owned lib dir).
install() {
    local a=() skip=0
    for x in "$@"; do
        if ((skip)); then skip=0; continue; fi
        case "$x" in -o|-g) skip=1 ;; *) a+=("$x") ;; esac
    done
    command install "${a[@]}"
}
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
SOLO_HEAD='Правила закрывают места, где агент обычно тупит.'
SOLO_TAIL='Правила работают, если: меньше переделок, агент не трогает лишнего и помнит сказанное с первого раза.'
reset_home() { rm -rf "${FAKE_HOME:?}/.claude"; mkdir -p "${FAKE_HOME}/.claude"; }
# An install made before the solo templates: the full starter block (rules 0-8).
old_starter() { SOLO=0 _starter_rules_block; }

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
check "full: old header kept"             grep -qxF "Правила закрывают девять мест, где ИИ-агент обычно тупит." "$GMD"
check "full: old closing kept"            grep -qF "в диффах меньше лишних изменений" "$GMD"
check "full: no solo closing"             no_line "$GMD" "$SOLO_TAIL"

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
check "solo fresh: template rendered"     grep -qF "**Имя:** Tester" "$GMD"
check "solo fresh: no backup"             test "$(baks)" -eq 0
check "solo fresh: solo header"           grep -qxF "$SOLO_HEAD" "$GMD"
check "solo fresh: solo closing"          grep -qxF "$SOLO_TAIL" "$GMD"
check "solo fresh: no 'девять мест'"      no_line "$GMD" "девять мест"
check "solo fresh: no 'в диффах'"         no_line "$GMD" "в диффах"
cp "$GMD" "${TDIR}/solo.copy"
setup_global_claude >/dev/null 2>&1
check "solo re-run: unchanged"            cmp -s "$GMD" "${TDIR}/solo.copy"
check "solo re-run: no backup"            test "$(baks)" -eq 0

# --- old --solo install: starter 0-8, owner text around it ------------------------
reset_home
{
    printf '# My own rules\n\nOwner line that must survive.\n'
    old_starter
    cat "${REPO}/templates/RED-SECRETS-RULE.md"
    printf 'last owner line'     # no final newline
} >"$GMD"
chmod 0640 "$GMD"
cp "$GMD" "${TDIR}/old.copy"
check "old: starts with 0-8"              test "$(rules_of "$GMD")" = "0 1 2 3 4 5 6 7 8"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "old: 0,5-8 + 9-13"                 test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"
check "old: solo header and closing"      bash -c 'grep -qxF "$1" "$0" && grep -qxF "$2" "$0"' "$GMD" "$SOLO_HEAD" "$SOLO_TAIL"
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
check "old: only 1-4, 8 and block differ" python3 - "${TDIR}/old.copy" "$GMD" "$BEGIN" "$END" "${REPO}/templates/solo/AGENT-RULES-STARTER.md" <<'PY'
import sys
old = open(sys.argv[1], encoding="utf-8").read()
new = open(sys.argv[2], encoding="utf-8").read()
solo = open(sys.argv[5], encoding="utf-8").read()
r8 = lambda t: (t.index("\n## 8. ") + 1, t.index("\n---\n", t.index("\n## 8. ")) + 1)
a, z = r8(old)
sa, sz = r8(solo)
old = old[:a] + solo[sa:sz] + old[z:]
i, j = old.index("\n## 1. ") + 1, old.index("\n## 5. ") + 1
old = old.replace("Правила закрывают девять мест, где ИИ-агент обычно тупит.",
                  "Правила закрывают места, где агент обычно тупит.")
old = old.replace("**Правила работают, если:** в диффах меньше лишних изменений, реже приходится переписывать\n"
                  "переусложнённое, и вопросы задаются до работы, а не после переделки.",
                  "Правила работают, если: меньше переделок, агент не трогает лишнего и помнит сказанное с первого раза.")
i, j = old.index("\n## 1. ") + 1, old.index("\n## 5. ") + 1
b = new.index("\n" + sys.argv[3] + "\n")
e = new.index(sys.argv[4] + "\n") + len(sys.argv[4]) + 1
sys.exit(0 if old[:i] + old[j:] == new[:b] + new[e:] else 1)
PY
cp "$GMD" "${TDIR}/old2.copy"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "old repeat: unchanged"             cmp -s "$GMD" "${TDIR}/old2.copy"
check "old repeat: still one backup"      test "$(baks)" -eq 1

# --- old --solo install from before #1920: rule 8 with «тремя вещами» -> solo rule 8 ------
reset_home
old_starter | python3 -c '
import re, sys
t = sys.stdin.read()
t2 = re.sub(r"^- К владельцу идёшь только с .*?(?=\n\n)",
            "- К владельцу идёшь только с тремя вещами: деньги, доступы, обещания клиентам и людям.", t, count=1,
            flags=re.M | re.S)
assert t2 != t
sys.stdout.write(t2)' >"$GMD"
check "legacy r8: fixture has «тремя вещами»" grep -qF "только с тремя вещами" "$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "legacy r8: converted to solo rule 8" grep -qxF "## 8. Что решаешь сам" "$GMD"
check "legacy r8: «Решаю сам» gone"        no_line "$GMD" "Решаю сам"
check "legacy r8: «тремя вещами» gone"     no_line "$GMD" "тремя вещами"

# --- install of the #1920 hooks branch: rule 8 without the correction-line exception -> solo rule 8 ------
reset_home
old_starter | grep -vxF "  Новую строку с его поправкой в core/rules.md пишешь без вопроса." >"$GMD"
check "hooks r8: fixture has the list, no exception" bash -c 'grep -qF "изменения из пункта ниже" "$0" && ! grep -qF "пишешь без вопроса" "$0"' "$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "hooks r8: converted to solo rule 8"  grep -qxF "## 8. Что решаешь сам" "$GMD"
check "hooks r8: «Решаю сам» gone"          no_line "$GMD" "Решаю сам"

# --- pasted by hand without markers: not added again, 1-4 still cut ---------------
reset_home
{ old_starter; printf '\nowner text\n'; cat "$SRC"; } >"$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "manual: probe still once"          count_is "$GMD" "$PROBE" 1
check "manual: no marker added"           no_line "$GMD" "$BEGIN"
check "manual: 1-4 cut"                   test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"
cp "$GMD" "${TDIR}/manual.copy"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "manual repeat: unchanged"          cmp -s "$GMD" "${TDIR}/manual.copy"

# --- the phrase alone in owner notes is not the block: block still added ---------
reset_home
{ old_starter; printf '\nmy note: Тест глазами живого человека later\n'; } >"$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "phrase only: block added"          count_is "$GMD" "$BEGIN" 1
check "phrase only: 0,5-8 + 9-13"         test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"

# --- begin marker without end: block added whole ----------------------------------
reset_home
{ old_starter; printf '%s\n' "$BEGIN"; } >"$GMD"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "half marker: end marker added"     count_is "$GMD" "$END" 1
check "half marker: rules 9-13 present"   test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"

# --- the file is read through as_agent, never by root directly -------------------
reset_home
old_starter >"$GMD"
: >"$AS_AGENT_LOG"
ensure_azv_owner_rules "$GMD" >/dev/null 2>&1
check "read: CLAUDE.md via as_agent cat"  grep -qxF "cat -- ${GMD}" "$AS_AGENT_LOG"
check "read: converted"                   test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"
check "write: CLAUDE.md as the agent"     grep -qF " write ${GMD} " "$AS_AGENT_LOG"
check "write: backup as the agent"        grep -qE " write ${GMD}\.bak-[0-9-]+-owner-work " "$AS_AGENT_LOG"
# A read the agent user cannot do stops the change (the case of a swap to a root-only file).
reset_home
old_starter >"$GMD"
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

# --- backup name planted as a symlink: stops, its target never written ------------
reset_home
old_starter >"$GMD"
VICTIM="${TDIR}/victim"
printf 'victim\n' >"$VICTIM"
PLANT="${GMD}.bak-20260101-000000-owner-work"
ln -s "$VICTIM" "$PLANT"
( date() { printf '20260101-000000\n'; }
  ensure_azv_owner_rules "$GMD" ) >/dev/null 2>&1
check "plant: victim untouched"           grep -qxF victim "$VICTIM"
check "plant: link left, not followed"    test -L "$PLANT"
check "plant: CLAUDE.md not changed"      test "$(rules_of "$GMD")" = "0 1 2 3 4 5 6 7 8"

# --- symlinked CLAUDE.md: target updated, link kept ------------------------------
reset_home
REAL="${TDIR}/real-CLAUDE.md"
old_starter >"$REAL"
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
out=$( _agent_write() { [[ "$2" == *.bak-* ]] || return 1; install -m "$3" "$1" "$2"; }
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
out=$( { mkdir -p "$AZV_AGENT_DIR"; old_starter >"$GMD"; azv_owner_rules_only; } 2>&1 )
check "sp: not off -> not reported off"   bash -c '! grep -qF "Superpowers выключен." <<<"$0"' "$out"
rm -f "${SETTINGS:?}"

# --- team-rules.md and core/rules.md: solo texts ---------------------------------
TEAM_SRC="${TDIR}/team-rules.rendered"
render_template "${REPO}/templates/shared/team-rules.md" "$TEAM_SRC" \
    USER_NAME Tester LIB /opt/lib CONFIG_ROOT /etc/x USER "$ME" AGENT_NAME A DOCTOR_NAME D >/dev/null 2>&1
check "team: rendered"                    test -s "$TEAM_SRC"
_azv_fix team "$TEAM_SRC" "${TDIR}/team.solo" >/dev/null 2>&1; rc=$?
TS="${TDIR}/team.solo"
check "team: changed (rc 0)"              test "$rc" -eq 0
check "team: no Skills first"             no_line "$TS" "## Skills first"
check "team: no brainstorming"            no_line "$TS" "brainstorming"
check "team: no feedback-note route"      no_line "$TS" "feedback-note.py"
check "team: no 'Not into core/rules.md'" no_line "$TS" "Not into core/rules.md"
check "team: route = core/rules.md"       grep -qF "one short line in core/rules.md" "$TS"
check "team: «Записал в правила»"         grep -qF "«Записал в правила»" "$TS"
check "team: cancel in core/rules.md"     grep -qF "rewrite or delete that line in core/rules.md" "$TS"
check "team: Memory heading kept"         count_is "$TS" "## Memory" 1
check "team: other lines kept"            python3 - "$TEAM_SRC" "$TS" <<'PY'
import sys
old = open(sys.argv[1], encoding="utf-8").read().split("\n")
new = open(sys.argv[2], encoding="utf-8").read().split("\n")
h = old.index("## Skills first")
m = old.index("## Memory")
f = next(i for i, ln in enumerate(old) if ln.startswith("- The owner's correction has ONE route."))
c = next(i for i, ln in enumerate(old) if ln.startswith("- Cancel: a new note"))
t = next(i for i, ln in enumerate(old) if ln.startswith("- The owner's idea or plan:"))
keep = old[:t] + old[t + 2:h] + old[m:f] + old[c + 1:]
nt = next(i for i, ln in enumerate(new) if ln.startswith("- The owner's request: do exactly what was asked"))
nf = next(i for i, ln in enumerate(new) if ln.startswith("- The owner's correction has ONE route."))
nc = next(i for i, ln in enumerate(new) if ln.startswith("- Cancel: rewrite"))
sys.exit(0 if new[:nt] + new[nt + 2:nf] + new[nc + 1:] == keep else 1)
PY
_azv_fix team "$TS" "${TDIR}/team.twice" >/dev/null 2>&1; rc=$?
check "team: second pass rc 1"            test "$rc" -eq 1
# owner edits inside the replaced parts: those parts stay as they are
python3 - "$TEAM_SRC" "${TDIR}/team.edited" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
t = t.replace("  Fields: area (where it applies)", "  Fields (owner edit): area (where it applies)")
t = t.replace("the old note and its line are deleted.", "the old note and its line are deleted. OWNER ADDITION.")
t = t.replace("No fitting skill: skill-finder.", "No fitting skill: ask me.")
t = t.replace("Agree only with a\n  reason; argue once.", "Agree only with a\n  reason; argue twice.")
open(sys.argv[2], "w", encoding="utf-8").write(t)
PY
_azv_fix team "${TDIR}/team.edited" "${TDIR}/team.edited.out" >/dev/null 2>&1; rc=$?
check "team edited: nothing replaced"     test "$rc" -eq 1
why=$(_azv_fix team "${TDIR}/team.edited" "${TDIR}/team.edited.out" 2>&1 >/dev/null)
check "team edited: says why (3 parts)"   test "$(grep -c "edited by the owner" <<<"$why")" -eq 3
# only the route edited: the untouched «Cancel» stays too (they move together); Skills still cut
python3 - "$TEAM_SRC" "${TDIR}/team.route" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(
    t.replace("  Fields: area (where it applies)", "  Fields (owner edit): area (where it applies)"))
PY
_azv_fix team "${TDIR}/team.route" "${TDIR}/team.route.out" >/dev/null 2>&1; rc=$?
check "route edited: Skills still cut"    test "$rc" -eq 0 -a "$(grep -c "## Skills first" "${TDIR}/team.route.out")" -eq 0
check "route edited: route kept"          grep -qF "Fields (owner edit)" "${TDIR}/team.route.out"
check "route edited: old Cancel kept"     grep -qF -- "- Cancel: a new note with" "${TDIR}/team.route.out"
check "route edited: no new Cancel"       no_line "${TDIR}/team.route.out" "rewrite or delete that line"
# only «Cancel» edited: the untouched route stays too
python3 - "$TEAM_SRC" "${TDIR}/team.cancel" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(
    t.replace("the old note and its line are deleted.", "the old note and its line are deleted. OWNER ADDITION."))
PY
_azv_fix team "${TDIR}/team.cancel" "${TDIR}/team.cancel.out" >/dev/null 2>&1
check "cancel edited: route kept"         grep -qF "feedback-note.py" "${TDIR}/team.cancel.out"
check "cancel edited: cancel kept"        grep -qF "OWNER ADDITION." "${TDIR}/team.cancel.out"

RS="${TDIR}/rules.md"
printf '# Rules\n\n- Ask before destructive operations.\n- On each correction of the owner: one feedback note in auto memory + one line in MEMORY.md (route and command: ~/.claude-lab/shared/team-rules.md, «Memory»). Not here, not in LEARNINGS.md.\n- Owner rule: no emoji.\n' >"$RS"
_azv_fix rules "$RS" "${TDIR}/rules.solo" >/dev/null 2>&1; rc=$?
check "rules: changed (rc 0)"             test "$rc" -eq 0
check "rules: line points here"           grep -qF "one line here, in this file, in the same turn" "${TDIR}/rules.solo"
check "rules: no feedback note"           no_line "${TDIR}/rules.solo" "feedback note"
check "rules: owner line kept"            grep -qxF -- "- Owner rule: no emoji." "${TDIR}/rules.solo"
check "rules: 5 lines as before"          test "$(wc -l <"${TDIR}/rules.solo")" -eq "$(wc -l <"$RS")"
_azv_fix rules "${TDIR}/rules.solo" "${TDIR}/rules.twice" >/dev/null 2>&1; rc=$?
check "rules: second pass rc 1"           test "$rc" -eq 1
printf -- '- On each correction of the owner: my own wording.\n' >"${TDIR}/rules.edited"
_azv_fix rules "${TDIR}/rules.edited" "${TDIR}/rules.e2" >/dev/null 2>&1; rc=$?
check "rules: owner-edited line kept"     test "$rc" -eq 1

# workspace: full install keeps the stub line, --solo writes the solo one
WS="${TDIR}/ws-full/.claude"
SOLO=0
_write_agent_workspace "$WS" >/dev/null 2>&1
check "ws full: stub feedback line kept"  grep -qF "one feedback note in auto memory" "${WS}/core/rules.md"
WS="${TDIR}/ws-solo/.claude"
SOLO=1
_write_agent_workspace "$WS" >/dev/null 2>&1
check "ws solo: stub points at rules.md"  grep -qF "one line here, in this file, in the same turn" "${WS}/core/rules.md"
check "ws solo: no backup on fresh"       test "$(find "${WS}/core" -name '*.bak-*' | wc -l)" -eq 0
cp "${WS}/core/rules.md" "${TDIR}/ws.copy"
_write_agent_workspace "$WS" >/dev/null 2>&1
check "ws solo re-run: unchanged"         cmp -s "${WS}/core/rules.md" "${TDIR}/ws.copy"
# an old solo workspace with the full stub: converted on re-run, backup made
WS="${TDIR}/ws-old/.claude"
SOLO=0
_write_agent_workspace "$WS" >/dev/null 2>&1
SOLO=1
_write_agent_workspace "$WS" >/dev/null 2>&1
check "ws old: converted on solo re-run"  grep -qF "one line here, in this file, in the same turn" "${WS}/core/rules.md"
check "ws old: one backup"                test "$(find "${WS}/core" -name 'rules.md.bak-*-owner-work' | wc -l)" -eq 1

# final notes: no Superpowers lines in --solo, both in the full install
fin() { ( JARVIS_BOT_TOKEN=x RICHARD_BOT_TOKEN=x SOLO=$1 final_instructions ) 2>/dev/null | grep -c superpowers; }
check "final: full has 2 superpowers lines" test "$(fin 0)" -eq 2
check "final: solo has none"              test "$(fin 1)" -eq 0

# --- correction hooks refreshed into the lib dir -------------------------------------
H="${GUARD_LIB_DIR}/hooks"
( azv_refresh_correction_hooks ) >/dev/null 2>&1; rc=$?
check "hooks: no lib dir -> rc 1"         test "$rc" -eq 1
mkdir -p "$H"
printf 'old detector\n' >"${H}/correction-detector.py"
printf 'old closer\n' >"${H}/correction-closed.py"
printf 'old conf\n' >"${GUARD_LIB_DIR}/guard_conf.py"
( azv_refresh_correction_hooks ) >/dev/null 2>&1; rc=$?
check "hooks: old guard_conf -> rc 1"     test "$rc" -eq 1
check "hooks: old guard_conf -> kept"     test "$(cat "${H}/correction-detector.py")" = "old detector"
cp "${REPO}/lib/guard_conf.py" "${GUARD_LIB_DIR}/guard_conf.py"
cp "${REPO}/lib/hooks/correction-closed.py" "${H}/correction-closed.py"
azv_refresh_correction_hooks >/dev/null 2>&1; rc=$?
check "hooks: rc 0"                       test "$rc" -eq 0
check "hooks: detector current"           cmp -s "${H}/correction-detector.py" "${REPO}/lib/hooks/correction-detector.py"
check "hooks: closer current"             cmp -s "${H}/correction-closed.py" "${REPO}/lib/hooks/correction-closed.py"
rm -f "${H:?}/correction-closed.py"
azv_refresh_correction_hooks >/dev/null 2>&1
check "hooks: absent hook not added"      test ! -e "${H}/correction-closed.py"
cp "${REPO}/lib/hooks/correction-closed.py" "${H}/correction-closed.py"
check "hooks: old detector backed up"     test "$(cat "${H}"/correction-detector.py.bak-*-owner-work)" = "old detector"
check "hooks: one backup"                 test "$(find "$H" -name '*.bak-*' | wc -l)" -eq 1
azv_refresh_correction_hooks >/dev/null 2>&1
check "hooks: repeat no new backup"       test "$(find "$H" -name '*.bak-*' | wc -l)" -eq 1
printf 'old closer\n' >"${H}/correction-closed.py"

# --- --azv-owner-rules: only these steps ----------------------------------------------
reset_home
parse_args --azv-owner-rules >/dev/null 2>&1
check "flag: parsed"                      test "$AZV_OWNER_RULES_ONLY" = "1"
AZV_OWNER_RULES_ONLY=0
parse_args --solo >/dev/null 2>&1
check "flag: off without it"              test "$AZV_OWNER_RULES_ONLY" = "0"

old_starter >"$GMD"
rm -rf "${AZV_AGENT_DIR:?}"
( azv_owner_rules_only ) >/dev/null 2>&1; rc=$?
check "only: not an AZV server -> stops"  test "$rc" -ne 0
check "only: not AZV -> file untouched"   test "$(rules_of "$GMD")" = "0 1 2 3 4 5 6 7 8"
mkdir -p "$AZV_AGENT_DIR"
rm -f "${GMD:?}"
( azv_owner_rules_only ) >/dev/null 2>&1; rc=$?
check "only: no CLAUDE.md -> stops"       test "$rc" -ne 0
check "only: no CLAUDE.md -> none made"   test ! -e "$GMD"

{ printf '# owner\n'; old_starter; } >"$GMD"
SH_TEAM="${FAKE_HOME}/.claude-lab/shared/team-rules.md"
J_RULES="${FAKE_HOME}/.claude-lab/jarvis/.claude/core/rules.md"
mkdir -p "$(dirname "$SH_TEAM")" "$(dirname "$J_RULES")"
cp "$TEAM_SRC" "$SH_TEAM"
cp "$RS" "$J_RULES"
sp_setup
printf '{"enabledPlugins":{"superpowers@spm":true}}\n' >"$SETTINGS"
( azv_owner_rules_only ) >/dev/null 2>&1; rc=$?
check "only: rc 0"                        test "$rc" -eq 0
check "only: rules 0,5-8 + 9-13"          test "$(rules_of "$GMD")" = "0 5 6 7 8 9 10 11 12 13"
check "only: superpowers off"             test "$(jq -r '.enabledPlugins["superpowers@spm"]' "$SETTINGS")" = "false"
check "only: RED not added"               no_line "$GMD" "$RED_SECRETS_BEGIN"
check "only: CLAUDE.md backup"            test "$(baks)" -eq 1
check "only: solo header"                 grep -qxF "$SOLO_HEAD" "$GMD"
check "only: team-rules converted"        cmp -s "$SH_TEAM" "$TS"
check "only: team-rules backup"           test "$(find "$(dirname "$SH_TEAM")" -name 'team-rules.md.bak-*-owner-work' | wc -l)" -eq 1
check "only: rules.md converted"          cmp -s "$J_RULES" "${TDIR}/rules.solo"
check "only: rules.md backup"             test "$(find "$(dirname "$J_RULES")" -name 'rules.md.bak-*-owner-work' | wc -l)" -eq 1
cp "$SH_TEAM" "${TDIR}/only.team"; cp "$J_RULES" "${TDIR}/only.rules"
cp "$GMD" "${TDIR}/only.copy"; cp "$SETTINGS" "${TDIR}/only.settings"
( azv_owner_rules_only ) >/dev/null 2>&1; rc=$?
check "only: repeat rc 0"                 test "$rc" -eq 0
check "only: repeat CLAUDE.md unchanged"  cmp -s "$GMD" "${TDIR}/only.copy"
check "only: repeat settings unchanged"   cmp -s "$SETTINGS" "${TDIR}/only.settings"
check "only: repeat no new backup"        test "$(baks)" -eq 1
check "only: repeat team-rules unchanged" cmp -s "$SH_TEAM" "${TDIR}/only.team"
check "only: repeat rules.md unchanged"   cmp -s "$J_RULES" "${TDIR}/only.rules"
check "only: closer hook refreshed"      cmp -s "${H}/correction-closed.py" "${REPO}/lib/hooks/correction-closed.py"
check "only: repeat no team/rules backup" test "$(find "${FAKE_HOME}/.claude-lab" -name '*.bak-*-owner-work' | wc -l)" -eq 2

# main with the flag: preflight, then only this step (the rest of main never runs).
out=$( preflight() { :; }
       banner() { echo BANNER; }
       install_apt_deps() { echo APT; }
       main --azv-owner-rules 2>&1 ); rc=$?
check "main flag: rc 0"                   test "$rc" -eq 0
check "main flag: no banner, no apt"      bash -c '! grep -qE "^(BANNER|APT)$" <<<"$0"' "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
