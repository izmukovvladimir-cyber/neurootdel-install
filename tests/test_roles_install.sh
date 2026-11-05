#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Roles from the install data: the main agent and the doctor get their names and explicit model ids,
# the brief pointer is there or marked absent, guard.conf carries the correction groups. No root needed.
# Synthetic names and ids only. Run: bash tests/test_roles_install.sh
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
for v in AGENT_NAME DOCTOR_NAME AGENT_MODEL DOCTOR_MODEL BRIEF_DIR CORRECTION_GROUP_CHAT_IDS; do
    unset "NEUROOTDEL_${v}" "EDGELAB_${v}"
done
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e
apply_install_names new
GUARD_LIB_DIR="${TDIR}/lib"   # guard.conf of this test only (names saved by an earlier run)
mkdir -p "$GUARD_LIB_DIR"
write_as_user() { mkdir -p "$(dirname "$2")"; install -m "${3:-0644}" "$1" "$2"; }
as_agent() { "$@"; }
step() { :; }
ok() { :; }
warn() { printf 'warn: %s\n' "$*" >>"${TDIR}/warn.log"; }
err() { :; }
OPERATOR_NAME="Анна"
OPERATOR_LANGUAGE="Russian"
OPERATOR_TIMEZONE="Europe/Moscow"
TG_USER_ID="555"
RICHARD_BOT_TOKEN=""
RICHARD_BOT_USERNAME=""

# render_all <dir> -- every role file this install writes from the data.
render_all() {
    mkdir -p "$1"
    render_agent_claude_md "$1/CLAUDE.md"
    render_jarvis_unit "$1/unit" /p/plugin /etc/x/channel.env
    render_richard_env "$1/richard.env"
    render_doctor_role "$1/DOCTOR.md"
    render_template "${TEMPLATES_DIR}/shared/STAFF.md" "$1/STAFF.md" USER_NAME "$OPERATOR_NAME" \
        AGENT_NAME "$MAIN_AGENT_NAME" DOCTOR_NAME "$DOCTOR_NAME"
}

# --- role pair 1 ------------------------------------------------------------------------------
export NEUROOTDEL_AGENT_NAME="Координатор" NEUROOTDEL_DOCTOR_NAME="Доктор"
export NEUROOTDEL_AGENT_MODEL="claude-opus-5-5" NEUROOTDEL_DOCTOR_MODEL="claude-sonnet-5-5"
export NEUROOTDEL_BRIEF_DIR="~/knowledge/istochniki/"
resolve_role_settings >/dev/null
A="${TDIR}/a"; render_all "$A"
check "pair1: agent name in CLAUDE.md"         grep -q 'You are Координатор --' "$A/CLAUDE.md"
check "pair1: brief pointer line"              grep -qF -- '- Где бриф и созвоны клиента: ~/knowledge/istochniki/' "$A/CLAUDE.md"
check "pair1: explicit model in ExecStart"     grep -q -- 'claude --model claude-opus-5-5 ' "$A/unit"
check "pair1: no alias left"                   bash -c '! grep -q -- "--model opus " "$0"' "$A/unit"
check "pair1: doctor model in .env"            grep -qx 'CLAUDE_MODEL=claude-sonnet-5-5' "$A/richard.env"
check "pair1: doctor rules sources"            grep -qx 'RICHARD_SETTING_SOURCES=user,project' "$A/richard.env"
check "pair1: doctor role file path"           grep -qx 'RICHARD_ROLE_FILE=/opt/richard/DOCTOR.md' "$A/richard.env"
check "pair1: doctor knows his own name"       grep -q 'Ты, Доктор: доктор' "$A/DOCTOR.md"
check "pair1: doctor names the agent"          grep -q 'Координатор: основной агент владельца, служба `channel-jarvis`' "$A/DOCTOR.md"
check "pair1: doctor report has recovery check" grep -q 'Как проверю восстановление' "$A/DOCTOR.md"
check "pair1: doctor report 6 lines, Russian"  grep -q 'По-русски, не длиннее 6 строк' "$A/DOCTOR.md"
check "pair1: STAFF names both"                bash -c 'grep -q "| Координатор |" "$0" && grep -q "| Доктор |" "$0"' "$A/STAFF.md"
for f in CLAUDE.md unit richard.env DOCTOR.md STAFF.md; do
    check "pair1: ${f} placeholders filled"    bash -c '! grep -q "{{" "$0"' "$A/$f"
done

# --- role pair 2: other names and models, nothing of pair 1 leaks ----------------------------------
export NEUROOTDEL_AGENT_NAME="Helper" NEUROOTDEL_DOCTOR_NAME="Medic"
export NEUROOTDEL_AGENT_MODEL="claude-opus-4-8" NEUROOTDEL_DOCTOR_MODEL="claude-haiku-4-5"
unset NEUROOTDEL_BRIEF_DIR
resolve_role_settings >/dev/null
B="${TDIR}/b"; render_all "$B"
check "pair2: agent name"                      grep -q 'You are Helper --' "$B/CLAUDE.md"
check "pair2: agent model"                     grep -q -- '--model claude-opus-4-8 ' "$B/unit"
check "pair2: doctor model"                    grep -qx 'CLAUDE_MODEL=claude-haiku-4-5' "$B/richard.env"
check "pair2: doctor names"                    bash -c 'grep -q "Ты, Medic: доктор" "$0" && grep -q "Helper: основной агент" "$0"' "$B/DOCTOR.md"
check "pair2: nothing of pair 1"               bash -c '! grep -rqE "Координатор|Доктор|sonnet-5-5|opus-5-5" "$0"' "$B"

# --- re-run without names: the names of the earlier run stay (guard.conf), DOCTOR.md keeps them ---------
render_guard_conf "" >"${GUARD_LIB_DIR}/guard.conf"
check "rerun: guard.conf saves the doctor name" grep -qx 'DOCTOR_NAME="Medic"' "${GUARD_LIB_DIR}/guard.conf"
unset NEUROOTDEL_AGENT_NAME NEUROOTDEL_DOCTOR_NAME
resolve_role_settings >/dev/null
check "rerun: names kept without env"          test "$MAIN_AGENT_NAME/$DOCTOR_NAME" = "Helper/Medic"
render_doctor_role "${TDIR}/DOCTOR.rerun"
check "rerun: DOCTOR.md keeps the team names"  bash -c 'grep -q "Ты, Medic: доктор" "$0" && grep -q "Helper: основной агент" "$0"' "${TDIR}/DOCTOR.rerun"
NEUROOTDEL_DOCTOR_NAME="Врач" resolve_role_settings >/dev/null
check "rerun: a new name given wins"           test "$DOCTOR_NAME" = "Врач"
rm -f "${GUARD_LIB_DIR:?}/guard.conf"

# --- empty brief: install does not fail, the role is marked ---------------------------------------
check "empty brief: BRIEF_DIR empty"           test -z "$BRIEF_DIR"
check "empty brief: marked «Бриф не передан»"  grep -q -- '- Бриф не передан' "$B/CLAUDE.md"
check "empty brief: no pointer line"           bash -c '! grep -q "Где бриф и созвоны" "$0"' "$B/CLAUDE.md"
rc=0; ( set -e; render_agent_claude_md "${TDIR}/c.md" ) || rc=$?
check "empty brief: render under set -e rc 0"  test "$rc" -eq 0

# --- defaults and bad input --------------------------------------------------------------------------
unset NEUROOTDEL_AGENT_NAME NEUROOTDEL_DOCTOR_NAME NEUROOTDEL_AGENT_MODEL NEUROOTDEL_DOCTOR_MODEL
resolve_role_settings >/dev/null
check "defaults: explicit agent id"            test "$AGENT_MODEL" = "$AGENT_MODEL_DEFAULT" -a "$AGENT_MODEL" != opus
check "defaults: explicit doctor id"           test "$DOCTOR_MODEL" = "$DOCTOR_MODEL_DEFAULT"
check "defaults: ids look like full ids"       bash -c '[[ "$0" == claude-*-* && "$1" == claude-*-* ]]' "$AGENT_MODEL" "$DOCTOR_MODEL"
check "defaults: names"                        test "$MAIN_AGENT_NAME/$DOCTOR_NAME" = "Jarvis/Richard"
NEUROOTDEL_AGENT_MODEL='opus --dangerously x' NEUROOTDEL_AGENT_NAME='x"; rm' NEUROOTDEL_BRIEF_DIR='$(id)' \
    resolve_role_settings >/dev/null
check "bad model -> default"                   test "$AGENT_MODEL" = "$AGENT_MODEL_DEFAULT"
check "bad name -> default"                    test "$MAIN_AGENT_NAME" = Jarvis
check "bad brief -> none"                      test -z "$BRIEF_DIR"
check "bad input warned"                       test "$(grep -c '^warn:' "${TDIR}/warn.log")" -ge 3
NEUROOTDEL_AGENT_MODEL='claude-opus-5-5[1m]' resolve_role_settings >/dev/null
check "context suffix [1m] accepted"           test "$AGENT_MODEL" = 'claude-opus-5-5[1m]'
for alias in opus sonnet haiku default 'opus[1m]'; do
    NEUROOTDEL_AGENT_MODEL="$alias" NEUROOTDEL_DOCTOR_MODEL="$alias" resolve_role_settings >/dev/null
    check "alias ${alias} refused -> explicit ids" test "$AGENT_MODEL/$DOCTOR_MODEL" = "$AGENT_MODEL_DEFAULT/$DOCTOR_MODEL_DEFAULT"
done

# --- richard .env re-run: a hand-set model survives unless a new one is given -------------------------
resolve_role_settings >/dev/null
render_richard_env "${TDIR}/r.new"
printf 'TELEGRAM_BOT_TOKEN=1:a\nCLAUDE_MODEL=hand-set-model\n' >"${TDIR}/r.old"
merge_env_file "${TDIR}/r.new" "${TDIR}/r.old" TELEGRAM_BOT_TOKEN,TELEGRAM_BOT_USERNAME,ALLOWED_USERS >"${TDIR}/r.m1"
check "rerun: hand-set doctor model kept"      grep -qx 'CLAUDE_MODEL=hand-set-model' "${TDIR}/r.m1"
merge_env_file "${TDIR}/r.new" "${TDIR}/r.old" TELEGRAM_BOT_TOKEN,TELEGRAM_BOT_USERNAME,ALLOWED_USERS,CLAUDE_MODEL >"${TDIR}/r.m2"
check "rerun: given model wins"                grep -qx "CLAUDE_MODEL=${DOCTOR_MODEL}" "${TDIR}/r.m2"
printf 'TELEGRAM_BOT_TOKEN=1:a\n' >"${TDIR}/r.old2"
merge_env_file "${TDIR}/r.new" "${TDIR}/r.old2" TELEGRAM_BOT_TOKEN >"${TDIR}/r.m3"
check "rerun: old .env without a model gets the explicit id" grep -qx "CLAUDE_MODEL=${DOCTOR_MODEL}" "${TDIR}/r.m3"

# --- guard.conf: correction groups only from the explicit list; labels follow the name -----------------
NEUROOTDEL_CORRECTION_GROUP_CHAT_IDS="-100111,-100222" render_guard_conf "" >"${TDIR}/g1"
check "guard.conf: groups written"             grep -qx 'CORRECTION_GROUP_CHAT_IDS="-100111,-100222"' "${TDIR}/g1"
render_guard_conf "${TDIR}/g1" >"${TDIR}/g2"
check "guard.conf: groups kept on re-run"      grep -qx 'CORRECTION_GROUP_CHAT_IDS="-100111,-100222"' "${TDIR}/g2"
NEUROOTDEL_CORRECTION_GROUP_CHAT_IDS="владелец" render_guard_conf "" >"${TDIR}/g3"
check "guard.conf: words are not a group"      grep -qx 'CORRECTION_GROUP_CHAT_IDS=""' "${TDIR}/g3"
NEUROOTDEL_CORRECTION_GROUP_CHAT_IDS="555" render_guard_conf "" >"${TDIR}/g4"
check "guard.conf: a user id is not a group"   grep -qx 'CORRECTION_GROUP_CHAT_IDS=""' "${TDIR}/g4"
render_guard_conf "" >"${TDIR}/g5"
check "guard.conf: default no groups"          grep -qx 'CORRECTION_GROUP_CHAT_IDS=""' "${TDIR}/g5"
printf 'AGENT_LABELS="jarvis=Old,coder=Coder"\n' >"${TDIR}/g6"
NEUROOTDEL_AGENT_NAME="Координатор" resolve_role_settings >/dev/null
NEUROOTDEL_AGENT_NAME="Координатор" render_guard_conf "${TDIR}/g6" >"${TDIR}/g7"
check "guard.conf: label follows the given name" grep -qx 'AGENT_LABELS="jarvis=Координатор,coder=Coder"' "${TDIR}/g7"
render_guard_conf "${TDIR}/g6" >"${TDIR}/g8"
check "guard.conf: no name given -> labels kept" grep -qx 'AGENT_LABELS="jarvis=Old,coder=Coder"' "${TDIR}/g8"
check "guard.conf: python reads the groups"    bash -c 'NEUROOTDEL_GUARD_CONF="$0" python3 -B -c "import sys; sys.path.insert(0, \"$1/lib\"); import guard_conf; print(guard_conf.load().correction_group_chat_ids)" | grep -qx -- "-100111,-100222"' "${TDIR}/g1" "$REPO"

# --- templates carry nothing of a real fleet ------------------------------------------------------------
check "templates: no fleet names/ids/paths"    bash -c '! grep -rliE "дарь|daria|darya|николай|nikolai|светлан|svetlan|vladimir|владимир|gosteva|гостев|/home/edgelab|1815303740" "$0"/templates/richard-DOCTOR.md "$0"/templates/shared/ROLE-ACCEPTANCE.md "$0"/templates/richard.env "$0"/templates/CLAUDE.md "$0"/lib/feedback-note.py "$0"/lib/hooks/correction-detector.py' "$REPO"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
