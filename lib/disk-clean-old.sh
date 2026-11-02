#!/usr/bin/env bash
# disk-clean-old.sh -- daily cleanup of FILES older than 14 days in directories nobody reads
# back (installed by the installer): media inboxes of the channel agents' plugin, chip media,
# Claude Code temp dirs of the agents and Richard. Directories stay, no quarantine.
# Runs as the agent user from /etc/cron.d/<user>-service-watch every 10 min; the run itself
# happens once a day in 04:30-04:59 by the owner's clock (OWNER_TIMEZONE). --now runs at once.
# Stop: touch ~/.claude-lab/shared/state/disk-clean/STOP
set -euo pipefail
LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck disable=SC1091
. "${NEUROOTDEL_GUARD_CONF:-$LIB/guard.conf}"
U="${AGENT_USER:?AGENT_USER missing in guard.conf}"
L="${AGENT_HOME:?}/.claude-lab"
OTZ="${OWNER_TIMEZONE:-Europe/Moscow}"
STATE=$L/shared/state/disk-clean
LOG=$STATE/disk-clean.log
mkdir -p "$STATE"
[[ -e "$STATE/STOP" ]] && exit 0
marker="$STATE/done-$(TZ="$OTZ" date +%Y%m%d)"
if [[ "${1:-}" != "--now" ]]; then
  hm=$(TZ="$OTZ" date +%H%M)
  [[ "$hm" =~ ^[0-9]{4}$ ]] || exit 0
  (( 10#$hm >= 430 && 10#$hm < 500 )) || exit 0
fi
exec 9>"$STATE/lock"
flock -n 9 || exit 0
# Marker is checked under the lock, so a second instance cannot repeat a finished run.
[[ "${1:-}" != "--now" && -e "$marker" ]] && exit 0
# "days:path".
dirs=()
read -r -a agents <<< "${CHANNEL_AGENTS:-jarvis}"
tmproot="/tmp/claude-$(id -u)"
for a in "${agents[@]}"; do
  [[ "$a" =~ ^[a-z0-9-]+$ ]] || continue
  dirs+=("14:$L/$a/telegram-chip/media" "14:$L/shared/state/$a/telegram/inbox"
         "14:$L/shared/state/$a/telegram/group-media")
  # Claude Code temp dirs (scratchpads, task outputs) of this agent's sessions.
  prefix=$(printf '%s' "$L/$a/.claude" | sed 's/[^A-Za-z0-9]/-/g')
  for p in "$tmproot/$prefix" "$tmproot/$prefix"-*; do
    if [[ -d "$p" ]]; then dirs+=("14:$p"); fi
  done
done
# Richard's sessions run with cwd = the home dir: that exact temp dir, nothing below it by glob.
p="$tmproot/$(printf '%s' "$AGENT_HOME" | sed 's/[^A-Za-z0-9]/-/g')"
if [[ -d "$p" ]]; then dirs+=("14:$p"); fi
manifest="$STATE/deleted-$(date +%Y%m%d)-$$.nul"
total=0
for entry in "${dirs[@]}"; do
  days=${entry%%:*}
  d=${entry#*:}
  [[ -d "$d" ]] || continue
  # A symlink anywhere in the path would send find outside the list: skip such a directory.
  if [[ "$(realpath -e -- "$d")" != "$d" ]]; then
    echo "$(date -Is) SKIP $d: path resolves elsewhere" >> "$LOG"
    continue
  fi
  # One pass; -fprintf/-printf after -delete fire only on a successful delete.
  # Manifest is NUL-separated (names may hold newlines); stdout carries sizes only.
  part=$(mktemp "$STATE/part.XXXXXX")
  bytes=$(find "$d" -xdev -type f -mtime +"$days" -delete -fprintf "$part" '%p\0' -printf '%s\n' \
          | awk '{s+=$1} END{printf "%.0f\n", s+0}')
  cat "$part" >> "$manifest"; rm -f "${part:?}"
  total=$((total + bytes))
  echo "$(date -Is) $d freed=${bytes}" >> "$LOG"
done
echo "$(date -Is) total_freed=${total} manifest=${manifest}" >> "$LOG"
touch "$marker"
echo "$total"
