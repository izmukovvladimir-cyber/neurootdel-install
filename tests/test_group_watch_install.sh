#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Tests for the group watch part of install.sh, no root needed: the unit is always written,
# an instance is enabled only with NEUROOTDEL_GROUP_WATCH_CHAT_ID + _CHIP, ALL_HUMAN defaults to 0.
# Run: bash tests/test_group_watch_install.sh
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
has() { grep -qxF -- "$2" "$1"; }

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e    # the checks below report failures themselves
log() { :; }
ok() { :; }
warn() { printf '%s\n' "$*" >>"${TDIR}/warns"; }
install() {    # drop -o/-g/-m: the sandbox user cannot chown to root
    local args=()
    while (($#)); do case $1 in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
}
CALLS="${TDIR}/calls"
: >"$CALLS"
systemctl() { printf '%s\n' "$*" >>"$CALLS"; return 0; }
GETME="${TDIR}/getme"
tg_get_me() { printf 'getMe %s\n' "${1%%:*}" >>"$GETME"; printf '{"ok":true,"result":{"username":"from_getme_bot"}}'; }

AGENT_USER="$(id -un)"
INSTALL_TAG=neurootdel-install
GUARD_LIB_DIR=/usr/local/lib/testagent
CONFIG_ROOT="${TDIR}/etc"
JARVIS_BOT_USERNAME=""
GROUP_WATCH_SYSTEMD_DIR="${TDIR}/systemd"
GROUP_WATCH_CONF_DIR="${TDIR}/gw"
mkdir -p "$GROUP_WATCH_SYSTEMD_DIR" "${CONFIG_ROOT}/jarvis"
printf 'TELEGRAM_BOT_TOKEN=123456789:AAsecretpartsecretpartsecretpart00\nTELEGRAM_ALLOWED_CHAT_IDS=555,-5550001\n' >"${CONFIG_ROOT}/jarvis/channel.env"
UNIT="${GROUP_WATCH_SYSTEMD_DIR}/${AGENT_USER}-group-watch@.service"
for v in $(compgen -v NEUROOTDEL_GROUP_WATCH_ || true); do unset "$v"; done

# --- no chip: unit written, nothing enabled ---------------------------------------
install_group_watch
check "unit: template written"               test -f "$UNIT"
check "unit: runs the lib script"            grep -qx "ExecStart=/usr/bin/python3 ${GUARD_LIB_DIR}/group-watch.py" "$UNIT"
check "unit: env file per instance"          grep -qx "EnvironmentFile=${GROUP_WATCH_CONF_DIR}/%i.env" "$UNIT"
check "unit: bad settings do not loop"       grep -qx "RestartPreventExitStatus=2" "$UNIT"
check "unit: names the STOP file"            grep -q "STOP" "$UNIT"
check "unit: private state (UMask 0077)"     grep -qx "UMask=0077" "$UNIT"
check "off: no instance env"                 test ! -e "${GROUP_WATCH_CONF_DIR}/main.env"
check "off: systemctl not called"            test ! -s "$CALLS"
check "off: status off"                      test "$GROUP_WATCH_STATUS" = off
NEUROOTDEL_GROUP_WATCH_CHAT_ID=-5550001 install_group_watch
check "chat without chip: still off"         bash -c '! grep -q enable "$0"' "$CALLS"

# --- chat + chip: instance written and enabled ---------------------------------------
NEUROOTDEL_GROUP_WATCH_CHAT_ID=-5550001 NEUROOTDEL_GROUP_WATCH_CHIP=http://127.0.0.1:18000 \
    NEUROOTDEL_GROUP_WATCH_TITLE="Группа 'X' \$y" NEUROOTDEL_GROUP_WATCH_NAME_REGEX='(?<!\w)тим(?:а|е)' NEUROOTDEL_GROUP_WATCH_BOT_USERNAME=@team_agent_bot install_group_watch
ENVF="${GROUP_WATCH_CONF_DIR}/main.env"
check "on: env written"                      test -f "$ENVF"
check "on: chat id"                          has "$ENVF" "GW_CHAT_ID=-5550001"
check "on: chip"                             has "$ENVF" "GW_CHIP=http://127.0.0.1:18000"
check "on: ALL_HUMAN defaults to 0"          has "$ENVF" "GW_ALL_HUMAN=0"
check "on: feed defaults to 0"               has "$ENVF" "GW_FEED=0"
check "on: bot id from the token prefix"     has "$ENVF" "GW_BOT_ID=123456789"
check "on: token itself never written"       bash -c '! grep -q secretpart "$0"' "$ENVF"
check "on: bot username without @"           has "$ENVF" "GW_BOT_USERNAME=team_agent_bot"
check "on: title quoted, its quotes dropped"  has "$ENVF" "GW_TITLE='Группа X \$y'"
check "on: name regex keeps backslashes"     has "$ENVF" "GW_NAME_REGEX='(?<!\\w)тим(?:а|е)'"
check "on: state dir per instance"           has "$ENVF" "GW_BASE=/var/lib/${AGENT_USER}-group-watch/main"
check "on: staging owned by the agent user"  has "$ENVF" "GW_STAGING_UID=$(id -u)"
check "on: default agent"                    has "$ENVF" "GW_AGENT=jarvis"
check "on: daemon-reload, enable, restart"   bash -c 'grep -qx "daemon-reload" "$0" && grep -qx "enable $1-group-watch@main.service --quiet" "$0" && grep -qx "restart $1-group-watch@main.service" "$0"' "$CALLS" "$AGENT_USER"
check "on: status names the instance"        test "$GROUP_WATCH_STATUS" = on:main
check "on: allowed group, no warning"        test ! -s "${TDIR}/warns"
check "on: env is a valid systemd env file"  bash -c 'set -a; . "$0" 2>/dev/null || exit 1; [[ "$GW_CHAT_ID" == -5550001 && "$GW_ALL_HUMAN" == 0 && "$GW_TITLE" == "Группа X \$y" ]]' "$ENVF"

NEUROOTDEL_GROUP_WATCH_CHAT_ID=-5550001 NEUROOTDEL_GROUP_WATCH_CHIP=http://127.0.0.1:18000 \
    NEUROOTDEL_GROUP_WATCH_ALL_HUMAN=1 install_group_watch
check "ALL_HUMAN=1 only when asked"          has "$ENVF" "GW_ALL_HUMAN=1"
check "re-run: no username given -> getMe of the agent's token" has "$ENVF" "GW_BOT_USERNAME=from_getme_bot"
check "getMe got the token, nothing printed" bash -c 'grep -qx "getMe 123456789" "$0"' "$GETME"
check "re-run: running instance restarted"   test "$(grep -c "^restart .*group-watch@main.service" "$CALLS")" -ge 2

# --- other group, not allowed in channel.env: written, warned ----------------------------
: >"$CALLS"
NEUROOTDEL_GROUP_WATCH_NAME=second NEUROOTDEL_GROUP_WATCH_CHAT_ID=-5550009 NEUROOTDEL_GROUP_WATCH_CHIP=http://127.0.0.1:18000 \
    NEUROOTDEL_GROUP_WATCH_BOT_ID=42 install_group_watch
check "second: own env file"                 has "${GROUP_WATCH_CONF_DIR}/second.env" "GW_BOT_ID=42"
check "second: first instance kept"          has "$ENVF" "GW_CHAT_ID=-5550001"
check "second: not-allowed group warned"     grep -q "TELEGRAM_ALLOWED_CHAT_IDS" "${TDIR}/warns"
check "second: enabled by name"              grep -qx "enable ${AGENT_USER}-group-watch@second.service --quiet" "$CALLS"

# --- malformed values: nothing written, nothing enabled ---------------------------------
: >"$CALLS"; : >"${TDIR}/warns"
for bad in "CHAT_ID=abc" "CHIP=https://x" "CHIP=http://h/x;rm" "ALL_HUMAN=yes" "NAME=../x" "BOT_ID=12a"; do
    rm -f "${GROUP_WATCH_CONF_DIR}/bad.env"
    (
        export NEUROOTDEL_GROUP_WATCH_NAME=bad NEUROOTDEL_GROUP_WATCH_CHAT_ID=-5550001 NEUROOTDEL_GROUP_WATCH_CHIP=http://127.0.0.1:1
        export "NEUROOTDEL_GROUP_WATCH_${bad}"
        install_group_watch
        [[ "$GROUP_WATCH_STATUS" == error ]]
    ) && st=ok || st=bad
    check "bad ${bad}: refused"              test "$st" = ok
    check "bad ${bad}: nothing written"      test ! -e "${GROUP_WATCH_CONF_DIR}/bad.env" -a ! -e "${TDIR}/x.env"
done
check "bad: systemctl enable never called"   bash -c '! grep -q enable "$0"' "$CALLS"
check "bad: warning names the variable"      grep -q "CHAT_ID" "${TDIR}/warns"

# --- no token in channel.env and no BOT_ID: refused ---------------------------------------
printf 'TELEGRAM_ALLOWED_CHAT_IDS=-5550001\n' >"${CONFIG_ROOT}/jarvis/channel.env"
(NEUROOTDEL_GROUP_WATCH_NAME=nobot NEUROOTDEL_GROUP_WATCH_CHAT_ID=-5550001 NEUROOTDEL_GROUP_WATCH_CHIP=http://127.0.0.1:1 \
    install_group_watch; [[ "$GROUP_WATCH_STATUS" == error ]]) && st=ok || st=bad
check "no bot id anywhere: refused"          test "$st" = ok
tg_get_me() { printf '{"ok":false}'; }
printf 'TELEGRAM_BOT_TOKEN=123456789:AAsecretpartsecretpartsecretpart00\n' >"${CONFIG_ROOT}/jarvis/channel.env"
(NEUROOTDEL_GROUP_WATCH_NAME=nouser NEUROOTDEL_GROUP_WATCH_CHAT_ID=-5550001 NEUROOTDEL_GROUP_WATCH_CHIP=http://127.0.0.1:1 \
    install_group_watch; [[ "$GROUP_WATCH_STATUS" == error ]]) && st=ok || st=bad
check "no bot username anywhere: refused"    test "$st" = ok -a ! -e "${GROUP_WATCH_CONF_DIR}/nouser.env"
check "no bot username: warning names it"    grep -q "BOT_USERNAME" "${TDIR}/warns"

# --- wiring -------------------------------------------------------------------------------------
check "main: group watch after the guard"    bash -c 'grep -A1 "^    install_guard$" "$0" | grep -q "^    install_group_watch$"' "${REPO}/install.sh"
check "final notes: how to turn it on"       grep -q 'NEUROOTDEL_GROUP_WATCH_CHAT_ID=<-100' "${REPO}/install.sh"
check "lib: watcher and helper shipped"      test -f "${REPO}/lib/group-watch.py" -a -f "${REPO}/lib/group-wake.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
