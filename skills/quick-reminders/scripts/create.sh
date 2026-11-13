#!/usr/bin/env bash
set -euo pipefail
# Usage: create.sh [--wake] TIMESPEC MESSAGE
# TIMESPEC: anything `date -d` understands, e.g. "in 10 minutes", "tomorrow 9am", "2026-05-01 14:30".
# --wake: MESSAGE goes to the agent itself (its channel webhook, scripts/wake.sh), not to the owner's Telegram:
#         the agent wakes up and does what it promised ("проверю через час", "взял ли исполнитель").

WAKE=0
if [[ "${1:-}" == "--wake" ]]; then
    WAKE=1
    shift
fi
if [[ $# -lt 2 ]]; then
    echo "usage: $0 [--wake] TIMESPEC MESSAGE" >&2
    exit 2
fi

TIMESPEC="$1"
shift
MESSAGE="$*"

# GNU date rejects "in 10 minutes" and "10m"; normalise the forms SKILL.md advertises.
TIMESPEC_NORM=$(printf '%s' "$TIMESPEC" | sed -E 's/^in +/+/; s/^\+?([0-9]+) *m$/+\1 minutes/; s/^\+?([0-9]+) *h$/+\1 hours/; s/^\+?([0-9]+) *d$/+\1 days/')
if ! TARGET_EPOCH=$(date -d "$TIMESPEC_NORM" +%s 2>/dev/null); then
    echo "error: cannot parse timespec '${TIMESPEC}'" >&2
    exit 1
fi

NOW=$(date +%s)
if [[ "$TARGET_EPOCH" -le "$NOW" ]]; then
    echo "error: timespec is in the past" >&2
    exit 1
fi

MIN=$(date -d "@${TARGET_EPOCH}" +%M)
HOUR=$(date -d "@${TARGET_EPOCH}" +%H)
DAY=$(date -d "@${TARGET_EPOCH}" +%d)
MON=$(date -d "@${TARGET_EPOCH}" +%m)

# One-shot: run at specific minute/hour/day/month, then remove its own cron line.
NONCE=$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')
# shellcheck source=crontab-edit.sh
source "$(dirname "${BASH_SOURCE[0]}")/crontab-edit.sh"

if [[ "$WAKE" == 1 ]]; then
    # The agent whose skill this is: ~/.claude-lab/<agent>/.claude/skills/quick-reminders/scripts.
    SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    AGENT=$(sed -n 's#.*/\.claude-lab/\([a-z0-9-]*\)/\.claude/skills/quick-reminders/scripts$#\1#p' <<<"$SCRIPTS")
    AGENT="${AGENT:-jarvis}"
    ENV_FILE="${NEUROOTDEL_CHANNEL_ENV:-/etc/vladimir-plugin/${AGENT}/channel.env}"
    [[ -e "$ENV_FILE" ]] || ENV_FILE="/etc/dashi-plugin/${AGENT}/channel.env"
    [[ -r "$ENV_FILE" ]] || { echo "error: ${ENV_FILE} not readable: no webhook to wake ${AGENT}" >&2; exit 1; }
    grep -qE '^TELEGRAM_WEBHOOK_PORT=[0-9]+' "$ENV_FILE" \
        || { echo "error: no TELEGRAM_WEBHOOK_PORT in ${ENV_FILE}" >&2; exit 1; }
    CHAT="${TG_ID:-${TELEGRAM_CHAT_ID:-}}"
    [[ -n "$CHAT" ]] || CHAT=$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$ENV_FILE" | head -n1 | cut -d, -f1 | tr -d '[:space:]"')
    [[ "$CHAT" =~ ^-?[0-9]+$ ]] || { echo "error: no owner chat id (TELEGRAM_ALLOWED_USER_IDS in ${ENV_FILE})" >&2; exit 1; }
    WAKE_DIR="${QR_WAKE_DIR:-$HOME/.claude-lab/shared/state/reminders}"
    [[ "$SCRIPTS" != *"'"* && "$WAKE_DIR" != *"'"* ]] || { echo "error: a path contains a quote" >&2; exit 1; }
    mkdir -p "$WAKE_DIR"
    # The text goes to jq through the environment (not argv) into a private file; nothing of it is printed.
    ( umask 077; QR_MSG="[будильник] ${MESSAGE}" jq -n --arg c "$CHAT" --arg e "$ENV_FILE" \
        '{message: env.QR_MSG, chat: $c, env: $e}' > "${WAKE_DIR}/${NONCE}.json" )
    # wake.sh removes this line itself after delivery or its last retry, under the same lock.
    CRON_LINE="${MIN} ${HOUR} ${DAY} ${MON} * QR_WAKE_DIR='${WAKE_DIR}' /bin/bash '${SCRIPTS}/wake.sh' ${NONCE} >/dev/null 2>&1 # qr:ID=${NONCE} wake"
    (
        flock -w 30 9 || { echo "error: crontab lock busy, try again" >&2; exit 1; }
        qr_crontab_add "$CRON_LINE" || { echo "error: crontab not read or not written, nothing scheduled" >&2; exit 1; }
    ) 9>"${WAKE_DIR}/.crontab.lock"
    echo "scheduled: id=${NONCE} at=$(date -d "@${TARGET_EPOCH}" '+%Y-%m-%d %H:%M') wake=${AGENT}"
    exit 0
fi
# Token source and owner id: see tg-target.sh (channel.env from the installer,
# then the old gateway path). The token is read by the cron line at run time.
# shellcheck source=tg-target.sh
source "$(dirname "${BASH_SOURCE[0]}")/tg-target.sh"
tg_resolve_target || exit 1
TOKEN_CMD=$(tg_token_cmd) || exit 1

if [[ -z "$TG_ID" ]]; then
    echo "error: no Telegram ID (set TELEGRAM_CHAT_ID or TELEGRAM_ALLOWED_USER_IDS in channel.env)" >&2
    exit 1
fi

# Every crontab rewrite (this add, the line's own removal through delete.sh when it fires, wake.sh) runs
# under one lock, so a parallel add or removal cannot drop another line.
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_DIR="${QR_WAKE_DIR:-$HOME/.claude-lab/shared/state/reminders}"
[[ "$SCRIPTS" != *"'"* && "$LOCK_DIR" != *"'"* ]] || { echo "error: a path contains a quote" >&2; exit 1; }
mkdir -p "$LOCK_DIR"
LOCK="${LOCK_DIR}/.crontab.lock"

# Escape message for cron line (no newlines, no unescaped quotes)
SAFE_MSG=$(printf '%s' "$MESSAGE" | tr '\n' ' ' | sed 's/"/\\"/g')

CRON_LINE="${MIN} ${HOUR} ${DAY} ${MON} * TOKEN=\$(${TOKEN_CMD}) && curl -fsSL --max-time 30 -d \"chat_id=${TG_ID}\" -d \"text=${SAFE_MSG}\" \"https://api.telegram.org/bot\${TOKEN}/sendMessage\" >/dev/null 2>&1; QR_WAKE_DIR='${LOCK_DIR}' /bin/bash '${SCRIPTS}/delete.sh' ${NONCE} >/dev/null 2>&1 # qr:ID=${NONCE}"

(
    flock -w 30 9 || { echo "error: crontab lock busy, try again" >&2; exit 1; }
    qr_crontab_add "$CRON_LINE" || { echo "error: crontab not read or not written, nothing scheduled" >&2; exit 1; }
) 9>"$LOCK"

echo "scheduled: id=${NONCE} at=$(date -d "@${TARGET_EPOCH}" '+%Y-%m-%d %H:%M')"
echo "message: ${MESSAGE}"
