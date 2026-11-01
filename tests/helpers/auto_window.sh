#!/usr/bin/env bash
# auto_window.sh <reset log> <agents-reset.sh> -- `--auto` writes to the log only inside
# the owner-clock windows (04:00-04:09 nightly, 06:00-22:59 daytime). Uses OWNER_TIMEZONE
# from the conf in NEUROOTDEL_GUARD_CONF.
set -euo pipefail
log=$1 script=$2
# shellcheck disable=SC1090
. "$NEUROOTDEL_GUARD_CONF"
tz="${OWNER_TIMEZONE:-Europe/Moscow}"
h=$(TZ="$tz" date +%-H); m=$(TZ="$tz" date +%-M)
before=$(wc -l <"$log")
bash "$script" --auto --dry-run 2>/dev/null
after=$(wc -l <"$log")
if { [ "$h" -eq 4 ] && [ "$m" -lt 10 ]; } || { [ "$h" -ge 6 ] && [ "$h" -le 22 ]; }; then
    [ "$after" -gt "$before" ]
else
    [ "$after" -eq "$before" ]
fi
