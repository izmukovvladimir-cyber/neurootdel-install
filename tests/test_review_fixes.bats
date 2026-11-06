#!/usr/bin/env bats
# Regression tests for the four review fixes that needed explicit coverage:
#   F1  -- owner answers survive a re-run (guard.conf; v2 state file is gone since v3.0.0)
#   F2  -- tg_get_me uses curl -K so the bot token is never in argv
#   F5  -- Superpowers jq merge handles malformed plugins config.json
#   F9  -- install_skill_bundle stages on the same filesystem as dst_parent

setup() {
    export INSTALL_SH_SOURCED_FOR_TESTING=1
    # install.sh sets `trap _cleanup EXIT`, which replaces bats' own EXIT trap: a failing
    # test then vanishes ("Executed N instead of expected M") instead of "not ok". Keep bats' trap.
    local bats_exit_trap
    bats_exit_trap="$(trap -p EXIT)"
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../install.sh"
    eval "${bats_exit_trap:-trap - EXIT}"

    TDIR="$(mktemp -d)"

    # Override state_file() so writes go into $TDIR (default points at /root).
    # The override must be installed AFTER sourcing install.sh.
    eval "state_file() { echo \"${TDIR}/install-state.json\"; }"

    # Neutralise user-switching helpers so tests run as the current user.
    eval 'as_user() { "$@"; }'
    eval 'fix_owner() { :; }'
    eval 'write_as_user() { cp "$1" "$2"; chmod "$3" "$2"; }'
}

teardown() {
    rm -rf "$TDIR"
}

# --- F1: inputs survive a re-run ----------------------------------------------
# v3.0.0 dropped the v2 state file (record_step/state_file). The owner's answers now live in
# guard.conf, and a re-run without env reads them back as the defaults of collect_inputs.

_f1_render_conf() {   # guard.conf of this test, from the current answers
    apply_install_names new
    GUARD_LIB_DIR="${TDIR}/lib"; AGENT_HOME="${TDIR}/home"; mkdir -p "$GUARD_LIB_DIR"
    render_guard_conf "" > "${GUARD_LIB_DIR}/guard.conf"
}

_f1_collect_without_env() {   # a re-run: no env, Enter on every question
    unset NEUROOTDEL_USER_NAME NEUROOTDEL_TG_USER_ID NEUROOTDEL_LANGUAGE NEUROOTDEL_TIMEZONE \
        NEUROOTDEL_JARVIS_BOT_TOKEN NEUROOTDEL_RICHARD_BOT_TOKEN \
        EDGELAB_USER_NAME EDGELAB_TG_USER_ID EDGELAB_LANGUAGE EDGELAB_TIMEZONE
    export NEUROOTDEL_NONINTERACTIVE=1
    OPERATOR_NAME=""; TG_USER_ID=""; OPERATOR_LANGUAGE=""; OPERATOR_TIMEZONE=""
    eval 'step() { :; }; log() { :; }; warn() { :; }; ok() { :; }'
    # The bots are already on this server; the bot checks live in test_mandatory_bots.sh.
    eval 'collect_bot_token() { :; }'
    collect_inputs </dev/null
}

@test "F1 re-run: owner name, id, timezone and language come back from guard.conf" {
    OPERATOR_NAME="Dashi"; TG_USER_ID="424242"; OPERATOR_TIMEZONE="Asia/Bangkok"; OPERATOR_LANGUAGE="English"
    MAIN_AGENT_NAME="Thrall"; DOCTOR_NAME="Doc"
    _f1_render_conf
    grep -qx 'OWNER_NAME="Dashi"' "${GUARD_LIB_DIR}/guard.conf"
    grep -qx 'OWNER_TG_ID="424242"' "${GUARD_LIB_DIR}/guard.conf"
    grep -qx 'OWNER_TIMEZONE="Asia/Bangkok"' "${GUARD_LIB_DIR}/guard.conf"
    grep -qx 'OWNER_LANGUAGE="English"' "${GUARD_LIB_DIR}/guard.conf"

    _f1_collect_without_env
    [ "$OPERATOR_NAME" = "Dashi" ]
    [ "$TG_USER_ID" = "424242" ]
    [ "$OPERATOR_TIMEZONE" = "Asia/Bangkok" ]
    [ "$OPERATOR_LANGUAGE" = "English" ]
}

@test "F1 re-run: bot tokens are NOT written to guard.conf" {
    OPERATOR_NAME="Dashi"; TG_USER_ID="424242"; MAIN_AGENT_NAME="Thrall"; DOCTOR_NAME="Doc"
    JARVIS_BOT_TOKEN="1234567:ABCDEFsecretJarvisTokenPart_xyz0123"
    RICHARD_BOT_TOKEN="7654321:ABCDEFsecretRichardTokenPart_xyz012"
    _f1_render_conf
    # `! cmd` never fails a bats test (errexit ignores negated commands): check the status.
    run grep -q "ABCDEFsecretJarvisTokenPart" "${GUARD_LIB_DIR}/guard.conf"
    [ "$status" -eq 1 ]
    run grep -q "ABCDEFsecretRichardTokenPart" "${GUARD_LIB_DIR}/guard.conf"
    [ "$status" -eq 1 ]
    # only the public bot ids (numeric part) are kept, for the fact gate
    grep -qx 'FACT_GATE_SELF_IDS="1234567"' "${GUARD_LIB_DIR}/guard.conf"
}

# --- F2: token never in curl argv ----------------------------------------------
# v3.0.0 replaced _tg_curl_cfg/_tg_getme with tg_get_me; the property is the same: the bot
# token must not be in curl's argv (visible to every local user in ps / /proc/*/cmdline).

@test "F2 telegram: tg_get_me does not put the token in curl argv" {
    local argv_log="${TDIR}/curl-argv.log" stdin_log="${TDIR}/curl-stdin.log"
    eval "curl() { printf '%s\n' \"\$@\" > '${argv_log}'; cat > '${stdin_log}'; echo '{\"ok\":false,\"error_code\":401}'; }"

    local resp
    resp=$(tg_get_me "999:ARGV_TOKEN_MUST_NOT_APPEAR" </dev/null)
    [ "$resp" = '{"ok":false,"error_code":401}' ]

    [ -f "$argv_log" ]
    run grep -q "ARGV_TOKEN_MUST_NOT_APPEAR" "$argv_log"
    [ "$status" -eq 1 ]
    grep -qx -- '-K' "$argv_log"
    # the request itself went through the config on stdin
    grep -qF 'url = "https://api.telegram.org/bot999:ARGV_TOKEN_MUST_NOT_APPEAR/getMe"' "$stdin_log"
}

# --- F5: Superpowers jq merge defensive path -----------------------------------

@test "F5 jq merge: malformed plugins/config.json is backed up and preserved" {
    local plugins_dir="${TDIR}/plugins"
    local cfg="${plugins_dir}/config.json"
    mkdir -p "$plugins_dir"
    printf 'not valid json at all\n' > "$cfg"

    run jq -e 'type=="object"' "$cfg"
    [ "$status" -ne 0 ]

    local backup="${cfg}.bak.$(date +%s)"
    cp "$cfg" "$backup"
    [ -f "$backup" ]
    [ -f "$cfg" ]
    run cat "$cfg"
    [ "$output" = "not valid json at all" ]
}

@test "F5 jq merge: well-formed config gains the superpowers entry with absolute path" {
    local plugins_dir="${TDIR}/plugins"
    local cfg="${plugins_dir}/config.json"
    local sp_dir="${plugins_dir}/superpowers"
    mkdir -p "$plugins_dir"
    printf '{"plugins":{"other":{"enabled":true,"path":"/tmp/other"}}}' > "$cfg"

    local tmp
    tmp=$(mktemp)
    jq --arg p "$sp_dir" \
       '.plugins = ((.plugins // {}) + {"superpowers": {"enabled": true, "path": $p}})' \
       "$cfg" > "$tmp"
    mv "$tmp" "$cfg"

    run jq -r '.plugins.superpowers.path' "$cfg"
    [ "$output" = "$sp_dir" ]
    run jq -r '.plugins.other.enabled' "$cfg"
    [ "$output" = "true" ]
}

# --- F9: same-filesystem staging -----------------------------------------------

@test "F9 skill staging: stage dir sits under dst_parent, not /tmp" {
    local src_skill="${TDIR}/src/hello-skill"
    local dst_parent="${TDIR}/home/user/.claude/skills"
    mkdir -p "$src_skill"
    echo "SKILL" > "${src_skill}/SKILL.md"

    # Wrap mkdir so we capture any staging path install_skill_bundle creates.
    local captured="${TDIR}/staging-path.log"
    : > "$captured"
    eval '
    _orig_mkdir() { command mkdir "$@"; }
    mkdir() {
        for arg in "$@"; do
            case "$arg" in
                *'"'"'.staging.'"'"'*)
                    echo "$arg" >> "'"${captured}"'"
                    ;;
            esac
        done
        _orig_mkdir "$@"
    }
    '

    install_skill_bundle "$src_skill" "$dst_parent" "hello-skill"

    [ -s "$captured" ]
    local stage_path
    stage_path=$(head -n1 "$captured")
    case "$stage_path" in
        "${dst_parent}"/.hello-skill.staging.*)
            :  # ok
            ;;
        /tmp/*|/var/folders/*)
            echo "BUG: stage path is on tmpfs: $stage_path" >&2
            return 1
            ;;
        *)
            echo "BUG: unexpected stage path: $stage_path" >&2
            return 1
            ;;
    esac

    [ -f "${dst_parent}/hello-skill/SKILL.md" ]
}
