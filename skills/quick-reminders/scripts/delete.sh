#!/usr/bin/env bash
set -euo pipefail
# Usage: delete.sh ID
# Remove a reminder cron line by its qr:ID=<nonce> tag.

if [[ $# -ne 1 ]]; then
    echo "usage: $0 ID" >&2
    exit 2
fi

ID="$1"
TAG="qr:ID=${ID}"

# shellcheck source=crontab-edit.sh
source "$(dirname "${BASH_SOURCE[0]}")/crontab-edit.sh"
# Same lock as create.sh and wake.sh: a parallel add or removal cannot overwrite this one.
LOCK_DIR="${QR_WAKE_DIR:-$HOME/.claude-lab/shared/state/reminders}"
mkdir -p "$LOCK_DIR"
(
    flock -w 30 9 || { echo "error: crontab lock busy, try again" >&2; exit 1; }
    CUR=$(qr_crontab_read) || { echo "error: crontab not readable, nothing changed" >&2; exit 1; }
    BEFORE=$(grep -c . <<<"$CUR" || true)
    qr_crontab_drop "$TAG" || { echo "error: crontab not rewritten" >&2; exit 1; }
    CUR=$(qr_crontab_read) || { echo "error: crontab not readable after the change" >&2; exit 1; }
    AFTER=$(grep -c . <<<"$CUR" || true)

    REMOVED=$((BEFORE - AFTER))
    if [[ "$REMOVED" -gt 0 ]]; then
        echo "deleted reminder ${ID} (${REMOVED} cron line removed)"
    else
        echo "no reminder found with id ${ID}" >&2
        exit 1
    fi
) 9>"${LOCK_DIR}/.crontab.lock"
