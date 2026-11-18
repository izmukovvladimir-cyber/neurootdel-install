#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced install.sh functions, overrides
# «Агент за вечер» (--solo), what loads on every turn of a clean install (#1920 c, e, f):
#   weight   the whole turn (tests/helpers/solo_weight.sh, the files lib/include_weight.py counts) is under
#            25 KB with a soul of SOUL_FILLER_BYTES; the team install keeps its team texts;
#   texts    none of the phrases that contradicted the owner-work rules (audit #1920, 2.3) is in the
#            every-turn files of a solo install; what left the turn is on disk and named by a pointer line;
#   re-run   an earlier solo install (team-rules @, learned-practices in rules/, lessons in MEMORY.md) loses
#            them from the turn, the files are kept;
#   hooks    guard.conf AGENT_MODE: solo for --solo (text standard off by default), team otherwise;
#            critical-check.py in solo asks to read the whole message, not to argue; the Pro plan is not
#            called «too small» in solo.
# No root, no network. Run: bash tests/test_solo_context.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
LIMIT=$((25 * 1024))

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
total_of() { sed -n 's/^TOTAL \([0-9]*\)$/\1/p' "$1"; }

# --- weight -------------------------------------------------------------------------
bash "${REPO}/tests/helpers/solo_weight.sh" --keep "${TDIR}/solo" >"${TDIR}/solo.txt"
bash "${REPO}/tests/helpers/solo_weight.sh" --full --keep "${TDIR}/full" >"${TDIR}/full.txt"
SOLO_TOTAL=$(total_of "${TDIR}/solo.txt")
cat "${TDIR}/solo.txt"
check "weight: measured"                     test -n "$SOLO_TOTAL"
check "weight: solo turn < 25 KB (${SOLO_TOTAL} B)" test "${SOLO_TOTAL:-999999}" -lt "$LIMIT"
SOUL_SUM=$(awk '/azv\/soul\// {s += $1} END {print s + 0}' "${TDIR}/solo.txt")
check "weight: whole soul budget counted (${SOUL_SUM} B)" test "$SOUL_SUM" -ge 8100
check "weight: no learned-practices in turn" bash -c '! grep -q learned-practices "$0"' "${TDIR}/solo.txt"
check "weight: no team-rules in turn"        bash -c '! grep -qE "team-rules|TOOLS-root-requests" "$0"' "${TDIR}/solo.txt"
check "weight: full keeps team-rules"        grep -q 'shared/team-rules.md$' "${TDIR}/full.txt"
check "weight: full keeps learned-practices" grep -q 'rules/learned-practices.md$' "${TDIR}/full.txt"

H="${TDIR}/solo/home"
WS="${H}/.claude-lab/jarvis/.claude"
TURN="${TDIR}/turn.txt"
# The every-turn files of the solo install, as the measure listed them.
sed -n 's/^ *[0-9][0-9]*  \(.*\)$/\1/p' "${TDIR}/solo.txt" | while read -r f; do cat -- "${H}/${f}"; done >"$TURN"
check "texts: turn files collected"          test -s "$TURN"

# --- texts: the contradictions of the audit (2.3) are gone from the solo turn ----------
# 1 wait for «да»: starter rule 4 «не жди», rule 8 «решаю сам», the global's «retell and start»
# 2 propose your own: starter rule 1 «спорь», team «Thinking», critical-check «не соглашайся»
# 3 where a correction goes: auto memory / feedback note / «not into core/rules.md»
# 4 interim messages: «Silence = bug»
# 5 how a reply starts: «Code first»
# 6 the first meeting: the team template's own interview wording
BANNED=(
    "разрешения не жди"
    "Решаю сам"
    "К владельцу идёшь только с тремя вещами"
    "retell in one line and start"
    "Видишь способ проще"
    "Спорь"
    "the better option"
    "your own assessment"
    "не соглашайся"
    "feedback note"
    "Not into core/rules.md"
    "Not here, not in LEARNINGS.md"
    "One link line per"
    "Silence = bug"
    "Code first"
    "offer the interview"
    "Plan mode"
    "git push"
)
for p in "${BANNED[@]}"; do
    check "texts: no «${p}»"                 bash -c '! grep -qiF -- "$1" "$0"' "$TURN" "$p"
done
check "texts: read the whole message"        grep -qF "читаешь целиком до первого действия" "$TURN"
check "texts: one question when unclear"     grep -qF "один вопрос до работы" "$TURN"
check "texts: rules 9-13 in the turn"        test "$(grep -cE '^## (9|1[0-3])\. ' "$TURN")" -eq 5
check "texts: correction -> core/rules.md"   grep -qF "правило работы в \`core/rules.md\`" "$TURN"
check "texts: RED block in the turn"         grep -qF "red-secrets-rule:begin" "$TURN"
check "texts: one first meeting"             grep -qF "Знакомство одно" "$TURN"
# #1920: the owner's things and own rules only after «да», how-to stays with the agent (rule 8), deadlines in
# hours with a ready time (#1921), the first meeting starts with the agent's own name.
check "texts: owner's settings after «да»"   grep -qF "подключения его ботов, сервисов, cron," "$TURN"
check "texts: own rules after «да»"          grep -qF "свои CLAUDE.md, settings и правила (кроме новой строки в core/rules.md) только после" "$TURN"
check "texts: rule 8 how = agent"            grep -qF "сам решаешь, как его сделать" "$TURN"
check "texts: deadlines in hours"            grep -qF "Расход в минутах/часах -> время готовности по его часам" "$TURN"
check "texts: greets with its own name"      grep -qF "«Привет, я Jarvis»" "$TURN"
check "texts: no placeholders left"          bash -c '! grep -qF "{{" "$0"' "$TURN"

# --- what left the turn is kept, with a pointer --------------------------------------
SH="${H}/.claude-lab/shared"
LP="${WS}/dashi-plugin-claude-code/plugin/.claude/learned-practices/learned-practices.md"
MEM_DIR=$(dirname "$(sed -n 's/^ *[0-9][0-9]*  \(.*memory\/MEMORY.md\)$/\1/p' "${TDIR}/solo.txt")")
for f in "${SH}/GLOBAL-TEAM-RULES.md" "${SH}/team-rules.md" "${SH}/TOOLS-root-requests.md" "$LP"; do
    check "refs: $(basename "$f") on disk"   test -s "$f"
    check "refs: $(basename "$f") named"     grep -qF "$(basename "$f")" "${WS}/CLAUDE.md"
done
check "refs: no @ to a reference"            bash -c '! grep -qE "^@.*(team-rules|TOOLS-root-requests|GLOBAL-TEAM-RULES|learned-practices)" "$0"' "${WS}/CLAUDE.md"
check "refs: team global = template + note"  grep -qF "## Git" "${SH}/GLOBAL-TEAM-RULES.md"
check "refs: team global yields to solo"     grep -qF "правы они" "${SH}/GLOBAL-TEAM-RULES.md"
check "refs: lessons index in index-infra"   grep -qE "BEGIN [a-z-]+: memory-lessons -->" "${H}/${MEM_DIR}/index-infra.md"
check "refs: no lessons in MEMORY.md"        bash -c '! grep -qE "^- \[[^]]*\]\(feedback-" "$0"' "${H}/${MEM_DIR}/MEMORY.md"
check "refs: team solo route kept"           grep -qF "one short line in core/rules.md" "${SH}/team-rules.md"
check "refs: team solo no «better option»"   bash -c '! grep -qF "the better option" "$0"' "${SH}/team-rules.md"
check "refs: LEARNINGS stub -> core/rules"   grep -qF "core/rules.md" "${WS}/core/LEARNINGS.md"
# #1920 live weight: the model counts what a live install loads (key watermark in every soul file, the
# plugin's own CLAUDE.md); the solo core/rules.md stub has no copies of the global rules.
check "weight: soul files carry the watermark" grep -qF "Личная копия для" "${WS}/azv/soul/rules.md"
check "weight: plugin CLAUDE.md counted"     grep -q 'dashi-plugin-claude-code/plugin/CLAUDE.md$' "${TDIR}/solo.txt"
check "rules stub: correction line kept"     grep -qF "one line here, in this file, in the same turn" "${WS}/core/rules.md"
check "rules stub: one reply per question"   grep -qF "## Один ответ на вопрос" "${WS}/core/rules.md"
check "rules stub: no global duplicates"     bash -c '! grep -qE "Ask before destructive|Never commit secrets|Prefer small" "$0"' "${WS}/core/rules.md"

# --- the team install is unchanged -----------------------------------------------------
FH="${TDIR}/full/home"
check "full: team global"                    grep -qF "Code first" "${FH}/.claude/CLAUDE.md"
check "full: rules 0-8"                      test "$(grep -oE '^## [0-9]\. ' "${FH}/.claude/CLAUDE.md" | tr -d '#. \n')" = "012345678"
check "full: team-rules @"                   grep -qx '@~/.claude-lab/shared/team-rules.md' "${FH}/.claude-lab/jarvis/.claude/CLAUDE.md"
check "full: no solo refs"                   test ! -e "${FH}/.claude-lab/shared/GLOBAL-TEAM-RULES.md"

# --- re-run over an earlier solo install: the references leave the turn ------------------
export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
cp "${REPO}/install.sh" "${TDIR}/install.sh"
# shellcheck disable=SC1091
source "${TDIR}/install.sh"
set +e
as_agent() { "$@"; }
step() { :; }
ok() { :; }
log() { :; }
warn() { :; }
err() { :; }
RH="${TDIR}/full/home"
AGENT_HOME="$RH"
AGENT_USER="$(id -un)"
GUARD_LIB_DIR="${TDIR}/lib"
TEMPLATES_DIR="${REPO}/templates"
OPERATOR_NAME="Анна"; TG_USER_ID=42; OPERATOR_LANGUAGE=ru; OPERATOR_TIMEZONE=Europe/Moscow
MAIN_AGENT_NAME=Jarvis; CODER_INSTALLED=0
RWS="${RH}/.claude-lab/jarvis/.claude"
RPL="${RWS}/dashi-plugin-claude-code/plugin/.claude"
SOLO=1
install_team_refs; rc=$?
check "re-run: rc 0"                         test "$rc" -eq 0
check "re-run: team-rules not @ any more"    bash -c '! grep -qx "@~/.claude-lab/shared/team-rules.md" "$0"' "${RWS}/CLAUDE.md"
check "re-run: root memo not @ any more"     bash -c '! grep -qx "@~/.claude-lab/shared/TOOLS-root-requests.md" "$0"' "${RWS}/CLAUDE.md"
check "re-run: pointer to team-rules"        grep -qF "~/.claude-lab/shared/team-rules.md" "${RWS}/CLAUDE.md"
check "re-run: learned-practices moved"      test ! -e "${RPL}/rules/learned-practices.md" -a -s "${RPL}/learned-practices/learned-practices.md"
RMEM=$(find "${RH}/.claude/projects" -name MEMORY.md | head -1)
check "re-run: lessons out of MEMORY.md"     bash -c '! grep -qE "^- \[[^]]*\]\(feedback-" "$0"' "$RMEM"
check "re-run: lessons in index-infra"       grep -qE "BEGIN [a-z-]+: memory-lessons -->" "$(dirname "$RMEM")/index-infra.md"
# an owner-edited learned-practices in rules/ stays where it is
printf 'owner edit\n' >>"${RPL}/learned-practices/learned-practices.md"
mv "${RPL}/learned-practices/learned-practices.md" "${RPL}/rules/learned-practices.md"
cp "${RPL}/rules/learned-practices.md" "${TDIR}/lp.edited"
install_team_refs >/dev/null 2>&1; rc=$?
check "re-run 2: rc 0"                       test "$rc" -eq 0
check "re-run 2: edited copy left as is"     cmp -s "${TDIR}/lp.edited" "${RPL}/rules/learned-practices.md"
check "re-run 2: no reference copy made"     test ! -e "${RPL}/learned-practices/learned-practices.md"
check "re-run 2: no pointer to a missing reference" bash -c '! grep -qF "learned-practices/learned-practices.md" "$0"' "${RWS}/CLAUDE.md"
check "re-run 2: other pointers kept"        grep -qF "~/.claude-lab/shared/team-rules.md" "${RWS}/CLAUDE.md"

# --- guard.conf AGENT_MODE and the hooks ---------------------------------------------------
DOCTOR_NAME=D
unset NEUROOTDEL_FACT_GATE_TEXT_STANDARD
SOLO=1; render_guard_conf "" >"${TDIR}/g.solo"
SOLO=0; render_guard_conf "" >"${TDIR}/g.team"
SOLO=0; render_guard_conf "${TDIR}/g.solo" >"${TDIR}/g.kept"
check "conf: solo mode"                      grep -qx 'AGENT_MODE="solo"' "${TDIR}/g.solo"
check "conf: solo text standard off"         grep -qx 'FACT_GATE_TEXT_STANDARD="0"' "${TDIR}/g.solo"
check "conf: team mode"                      grep -qx 'AGENT_MODE="team"' "${TDIR}/g.team"
check "conf: team text standard on"          grep -qx 'FACT_GATE_TEXT_STANDARD="1"' "${TDIR}/g.team"
check "conf: solo kept on re-run"            grep -qx 'AGENT_MODE="solo"' "${TDIR}/g.kept"

HK="${REPO}/lib/hooks"
owner_msg() { jq -cn --arg p "<channel source=\"telegram\" chat_id=\"42\" user_id=\"42\">$1</channel>" '{prompt:$p}'; }
IDEA="Давай уберём меню из бота и сделаем одну кнопку, а потом поменяй текст приветствия"
OUT=$(owner_msg "$IDEA" | NEUROOTDEL_GUARD_CONF="${TDIR}/g.solo" python3 "${HK}/critical-check.py")
check "critical solo: read-whole line"       grep -qF "прочитай его целиком" <<<"$OUT"
check "critical solo: no «не соглашайся»"    bash -c '! grep -qF "не соглашайся" <<<"$0"' "$OUT"
OUT=$(owner_msg "$IDEA" | NEUROOTDEL_GUARD_CONF="${TDIR}/g.team" python3 "${HK}/critical-check.py")
check "critical team: unchanged"             grep -qF "критическое мышление" <<<"$OUT"
OUT=$(owner_msg "ок" | NEUROOTDEL_GUARD_CONF="${TDIR}/g.solo" python3 "${HK}/critical-check.py")
check "critical solo: ack -> silent"         test -z "$OUT"

cred="${TDIR}/cred.json"
printf '{"claudeAiOauth":{"subscriptionType":"pro"}}' >"$cred"
ok() { printf 'OK %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
SOLO=1; OUT=$(report_claude_plan "$cred" 2>&1)
check "plan solo: pro not «too small»"       bash -c '! grep -qF "too small" <<<"$0"' "$OUT"
check "plan solo: pro named"                 grep -qF "plan: pro" <<<"$OUT"
SOLO=0; OUT=$(report_claude_plan "$cred" 2>&1)
check "plan team: pro still warned"          grep -qF "too small" <<<"$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
