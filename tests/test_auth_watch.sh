#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Tests for lib/claude-auth-watch.sh (Claude login watch) and its cron, no root needed:
#   "Not logged in" on an agent screen, no login at all, long-lived token near expiry,
#   cooldowns, STOP, the bot fallback, and that the bot token never reaches argv or output.
# Run: bash tests/test_auth_watch.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
W="${REPO}/lib/claude-auth-watch.sh"

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

H="${TDIR}/home"; ETC="${TDIR}/etc"; ST="${TDIR}/state"; PANES="${TDIR}/panes"
mkdir -p "${H}/.claude" "${ETC}/jarvis" "${ETC}/coder" "$PANES"
TOKEN_J="123456789:AAHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_C="777888999:CCHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN_R="222333444:RRHabcdefghijklmnopqrstuvwxyz0123456"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_J" >"${ETC}/jarvis/channel.env"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN_C" >"${ETC}/coder/channel.env"
printf 'TELEGRAM_BOT_TOKEN=%s\nALLOWED_USERS=555\n' "$TOKEN_R" >"${TDIR}/richard.env"
write_conf() {
    cat >"${TDIR}/guard.conf" <<EOF
AGENT_USER="neurootdel"
AGENT_HOME="${H}"
CONFIG_ROOT="${ETC}"
CHANNEL_AGENTS="jarvis coder"
MAIN_AGENT="jarvis"
AGENT_LABELS="jarvis=Jarvis,coder=Coder"
OWNER_TG_ID="${1-555}"
OWNER_TIMEZONE="Europe/Moscow"
RICHARD_ENV="${TDIR}/richard.env"
EOF
}
write_conf
export NEUROOTDEL_GUARD_CONF="${TDIR}/guard.conf" AUTH_WATCH_STATE="$ST" AUTH_WATCH_PANES="$PANES"
NOW0=1800000000   # fixed clock
run() { AUTH_WATCH_DRY=1 AUTH_WATCH_ENABLED="${ENABLED-}" AUTH_WATCH_NOW="${1:-$NOW0}" bash "$W"; }

check "syntax"                          bash -n "$W"
check "installed executable"            test -x "$W"

# --- logged in, panes fine: silent -------------------------------------------------------
printf '{"claudeAiOauth":{}}' >"${H}/.claude/.credentials.json"
printf '❯ \n  bypass permissions on (shift+tab to cycle)\n' >"${PANES}/jarvis.txt"
printf '❯ \n' >"${PANES}/coder.txt"
ENABLED="channel-jarvis channel-coder"
OUT=$(run)
check "fine: nothing sent"              test -z "$OUT"

# --- 1) pane shows Not logged in --------------------------------------------------------------
printf '● Bash(ls)\n  ⎿  Not logged in · Please run /login\n\n❯ \n' >"${PANES}/coder.txt"
OUT=$(run)
check "pane: alert by Coder's own bot"  grep -q '^SEND via=coder chat=555 text=Coder: вход в Claude слетел' <<<"$OUT"
check "pane: says how to log in"        grep -q "claude auth login" <<<"$OUT"
check "pane: jarvis not blamed"         bash -c '! grep -q "via=jarvis" <<<"$1"' _ "$OUT"
check "pane: cooldown stamp"            test "$(cat "${ST}/pane-coder")" = "$NOW0"
OUT=$(run $((NOW0 + 3600)))
check "pane: silent within 6 h"         test -z "$OUT"
OUT=$(run $((NOW0 + 21601)))
check "pane: again after 6 h"           grep -q 'via=coder' <<<"$OUT"
printf '  ⎿  OAuth token has expired\n' >"${PANES}/jarvis.txt"
OUT=$(run $((NOW0 + 21602)))
check "pane: expired token caught"      grep -q '^SEND via=jarvis .*Jarvis: вход в Claude слетел' <<<"$OUT"
printf 'user wrote: Not logged in?\n' >"${PANES}/jarvis.txt"; rm -f "${ST}/pane-jarvis"
OUT=$(run $((NOW0 + 21603)))
check "pane: plain text is no alert"    bash -c '! grep -q "via=jarvis" <<<"$1"' _ "$OUT"
printf '❯ \n' >"${PANES}/coder.txt"; printf '❯ \n' >"${PANES}/jarvis.txt"

# --- 2) no login at all (per enabled agent, by its own bot) ------------------------------------
rm -f "${H}/.claude/.credentials.json"
OUT=$(run)
check "nologin: jarvis told by its bot" grep -q '^SEND via=jarvis chat=555 text=Jarvis: нет входа в Claude' <<<"$OUT"
check "nologin: coder told by its bot"  grep -q '^SEND via=coder chat=555 text=Coder: нет входа в Claude' <<<"$OUT"
OUT=$(run $((NOW0 + 3600)))
check "nologin: once a day"             test -z "$OUT"
OUT=$(run $((NOW0 + 86400)))
check "nologin: next day again"         grep -q 'нет входа' <<<"$OUT"
rm -f "${ST}"/nologin-*
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-x\n' >>"${ETC}/coder/channel.env"
OUT=$(run)
check "nologin: coder setup-token counts for coder" bash -c '! grep -q "via=coder" <<<"$1"' _ "$OUT"
check "nologin: ...but not for jarvis"  grep -q '^SEND via=jarvis .*нет входа' <<<"$OUT"
sed -i '/CLAUDE_CODE_OAUTH_TOKEN/d' "${ETC}/coder/channel.env"; rm -f "${ST}"/nologin-*
OUT=$(ENABLED="channel-jarvis" run)
check "nologin: disabled coder silent"  bash -c 'grep -q "via=jarvis" <<<"$1" && ! grep -q "via=coder" <<<"$1"' _ "$OUT"
rm -f "${ST}"/nologin-*
OUT=$(ENABLED="" run)
check "nologin: no enabled agent -> silent" test -z "$OUT"
printf '{}' >"${H}/.claude/.credentials.json"
OUT=$(run)
check "nologin: shared login -> silent" test -z "$OUT"

# --- 3) long-lived token close to expiry ----------------------------------------------------------
date -u -d "@$((NOW0 - 360 * 86400))" +%F >"${ST}/oauth-issued"
OUT=$(run)
check "expiry: warned 5 days before"    grep -qE '^SEND via=jarvis .*истекает через [45] дн\.' <<<"$OUT"
OUT=$(run $((NOW0 + 60)))
check "expiry: once a day"              test -z "$OUT"
date -u -d "@$((NOW0 - 100 * 86400))" +%F >"${ST}/oauth-issued"; rm -f "${ST}/expiry-sent"
OUT=$(run)
check "expiry: far away -> silent"      test -z "$OUT"
printf 'garbage\n' >"${ST}/oauth-issued"
OUT=$(run); RC=$?
check "expiry: bad date logged, rc 0"   bash -c '[[ $1 -eq 0 ]] && grep -q "bad date" <<<"$2"' _ "$RC" "$OUT"
rm -f "${ST}/oauth-issued"

# --- STOP and no owner -----------------------------------------------------------------------------
printf '  ⎿  Not logged in\n' >"${PANES}/coder.txt"; rm -f "${ST}/pane-coder"
touch "${ST}/STOP"
OUT=$(run)
check "stop: nothing sent"              test -z "$OUT"
rm -f "${ST}/STOP"
write_conf ""
OUT=$(run); RC=$?
check "no owner: rc 0, nobody to tell"  bash -c '[[ $1 -eq 0 ]] && grep -q "no OWNER_TG_ID" <<<"$2" && ! grep -q SEND <<<"$2"' _ "$RC" "$OUT"
write_conf

# --- real send path: token through stdin only, never argv or output -----------------------------------
BIN="${TDIR}/bin"; mkdir -p "$BIN"
cat >"${BIN}/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CURL_ARGV}"
cat >>"${CURL_STDIN}"
printf '%s' "${CURL_REPLY:-{\"ok\":true}}"
SH
chmod +x "${BIN}/curl"
export CURL_ARGV="${TDIR}/curl.argv" CURL_STDIN="${TDIR}/curl.stdin"
: >"$CURL_ARGV"; : >"$CURL_STDIN"; rm -f "${ST}/pane-coder"
OUT=$(PATH="${BIN}:${PATH}" AUTH_WATCH_ENABLED="channel-jarvis" AUTH_WATCH_NOW="$NOW0" bash "$W" 2>&1)
check "send: delivered and logged"      grep -q 'alert sent via coder' <<<"$OUT"
check "send: token not in argv"         bash -c '! grep -q "CCHabc" "$1"' _ "$CURL_ARGV"
check "send: owner chat in argv"        grep -q 'chat_id=555' "$CURL_ARGV"
check "send: token via stdin config"    grep -q "^url = \"https://api.telegram.org/bot${TOKEN_C}/sendMessage\"$" "$CURL_STDIN"
check "send: token never printed"       bash -c '! grep -qE "CCHabc|AAHabc|RRHabc" <<<"$1"' _ "$OUT"
check "send: stamp after delivery"      test -f "${ST}/pane-coder"
# Telegram refused: no stamp, so the next hour tries again
rm -f "${ST}/pane-coder"
OUT=$(CURL_REPLY='{"ok":false}' PATH="${BIN}:${PATH}" AUTH_WATCH_ENABLED="channel-jarvis" AUTH_WATCH_NOW="$NOW0" bash "$W" 2>&1)
check "send: refused -> logged"         grep -q 'NOT delivered via coder' <<<"$OUT"
check "send: refused -> no stamp"       test ! -f "${ST}/pane-coder"
# the agent's bot missing: falls back to the main agent's, then Richard's
sed -i '/TELEGRAM_BOT_TOKEN/d' "${ETC}/coder/channel.env"; : >"$CURL_STDIN"
PATH="${BIN}:${PATH}" AUTH_WATCH_ENABLED="channel-jarvis" AUTH_WATCH_NOW="$NOW0" bash "$W" >/dev/null 2>&1
check "send: fallback to main bot"      grep -q "bot${TOKEN_J}/" "$CURL_STDIN"
sed -i '/TELEGRAM_BOT_TOKEN/d' "${ETC}/jarvis/channel.env"; : >"$CURL_STDIN"; rm -f "${ST}/pane-coder"
PATH="${BIN}:${PATH}" AUTH_WATCH_ENABLED="channel-jarvis" AUTH_WATCH_NOW="$NOW0" bash "$W" >/dev/null 2>&1
check "send: fallback to Richard bot"   grep -q "bot${TOKEN_R}/" "$CURL_STDIN"

# --- installer: hourly root cron, STOP named, manifest knows it ------------------------------------------
export INSTALL_SH_SOURCED_FOR_TESTING=1
CRON_OUT=$(
    # shellcheck disable=SC1091
    source "${REPO}/install.sh" >/dev/null 2>&1
    set +e
    apply_install_names new
    install() { :; }
    _install_cron_file() { printf 'FILE=%s\n%s\n' "$1" "$2"; }
    install_auth_watch_cron
)
check "cron: file name"                 grep -qx 'FILE=neurootdel-auth-watch' <<<"$CRON_OUT"
check "cron: hourly as root"            grep -qE '^17 \* \* \* \* root /bin/bash /usr/local/lib/neurootdel/claude-auth-watch.sh >> /var/log/neurootdel-auth-watch.log 2>&1$' <<<"$CRON_OUT"
check "cron: STOP named"                grep -q 'touch /var/lib/neurootdel-auth-watch/STOP' <<<"$CRON_OUT"
check "cron: called from install_guard" bash -c "sed -n '/^install_guard() {/,/^}/p' '${REPO}/install.sh' | grep -qx '    install_auth_watch_cron'"
check "manifest: cron slot expected"    grep -q 'auth-watch::claude-auth-watch.sh::' "${REPO}/lib/cron-manifest-watchdog.sh"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
