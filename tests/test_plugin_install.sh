#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2059,SC2329  # eval strings, globals read by sourced fns, overrides
# Tests for the dashi-plugin (channel-jarvis) part of install.sh, no root needed:
#   channel.env rendering + merge on re-run, folder-trust edit of ~/.claude.json,
#   unit template, sudoers entries, migration inputs from the old gateway,
#   workspace files kept on re-run.
# Run: bash tests/test_plugin_install.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
TMUX_SOCKS=()
cleanup() {
    local sock
    for sock in "${TMUX_SOCKS[@]:-}"; do
        if [[ -n "$sock" ]]; then
            tmux -L "$sock" kill-server >/dev/null 2>&1 || true
        fi
    done
    rm -rf "${TDIR:?}"
}
trap cleanup EXIT

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
has()    { grep -qxF -- "$2" "$1"; }
hasnt()  { ! grep -qE -- "$2" "$1"; }

# A copy of install.sh whose agent home points into the sandbox (set after sourcing).
FAKE_HOME="${TDIR}/home"
mkdir -p "$FAKE_HOME"
# Root-only paths (/etc, /var/backups) and the root check are pointed into
# the sandbox too, so the switch-over logic runs as a normal user.
mkdir -p "${TDIR}/systemd" "${TDIR}/etc-jarvis" "${TDIR}/backups"
sed -e "s#^readonly RICHARD_HOME=.*#readonly RICHARD_HOME=\"${TDIR}/richard\"#" \
    -e "s#/etc/systemd/system/#${TDIR}/systemd/#g" \
    -e 's#\$EUID -ne 0 ]]#$EUID -ne 0 \&\& -z "${TEST_AS_ROOT:-}" ]]#' \
    "${REPO}/install.sh" >"${TDIR}/install.sh"

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${TDIR}/install.sh"
set +e    # the checks below report failures themselves
# New-install names, then every root path pointed into the sandbox.
apply_install_names new
AGENT_HOME="$FAKE_HOME"
JARVIS_ENV_DIR="${TDIR}/etc-jarvis"
LEGACY_BACKUP_ROOT="${TDIR}/backups"
CHANNEL_CONFIRM_BIN="${TDIR}/libexec/channel-confirm.sh"
CHANNEL_START_BIN="${TDIR}/libexec/channel-start.sh"
as_agent() { "$@"; }

TOKEN="123456789:AAHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN2="987654321:BBHabcdefghijklmnopqrstuvwxyz0123456"

# --- channel.env: fresh install ------------------------------------------------
ENV1="${TDIR}/env1"
CHANNEL_ENV_TOKEN="$TOKEN" render_channel_env "" "555" "" /st /ws >"$ENV1"
check "fresh: token written"            has "$ENV1" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "fresh: user ids"                 has "$ENV1" "TELEGRAM_ALLOWED_USER_IDS=555"
check "fresh: chat ids = user ids"      has "$ENV1" "TELEGRAM_ALLOWED_CHAT_IDS=555"
check "fresh: state dir"                has "$ENV1" "TELEGRAM_STATE_DIR=/st"
check "fresh: workspace root"           has "$ENV1" "TELEGRAM_WORKSPACE_ROOT=/ws"
check "fresh: agent id"                 has "$ENV1" "AGENT_ID=jarvis"
check "fresh: no expected bot id line"  hasnt "$ENV1" '^TELEGRAM_EXPECTED_BOT_ID='
check "fresh: no groq without key"      hasnt "$ENV1" '^GROQ_API_KEY='
check "fresh: token not in argv form"   hasnt "$ENV1" '^#.*AAHabc'

# --- channel.env: empty answers (tokens filled later by hand) ------------------
ENV0="${TDIR}/env0"
CHANNEL_ENV_TOKEN="" render_channel_env "" "" "" /st /ws >"$ENV0"
check "empty: renders"                  test -s "$ENV0"
check "empty: token line present"       has "$ENV0" "TELEGRAM_BOT_TOKEN="
check "empty: chat ids line present"    has "$ENV0" "TELEGRAM_ALLOWED_CHAT_IDS="

# --- channel.env: re-run keeps values, merges chat ids, keeps extras ----------
PREV="${TDIR}/prev"
cat >"$PREV" <<EOF
TELEGRAM_BOT_TOKEN=${TOKEN}
TELEGRAM_EXPECTED_BOT_ID=111
TELEGRAM_ALLOWED_USER_IDS=555
TELEGRAM_ALLOWED_CHAT_IDS=-100777
TELEGRAM_WEBHOOK_PORT=8095
MY_EXTRA=keep
EOF
ENV2="${TDIR}/env2"
CHANNEL_ENV_TOKEN="" render_channel_env "$PREV" "" "" /st /ws >"$ENV2"
check "rerun: token kept"               has "$ENV2" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "rerun: user ids kept"            has "$ENV2" "TELEGRAM_ALLOWED_USER_IDS=555"
check "rerun: group kept + owner added" has "$ENV2" "TELEGRAM_ALLOWED_CHAT_IDS=-100777,555"
check "rerun: custom port kept"         has "$ENV2" "TELEGRAM_WEBHOOK_PORT=8095"
check "rerun: extra key kept"           has "$ENV2" "MY_EXTRA=keep"
check "rerun: stale expected id dropped" hasnt "$ENV2" '^TELEGRAM_EXPECTED_BOT_ID='

ENV3="${TDIR}/env3"
CHANNEL_ENV_TOKEN="$TOKEN2" render_channel_env "$PREV" "999" "" /st /ws >"$ENV3"
check "rerun: new token wins"           has "$ENV3" "TELEGRAM_BOT_TOKEN=${TOKEN2}"
check "rerun: new user id wins"         has "$ENV3" "TELEGRAM_ALLOWED_USER_IDS=999"
check "rerun: new id added to chats"    has "$ENV3" "TELEGRAM_ALLOWED_CHAT_IDS=-100777,999"

# --- channel.env: permission prompts pinned to the owner ------------------------
check "perm: fresh pinned to owner"     has "$ENV1" "TELEGRAM_PERMISSION_ALLOWED_USER_IDS=555"
check "perm: empty answers, no line"    hasnt "$ENV0" '^TELEGRAM_PERMISSION_ALLOWED_USER_IDS='
check "perm: rerun pins existing owner" has "$ENV2" "TELEGRAM_PERMISSION_ALLOWED_USER_IDS=555"
check "perm: new owner answer re-pins"  has "$ENV3" "TELEGRAM_PERMISSION_ALLOWED_USER_IDS=999"
TEAM="${TDIR}/team"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USER_IDS=555,777\nTELEGRAM_ALLOWED_CHAT_IDS=555,777\nTELEGRAM_PERMISSION_ALLOWED_USER_IDS=555\n' "$TOKEN" >"$TEAM"
ENV6="${TDIR}/env6"
CHANNEL_ENV_TOKEN="" render_channel_env "$TEAM" "" "" /st /ws >"$ENV6"
check "perm: team member added, owner kept" has "$ENV6" "TELEGRAM_PERMISSION_ALLOWED_USER_IDS=555"
check "perm: team member stays allowed" has "$ENV6" "TELEGRAM_ALLOWED_USER_IDS=555,777"
check "perm: exactly one perm line"     test "$(grep -c '^TELEGRAM_PERMISSION_ALLOWED_USER_IDS=' "$ENV6")" -eq 1
ENV7="${TDIR}/env7"
CHANNEL_ENV_TOKEN="" render_channel_env "$TEAM" "999" "" /st /ws >"$ENV7"
check "perm: owner answer overrides pin" has "$ENV7" "TELEGRAM_PERMISSION_ALLOWED_USER_IDS=999"

# --- channel.env: groq key from file -------------------------------------------
printf 'gsk_test123\n' >"${TDIR}/groq"
ENV4="${TDIR}/env4"
CHANNEL_ENV_TOKEN="$TOKEN" render_channel_env "" "555" "${TDIR}/groq" /st /ws >"$ENV4"
check "groq: key from file"             has "$ENV4" "GROQ_API_KEY=gsk_test123"

# --- channel.env: bad input refused ---------------------------------------------
check "bad token refused"   eval '! CHANNEL_ENV_TOKEN="nope" render_channel_env "" "" "" /st /ws >/dev/null 2>&1'
check "bad user id refused" eval '! CHANNEL_ENV_TOKEN="" render_channel_env "" "12a" "" /st /ws >/dev/null 2>&1'

# --- ~/.claude.json folder trust ------------------------------------------------
CJ="${TDIR}/claude.json"
printf '{"oauthAccount":{"x":1},"projects":{"/other":{"a":1}},"hasCompletedOnboarding":false}\n' >"$CJ"
chmod 600 "$CJ"
_accept_trust_dialog "$CJ" "/p/plugin"
check "trust: set for plugin dir" \
    python3 -c "import json,sys; d=json.load(open('$CJ')); sys.exit(0 if d['projects']['/p/plugin']['hasTrustDialogAccepted'] is True else 1)"
check "trust: other keys kept" \
    python3 -c "import json,sys; d=json.load(open('$CJ')); sys.exit(0 if d['oauthAccount']=={'x':1} and d['projects']['/other']=={'a':1} else 1)"
check "trust: explicit onboarding value kept" \
    python3 -c "import json,sys; d=json.load(open('$CJ')); sys.exit(0 if d['hasCompletedOnboarding'] is False else 1)"
check "trust: mode 600 kept"      test "$(stat -c %a "$CJ")" = "600"
check "trust: backup written"     test -f "${CJ}.bak-install"
_accept_trust_dialog "$CJ" "/p/plugin"
check "trust: idempotent" \
    python3 -c "import json,sys; d=json.load(open('$CJ')); sys.exit(0 if len(d['projects'])==2 else 1)"

CJ2="${TDIR}/new.json"
_accept_trust_dialog "$CJ2" "/p/plugin"
check "trust: file created"       test -f "$CJ2"
check "trust: new file onboarding done" \
    python3 -c "import json,sys; d=json.load(open('$CJ2')); sys.exit(0 if d['hasCompletedOnboarding'] is True else 1)"

CJ3="${TDIR}/broken.json"
printf '{not json' >"$CJ3"
check "trust: broken json -> non-zero" eval '! _accept_trust_dialog "$CJ3" /p/plugin 2>/dev/null'
check "trust: broken json untouched"   test "$(cat "$CJ3")" = "{not json"

# --- trust: several dirs, rejected channel repaired -------------------------------
CJ4="${TDIR}/multi.json"
printf '{"projects":{"/r":{"disabledMcpjsonServers":["dashi-channel","x"],"k":1}}}\n' >"$CJ4"
_accept_trust_dialog "$CJ4" /r /r/plugin
check "trust multi: root trusted" \
    python3 -c "import json,sys; d=json.load(open('$CJ4'))['projects']; sys.exit(0 if d['/r']['hasTrustDialogAccepted'] and d['/r/plugin']['hasTrustDialogAccepted'] else 1)"
check "trust multi: channel un-disabled, rest kept" \
    python3 -c "import json,sys; e=json.load(open('$CJ4'))['projects']['/r']; sys.exit(0 if e['disabledMcpjsonServers']==['x'] and e['k']==1 else 1)"

# --- MCP pre-approval (settings.local.json) -------------------------------------
SL1="${TDIR}/repo/.claude/settings.local.json"; SL2="${TDIR}/repo/plugin/.claude/settings.local.json"
_approve_channel_mcp "$SL1" "$SL2"
check "mcp: root file created"   python3 -c "import json,sys; sys.exit(0 if json.load(open('$SL1'))['enabledMcpjsonServers']==['dashi-channel'] else 1)"
check "mcp: plugin file created" python3 -c "import json,sys; sys.exit(0 if json.load(open('$SL2'))['enabledMcpjsonServers']==['dashi-channel'] else 1)"
check "mcp: new file is 0600"  test "$(stat -c %a "$SL2")" = "600"
printf '{"disabledMcpjsonServers":["dashi-channel","other"],"enabledMcpjsonServers":["gbrain"],"permissions":{"allow":["x"]}}\n' >"$SL1"
chmod 640 "$SL1"
_approve_channel_mcp "$SL1"
_approve_channel_mcp "$SL1"
check "mcp: rejected channel repaired" \
    python3 -c "import json,sys; d=json.load(open('$SL1')); sys.exit(0 if d['disabledMcpjsonServers']==['other'] and d['enabledMcpjsonServers']==['gbrain','dashi-channel'] else 1)"
check "mcp: existing mode kept" test "$(stat -c %a "$SL1")" = "640"
check "mcp: other keys kept" \
    python3 -c "import json,sys; d=json.load(open('$SL1')); sys.exit(0 if d['permissions']=={'allow':['x']} else 1)"
printf '{broken' >"$SL2"
check "mcp: broken json -> non-zero" eval '! _approve_channel_mcp "$SL2" 2>/dev/null'
check "mcp: broken json untouched"   test "$(cat "$SL2")" = "{broken"

# --- channel-start.sh: bot id from the token ------------------------------------
FAKEBIN="${TDIR}/fakebin"; mkdir -p "$FAKEBIN"
cat >"${FAKEBIN}/tmux" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" kill-server "* ]] && { printf 'KILL=%s\n' "$*" >>"${FAKE_TMUX_LOG:?}"; exit 1; }
printf 'ARGS=%s\n' "$*"
printf 'ENV=%s\n' "${TELEGRAM_EXPECTED_BOT_ID-<unset>}"
EOF
chmod +x "${FAKEBIN}/tmux"
CS="${REPO}/templates/channel-start.sh"
export FAKE_TMUX_LOG="${TDIR}/fake-tmux.log"; : >"$FAKE_TMUX_LOG"
O1=$(PATH="${FAKEBIN}:$PATH" TELEGRAM_BOT_TOKEN="$TOKEN" TELEGRAM_EXPECTED_BOT_ID=8507713167 bash "$CS" channel-jarvis claude --x)
check "start: id from token, stale one replaced" grep -qx 'ENV=123456789' <<<"$O1"
check "start: leftover server killed first"     grep -qx 'KILL=-L channel-jarvis kill-server' "$FAKE_TMUX_LOG"
check "start: session args"                      grep -qx 'ARGS=-L channel-jarvis new-session -d -s channel-jarvis claude --x' <<<"$O1"
check "start: token not in argv"                 bash -c "! grep -q 'AAHabc' <<<\"\$1\"" _ "$O1"
O2=$(PATH="${FAKEBIN}:$PATH" TELEGRAM_BOT_TOKEN="" TELEGRAM_EXPECTED_BOT_ID="" bash "$CS" channel-jarvis claude)
check "start: no token -> id unset (not empty)"  grep -qx 'ENV=<unset>' <<<"$O2"
check "start: no token -> session args"          grep -qx 'ARGS=-L channel-jarvis new-session -d -s channel-jarvis claude' <<<"$O2"
if command -v tmux >/dev/null 2>&1; then
    SOCK="edgelab-test-$$"; TMUX_SOCKS+=("$SOCK"); ENVOUT="${TDIR}/tmux-env"; : >"$ENVOUT"
    TELEGRAM_BOT_TOKEN="$TOKEN2" TELEGRAM_EXPECTED_BOT_ID=8507713167 \
        bash "$CS" "$SOCK" sh -c "env >'$ENVOUT'; sleep 30" >/dev/null 2>&1
    for _ in 1 2 3 4 5; do [[ -s "$ENVOUT" ]] && break; sleep 1; done
    tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
    check "start (real tmux): id reaches the session" grep -qx 'TELEGRAM_EXPECTED_BOT_ID=987654321' "$ENVOUT"

    # A leftover server started with bot A must not leak A into bot B's session.
    SOCK2="edgelab-test2-$$"; TMUX_SOCKS+=("$SOCK2"); ENVOUT2="${TDIR}/tmux-env2"; : >"$ENVOUT2"
    TELEGRAM_BOT_TOKEN="$TOKEN" TELEGRAM_EXPECTED_BOT_ID=123456789 \
        tmux -L "$SOCK2" new-session -d -s "$SOCK2" sleep 60
    TELEGRAM_BOT_TOKEN="$TOKEN2" bash "$CS" "$SOCK2" sh -c "env >'$ENVOUT2'; sleep 30" >/dev/null 2>&1
    for _ in 1 2 3 4 5; do [[ -s "$ENVOUT2" ]] && break; sleep 1; done
    check "start (leftover server): new id"    grep -qx 'TELEGRAM_EXPECTED_BOT_ID=987654321' "$ENVOUT2"
    check "start (leftover server): new token" grep -qx "TELEGRAM_BOT_TOKEN=${TOKEN2}" "$ENVOUT2"
    tmux -L "$SOCK2" kill-server >/dev/null 2>&1 || true

    # Leftover server with an id, then no token: the id must not survive.
    SOCK3="edgelab-test3-$$"; TMUX_SOCKS+=("$SOCK3"); ENVOUT3="${TDIR}/tmux-env3"; : >"$ENVOUT3"
    TELEGRAM_EXPECTED_BOT_ID=123456789 tmux -L "$SOCK3" new-session -d -s "$SOCK3" sleep 60
    env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_EXPECTED_BOT_ID bash "$CS" "$SOCK3" sh -c "env >'$ENVOUT3'; echo end >>'$ENVOUT3'; sleep 30" >/dev/null 2>&1
    for _ in 1 2 3 4 5; do grep -q '^end$' "$ENVOUT3" && break; sleep 1; done
    check "start (leftover server, no token): no id" bash -c "grep -q '^end$' '$ENVOUT3' && ! grep -q '^TELEGRAM_EXPECTED_BOT_ID=' '$ENVOUT3'"
    tmux -L "$SOCK3" kill-server >/dev/null 2>&1 || true
fi

# --- unit template --------------------------------------------------------------
UNIT="${TDIR}/unit"
render_template "${REPO}/templates/channel-jarvis.service" "$UNIT" \
    USER edgelab HOME /home/edgelab PLUGIN_DIR /pd ENV_FILE /etc/dashi-plugin/jarvis/channel.env \
    CONFIRM_SCRIPT /usr/local/lib/edgelab/channel-confirm.sh \
    START_SCRIPT /usr/local/lib/edgelab/channel-start.sh
check "unit: start via channel-start.sh" grep -q '^ExecStart=/bin/bash /usr/local/lib/edgelab/channel-start.sh channel-jarvis claude ' "$UNIT"
check "unit: no placeholders left"   hasnt "$UNIT" '\{\{'
check "unit: user"                   has "$UNIT" "User=edgelab"
check "unit: workdir"                has "$UNIT" "WorkingDirectory=/pd"
check "unit: env file"               has "$UNIT" "EnvironmentFile=/etc/dashi-plugin/jarvis/channel.env"
check "unit: bun on PATH"            grep -q '^Environment=PATH=/home/edgelab/.bun/bin:' "$UNIT"
check "unit: system target"          has "$UNIT" "WantedBy=multi-user.target"
check "unit: confirm script"         has "$UNIT" "ExecStartPost=/bin/bash /usr/local/lib/edgelab/channel-confirm.sh channel-jarvis"
if command -v systemd-analyze >/dev/null 2>&1; then
    cp "$UNIT" "${TDIR}/channel-jarvis.service"
    check "unit: systemd-analyze verify" \
        bash -c "systemd-analyze verify '${TDIR}/channel-jarvis.service' 2>&1 | grep -vE 'not executable|No such file|Failed to|WorkingDirectory|EnvironmentFile|/pd' | grep -qiE 'error|unknown' && exit 1 || exit 0"
fi

# --- sudoers: channel-jarvis entries, legacy kept, syntax valid ----------------
SUDO_OUT="${TDIR}/sudoers"
install() { cp "${@: -2:1}" "$SUDO_OUT"; }
step() { :; }
PATH="${PATH}:/usr/sbin:/sbin" install_sudoers >/dev/null
unset -f install
check "sudoers: restart channel-jarvis" grep -q '/usr/bin/systemctl restart channel-jarvis, ' "$SUDO_OUT"
check "sudoers: journal channel-jarvis" grep -q '/usr/bin/journalctl -u channel-jarvis \*' "$SUDO_OUT"
check "sudoers: gateway kept for rollback" grep -q '/usr/bin/systemctl enable claude-gateway, ' "$SUDO_OUT"
if [[ -x /usr/sbin/visudo ]]; then
    check "sudoers: visudo -c" /usr/sbin/visudo -cqf "$SUDO_OUT"
fi

# --- migration: inputs from the old gateway config -----------------------------
mkdir -p "${FAKE_HOME}/claude-gateway/secrets" "${FAKE_HOME}/.claude-lab/shared/secrets"
printf '{"allowed_user_ids":[555,777],"agents":{"jarvis":{"bot_token":"%s"}}}\n' "$TOKEN" \
    >"${FAKE_HOME}/claude-gateway/config.json"
printf 'gsk_legacy\n' >"${FAKE_HOME}/claude-gateway/secrets/groq-api-key"
JARVIS_BOT_TOKEN=""; TG_USER_ID=""
_collect_jarvis_channel_inputs
check "legacy: token imported"      test "$JARVIS_BOT_TOKEN" = "$TOKEN"
check "legacy: ids imported"        test "$JARVIS_ALLOWED_IDS" = "555,777"
check "legacy: groq file fallback"  test "$JARVIS_GROQ_KEY_FILE" = "${FAKE_HOME}/claude-gateway/secrets/groq-api-key"

printf 'gsk_shared\n' >"${FAKE_HOME}/.claude-lab/shared/secrets/groq-api-key"
JARVIS_BOT_TOKEN="$TOKEN2"; TG_USER_ID="999"
_collect_jarvis_channel_inputs
check "legacy: operator answer wins (token)" test "$JARVIS_BOT_TOKEN" = "$TOKEN2"
check "legacy: operator answer wins (id)"    test "$JARVIS_ALLOWED_IDS" = "999"
check "legacy: shared groq preferred"        test "$JARVIS_GROQ_KEY_FILE" = "${FAKE_HOME}/.claude-lab/shared/secrets/groq-api-key"

# groq key rotated inside channel.env: the file on disk must not win back
GENV="${TDIR}/groq.env"
printf 'TELEGRAM_BOT_TOKEN=%s\nGROQ_API_KEY=gsk_rotated\n' "$TOKEN" >"$GENV"
_collect_jarvis_channel_inputs "$GENV"
check "groq rotated: no file import" test -z "$JARVIS_GROQ_KEY_FILE"
CHANNEL_ENV_TOKEN="" render_channel_env "$GENV" "" "$JARVIS_GROQ_KEY_FILE" /st /ws >"${TDIR}/groq.out"
check "groq rotated: kept" has "${TDIR}/groq.out" "GROQ_API_KEY=gsk_rotated"

rm -rf "${FAKE_HOME:?}/claude-gateway"
JARVIS_BOT_TOKEN=""; TG_USER_ID=""
check "fresh server: no legacy, returns 0" _collect_jarvis_channel_inputs
check "fresh server: token stays empty"    test -z "$JARVIS_BOT_TOKEN"

# --- migrated server, re-run: channel.env beats the stale gateway config ------
mkdir -p "${FAKE_HOME}/claude-gateway"
printf '{"allowed_user_ids":[555],"agents":{"jarvis":{"bot_token":"%s"}}}\n' "$TOKEN" \
    >"${FAKE_HOME}/claude-gateway/config.json"
ROT="${TDIR}/rotated.env"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USER_IDS=999\nTELEGRAM_ALLOWED_CHAT_IDS=999\n' "$TOKEN2" >"$ROT"
JARVIS_BOT_TOKEN=""; TG_USER_ID=""
_collect_jarvis_channel_inputs "$ROT"
check "rotated: legacy token not re-imported" test -z "$JARVIS_BOT_TOKEN"
check "rotated: legacy ids not re-imported"   test -z "$JARVIS_ALLOWED_IDS"
ENV5="${TDIR}/env5"
CHANNEL_ENV_TOKEN="$JARVIS_BOT_TOKEN" render_channel_env "$ROT" "$JARVIS_ALLOWED_IDS" "" /st /ws >"$ENV5"
check "rotated: rotated token kept"  has "$ENV5" "TELEGRAM_BOT_TOKEN=${TOKEN2}"
check "rotated: revoked id not back" has "$ENV5" "TELEGRAM_ALLOWED_USER_IDS=999"
rm -rf "${FAKE_HOME:?}/claude-gateway"

# --- switch-over with a stubbed systemctl -----------------------------------------
CALLS="${TDIR}/calls"
# Stub state: *_ACTIVE / *_ENABLED; *_STOPS / *_DISABLES say whether
# `disable --now` manages to stop / disable that unit.
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; LEGACY_STOPS=1; LEGACY_DISABLES=1
PLUGIN_ACTIVE=0; PLUGIN_ENABLED=0; PLUGIN_STOPS=1; PLUGIN_DISABLES=1
systemctl() {
    printf '%s\n' "$*" >>"$CALLS"
    local verb=$1 unit=${*: -1} who
    [[ "$unit" == --quiet ]] && unit=${*: -2:1}
    if [[ "$unit" == claude-gateway* ]]; then who=LEGACY; else who=PLUGIN; fi
    local -n active="${who}_ACTIVE" enabled="${who}_ENABLED" stops="${who}_STOPS" disables="${who}_DISABLES"
    case "$verb" in
        is-active)  [[ "$active" == 1 ]] ;;
        is-enabled) [[ "$enabled" == 1 ]] ;;
        disable)
            [[ "$stops" == 1 ]] && active=0
            [[ "$disables" == 1 ]] && enabled=0
            return 0 ;;
        enable)
            enabled=1
            [[ "$*" == *"--now"* ]] && active=1
            return 0 ;;
        restart) active=1 ;;
        *) return 0 ;;
    esac
}
install() {    # drop -o/-g/-m: the sandbox user cannot chown to root
    local args=()
    while (($#)); do case $1 in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
}
printf '[Service]\n' >"${TDIR}/systemd/claude-gateway.service"
printf '[Service]\n' >"${TDIR}/systemd/channel-jarvis.service"
mkdir -p "${FAKE_HOME}/.claude"; printf '{}' >"${FAKE_HOME}/.claude/.credentials.json"
RICHARD_BOT_TOKEN=""

# token only in the file (filled by hand), no answer this run
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" >"${TDIR}/etc-jarvis/channel.env"
JARVIS_BOT_TOKEN=""; : >"$CALLS"
enable_services >/dev/null 2>&1
check "switch: token from file starts plugin" grep -qx 'restart channel-jarvis.service' "$CALLS"
check "switch: gateway disabled first" \
    bash -c "grep -n 'disable --now claude-gateway' '$CALLS' | cut -d: -f1 | head -1 | xargs -I{} test {} -lt \$(grep -n 'restart channel-jarvis' '$CALLS' | cut -d: -f1)"
check "switch: gateway backup made" bash -c "ls '${TDIR}/backups'/claude-gateway-*/claude-gateway.service >/dev/null"

# gateway refuses to stop -> plugin must not start
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; LEGACY_STOPS=0; PLUGIN_ACTIVE=0; : >"$CALLS"
enable_services >/dev/null 2>&1
check "switch: stuck gateway -> plugin not started" bash -c "! grep -q 'channel-jarvis' '$CALLS'"

# gateway stops but stays enabled (would come back at boot) -> no start
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; LEGACY_STOPS=1; LEGACY_DISABLES=0; : >"$CALLS"
enable_services >/dev/null 2>&1
check "switch: gateway still enabled -> plugin not started" bash -c "! grep -q 'channel-jarvis' '$CALLS'"
LEGACY_DISABLES=1

# backup fails -> gateway untouched, plugin not started
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; : >"$CALLS"
cp() { return 1; }
enable_services >/dev/null 2>&1
unset -f cp
check "switch: backup fails -> gateway untouched" bash -c "! grep -q 'disable --now claude-gateway' '$CALLS'"
check "switch: backup fails -> plugin not started" bash -c "! grep -q 'channel-jarvis' '$CALLS'"

# no token anywhere -> nothing enabled
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; LEGACY_STOPS=1; printf 'TELEGRAM_BOT_TOKEN=\n' >"${TDIR}/etc-jarvis/channel.env"; : >"$CALLS"
enable_services >/dev/null 2>&1
check "switch: empty token -> plugin not enabled" bash -c "! grep -q 'channel-jarvis' '$CALLS'"
check "switch: empty token -> gateway untouched"  bash -c "! grep -q 'disable --now claude-gateway' '$CALLS'"

# rollback: plugin off, gateway on
export TEST_AS_ROOT=1
LEGACY_ACTIVE=0; LEGACY_ENABLED=0; PLUGIN_ACTIVE=1; PLUGIN_ENABLED=1; PLUGIN_STOPS=1; : >"$CALLS"
( rollback_to_gateway ) >/dev/null 2>&1
check "rollback: exit 0" test $? -eq 0
check "rollback: plugin disabled" grep -q 'disable --now channel-jarvis.service' "$CALLS"
check "rollback: gateway enabled" grep -q 'enable --now claude-gateway.service' "$CALLS"

# rollback: plugin refuses to stop -> gateway must not start
LEGACY_ACTIVE=0; LEGACY_ENABLED=0; PLUGIN_ACTIVE=1; PLUGIN_ENABLED=1; PLUGIN_STOPS=0; : >"$CALLS"
( rollback_to_gateway ) >/dev/null 2>&1
check "rollback: stuck plugin -> non-zero" test $? -ne 0
check "rollback: stuck plugin -> gateway not started" bash -c "! grep -q 'enable --now claude-gateway' '$CALLS'"

# rollback: plugin stops but stays enabled -> gateway must not start
PLUGIN_ACTIVE=1; PLUGIN_ENABLED=1; PLUGIN_STOPS=1; PLUGIN_DISABLES=0; : >"$CALLS"
( rollback_to_gateway ) >/dev/null 2>&1
check "rollback: plugin still enabled -> non-zero" test $? -ne 0
check "rollback: plugin still enabled -> gateway not started" bash -c "! grep -q 'enable --now claude-gateway' '$CALLS'"
PLUGIN_DISABLES=1

# rollback on a plugin-only server: nothing to return to, exit 0
rm -f "${TDIR}/systemd/claude-gateway.service"
PLUGIN_ACTIVE=1; PLUGIN_STOPS=1; : >"$CALLS"
( rollback_to_gateway ) >/dev/null 2>&1
check "rollback: no gateway -> exit 0" test $? -eq 0
check "rollback: no gateway -> nothing enabled" bash -c "! grep -q '^enable' '$CALLS'"
check "rollback: no gateway -> plugin left running" bash -c "! grep -q 'disable' '$CALLS'"
unset -f systemctl install
unset TEST_AS_ROOT

# --- install_jarvis end to end (git/bun stubbed): approval + trust land -------
PR="${FAKE_HOME}/.claude-lab/jarvis/.claude/dashi-plugin-claude-code"
mkdir -p "${PR}/.git" "${PR}/plugin" "${PR}/.claude"; printf '{}' >"${PR}/plugin/.mcp.json"
# What a rejected first start leaves behind (seen live, Claude Code 2.1.283).
printf '{"disabledMcpjsonServers":["dashi-channel"]}\n' >"${PR}/.claude/settings.local.json"
as_agent() { case "$1" in git|env) return 0 ;; *) "$@" ;; esac; }
install() {
    local args=()
    while (($#)); do case $1 in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
}
fix_owner() { :; }
mkdir -p "${TDIR}/libexec"
JARVIS_BOT_TOKEN="$TOKEN"; TG_USER_ID="555"
install_jarvis >/dev/null 2>&1
check "jarvis: root settings approve channel" \
    python3 -c "import json,sys; d=json.load(open('${PR}/.claude/settings.local.json')); sys.exit(0 if 'dashi-channel' in d['enabledMcpjsonServers'] and 'dashi-channel' not in d.get('disabledMcpjsonServers',[]) else 1)"
check "jarvis: plugin settings approve channel" \
    python3 -c "import json,sys; d=json.load(open('${PR}/plugin/.claude/settings.local.json')); sys.exit(0 if 'dashi-channel' in d['enabledMcpjsonServers'] else 1)"
check "jarvis: repo root + plugin trusted" \
    python3 -c "import json,sys; p=json.load(open('${FAKE_HOME}/.claude.json'))['projects']; sys.exit(0 if p['${PR}']['hasTrustDialogAccepted'] and p['${PR}/plugin']['hasTrustDialogAccepted'] else 1)"
check "jarvis: start script installed"  test -x "${TDIR}/libexec/channel-start.sh"
check "jarvis: unit uses start script"  grep -q "^ExecStart=/bin/bash ${TDIR}/libexec/channel-start.sh channel-jarvis " "${TDIR}/systemd/channel-jarvis.service"
unset -f install fix_owner
as_agent() { "$@"; }

# --- workspace: a re-run keeps the agent's files --------------------------------
WS="${TDIR}/ws"
write_as_user() { mkdir -p "$(dirname "$2")"; cp "$1" "$2"; chmod "$3" "$2"; }
_write_agent_workspace_test() {
    local f="${WS}/core/hot/handoff.md" tmp
    mkdir -p "$(dirname "$f")"
    printf 'MY MEMORY\n' >"$f"
    tmp=$(mktemp)
    printf 'stub\n' >"$tmp"
    _write_if_absent "$tmp" "$f" 0644
    _write_if_absent "$tmp" "${WS}/core/new.md" 0644
    rm -f "$tmp"
}
_write_agent_workspace_test
check "workspace: existing file kept" test "$(cat "${WS}/core/hot/handoff.md")" = "MY MEMORY"
check "workspace: missing file written" test "$(cat "${WS}/core/new.md")" = "stub"

# --- prompt_or_env without a tty: like Enter, never dies -----------------------
unset NEUROOTDEL_TEST_ANSWER
R1=$( (NEUROOTDEL_NONINTERACTIVE=1 prompt_or_env V NEUROOTDEL_TEST_ANSWER "q" "" --secret </dev/null 2>/dev/null; printf 'rc=%s v=[%s]' "$?" "$V") )
check "no tty, no default: rc 0, empty" test "$R1" = "rc=0 v=[]"
R2=$( (prompt_or_env V NEUROOTDEL_TEST_ANSWER "q" "Russian" </dev/null 2>/dev/null; printf 'rc=%s v=[%s]' "$?" "$V") )
check "no tty, default used"            test "$R2" = "rc=0 v=[Russian]"
R3=$( (NEUROOTDEL_TEST_ANSWER=from_env prompt_or_env V NEUROOTDEL_TEST_ANSWER "q" "" </dev/null 2>/dev/null; printf 'rc=%s v=[%s]' "$?" "$V") )
check "no tty, env wins"                test "$R3" = "rc=0 v=[from_env]"
R3b=$( (EDGELAB_TEST_ANSWER=old_name prompt_or_env V NEUROOTDEL_TEST_ANSWER "q" "" </dev/null 2>/dev/null; printf 'rc=%s v=[%s]' "$?" "$V") )
check "no tty, old EDGELAB_ name accepted" test "$R3b" = "rc=0 v=[old_name]"
R3c=$( (EDGELAB_TEST_ANSWER=old NEUROOTDEL_TEST_ANSWER=new prompt_or_env V NEUROOTDEL_TEST_ANSWER "q" "" </dev/null 2>/dev/null; printf 'rc=%s v=[%s]' "$?" "$V") )
check "no tty, new name wins over old"  test "$R3c" = "rc=0 v=[new]"
R3d=$( (unset NEUROOTDEL_NONINTERACTIVE; EDGELAB_NONINTERACTIVE=1 is_noninteractive </dev/null; printf 'rc=%s' "$?") )
check "old EDGELAB_NONINTERACTIVE honoured" test "$R3d" = "rc=0"
R4=$( (NEUROOTDEL_NONINTERACTIVE=1 collect_inputs </dev/null >/dev/null 2>&1; printf 'rc=%s' "$?") )
check "no tty: collect_inputs survives with no tokens" test "$R4" = "rc=0"

# --- merge_env_file ---------------------------------------------------------------
REND="${TDIR}/rend.env"; OLD="${TDIR}/old.env"
printf '# c\nTELEGRAM_BOT_TOKEN=\nTELEGRAM_BOT_USERNAME=\nALLOWED_USERS=\nENVIRONMENT=production\nNEW_KEY=1\n' >"$REND"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_BOT_USERNAME=rbot\nALLOWED_USERS=555\nENVIRONMENT=dev\nMY_OWN=x\n' "$TOKEN" >"$OLD"
merge_env_file "$REND" "$OLD" TELEGRAM_BOT_TOKEN,TELEGRAM_BOT_USERNAME,ALLOWED_USERS >"${TDIR}/m1"
check "merge: empty answer keeps token" has "${TDIR}/m1" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "merge: empty answer keeps users" has "${TDIR}/m1" "ALLOWED_USERS=555"
check "merge: hand edit kept"           has "${TDIR}/m1" "ENVIRONMENT=dev"
check "merge: extra key kept"           has "${TDIR}/m1" "MY_OWN=x"
check "merge: new template key added"   has "${TDIR}/m1" "NEW_KEY=1"
check "merge: comments from template"   has "${TDIR}/m1" "# c"
printf 'TELEGRAM_BOT_TOKEN=%s\nALLOWED_USERS=999\n' "$TOKEN2" >"$REND"
merge_env_file "$REND" "$OLD" TELEGRAM_BOT_TOKEN,TELEGRAM_BOT_USERNAME,ALLOWED_USERS >"${TDIR}/m2"
check "merge: new answer wins (token)"  has "${TDIR}/m2" "TELEGRAM_BOT_TOKEN=${TOKEN2}"
check "merge: new answer wins (users)"  has "${TDIR}/m2" "ALLOWED_USERS=999"
printf 'TELEGRAM_BOT_TOKEN=\nANTHROPIC_API_KEY=\n' >"$REND"
printf 'export TELEGRAM_BOT_TOKEN = %s\nANTHROPIC_API_KEY = sk-x\nexport MY_EXP=1\nQ="a \\"b\\" c"\n' "$TOKEN" >"$OLD"
merge_env_file "$REND" "$OLD" TELEGRAM_BOT_TOKEN >"${TDIR}/m3"
check "merge: export/space answer key kept" has "${TDIR}/m3" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "merge: spaced other key kept"        has "${TDIR}/m3" "ANTHROPIC_API_KEY=sk-x"
check "merge: export extra kept"            has "${TDIR}/m3" "MY_EXP=1"
check "merge: escaped quotes one line kept" has "${TDIR}/m3" 'Q="a \"b\" c"'
for bad in 'MY_OWN="first\nsecond"\nANOTHER=ok\n' 'MY_OWN="first \\"\nsecond"\nANOTHER=ok\n' "MY_OWN='open\nANOTHER=ok\n" 'weird line\nANOTHER=ok\n' \
        "T=a\nMY_OWN='first \\\\'\nU=b\nTAIL=end'\n" 'T=a\nT=b\n' \
        'LOCAL_ROOT=/srv\nAPPROVED_DIRECTORY=${LOCAL_ROOT}\n'; do
    printf "$bad" >"$OLD"
    merge_env_file "$REND" "$OLD" TELEGRAM_BOT_TOKEN >/dev/null 2>&1
    rc=$?
    check "merge: unsafe file -> exit 3 ($(head -1 "$OLD"))" test "$rc" -eq 3
done

# --- install_richard re-run with empty answers keeps Richard alive ---------------
RH="${TDIR}/richard"
mkdir -p "${RH}/venv/bin"
printf '#!/bin/sh\n' >"${RH}/venv/bin/python"; printf '#!/bin/sh\n' >"${RH}/venv/bin/claude-telegram-bot"
chmod +x "${RH}/venv/bin/python" "${RH}/venv/bin/claude-telegram-bot"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_BOT_USERNAME=rbot\nALLOWED_USERS=555\nMY_OWN=x\n' "$TOKEN2" >"${RH}/.env"
sudo() { :; }
install() {
    local args=()
    while (($#)); do case $1 in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
}
RICHARD_BOT_TOKEN=""; RICHARD_BOT_USERNAME=""; TG_USER_ID=""
install_richard >/dev/null 2>&1
check "richard rerun: token kept"    has "${RH}/.env" "TELEGRAM_BOT_TOKEN=${TOKEN2}"
check "richard rerun: users kept"    has "${RH}/.env" "ALLOWED_USERS=555"
check "richard rerun: own line kept" has "${RH}/.env" "MY_OWN=x"
check "richard rerun: template keys" has "${RH}/.env" "USE_SDK=true"
check "richard rerun: backup made"   bash -c "ls '${RH}'/.env.bak-* >/dev/null 2>&1"
check "richard rerun: backup = old"  bash -c "grep -qx 'MY_OWN=x' '${RH}'/.env.bak-* && ! grep -q '^USE_SDK' '${RH}'/.env.bak-*"
N_BAK=$(find "$RH" -name '.env.bak-*' | wc -l)
install_richard >/dev/null 2>&1
check "richard rerun: unchanged -> no new backup" test "$(find "$RH" -name '.env.bak-*' | wc -l)" = "$N_BAK"
rm -f "${RH}/.env"
RICHARD_BOT_TOKEN="$TOKEN"; TG_USER_ID="777"
install_richard >/dev/null 2>&1
check "richard fresh: token written" has "${RH}/.env" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "richard fresh: users written" has "${RH}/.env" "ALLOWED_USERS=777"
printf 'TELEGRAM_BOT_TOKEN=%s\nMY_OWN="first \\"\nsecond"\nANOTHER=ok\n' "$TOKEN" >"${RH}/.env"
cp "${RH}/.env" "${TDIR}/richard-ml.orig"
RICHARD_BOT_TOKEN=""; TG_USER_ID=""
install_richard >/dev/null 2>&1
check "richard multi-line: file untouched" cmp -s "${RH}/.env" "${TDIR}/richard-ml.orig"
printf "TELEGRAM_BOT_TOKEN=%s\nMY_OWN='first \\\\'\nTELEGRAM_BOT_TOKEN=wrong\nTAIL=end'\n" "$TOKEN" >"${RH}/.env"
cp "${RH}/.env" "${TDIR}/richard-sq.orig"
install_richard >/dev/null 2>&1
check "richard single-quote backslash: file untouched" cmp -s "${RH}/.env" "${TDIR}/richard-sq.orig"
printf 'TELEGRAM_BOT_TOKEN=%s\nLOCAL_ROOT=/srv/richard\nAPPROVED_DIRECTORY=${LOCAL_ROOT}\n' "$TOKEN" >"${RH}/.env"
cp "${RH}/.env" "${TDIR}/richard-interp.orig"
install_richard >/dev/null 2>&1
check "richard interpolation: file untouched" cmp -s "${RH}/.env" "${TDIR}/richard-interp.orig"

# --- Richard launcher: the bot token never reaches the log --------------------
check "richard launcher: installed"      test -f "${RH}/launch/richard_launch.py"
check "richard launcher: unit runs it"   grep -q '^ExecStart=/opt/richard/venv/bin/python /opt/richard/launch/richard_launch.py$' "${TDIR}/systemd/claude-richard.service"
# A stand-in for claude-code-telegram's src.main: the real v1.6.0 setup_logging()
# is logging.basicConfig(level=INFO, stream=sys.stdout), then python-telegram-bot's
# httpx client logs every request URL (with the token) at INFO.
FAKEPKG="${TDIR}/fakepkg"
mkdir -p "${FAKEPKG}/src"
: >"${FAKEPKG}/src/__init__.py"
cat >"${FAKEPKG}/src/main.py" <<'PYEOF'
import logging, os, sys
def run():
    t = os.environ["LEAK_TOKEN"]
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)
    for name in ("httpx", "httpcore"):
        print(f"LEVEL {name}={logging.getLevelName(logging.getLogger(name).getEffectiveLevel())}")
    logging.getLogger("httpx").info("HTTP Request: POST %s", f"https://api.telegram.org/bot{t}/getUpdates")
    logging.getLogger("httpcore").info("QUIET-MARK %s", t)
    logging.getLogger("httpx").warning("WARN-PASSES")
    print("RUN-DONE")
    sys.exit(1)
PYEOF
LOGOUT="${TDIR}/launcher.out"
(cd "$TDIR" && LEAK_TOKEN="$TOKEN" PYTHONPATH="$FAKEPKG" python3 "${RH}/launch/richard_launch.py") >"$LOGOUT" 2>&1
LOGRC=$?
check "richard launcher: entry point ran"      grep -q RUN-DONE "$LOGOUT"
check "richard launcher: exits like run()"     test "$LOGRC" = 1
check "richard launcher: httpx at WARNING"     grep -qx "LEVEL httpx=WARNING" "$LOGOUT"
check "richard launcher: httpcore at WARNING"  grep -qx "LEVEL httpcore=WARNING" "$LOGOUT"
check "richard launcher: no bot URL in output" bash -c '! grep -q "api.telegram.org/bot" "$1"' _ "$LOGOUT"
check "richard launcher: no token in output"   bash -c '! grep -qF -- "$1" "$2"' _ "${TOKEN#*:}" "$LOGOUT"
check "richard launcher: warnings still pass"  grep -q WARN-PASSES "$LOGOUT"
unset -f sudo install

# --- final notes point at `claude auth login` ------------------------------------
final_instructions >"${TDIR}/final.txt" 2>&1
check "final: claude auth login"    grep -q "bash -lc 'claude auth login'" "${TDIR}/final.txt"
check "final: no bare claude login" bash -c "! grep -q \"'claude login'\" '${TDIR}/final.txt'"
check "header: claude auth login"   grep -q "claude auth login" "${REPO}/install.sh"

# --- apt: only missing packages, installed ones never upgraded -------------------
APT_LOG="${TDIR}/apt.log"
INSTALLED=" systemd sudo curl git ca-certificates python3 "
dpkg-query() {
    local pkg=${*: -1}
    if [[ "$INSTALLED" == *" ${pkg} "* ]]; then printf 'install ok installed'; else return 1; fi
}
# Dry run (-s): "bigpkg" would upgrade installed systemd, "brokenpkg" does
# not resolve, everything else is a plain new install.
apt_get() {
    if [[ " $* " == *" -s "* ]]; then
        [[ " $* " == *" brokenpkg "* ]] && return 100
        local a
        for a in "$@"; do
            case $a in
                bigpkg) printf 'Inst systemd [255.4-1ubuntu8.4] (255.4-1ubuntu8.17 Ubuntu:24.04 [amd64])\nInst bigpkg (1.0 Ubuntu:24.04 [amd64])\n' ;;
                -*|install) ;;
                *) printf 'Inst %s (1.0 Ubuntu:24.04 [amd64])\n' "$a" ;;
            esac
        done
        return 0
    fi
    printf '%s\n' "$*" >>"$APT_LOG"
}
: >"$APT_LOG"
apt_install_missing systemd sudo tmux unzip
check "apt: only missing installed"  grep -qx 'install -y -qq --no-upgrade tmux unzip' "$APT_LOG"
check "apt: installed pkg untouched" bash -c "! grep -qw systemd '$APT_LOG'"
: >"$APT_LOG"
apt_install_missing systemd sudo
check "apt: all present -> no install call" test ! -s "$APT_LOG"
: >"$APT_LOG"
OUT=$(apt_install_missing tmux bigpkg unzip brokenpkg 2>&1)
check "apt dep-upgrade: safe ones installed"   bash -c "grep -qx 'install -y -qq --no-upgrade tmux' '$APT_LOG' && grep -qx 'install -y -qq --no-upgrade unzip' '$APT_LOG'"
check "apt dep-upgrade: bigpkg skipped"        bash -c "! grep -qw bigpkg '$APT_LOG'"
check "apt dep-upgrade: warns with systemd"    grep -q 'bigpkg NOT installed.*systemd' <<<"$OUT"
check "apt unresolvable: skipped + warned"     grep -q 'brokenpkg NOT installed.*cannot resolve' <<<"$OUT"
: >"$APT_LOG"
apt_install_missing bigpkg >/dev/null 2>&1
check "apt dep-upgrade only: no install call"  test ! -s "$APT_LOG"
# pkgA and pkgB are each fine alone but together upgrade systemd: the joint
# install must never run; each one goes alone after its own dry run.
apt_get() {
    if [[ " $* " == *" -s "* ]]; then
        if [[ " $* " == *" pkgA "* && " $* " == *" pkgB "* ]]; then
            printf 'Inst systemd [1] (2 Ubuntu [amd64])\n'
        fi
        return 0
    fi
    printf '%s\n' "$*" >>"$APT_LOG"
}
: >"$APT_LOG"
apt_install_missing pkgA pkgB >/dev/null 2>&1
check "apt joint-only upgrade: no joint install" bash -c "! grep -q 'pkgA pkgB' '$APT_LOG'"
check "apt joint-only upgrade: one by one"       bash -c "grep -qx 'install -y -qq --no-upgrade pkgA' '$APT_LOG' && grep -qx 'install -y -qq --no-upgrade pkgB' '$APT_LOG'"
: >"$APT_LOG"
( step() { :; }; add-apt-repository() { :; }; update-alternatives() { :; }; install_apt_deps ) >/dev/null 2>&1
check "apt deps: update still runs"       grep -qx 'update -qq' "$APT_LOG"
check "apt deps: never installs systemd"  bash -c "! grep -E '^install' '$APT_LOG' | grep -qwE 'systemd|sudo|curl|git|ca-certificates'"
check "apt deps: installs a missing one"  bash -c "grep -E '^install' '$APT_LOG' | grep -qw tmux"
check "apt deps: every install is --no-upgrade" bash -c "! grep -E '^install' '$APT_LOG' | grep -vq -- '--no-upgrade'"
unset -f dpkg-query apt_get

# --- apt: pure-python upgrades allowed along the way, nothing else --------------
dpkg-query() { return 1; }    # nothing of the test packages is installed
apt_get() {
    if [[ " $* " == *" -s "* ]]; then
        local a
        for a in "$@"; do
            case $a in
                python3-venv) printf 'Inst python3-setuptools [68.1.2-2ubuntu1.1] (68.1.2-2ubuntu1.2 Ubuntu [all])\nInst python3-pkg-resources [68.1.2-2ubuntu1.1] (68.1.2-2ubuntu1.2 Ubuntu [all])\nInst python3-venv (3.12 Ubuntu [amd64])\n' ;;
                mixpkg) printf 'Inst python3-setuptools [1] (2 Ubuntu [all])\nInst libc6 [1] (2 Ubuntu [amd64])\n' ;;
                rmpkg)  printf 'Remv python3-wheel [1]\nInst rmpkg (1 Ubuntu [all])\n' ;;
                failpkg) printf 'Inst failpkg (1 Ubuntu [all])\n' ;;
            esac
        done
        return 0
    fi
    [[ " $* " == *" failpkg "* ]] && return 100
    printf '%s\n' "$*" >>"$APT_LOG"
}
: >"$APT_LOG"; APT_SKIPPED=()
OUT=$(apt_install_missing python3-venv 2>&1; printf '\nskipped=[%s]' "${APT_SKIPPED[*]}")
check "allowlist: venv installed"              grep -qx 'install -y -qq --no-upgrade python3-venv' "$APT_LOG"
check "allowlist: one line about upgrades"     grep -q 'попутно обновлены: python3-pkg-resources python3-setuptools$' <<<"$OUT"
check "allowlist: nothing skipped"             grep -q 'skipped=\[\]' <<<"$OUT"
: >"$APT_LOG"
OUT=$(apt_install_missing mixpkg 2>&1; printf '\nskipped=[%s]' "${APT_SKIPPED[*]}")
check "allowlist: libc6 still blocks"          test ! -s "$APT_LOG"
check "allowlist: warn names only libc6"       grep -q 'mixpkg NOT installed.*: libc6\.' <<<"$OUT"
check "allowlist: skipped recorded"            grep -q 'skipped=\[mixpkg\]' <<<"$OUT"
: >"$APT_LOG"
OUT=$(apt_install_missing rmpkg 2>&1)
check "allowlist: removal never excused"       test ! -s "$APT_LOG"
check "allowlist: removal named"               grep -q 'remove:python3-wheel' <<<"$OUT"
R5=$( (apt_install_missing failpkg >/dev/null 2>&1; printf 'rc=%s' "$?") )
check "apt: real install failure is fatal"     test "$R5" != "rc=0"
unset -f apt_get dpkg-query

# --- required packages: stop before any agent, re-run passes --------------------
dpkg-query() {
    local pkg=${*: -1}
    if [[ "$INSTALLED" == *" ${pkg} "* ]]; then printf 'install ok installed'; else return 1; fi
}
INSTALLED=" ca-certificates curl git jq rsync sudo tmux unzip cron python3 "
OUT=$( (require_step_packages) 2>&1; printf 'rc=%s' "$?" )
check "gate: missing venv -> stop"             grep -q 'rc=1$' <<<"$OUT"
check "gate: says nothing installed yet"       grep -q 'Stopped before installing the agents' <<<"$OUT"
check "gate: ready command"                    grep -q 'sudo apt-get install python3-venv$' <<<"$OUT"
INSTALLED="${INSTALLED}python3-venv "
OUT=$( (require_step_packages) 2>&1; printf 'rc=%s' "$?" )
check "gate: after apt-get -> passes"          test "$OUT" = "rc=0"

# main: with the gate failing no agent step runs; re-run goes all the way
STEPS="${TDIR}/steps"
main_steps=(banner preflight install_apt_deps install_node ensure_agent_user check_node_for_agent
    install_claude_cli install_bun collect_inputs install_jarvis install_richard setup_global_claude
    install_skills install_superpowers install_sudoers install_memory_cron enable_services final_instructions)
run_main_stubbed() {
    (
        for f in "${main_steps[@]}"; do eval "${f}() { echo ${f} >>'${STEPS}'; }"; done
        main
    ) >/dev/null 2>&1
}
INSTALLED=" ca-certificates curl git jq rsync sudo tmux unzip cron python3 "; : >"$STEPS"
run_main_stubbed
check "main: gate stops the run"               test $? -ne 0
check "main: no Jarvis after stop"             bash -c "! grep -q install_jarvis '$STEPS'"
check "main: no Richard after stop"            bash -c "! grep -q install_richard '$STEPS'"
check "main: no user/claude/bun after stop"    bash -c "! grep -qE 'ensure_agent_user|install_claude_cli|install_bun' '$STEPS'"
INSTALLED="${INSTALLED}python3-venv "; : >"$STEPS"
run_main_stubbed
check "main: re-run passes"                    test $? -eq 0
check "main: re-run installs Jarvis+Richard"   bash -c "grep -q install_jarvis '$STEPS' && grep -q install_richard '$STEPS'"
check "main: gate right after apt deps"        test "$(sed -n 3p "$STEPS")" = "install_apt_deps" -a "$(sed -n 4p "$STEPS")" = "install_node"
unset -f dpkg-query

# --- node: >= 22 left alone, older replaced, not-runnable-as-edgelab warns --------
NODE_VER="v24.21.0"; CURL_LOG="${TDIR}/curl.log"
node() { printf '%s\n' "$NODE_VER"; }
curl() { printf '%s\n' "$*" >>"$CURL_LOG"; }
apt_get() { printf '%s\n' "$*" >>"$CURL_LOG"; }
step() { :; }
: >"$CURL_LOG"; ( install_node ) >/dev/null 2>&1
check "node v24: no nodesource"   test ! -s "$CURL_LOG"
NODE_VER="v22.1.0"; : >"$CURL_LOG"; ( install_node ) >/dev/null 2>&1
check "node v22: no nodesource"   test ! -s "$CURL_LOG"
NODE_VER="v20.11.1"; : >"$CURL_LOG"; ( install_node ) >/dev/null 2>&1
check "node v20: nodesource used" grep -q 'nodesource' "$CURL_LOG"
NODE_VER="v100.0.0"; : >"$CURL_LOG"; ( install_node ) >/dev/null 2>&1
check "node v100: numeric compare, left" test ! -s "$CURL_LOG"
unset -f curl apt_get

as_agent() { return 1; }
OUT=$( (check_node_for_agent; printf 'rc=%s' "$?") 2>&1 )
check "node as edgelab fails: warns"     grep -q 'does not run as' <<<"$OUT"
check "node as edgelab fails: rc 0"      grep -q 'rc=0$' <<<"$OUT"
as_agent() { "$@"; }
OUT=$( (check_node_for_agent; printf 'rc=%s' "$?") 2>&1 )
check "node as edgelab ok: silent"       test "$OUT" = "rc=0"
unset -f node

# --- sourcing does not run main -------------------------------------------------
check "guard: sourcing did not install anything" test ! -e "${FAKE_HOME}/.local/bin/claude"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
