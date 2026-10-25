#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Wave of small watchdogs: outbox-put routing, resource/disk/manifest/autosync dry runs,
# usage collector + digest, command-log and review-reminder hooks, and the installer's
# service-watch cron + hook wiring. No root needed (the root-only autosync run is
# exercised in the container acceptance).
# Run: bash tests/test_service_watch.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
export PYTHONDONTWRITEBYTECODE=1

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
jqtrue() { jq -e "$2" "$1" >/dev/null 2>&1; }

H="${TDIR}/home"
LIB="${REPO}/lib"
mkdir -p "${H}/.claude-lab/jarvis/.claude/core" "${H}/.claude/projects"
mkconf() {
    cat >"${TDIR}/guard.conf" <<EOF
AGENT_USER="$(id -un)"
AGENT_HOME="${H}"
LIB_DIR="${LIB}"
CONFIG_ROOT="${TDIR}/etc"
CHANNEL_AGENTS="jarvis"
OWNER_NAME="Анна"
OWNER_TG_ID="555"
OWNER_TIMEZONE="Asia/Kolkata"
ALERT_MODE="$1"
EOF
}
mkconf outbox
export NEUROOTDEL_GUARD_CONF="${TDIR}/guard.conf"
export NEUROOTDEL_GUARD_STATE="${TDIR}/guard-state"
export NEUROOTDEL_GUARD_LOG="${TDIR}/guard.log"

# --- outbox-put ------------------------------------------------------------------------------
ID=$(python3 "${LIB}/outbox-put.py" k1 "текст один")
check "outbox: item published"               test -f "${TDIR}/guard-state/outbox/${ID}.json"
check "outbox: --ack id format"              grep -qE '^[0-9]+-[0-9a-f]{8}$' <<<"$ID"
check "outbox: item fields"                  jqtrue "${TDIR}/guard-state/outbox/${ID}.json" '.key == "k1" and .text == "текст один" and (.at_msk | test(" IST$"))'
check "outbox: log line"                     grep -q 'ALERT k1' "${TDIR}/guard.log"
mkconf log
python3 "${LIB}/outbox-put.py" k2 "только журнал" >/dev/null
check "outbox: mode log -> no item"          test "$(find "${TDIR}/guard-state/outbox" -name '*.json' | wc -l)" -eq 1
check "outbox: mode log -> logged"           grep -q 'ALERT k2' "${TDIR}/guard.log"
mkconf outbox
if python3 "${LIB}/outbox-put.py" k3 >/dev/null 2>&1; then u_rc=0; else u_rc=$?; fi
check "outbox: usage error rc 64"            test "$u_rc" -eq 64

# --- resource-watchdog dry run ---------------------------------------------------------------
OUT=$(NEUROOTDEL_RESOURCE_STATE="${TDIR}/res" bash "${LIB}/resource-watchdog.sh" --dry-run 2>&1)
check "resource: measures ram/disk/load"     bash -c 'grep -q "^ram:" <<<"$0" && grep -q "^disk:" <<<"$0" && grep -q "^load1:" <<<"$0"' "$OUT"
check "resource: dry run writes nothing"     test ! -e "${TDIR}/res"
touch "${TDIR}/res-stop"; mkdir -p "${TDIR}/res2"; touch "${TDIR}/res2/STOP"
OUT=$(NEUROOTDEL_RESOURCE_STATE="${TDIR}/res2" bash "${LIB}/resource-watchdog.sh" 2>&1)
check "resource: STOP -> silent"             test -z "$OUT"

# --- disk-clean-old --------------------------------------------------------------------------
IN="${H}/.claude-lab/shared/state/jarvis/telegram/inbox"
mkdir -p "$IN"
touch -d '20 days ago' "${IN}/old.jpg"; touch "${IN}/new.jpg"
OUT=$(HOME="$H" bash "${LIB}/disk-clean-old.sh" --now)
check "disk: old file removed"               test ! -e "${IN}/old.jpg"
check "disk: fresh file kept"                test -e "${IN}/new.jpg"
check "disk: dir kept"                       test -d "$IN"
check "disk: log written"                    grep -q 'total_freed=' "${H}/.claude-lab/shared/state/disk-clean/disk-clean.log"
touch -d '20 days ago' "${IN}/old2.jpg"
rm -f "${H}"/.claude-lab/shared/state/disk-clean/done-*
HOME="$H" bash "${LIB}/disk-clean-old.sh" >/dev/null
hm=$(TZ=Asia/Kolkata date +%H%M)
if (( 10#$hm >= 430 && 10#$hm < 500 )); then
    check "disk: in window -> runs"          test ! -e "${IN}/old2.jpg"
else
    check "disk: outside owner window -> no run" test -e "${IN}/old2.jpg"
fi

# --- cron-manifest dry run on an empty cron dir ------------------------------------------------
mkdir -p "${TDIR}/crond"
OUT=$(NEUROOTDEL_CRON_D="${TDIR}/crond" NEUROOTDEL_MANIFEST_STATE="${TDIR}/man" bash "${LIB}/cron-manifest-watchdog.sh" --dry-run 2>&1)
check "manifest: missing slots listed"       grep -q 'нет файла' <<<"$OUT"
check "manifest: only the configured cron dir" bash -c '! grep -q "/etc/cron.d/" <<<"$0"' "$OUT"
U=$(id -un)
for n in agents-reset agents-guard memory-backup service-watch; do : >"${TDIR}/crond/${U}-${n}"; done
printf 'x agents-reset.sh --auto\n' >"${TDIR}/crond/${U}-agents-reset"
OUT=$(NEUROOTDEL_CRON_D="${TDIR}/crond" NEUROOTDEL_MANIFEST_STATE="${TDIR}/man" bash "${LIB}/cron-manifest-watchdog.sh" --dry-run 2>&1)
check "manifest: present slot not reported"  bash -c '! grep -q "сброс сессий" <<<"$0"' "$OUT"
check "manifest: emptied slot reported"      grep -q 'слот пропал' <<<"$OUT"

# --- agents-git-autosync dry run -------------------------------------------------------------
WSJ="${H}/.claude-lab/jarvis/.claude"
echo '# rules' >"${WSJ}/CLAUDE.md"
echo 'api_key = "abcdefghijklmnop"' >"${WSJ}/core/leak.md"
echo 'plain memory' >"${WSJ}/core/MEMORY.md"
mkdir -p "${WSJ}/secrets"; echo 'x' >"${WSJ}/secrets/t"
OUT=$(NEUROOTDEL_AUTOSYNC_STATE="${TDIR}/as" bash "${LIB}/agents-git-autosync.sh" --dry-run 2>&1)
check "autosync: would init the repo"        grep -q 'would init repo' <<<"$OUT"
check "autosync: key pattern excluded"       grep -q 'CREDENTIAL PATTERN, would exclude: core/leak.md' <<<"$OUT"
check "autosync: secrets dir not tracked"    bash -c '! grep -q "secrets/t" <<<"$0"' "$OUT"
check "autosync: dry run made no repo"       test ! -e "${WSJ}/.git"
eval "$(grep -E "^(KEEP_TOP|DENY)=" "${LIB}/agents-git-autosync.sh")"
hard_ok() { [[ "$1" =~ $KEEP_TOP ]] && ! [[ "$1" =~ $DENY ]]; }
check "autosync: core note kept"             hard_ok core/MEMORY.md
check "autosync: nested .env dropped"        bash -c '! { [[ "$0" =~ $1 ]] && ! [[ "$0" =~ $2 ]]; }' core/.env "$KEEP_TOP" "$DENY"
check "autosync: secrets/ dropped"           bash -c '! { [[ "$0" =~ $1 ]] && ! [[ "$0" =~ $2 ]]; }' skills/x/secrets/t "$KEEP_TOP" "$DENY"
check "autosync: .mcp.json dropped"          bash -c '! { [[ "$0" =~ $1 ]] && ! [[ "$0" =~ $2 ]]; }' core/.mcp.json "$KEEP_TOP" "$DENY"
check "autosync: top-level stray dropped"    bash -c '! { [[ "$0" =~ $1 ]] && ! [[ "$0" =~ $2 ]]; }' dashi-plugin-claude-code/x "$KEEP_TOP" "$DENY"
check "autosync: secret never printed"       bash -c '! grep -q abcdefghijklmnop <<<"$0"' "$OUT"

# --- usage collector + digest ----------------------------------------------------------------
rec() { printf '{"type":"assistant","timestamp":"%s","sessionId":"s","message":{"id":"%s","model":"claude-opus-4-7","usage":{"input_tokens":10,"output_tokens":%s}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }
PJ="${H}/.claude/projects/$(printf '%s' "$WSJ" | sed 's/[^A-Za-z0-9]/-/g')"
PP="${PJ}-dashi-plugin-claude-code-plugin"
PR="${H}/.claude/projects/$(printf '%s' "$H" | sed 's/[^A-Za-z0-9]/-/g')"
PX="${PR}--claude-lab-stranger--claude"
mkdir -p "$PP/s/subagents" "$PR" "$PX"
rec m1 5 >"$PP/a.jsonl"; rec m1 7 >>"$PP/a.jsonl"; rec m2 1 >"$PP/s/subagents/agent-x.jsonl"
rec m3 2 >"$PR/r.jsonl"; rec m4 3 >"$PX/x.jsonl"
export NEUROOTDEL_USAGE_DIR="${TDIR}/usage"
python3 "${LIB}/claude-usage-collector.py" >/dev/null 2>&1
q() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "${TDIR}/usage/usage.db" "$1"; }
check "usage: jarvis plugin + subagent rows" test "$(q "select count(*) from calls where agent='jarvis'")" -eq 2
check "usage: final output kept (7)"         test "$(q "select output_tokens from calls where msg_id='m1'")" -eq 7
check "usage: subagent marked"               test "$(q "select is_subagent from calls where msg_id='m2'")" -eq 1
check "usage: richard = home dir exactly"    test "$(q "select agent from calls where msg_id='m3'")" = richard
check "usage: unknown agent dir skipped"     test "$(q "select count(*) from calls where msg_id='m4'")" -eq 0
python3 "${LIB}/claude-usage-collector.py" >/dev/null 2>&1
check "usage: rerun adds nothing"            test "$(q "select count(*) from calls")" -eq 3
OUT=$(python3 "${LIB}/claude-usage-digest.py" --no-send 2>/dev/null)
check "usage: digest prints a report"        grep -q 'jarvis' <<<"$OUT"
check "usage: digest has no sender"          bash -c '! grep -qE "api.telegram|sendMessage|TOKEN_FILE|CHAT_ID" "$0"' "${LIB}/claude-usage-digest.py"

# --- hooks: command log + review reminder ----------------------------------------------------
export HOME="$H"
echo "{\"tool_input\":{\"command\":\"ls -la\"},\"cwd\":\"${WSJ}/dashi-plugin-claude-code/plugin\"}" | bash "${LIB}/hooks/log-commands.sh"
echo "{\"tool_input\":{\"command\":\"df -h\"},\"cwd\":\"${H}\"}" | bash "${LIB}/hooks/log-commands.sh"
CL="${H}/.claude-lab/shared/state/command-log/commands.log"
check "cmdlog: jarvis line"                  grep -qE '  jarvis  ls -la$' "$CL"
check "cmdlog: home session line"            grep -qE '  home  df -h$' "$CL"
SECRET_CMD='curl -H "Authorization: Bearer abcdefghijklmnopqrstuv" -u bob:hunter22 https://x:pw123456@h/ --token=tok12345678 && API_KEY=sk-ant-abcdefghijklmnopqrstu TOKEN="quoted secret value"'
jq -cn --arg c "$SECRET_CMD"$'\ncat <<EOF\nheredoc-secret-body\nEOF' --arg w "$WSJ" '{tool_input:{command:$c},cwd:$w}' | bash "${LIB}/hooks/log-commands.sh"
jq -cn --arg c 'tool --password "first second" --token '"'"'a b c'"'"' --secret=s3cr3tvalue' --arg w "$WSJ" '{tool_input:{command:$c},cwd:$w}' | bash "${LIB}/hooks/log-commands.sh"
jq -cn --arg c 'printf \" ; tool --password "esc aped" x' --arg w "$WSJ" '{tool_input:{command:$c},cwd:$w}' | bash "${LIB}/hooks/log-commands.sh"
jq -cn --arg c $'tool --password  spaced123 --token\ttabbed123 --auth= eqspace123' --arg w "$WSJ" '{tool_input:{command:$c},cwd:$w}' | bash "${LIB}/hooks/log-commands.sh"
jq -cn --arg c 'echo "unpaired quote secretword' --arg w "$WSJ" '{tool_input:{command:$c},cwd:$w}' | bash "${LIB}/hooks/log-commands.sh"
check "cmdlog: secrets masked"               bash -c '! grep -qE "abcdefghijklmnop|hunter22|pw123456|tok12345678|quoted secret|heredoc-secret|first|second|a b c|s3cr3t|secretword|esc|aped|spaced123|tabbed123|eqspace123" "$0"' "$CL"
check "cmdlog: masked line kept"             grep -qE '  jarvis  curl -H ‹…› \[\+3 lines not logged\]$' "$CL"
check "cmdlog: log is 0600"                  test "$(stat -c %a "$CL")" = 600
check "cmdlog: never blocks (rc 0 on junk)"  bash -c 'echo nope | bash "$0"' "${LIB}/hooks/log-commands.sh"
out_all=""
for i in $(seq 1 11); do out_all+=$(echo '{"session_id":"abc-1"}' | bash "${LIB}/hooks/review-reminder.sh"); out_all+=$'\n'; done
check "review: exactly one reminder"         test "$(grep -c 'review-reminder' <<<"$out_all")" -eq 1
check "review: valid hook JSON"              bash -c 'grep review-reminder <<<"$0" | jq -e ".hookSpecificOutput.hookEventName == \"PostToolUse\"" >/dev/null' "$out_all"
OUT=$(echo '{"session_id":"../../etc"}' | bash "${LIB}/hooks/review-reminder.sh")
check "review: bad session id ignored"       test -z "$OUT" -a ! -e "${H}/.claude-lab/shared/etc"

# --- installer: service-watch cron + hooks ---------------------------------------------------
export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e
as_agent() { "$@"; }
step() { :; }
ok() { :; }
_install_cron_file() { printf '%s\n' "$2" >"${TDIR}/cron-$1"; }
AGENT_USER=neurootdel
AGENT_HOME="$H"
GUARD_LIB_DIR=/usr/local/lib/neurootdel
install_service_watch_cron "${H}/.claude-lab/shared/state"
CF="${TDIR}/cron-neurootdel-service-watch"
check "cron: service-watch file"             test -s "$CF"
for s in resource-watchdog.sh disk-clean-old.sh cron-manifest-watchdog.sh agents-git-autosync.sh claude-usage-collector.py; do
    check "cron: ${s} scheduled"             bash -c 'grep -v "^#" "$0" | grep -q "$1"' "$CF" "$s"
done
check "cron: no 429 watcher, no digest send" bash -c '! grep -qE "429|claude-usage-digest.py[^)]*$" <(grep -v "^#" "$0")' "$CF"
check "cron: no CRON_TZ"                     bash -c '! grep -q CRON_TZ "$0"' "$CF"
check "cron: state dirs made"                test -d "${H}/.claude-lab/shared/state/disk-clean" -a -d "${H}/.claude-lab/shared/state/claude-usage"
check "memory cron: no ov-session-sync"      bash -c '! grep -q "ov-session-sync" <(sed -n "/^install_memory_cron()/,/^}/p" "$0")' "${REPO}/install.sh"
write_as_user() { install -m "${3:-0644}" "$1" "$2"; }
JARVIS_ENV_DIR="${TDIR}/etc/jarvis"
mkdir -p "$JARVIS_ENV_DIR" "${WSJ}/dashi-plugin-claude-code/plugin"
echo 'TELEGRAM_WEBHOOK_PORT=8095' >"${JARVIS_ENV_DIR}/channel.env"
setup_agent_hooks >/dev/null 2>&1
US="${H}/.claude/settings.json"
check "hooks: command log in user settings"  jqtrue "$US" '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | any(test("log-commands.sh"))'
check "hooks: review reminder PostToolUse"   jqtrue "$US" '[.hooks.PostToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[].command] | any(test("review-reminder.sh"))'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
