#!/usr/bin/env bash
# log-commands.sh -- PreToolUse hook for Bash (installed by the installer): audit trail of every
# shell command of every agent session. Never blocks. One line per command:
#   <UTC time>  <agent>  <first line of the command, secrets masked, cut at 500 chars>
# Only the first line is kept (heredoc bodies and scripts never reach the log), cut at its
# first quote/backslash/backtick (shown as ‹…›); key-like strings, "<secret name>=value", --password/--token values,
# Bearer/basic auth and URL passwords are masked as ***.
# The log is 0600 (umask 077).
# Agent = the ~/.claude-lab/<agent>/ dir of the session's cwd, else "home" (Richard, cwd = home).
# Log: ~/.claude-lab/shared/state/command-log/commands.log (rotated at 5 MB, one .1 kept).
# Stop: touch ~/.claude-lab/shared/state/command-log/STOP
set -uo pipefail

dir="${HOME:-/nonexistent}/.claude-lab/shared/state/command-log"
[[ -e "$dir/STOP" ]] && exit 0
input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null) || exit 0
[[ -n "$cmd" ]] || exit 0
cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null) || cwd=""
agent=home
if [[ "$cwd" =~ /\.claude-lab/([A-Za-z0-9_-]+)(/|$) ]]; then agent="${BASH_REMATCH[1]}"; fi

nlines=$(printf '%s\n' "$cmd" | wc -l)
first="${cmd%%$'\n'*}"
# Conservative: the line is cut at its first quote, backslash or backtick, so no quoted or
# escaped value (spaces, escapes, nesting) can ever be half-kept; the rest is masked below.
masked=$(printf '%s' "$first" | sed -E \
    -e 's/["'"'"'\\`].*$/‹…›/' \
    -e 's/(sk-ant-|sk-|gh[pousr]_|xox[abprs]-|AKIA)[A-Za-z0-9_-]{8,}/\1***/g' \
    -e 's/[0-9]{8,10}:AA[A-Za-z0-9_-]{20,}/***/g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_.-]+/***/g' \
    -e 's/([Bb]earer|[Bb]asic)[[:space:]]+[^[:space:]"'"'"']+/\1 ***/g' \
    -e 's#(://[^/:@[:space:]]+):[^@/[:space:]]+@#\1:***@#g' \
    -e 's/(-u|--user)[[:space:]]+[^[:space:]:]+:[^[:space:]]+/\1 ***/g' \
    -e 's/((api[_-]?key|apikey|api_hash|secret|password|passwd|pwd|token|session_string|cookie|auth)[A-Za-z0-9_-]*["'"'"']?[[:space:]]*[:=][[:space:]]*)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)/\1***/gI' \
    -e 's/(--?(password|passwd|token|secret|api-key|apikey|auth))([[:space:]]+|=[[:space:]]*)[^[:space:]]+/\1\3***/gI')
short="${masked:0:500}"
(( ${#masked} > 500 )) && short="${short}...[cut]"
(( nlines > 1 )) && short="${short} [+$((nlines - 1)) lines not logged]"

umask 077
mkdir -p "$dir" 2>/dev/null || exit 0
log="$dir/commands.log"
if [[ -f "$log" ]] && (( $(stat -c %s "$log" 2>/dev/null || echo 0) > 5242880 )); then
    mv -f "$log" "$log.1" 2>/dev/null || true
fi
printf '%s  %s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$agent" "$short" >>"$log" 2>/dev/null || true
exit 0
