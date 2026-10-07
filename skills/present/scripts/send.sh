#!/usr/bin/env bash
set -euo pipefail
# Usage: send.sh <path/to/file.html>
# Sends the HTML file to the operator via Telegram sendDocument.
# chat_id resolves from PRESENT_CHAT_ID env var, else channel.env / gateway config.

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <file>" >&2
    exit 2
fi

FILE="$1"
if [[ ! -f "$FILE" ]]; then
    echo "error: file not found: ${FILE}" >&2
    exit 1
fi

# Token source and owner id: see tg-target.sh (channel.env from the installer,
# then the old gateway path).
# shellcheck source=tg-target.sh
source "$(dirname "${BASH_SOURCE[0]}")/tg-target.sh"
TG_ID="${PRESENT_CHAT_ID:-}"
tg_resolve_target || exit 1
if [[ -z "$TG_ID" ]]; then
    echo "error: no chat id; set PRESENT_CHAT_ID or TELEGRAM_ALLOWED_USER_IDS in channel.env" >&2
    exit 1
fi

TOKEN=$(tg_read_token)
curl -fsSL --max-time 60 \
    -F "chat_id=${TG_ID}" \
    -F "document=@${FILE}" \
    "https://api.telegram.org/bot${TOKEN}/sendDocument" >/dev/null

echo "sent ${FILE##*/} to chat ${TG_ID}"
