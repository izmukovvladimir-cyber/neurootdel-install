#!/usr/bin/env bash
# quick-reminders --wake: the reminder wakes the agent itself through its channel webhook (wake.sh),
# the token never lands in crontab or in curl's argv, the job file goes once delivered.
# Synthetic data, crontab and curl are stubs. Run: bash tests/test_quick_reminders_wake.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT
PASS=0; FAIL=0
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   $n"; else FAIL=$((FAIL+1)); echo "FAIL $n"; fi; }

export HOME="${TDIR}/home"
SK="${HOME}/.claude-lab/coder/.claude/skills/quick-reminders/scripts"
mkdir -p "$SK" "${TDIR}/bin"
cp "${REPO}/skills/quick-reminders/scripts/"*.sh "$SK/"
ENV="${TDIR}/channel.env"
printf 'TELEGRAM_BOT_TOKEN=111:AAHsecret\nTELEGRAM_WEBHOOK_PORT=8091\nTELEGRAM_WEBHOOK_TOKEN=whsecret\nTELEGRAM_ALLOWED_USER_IDS=555,777\n' >"$ENV"
export NEUROOTDEL_CHANNEL_ENV="$ENV"
cat >"${TDIR}/bin/crontab" <<'F'
#!/usr/bin/env bash
f="${HOME}/crontab.txt"
if [[ "${1:-}" == "-l" ]]; then [[ -f "$f" ]] && cat "$f"; exit 0; fi
if [[ "${1:-}" == "-" ]]; then cat >"$f"; exit 0; fi
exit 1
F
cat >"${TDIR}/bin/curl" <<'F'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${HOME}/curl.argv"
cat >"${HOME}/curl.stdin"
cat "${HOME}/curl.code" 2>/dev/null || printf 200
F
chmod +x "${TDIR}/bin/crontab" "${TDIR}/bin/curl"
export PATH="${TDIR}/bin:${PATH}"

OUT=$(bash "${SK}/create.sh" --wake "in 30 minutes" 'Проверь, взял ли "Coder" задачу' 2>&1); RC=$?
check "create --wake: exit 0"                       test "$RC" -eq 0
check "create --wake: agent from the skill path"    grep -q 'wake=coder' <<<"$OUT"
ID=$(sed -n 's/^scheduled: id=\([0-9a-f]*\) .*/\1/p' <<<"$OUT")
JOB="${HOME}/.claude-lab/shared/state/reminders/${ID}.json"
check "job file written"                            test -f "$JOB"
check "job: message with the wake mark"             bash -c 'jq -e ".message == \"[будильник] Проверь, взял ли \\\"Coder\\\" задачу\"" "$0"' "$JOB"
check "job: owner chat = first allowed id"          bash -c 'jq -e ".chat == \"555\"" "$0"' "$JOB"
check "cron: one wake line, tagged"                 bash -c 'test "$(grep -c "qr:ID=$0 wake$" "$1")" -eq 1' "$ID" "${HOME}/crontab.txt"
check "cron: no token, no message text in it"       bash -c '! grep -qE "AAHsecret|whsecret|Проверь" "$0"' "${HOME}/crontab.txt"
check "list: shows the wake"                        bash -c 'bash "$0/list.sh" | grep -q "будильник агента"' "$SK"

bash "${SK}/wake.sh" "$ID"; RC=$?
check "wake: delivered, exit 0"                     test "$RC" -eq 0
check "wake: webhook URL of the agent's port"       grep -qx 'http://127.0.0.1:8091/hooks/agent' "${HOME}/curl.argv"
check "wake: token only through stdin"              bash -c 'grep -q "Bearer whsecret" "$0" && ! grep -q whsecret "$1"' "${HOME}/curl.stdin" "${HOME}/curl.argv"
check "wake: body = message + chatId"               bash -c 'grep -qF "\"chatId\":\"555\"" "$0"' "${HOME}/curl.argv"
check "wake: job file removed after delivery"       test ! -e "$JOB"

OUT=$(bash "${SK}/create.sh" --wake "in 1 hour" "второй" 2>&1)
ID2=$(sed -n 's/^scheduled: id=\([0-9a-f]*\) .*/\1/p' <<<"$OUT")
printf 502 >"${HOME}/curl.code"
bash "${SK}/wake.sh" "$ID2"; RC=$?
check "wake: webhook down -> exit 1, job kept"      bash -c 'test "$0" -eq 1 && test -f "$1"' "$RC" "${HOME}/.claude-lab/shared/state/reminders/${ID2}.json"
check "wake: reason in wake.log"                    grep -q 'webhook answered 502' "${HOME}/.claude-lab/shared/state/reminders/wake.log"
bash "${SK}/wake.sh" "../etc"; RC=$?
check "wake: a bad id refused"                      test "$RC" -eq 2

printf 'TELEGRAM_BOT_TOKEN=111:AAHsecret\nTELEGRAM_ALLOWED_USER_IDS=555\n' >"$ENV"
bash "${SK}/create.sh" --wake "in 5 minutes" "x" >/dev/null 2>&1; RC=$?
check "create --wake: no webhook port -> refused"   test "$RC" -ne 0
OUT=$(bash "${SK}/create.sh" "in 5 minutes" "обычное напоминание" 2>&1); RC=$?
check "plain reminder still works"                  bash -c 'test "$0" -eq 0 && grep -q "sendMessage" "$1"' "$RC" "${HOME}/crontab.txt"

echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
