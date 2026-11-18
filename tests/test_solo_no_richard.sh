#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, stubs called by main
# --solo («Агент за вечер») without a Richard bot token, no root needed (decision #1902):
#   main --solo with stdin not a terminal (the buyer runs it through «!» in Claude Code) and no
#   Richard token goes through step 5 with a warning, skips Richard's step and reaches the final
#   notes; the full install still stops without his token. Steps that need root, the network or
#   apt are stubbed; collect_inputs, install_richard, enable_services and final_instructions are real.
# Run: bash tests/test_solo_no_richard.sh
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

mkdir -p "${TDIR}/home" "${TDIR}/etc" "${TDIR}/lib"
sed -e "s#^readonly RICHARD_HOME=.*#readonly RICHARD_HOME=\"${TDIR}/richard\"#" "${REPO}/install.sh" >"${TDIR}/install.sh"

TOKEN_J="123456789:AAHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_R="222333444:RRHabcdefghijklmnopqrstuvwxyz0123456"

# run_main <args...> -- main in a subshell with stdin from /dev/null (no tty); prints its output,
# then "rc=<n>". The env is set by the caller.
run_main() {
    (
        export INSTALL_SH_SOURCED_FOR_TESTING=1
        export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
        export NEUROOTDEL_INSTALLER_ROOT="$REPO"
        export NEUROOTDEL_TG_USER_ID=42
        unset NEUROOTDEL_NONINTERACTIVE EDGELAB_NONINTERACTIVE NEUROOTDEL_STAGE EDGELAB_RICHARD_BOT_TOKEN
        # shellcheck disable=SC1091
        source "${TDIR}/install.sh"
        apply_install_names new
        AGENT_HOME="${TDIR}/home"
        CONFIG_ROOT="${TDIR}/etc"
        JARVIS_ENV_DIR="${CONFIG_ROOT}/jarvis"
        CODER_ENV_DIR="${CONFIG_ROOT}/coder"
        GUARD_LIB_DIR="${TDIR}/lib"
        for fn in banner preflight azv_activate install_apt_deps require_step_packages install_node \
                ensure_agent_user check_node_for_agent install_claude_cli install_bun resolve_role_settings \
                install_jarvis install_coder setup_global_claude install_skills azv_install_payload \
                disable_superpowers install_superpowers install_sudoers install_memory_cron install_guard \
                install_group_watch install_auditor setup_agent_hooks install_team_refs report_claude_plan \
                run_stage_verify; do
            eval "${fn}() { echo \"STEP ${fn}\"; }"
        done
        step() { echo "STEP-NO $1 $2"; }
        systemctl() { echo "systemctl $*"; }
        # Richard's real install needs root and pip: reaching it at all is the failure here.
        sudo() { echo "SUDO $*"; return 1; }
        tg_get_me() { printf '{"ok":true,"result":{"username":"bot_%s"}}' "${1%%:*}"; }
        set -e    # errexit as in a real run (install.sh sets it too; a $(...) would drop it)
        main "$@"
    ) </dev/null 2>&1
    printf 'rc=%s\n' "$?"
}

# --- --solo, no tty, Jarvis token only: Richard skipped, install reaches the end ---------------------
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="" run_main --solo)
printf '%s\n' "$OUT" >"${TDIR}/solo.out"
check "solo: rc 0"                              grep -qx 'rc=0' <<<"$OUT"
check "solo: no stop on Richard's token"        not grep -q 'Richard needs its own bot' <<<"$OUT"
check "solo: warns Richard is skipped"          grep -q 'Richard: no bot token -- Richard is skipped' <<<"$OUT"
check "solo: warning names the env variable"    grep -q 'sudo NEUROOTDEL_RICHARD_BOT_TOKEN=<token> bash install.sh --solo' <<<"$OUT"
check "solo: final notes have no claude-richard command" not grep -q 'claude-richard' <<<"$(sed -n '/Agent-native flow/,$p' <<<"$OUT")"
check "solo: final notes do not send to Richard" not grep -q 'student messages Richard' <<<"$OUT"
check "solo: step 7 says skipped"               grep -q 'Richard skipped: --solo without his bot token' <<<"$OUT"
check "solo: Richard's pip install not run"     not grep -q '^SUDO ' <<<"$OUT"
check "solo: no Richard unit written"           test ! -e "${TDIR}/richard/.env"
check "solo: Richard not enabled"               grep -q 'claude-richard NOT enabled (no token)' <<<"$OUT"
check "solo: steps after Richard run"           grep -q '^STEP install_team_refs$' <<<"$OUT"
check "solo: final notes printed"               grep -q 'complete.  Agent-native flow' <<<"$OUT"
check "solo: final notes say Richard not installed" grep -q 'Richard:   not installed: --solo without his bot' <<<"$OUT"
check "solo: verify step reached last"          test "$(grep -E '^(STEP |rc=)' <<<"$OUT" | tail -n 2 | head -n 1)" = "STEP run_stage_verify"
check "solo: no token printed"                  not grep -q 'AAHabc' <<<"$OUT"

# --- --solo with a Richard token: he is installed as before (reaches the real install) --------------
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="$TOKEN_R" run_main --solo)
check "solo + Richard token: not skipped"       not grep -q 'Richard is skipped' <<<"$OUT"
check "solo + Richard token: bot verified"      grep -q 'Richard bot verified: @bot_222333444' <<<"$OUT"

# --- --solo with a bad Richard token: still a stop (a given token is checked) -----------------------
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="nope" run_main --solo)
check "solo + bad Richard token: stop"          grep -qx 'rc=1' <<<"$OUT"
check "solo + bad Richard token: says format"   grep -q 'Richard token format invalid' <<<"$OUT"

# --- full install, no tty, no Richard token: unchanged, stops at step 5 -----------------------------
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="" run_main --stage workshop)
check "full: rc 1"                              grep -qx 'rc=1' <<<"$OUT"
check "full: stop names Richard's bot"          grep -q 'Richard needs its own bot' <<<"$OUT"
check "full: final notes not reached"           not grep -q 'complete.  Agent-native flow' <<<"$OUT"

# --- final notes when Richard is installed: unchanged, his unit and his bot are named --------------
final_notes() {
    (
        export INSTALL_SH_SOURCED_FOR_TESTING=1 NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates" NEUROOTDEL_INSTALLER_ROOT="$REPO"
        # shellcheck disable=SC1091
        source "${TDIR}/install.sh"
        apply_install_names new
        AGENT_HOME="${TDIR}/home"; RICHARD_SKIPPED=$1; RICHARD_BOT_USERNAME=rich_bot
        final_instructions
    ) </dev/null 2>&1
}
OUT=$(final_notes 0)
check "with Richard: systemctl names claude-richard" grep -q 'sudo systemctl enable .* claude-richard$' <<<"$OUT"
check "with Richard: smoke-check names claude-richard" grep -q 'systemctl is-active claude-richard' <<<"$OUT"
check "with Richard: student messages Richard"  grep -q 'student messages Richard:  @rich_bot' <<<"$OUT"
check "with Richard: his .env line"             grep -q 'Richard: .*/richard/.env -- TELEGRAM_BOT_TOKEN' <<<"$OUT"

# --- --solo without the Jarvis token either: no stop since #1920 a (tests/test_solo_no_jarvis.sh) -----
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="" NEUROOTDEL_RICHARD_BOT_TOKEN="" run_main --solo)
check "solo, no Jarvis token: rc 0"             grep -qx 'rc=0' <<<"$OUT"
check "solo, no Jarvis token: no stop"          not grep -q 'Jarvis needs its own bot' <<<"$OUT"
check "solo, no Jarvis token: Richard skipped"  grep -q 'Richard skipped: --solo without his bot token' <<<"$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
