#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329  # eval strings, globals read by sourced fns, overrides
# Tests for the required bot of every agent and the install stages of install.sh, no root needed:
#   collect_bot_token (asks again until a token passes: format, own bot, getMe; env / no tty -> stop;
#   empty answer keeps the server's token), resolve_stage / parse_args, collect_inputs per stage,
#   INSTALL_STAGE + SKILLS_EXPECTED in guard.conf, the end-of-stage check in main.
# Run: bash tests/test_mandatory_bots.sh
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
not() { ! "$@"; }

FAKE_HOME="${TDIR}/home"
mkdir -p "$FAKE_HOME" "${TDIR}/etc" "${TDIR}/lib"
sed -e "s#^readonly RICHARD_HOME=.*#readonly RICHARD_HOME=\"${TDIR}/richard\"#" "${REPO}/install.sh" >"${TDIR}/install.sh"

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
export NEUROOTDEL_INSTALLER_ROOT="$REPO"
unset NEUROOTDEL_NONINTERACTIVE EDGELAB_NONINTERACTIVE NEUROOTDEL_STAGE
for a in JARVIS RICHARD CODER AUDITOR; do unset "NEUROOTDEL_${a}_BOT_TOKEN" "EDGELAB_${a}_BOT_TOKEN"; done
# shellcheck disable=SC1091
source "${TDIR}/install.sh"
set +e
apply_install_names new
AGENT_HOME="$FAKE_HOME"
CONFIG_ROOT="${TDIR}/etc"
JARVIS_ENV_DIR="${CONFIG_ROOT}/jarvis"
CODER_ENV_DIR="${CONFIG_ROOT}/coder"
GUARD_LIB_DIR="${TDIR}/lib"
as_agent() { "$@"; }
step() { :; }

TOKEN_J="123456789:AAHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_R="222333444:RRHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_C="777888999:CCHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_A="444555666:AUDabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_DEAD="999000111:DEADbcdefghijklmnopqrstuvwxyz0123456"
# getMe stub: the "dead" bot is refused, every other answers ok with a username from its id.
GETME="${TDIR}/getme.calls"
tg_get_me() {
    printf '%s\n' "${1%%:*}" >>"$GETME"
    if [[ "${1%%:*}" == "${TOKEN_DEAD%%:*}" ]]; then printf '{"ok":false}'; return 0; fi
    printf '{"ok":true,"result":{"username":"bot_%s"}}' "${1%%:*}"
}
is_noninteractive() { [[ "${FAKE_NOTTY:-0}" == 1 ]]; }
answers() { printf '%s\n' "$@" >"${TDIR}/tty"; TTY_IN="${TDIR}/tty"; TTY_FD=""; }
reset_tokens() { JARVIS_BOT_TOKEN=""; RICHARD_BOT_TOKEN=""; CODER_BOT_TOKEN=""; AUDITOR_BOT_TOKEN="";
                 JARVIS_BOT_USERNAME=""; RICHARD_BOT_USERNAME=""; CODER_BOT_USERNAME=""; AUDITOR_BOT_USERNAME=""; }

# --- collect_bot_token: asks again until a token passes ------------------------------------------
reset_tokens; JARVIS_BOT_TOKEN="$TOKEN_J"; : >"$GETME"
answers "bad-token" "$TOKEN_J" "$TOKEN_DEAD" "$TOKEN_C"
OUT=$( (collect_bot_token coder; printf 'rc=%s tok=%s user=%s' "$?" "${CODER_BOT_TOKEN%%:*}" "$CODER_BOT_USERNAME") 2>&1 )
check "tty: ends with the good token"         grep -q 'rc=0 tok=777888999 user=bot_777888999$' <<<"$OUT"
check "tty: bad format said, asked again"     grep -q 'Coder token format invalid.* Try again' <<<"$OUT"
check "tty: other agent's bot said"           grep -q 'SEPARATE bot.* Try again' <<<"$OUT"
check "tty: getMe failure said"               grep -q 'getMe failed.* Try again' <<<"$OUT"
check "tty: the dead bot was really asked"    grep -qx "${TOKEN_DEAD%%:*}" "$GETME"
check "tty: no token printed"                 not grep -qE 'CCHabc|DEADbc|AAHabc' <<<"$OUT"

reset_tokens
answers "" "$TOKEN_J"
OUT=$( (collect_bot_token jarvis; printf 'rc=%s tok=%s' "$?" "${JARVIS_BOT_TOKEN%%:*}") 2>&1 )
check "tty: empty answer without a bot here -> asked again" grep -q 'Jarvis needs its own bot.* Try again' <<<"$OUT"
check "tty: second answer taken"              grep -q 'rc=0 tok=123456789$' <<<"$OUT"

reset_tokens
answers ""
OUT=$( (collect_bot_token jarvis) 2>&1; printf 'rc=%s' "$?" )
check "tty: input closed -> stop, no endless loop" grep -q 'rc=1$' <<<"$OUT"

# empty answer on a re-run keeps the bot already written on this server
mkdir -p "$JARVIS_ENV_DIR" "${TDIR}/richard"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_J" >"${JARVIS_ENV_DIR}/channel.env"
reset_tokens
answers ""
OUT=$( (collect_bot_token jarvis; printf 'rc=%s tok=[%s]' "$?" "$JARVIS_BOT_TOKEN") 2>&1 )
check "re-run: empty answer keeps the server's bot" grep -q 'rc=0 tok=\[\]$' <<<"$OUT"
check "re-run: says it is kept"               grep -q 'kept from this server' <<<"$OUT"
check "re-run: the kept bot was checked by getMe" grep -qx "${TOKEN_J%%:*}" "$GETME"
OUT=$( (FAKE_NOTTY=1 collect_bot_token jarvis; printf 'rc=%s' "$?") 2>&1 )
check "re-run, no tty: kept, no stop"         grep -q 'rc=0$' <<<"$OUT"
# a kept bot that no longer passes is not kept silently
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_DEAD" >"${JARVIS_ENV_DIR}/channel.env"
reset_tokens
answers "" "$TOKEN_J"
OUT=$( (collect_bot_token jarvis; printf 'rc=%s tok=%s' "$?" "${JARVIS_BOT_TOKEN%%:*}") 2>&1 )
check "re-run: revoked kept bot -> asked again" grep -q 'already on this server does not pass.* Try again' <<<"$OUT"
check "re-run: new token taken instead"       grep -q 'rc=0 tok=123456789$' <<<"$OUT"
OUT=$( (FAKE_NOTTY=1 collect_bot_token jarvis) 2>&1; printf 'rc=%s' "$?" )
check "re-run, no tty: revoked kept bot -> stop" grep -q 'rc=1$' <<<"$OUT"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_R" >"${JARVIS_ENV_DIR}/channel.env"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_R" >"${TDIR}/richard/.env"
reset_tokens
OUT=$( (FAKE_NOTTY=1 collect_bot_token jarvis) 2>&1; printf 'rc=%s' "$?" )
check "re-run, no tty: kept bot shared with Richard -> stop" grep -q 'rc=1$' <<<"$OUT"
rm -f "${JARVIS_ENV_DIR}/channel.env" "${TDIR}/richard/.env"

# env token / no tty: one try, a bad one stops (nobody to answer again)
reset_tokens
answers "$TOKEN_C"
OUT=$( (NEUROOTDEL_CODER_BOT_TOKEN="nope" collect_bot_token coder) 2>&1; printf 'rc=%s' "$?" )
check "env: bad token stops even with a tty"  grep -q 'rc=1$' <<<"$OUT"
OUT=$( (NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_DEAD" collect_bot_token coder) 2>&1; printf 'rc=%s' "$?" )
check "env: getMe failure stops"              grep -q 'rc=1$' <<<"$OUT"
OUT=$( (FAKE_NOTTY=1 collect_bot_token richard) 2>&1; printf 'rc=%s' "$?" )
check "no tty, no env, nothing here: stop"    grep -q 'rc=1$' <<<"$OUT"
check "no tty: stop names the env variable"   grep -q 'NEUROOTDEL_RICHARD_BOT_TOKEN' <<<"$OUT"
OUT=$( (FAKE_NOTTY=1 NEUROOTDEL_RICHARD_BOT_TOKEN="$TOKEN_R" collect_bot_token richard; printf 'rc=%s tok=%s' "$?" "${RICHARD_BOT_TOKEN%%:*}") 2>&1 )
check "no tty, env token: taken"              grep -q 'rc=0 tok=222333444$' <<<"$OUT"
OUT=$( (FAKE_NOTTY=1 NEUROOTDEL_RICHARD_BOT_TOKEN="$TOKEN_R" NEUROOTDEL_RICHARD_BOT_USER=my_richard collect_bot_token richard; printf 'user=%s' "$RICHARD_BOT_USERNAME") 2>&1 )
check "env username wins over getMe"          grep -q 'user=my_richard$' <<<"$OUT"

# clash with a bot already on the server, any agent (here: the Auditor's Hermes env for Coder)
mkdir -p "${FAKE_HOME}/.hermes"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_A" >"${FAKE_HOME}/.hermes/.env"
reset_tokens
OUT=$( (FAKE_NOTTY=1 NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_A" collect_bot_token coder) 2>&1; printf 'rc=%s' "$?" )
check "clash: Auditor's bot on server refused for Coder" grep -q 'rc=1$' <<<"$OUT"
check "clash wrappers: coder vs auditor"      _coder_bot_clash "$TOKEN_A"
check "clash wrappers: own bot is fine"       not _auditor_bot_clash "$TOKEN_A"
rm -f "${FAKE_HOME}/.hermes/.env"

# --- resolve_stage / parse_args --------------------------------------------------------------------
st() { (resolve_stage >/dev/null 2>&1; printf '%s' "$STAGE"); }
STAGE_ARG=intensive; check "stage: --stage wins"      test "$(st)" = intensive
STAGE_ARG=""
check "stage: env"                                    test "$(NEUROOTDEL_STAGE=intensive st)" = intensive
OUT=$( (NEUROOTDEL_STAGE=big resolve_stage) 2>&1; printf 'rc=%s' "$?" )
check "stage: wrong env value stops"                  grep -q 'rc=1$' <<<"$OUT"
check "stage: --solo -> workshop"                     test "$(SOLO=1 FAKE_NOTTY=1 st)" = workshop
check "stage: no tty, nothing here -> workshop"       test "$(FAKE_NOTTY=1 st)" = workshop
OUT=$( (FAKE_NOTTY=1 resolve_stage) 2>&1 )
check "stage: no tty default says how to get intensive" grep -q -- '--stage intensive' <<<"$OUT"
check "stage: coder token given -> intensive"         test "$(FAKE_NOTTY=1 NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_C" st)" = intensive
mkdir -p "$CODER_ENV_DIR"; printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_C" >"${CODER_ENV_DIR}/channel.env"
check "stage: Coder already on server -> intensive"   test "$(FAKE_NOTTY=1 st)" = intensive
rm -f "${CODER_ENV_DIR}/channel.env"
printf 'INSTALL_STAGE="intensive"\n' >"${GUARD_LIB_DIR}/guard.conf"
check "stage: guard.conf says intensive -> intensive" test "$(FAKE_NOTTY=1 st)" = intensive
rm -f "${GUARD_LIB_DIR}/guard.conf"
answers "x" "" "2"
check "stage: tty asks until 1 or 2"                  test "$(st)" = intensive
answers "1"
check "stage: tty 1 -> workshop"                      test "$(st)" = workshop

pa() { (STAGE_ARG=""; SOLO=0; parse_args "$@" 2>/dev/null; printf '%s/%s' "$STAGE_ARG" "$SOLO"); }
check "args: --stage X"                 test "$(pa --stage intensive)" = "intensive/0"
check "args: --stage=X with --solo"     test "$(pa --solo --stage=workshop)" = "workshop/1"
OUT=$( (parse_args --stage nope) 2>&1; printf 'rc=%s' "$?" )
check "args: wrong stage stops"         grep -q 'rc=1$' <<<"$OUT"
OUT=$( (parse_args --stage) 2>&1; printf 'rc=%s' "$?" )
check "args: --stage without value stops" grep -q 'rc=1$' <<<"$OUT"

# --- collect_inputs per stage ----------------------------------------------------------------------
ci() { (export FAKE_NOTTY=1 NEUROOTDEL_TG_USER_ID=42 "$@"; collect_inputs >"${TDIR}/ci.out" 2>&1; printf 'rc=%s c=%s a=%s' "$?" "${CODER_BOT_TOKEN%%:*}" "${AUDITOR_BOT_TOKEN%%:*}"); }
reset_tokens
OUT=$(ci NEUROOTDEL_STAGE=workshop NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="$TOKEN_R")
check "workshop: two bots -> ok, Coder/Auditor not asked" test "$OUT" = "rc=0 c= a="
check "workshop: says where the intensive is"  grep -q 'Coder and Auditor are not asked' "${TDIR}/ci.out"
OUT=$( (export FAKE_NOTTY=1 NEUROOTDEL_STAGE=workshop NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J"; collect_inputs >/dev/null 2>&1); printf 'rc=%s' "$?" )
check "workshop: Richard bot missing -> stop" test "$OUT" = "rc=1"
OUT=$( (export FAKE_NOTTY=1 NEUROOTDEL_STAGE=intensive NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="$TOKEN_R" \
        NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_C"; collect_inputs >"${TDIR}/ci.out" 2>&1); printf 'rc=%s' "$?" )
check "intensive: Auditor bot missing -> stop" test "$OUT" = "rc=1"
check "intensive: stop names the Auditor"     grep -q 'Auditor needs its own bot' "${TDIR}/ci.out"
OUT=$(ci NEUROOTDEL_STAGE=intensive NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="$TOKEN_R" \
        NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_C" NEUROOTDEL_AUDITOR_BOT_TOKEN="$TOKEN_A")
check "intensive: four bots -> ok"            test "$OUT" = "rc=0 c=777888999 a=444555666"
OUT=$( (export FAKE_NOTTY=1 NEUROOTDEL_STAGE=intensive NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="$TOKEN_R" \
        NEUROOTDEL_CODER_BOT_TOKEN="$TOKEN_C" NEUROOTDEL_AUDITOR_BOT_TOKEN="$TOKEN_C"; collect_inputs >/dev/null 2>&1); printf 'rc=%s' "$?" )
check "intensive: Auditor = Coder bot -> stop" test "$OUT" = "rc=1"
OUT=$( (export FAKE_NOTTY=1 NEUROOTDEL_STAGE=workshop NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="$TOKEN_J"; collect_inputs >/dev/null 2>&1); printf 'rc=%s' "$?" )
check "workshop: Richard = Jarvis bot -> stop" test "$OUT" = "rc=1"

# --- guard.conf: stage recorded, never goes back; skills count ----------------------------------------
GC="${TDIR}/gc"
(INSTALL_TAG=t AGENT_USER=u GUARD_LIB_DIR=/l CONFIG_ROOT=/c STAGE=workshop render_guard_conf "" 2>/dev/null) >"${GC}.1"
check "conf: workshop recorded"                grep -qx 'INSTALL_STAGE="workshop"' "${GC}.1"
check "conf: skills expected = installer count" grep -qx "SKILLS_EXPECTED=\"$(( ${#SKILLS_FROM_TEMPLATE[@]} + ${#SKILLS_FROM_INSTALLER[@]} ))\"" "${GC}.1"
(INSTALL_TAG=t AGENT_USER=u GUARD_LIB_DIR=/l CONFIG_ROOT=/c STAGE=intensive render_guard_conf "${GC}.1" 2>/dev/null) >"${GC}.2"
check "conf: intensive recorded"               grep -qx 'INSTALL_STAGE="intensive"' "${GC}.2"
(INSTALL_TAG=t AGENT_USER=u GUARD_LIB_DIR=/l CONFIG_ROOT=/c STAGE=workshop render_guard_conf "${GC}.2" 2>/dev/null) >"${GC}.3"
check "conf: workshop re-run keeps intensive"  grep -qx 'INSTALL_STAGE="intensive"' "${GC}.3"

# --- main: the end-of-stage check runs last; the command is linked in the guard step ------------------
check "main: run_stage_verify after final_instructions" \
    bash -c "grep -A1 '^    final_instructions\$' '${REPO}/install.sh' | grep -qx '    run_stage_verify'"
check "guard: links neurootdel-verify" \
    bash -c "sed -n '/^install_guard() {/,/^}/p' '${REPO}/install.sh' | grep -qx '    install_verify_command'"
OUT=$( (GUARD_LIB_DIR="${TDIR}/nolib"; STAGE=workshop; run_stage_verify) 2>&1; printf 'rc=%s' "$?" )
check "verify step: missing script never fails the install" grep -q 'rc=0$' <<<"$OUT"
mkdir -p "${TDIR}/vlib"; printf '#!/usr/bin/env bash\necho "args:$*"\nexit 1\n' >"${TDIR}/vlib/verify-stage.sh"
OUT=$( (GUARD_LIB_DIR="${TDIR}/vlib"; STAGE=intensive; run_stage_verify) 2>&1; printf 'rc=%s' "$?" )
check "verify step: passes the stage"          grep -q 'args:--stage intensive' <<<"$OUT"
check "verify step: a ❌ is reported, install goes on" grep -q 'rc=0$' <<<"$OUT"
check "verify step: says the command"          grep -q 'sudo neurootdel-verify' <<<"$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
