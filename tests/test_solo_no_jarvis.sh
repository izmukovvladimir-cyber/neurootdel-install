#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, stubs called by main
# --solo («Агент за вечер») without a Jarvis bot token, no root needed (#1920 a):
#   the guide (ch. 7) runs main --solo through «!» in Claude Code (stdin not a terminal) with the key
#   and the name only; the bot is made in ch. 8. Such a run goes through step 5 with a warning,
#   leaves channel-jarvis off and reaches the final notes with a Russian how-to. A Jarvis token given
#   or already on this server keeps the old path; the full install still stops without it.
#   Steps that need root, the network or apt are stubbed; collect_inputs, install_richard,
#   enable_services and final_instructions are real.
# Run: bash tests/test_solo_no_jarvis.sh
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

# --- --solo, no tty, no tokens at all (the guide's command): install reaches the end --------------
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="" NEUROOTDEL_RICHARD_BOT_TOKEN="" run_main --solo)
printf '%s\n' "$OUT" >"${TDIR}/solo.out"
check "solo, no Jarvis token: rc 0"                 grep -qx 'rc=0' <<<"$OUT"
check "solo, no Jarvis token: no stop on its bot"   not grep -q 'Jarvis needs its own bot' <<<"$OUT"
check "solo, no Jarvis token: step 5 warns"         grep -q 'Jarvis: no bot token -- installed without its bot' <<<"$OUT"
check "solo, no Jarvis token: Jarvis still installed" grep -q '^STEP install_jarvis$' <<<"$OUT"
check "solo, no Jarvis token: unit not enabled"     grep -q 'channel-jarvis NOT enabled (no token)' <<<"$OUT"
check "solo, no Jarvis token: no systemctl enable"  not grep -q '^systemctl enable channel-jarvis' <<<"$OUT"
check "solo, no Jarvis token: final notes printed"  grep -q 'complete.  Agent-native flow' <<<"$OUT"
check "solo, no Jarvis token: RU line names @BotFather" grep -q 'Jarvis: бот пока не подключён.*@BotFather' <<<"$OUT"
check "solo, no Jarvis token: RU line names channel.env" grep -q "TELEGRAM_BOT_TOKEN=<токен> в ${TDIR}/etc/jarvis/channel.env" <<<"$OUT"
check "solo, no Jarvis token: RU line enable --now" grep -q 'systemctl enable --now channel-jarvis' <<<"$OUT"
check "solo, no Jarvis token: verify step reached last" test "$(grep -E '^(STEP |rc=)' <<<"$OUT" | tail -n 2 | head -n 1)" = "STEP run_stage_verify"

# --- --solo, no tty, Jarvis token in env: unchanged, no RU how-to -----------------------------------
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="$TOKEN_J" NEUROOTDEL_RICHARD_BOT_TOKEN="" run_main --solo)
check "solo + Jarvis token: rc 0"                   grep -qx 'rc=0' <<<"$OUT"
check "solo + Jarvis token: bot verified"           grep -q 'Jarvis bot verified: @bot_123456789' <<<"$OUT"
check "solo + Jarvis token: no skip warning"        not grep -q 'Jarvis: no bot token' <<<"$OUT"
check "solo + Jarvis token: no RU how-to"           not grep -q 'Jarvis: бот пока не подключён' <<<"$OUT"
check "solo + Jarvis token: no token printed"       not grep -q 'AAHabc' <<<"$OUT"

# --- --solo, no tty, token already on this server (re-install, Simona's case): kept ----------------
mkdir -p "${TDIR}/etc/jarvis"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USER_IDS=42\n' "$TOKEN_J" >"${TDIR}/etc/jarvis/channel.env"
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="" NEUROOTDEL_RICHARD_BOT_TOKEN="" run_main --solo)
check "solo, kept token: rc 0"                      grep -qx 'rc=0' <<<"$OUT"
check "solo, kept token: kept and checked"          grep -q 'Jarvis: bot token kept from this server (checked)' <<<"$OUT"
check "solo, kept token: no skip warning"           not grep -q 'Jarvis: no bot token' <<<"$OUT"
check "solo, kept token: unit enabled"              grep -q '^systemctl enable channel-jarvis.service' <<<"$OUT"
check "solo, kept token: no RU how-to"              not grep -q 'Jarvis: бот пока не подключён' <<<"$OUT"
check "solo, kept token: no token printed"          not grep -q 'AAHabc' <<<"$OUT"
rm -f "${TDIR:?}/etc/jarvis/channel.env"

# --- --solo, bad Jarvis token given: still a stop (a given token is checked) -------------------------
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="nope" NEUROOTDEL_RICHARD_BOT_TOKEN="" run_main --solo)
check "solo + bad Jarvis token: stop"               grep -qx 'rc=1' <<<"$OUT"
check "solo + bad Jarvis token: says format"        grep -q 'Jarvis token format invalid' <<<"$OUT"

# --- full install, no tty, no Jarvis token: unchanged, stops at step 5 ------------------------------
OUT=$(NEUROOTDEL_JARVIS_BOT_TOKEN="" NEUROOTDEL_RICHARD_BOT_TOKEN="$TOKEN_R" run_main --stage workshop)
check "full, no Jarvis token: rc 1"                 grep -qx 'rc=1' <<<"$OUT"
check "full, no Jarvis token: stop names its bot"   grep -q 'Jarvis needs its own bot' <<<"$OUT"
check "full, no Jarvis token: final notes not reached" not grep -q 'complete.  Agent-native flow' <<<"$OUT"

# --- channel.env without a token renders (no stop under set -u, the line is empty) ------------------
ENV_OUT=$(
    export INSTALL_SH_SOURCED_FOR_TESTING=1 NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates" NEUROOTDEL_INSTALLER_ROOT="$REPO"
    # shellcheck disable=SC1091
    source "${TDIR}/install.sh"
    set -u
    CHANNEL_ENV_TOKEN="" render_channel_env "" 42 "" "${TDIR}/state" "${TDIR}/ws"
) && rc=0 || rc=$?
check "channel.env without token: renders"         test "$rc" = 0
check "channel.env without token: empty token line" grep -qE '^TELEGRAM_BOT_TOKEN="?"?$' <<<"$ENV_OUT"
check "channel.env without token: owner id kept"    grep -qE '^TELEGRAM_ALLOWED_USER_IDS="?42"?$' <<<"$ENV_OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
