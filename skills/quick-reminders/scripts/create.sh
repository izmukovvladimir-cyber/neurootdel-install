#!/usr/bin/env bash
set -euo pipefail
# Usage: create.sh TIMESPEC MESSAGE
# TIMESPEC: anything `date -d` understands, e.g. "in 10 minutes", "tomorrow 9am", "2026-05-01 14:30".

if [[ $# -lt 2 ]]; then
    echo "usage: $0 TIMESPEC MESSAGE" >&2
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

# Escape message for cron line (no newlines, no unescaped quotes)
SAFE_MSG=$(printf '%s' "$MESSAGE" | tr '\n' ' ' | sed 's/"/\\"/g')

CRON_LINE="${MIN} ${HOUR} ${DAY} ${MON} * TOKEN=\$(${TOKEN_CMD}) && curl -fsSL --max-time 30 -d \"chat_id=${TG_ID}\" -d \"text=${SAFE_MSG}\" \"https://api.telegram.org/bot\${TOKEN}/sendMessage\" >/dev/null 2>&1; (crontab -l 2>/dev/null | grep -vF 'qr:ID=${NONCE}') | crontab - # qr:ID=${NONCE}"

( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab -

echo "scheduled: id=${NONCE} at=$(date -d "@${TARGET_EPOCH}" '+%Y-%m-%d %H:%M')"
echo "message: ${MESSAGE}"
