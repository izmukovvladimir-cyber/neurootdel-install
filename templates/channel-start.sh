#!/usr/bin/env bash
# channel-start.sh <session> <command...> -- installed by the installer as
# /usr/local/lib/<agent user>/channel-start.sh, ExecStart of channel-<agent>.
#
# The plugin checks getMe against TELEGRAM_EXPECTED_BOT_ID and, when it is not
# set, against a hard-coded upstream bot id -> "bot_id mismatch" for every
# student bot; an empty value fails its schema. The id is the token prefix,
# so derive it here at every start: a token written by hand into channel.env
# just works, and a bot change never leaves a stale id behind.
set -euo pipefail

session="${1:?session name}"
shift

token="${TELEGRAM_BOT_TOKEN:-}"
if [[ "$token" =~ ^([0-9]+): ]]; then
    export TELEGRAM_EXPECTED_BOT_ID="${BASH_REMATCH[1]}"
else
    # No usable token: the plugin exits on its own; never pass an empty id.
    unset TELEGRAM_EXPECTED_BOT_ID
fi

# Dedicated tmux server per agent, and ExecStart runs only while the unit is
# not active: any server still on this socket is a leftover, and it would give
# the new session its OLD environment (old token, old id). Start clean.
# kill-server returns before the old server is gone; wait (max ~5 s) until
# it stops answering, or new-session may still land in the dying one.
if tmux -L "$session" kill-server >/dev/null 2>&1; then
    for _ in $(seq 1 50); do
        tmux -L "$session" list-sessions >/dev/null 2>&1 || break
        sleep 0.1
    done
fi
exec tmux -L "$session" new-session -d -s "$session" "$@"
