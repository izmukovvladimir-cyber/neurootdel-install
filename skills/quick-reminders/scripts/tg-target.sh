# tg-target.sh -- sourced by the skill scripts, never run directly.
#
# Finds where the Telegram bot token lives and who the owner is. Sets:
#   TG_TOKEN_KIND  env (KEY=VALUE file, token in TELEGRAM_BOT_TOKEN) | raw (file holds only the token)
#   TG_TOKEN_FILE  path of that file (the token itself is never put in a variable here)
#   TG_ID          owner chat id, unless the caller already set it
#
# Token source, first match wins:
#   1. $TELEGRAM_BOT_TOKEN_FILE                      -- raw token file, explicit override
#   2. channel.env written by the installer          -- /etc/vladimir-plugin/jarvis/channel.env,
#      on servers installed before the rename /etc/dashi-plugin/jarvis/channel.env
#      (override the path with $NEUROOTDEL_CHANNEL_ENV, old name $EDGELAB_CHANNEL_ENV);
#      root:<agent user> 0640, the agent reads it via its group
#   3. $HOME/claude-gateway/secrets/bot-token         -- old gateway installs
#   4. $HOME/.secrets/telegram-bot-token              -- manual setup
# Owner chat id: caller's TG_ID -> $TELEGRAM_CHAT_ID -> first TELEGRAM_ALLOWED_USER_IDS
# in channel.env -> allowlist_user_ids[0] in $HOME/claude-gateway/config.json.

tg_resolve_target() {
    local env_file="${NEUROOTDEL_CHANNEL_ENV:-${EDGELAB_CHANNEL_ENV:-}}"
    if [[ -z "$env_file" ]]; then
        env_file=/etc/vladimir-plugin/jarvis/channel.env
        [[ -e "$env_file" ]] || env_file=/etc/dashi-plugin/jarvis/channel.env
    fi
    local legacy_dir="${HOME}/claude-gateway"
    TG_TOKEN_KIND=""
    TG_TOKEN_FILE=""
    TG_ID="${TG_ID:-${TELEGRAM_CHAT_ID:-}}"

    if [[ -n "${TELEGRAM_BOT_TOKEN_FILE:-}" ]]; then
        if [[ ! -r "$TELEGRAM_BOT_TOKEN_FILE" ]]; then
            echo "error: TELEGRAM_BOT_TOKEN_FILE=${TELEGRAM_BOT_TOKEN_FILE} is not readable" >&2
            return 1
        fi
        TG_TOKEN_KIND=raw
        TG_TOKEN_FILE="$TELEGRAM_BOT_TOKEN_FILE"
    elif [[ -r "$env_file" ]] && grep -qE '^TELEGRAM_BOT_TOKEN=[^[:space:]]' "$env_file"; then
        TG_TOKEN_KIND=env
        TG_TOKEN_FILE="$env_file"
    elif [[ -r "${legacy_dir}/secrets/bot-token" ]]; then
        TG_TOKEN_KIND=raw
        TG_TOKEN_FILE="${legacy_dir}/secrets/bot-token"
    elif [[ -r "${HOME}/.secrets/telegram-bot-token" ]]; then
        TG_TOKEN_KIND=raw
        TG_TOKEN_FILE="${HOME}/.secrets/telegram-bot-token"
    else
        if [[ -e "$env_file" && ! -r "$env_file" ]]; then
            echo "error: ${env_file} exists but $(id -un) cannot read it (expected root:$(id -un) 0640)" >&2
        else
            echo "error: no bot token found (${env_file}, ${legacy_dir}/secrets/bot-token, or set TELEGRAM_BOT_TOKEN_FILE)" >&2
        fi
        return 1
    fi

    if [[ -z "$TG_ID" && -r "$env_file" ]]; then
        TG_ID=$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$env_file" | head -n1 | cut -d, -f1 | tr -d '[:space:]"')
    fi
    if [[ -z "$TG_ID" && -f "${legacy_dir}/config.json" ]]; then
        TG_ID=$(jq -r '.allowlist_user_ids[0] // empty' "${legacy_dir}/config.json" 2>/dev/null || true)
    fi
    return 0
}

# tg_token_cmd -- prints a /bin/sh command that writes the token to stdout.
# Used inside cron lines so the token is read at run time and never lands in crontab.
tg_token_cmd() {
    [[ "$TG_TOKEN_FILE" != *"'"* ]] || { echo "error: token path contains a quote: ${TG_TOKEN_FILE}" >&2; return 1; }
    case "$TG_TOKEN_KIND" in
        env) printf "sed -n 's/^TELEGRAM_BOT_TOKEN=//p' '%s' | head -n1 | tr -d '[:space:]'" "$TG_TOKEN_FILE" ;;
        raw) printf "tr -d '[:space:]' < '%s'" "$TG_TOKEN_FILE" ;;
        *) return 1 ;;
    esac
}

# tg_read_token -- writes the token to stdout.
tg_read_token() {
    case "$TG_TOKEN_KIND" in
        env) sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$TG_TOKEN_FILE" | head -n1 | tr -d '[:space:]' ;;
        raw) tr -d '[:space:]' < "$TG_TOKEN_FILE" ;;
        *) return 1 ;;
    esac
}
