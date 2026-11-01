#!/usr/bin/env bash
# review-reminder.sh -- PostToolUse hook for Edit|Write|MultiEdit (installed by the installer).
# Counts code-modifying calls per session; at the threshold the session gets ONE reminder
# (additionalContext, seen by the model) to have the change reviewed before a commit.
# State: ~/.claude-lab/shared/state/review-reminder/<session id> (files older than 7 days dropped).
# Stop: touch ~/.claude-lab/shared/state/review-reminder/STOP
set -uo pipefail

THRESHOLD="${REVIEW_REMINDER_THRESHOLD:-10}"
dir="${HOME:-/nonexistent}/.claude-lab/shared/state/review-reminder"
[[ -e "$dir/STOP" ]] && exit 0
input=$(cat)
sid=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || exit 0
[[ "$sid" =~ ^[A-Za-z0-9_-]{1,80}$ ]] || exit 0
mkdir -p "$dir" 2>/dev/null || exit 0
f="$dir/$sid"
count=$(cat "$f" 2>/dev/null || echo 0)
[[ "$count" =~ ^[0-9]+$ ]] || count=0
count=$((count + 1))
echo "$count" >"$f" 2>/dev/null || exit 0
find "$dir" -maxdepth 1 -type f -mtime +7 ! -name STOP -delete 2>/dev/null || true

if (( count == THRESHOLD )); then
    jq -cn --arg n "$count" '{hookSpecificOutput: {hookEventName: "PostToolUse",
        additionalContext: ("[review-reminder] " + $n + " code-modifying tool calls in this session. Before committing, get the change reviewed: a review subagent on a second model, or the review skill.")}}'
fi
exit 0
