#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Tests for the "full system, everything switched on" part of install.sh, no root needed:
#   plugin config defaults (HUD off), starter rules.
# Run: bash tests/test_guard_install.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT

PASS=0
FAIL=0
check() {
    local name=$1; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name" >&2
    fi
}
jqtrue() { jq -e "$2" "$1" >/dev/null 2>&1; }

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e    # the checks below report failures themselves
write_as_user() { install -m "${3:-0644}" "$1" "$2"; }
warn() { printf 'warn: %s\n' "$*" >"${TDIR}/last-warn"; }

# --- plugin config.json defaults ---------------------------------------------
C="${TDIR}/config.json"
ensure_channel_config_defaults "$C"
check "cfg: fresh file gets hud off"          jqtrue "$C" '.hud.enabled == false'
check "cfg: fresh file mode 600"              test "$(stat -c %a "$C")" = 600

echo '{"hud":{"x":1},"other":2}' >"$C"; chmod 640 "$C"
ensure_channel_config_defaults "$C"
check "cfg: hud without enabled gets it"      jqtrue "$C" '.hud.enabled == false and .hud.x == 1 and .other == 2'
check "cfg: mode kept"                        test "$(stat -c %a "$C")" = 640

echo '{"hud":{"enabled":true}}' >"$C"
ensure_channel_config_defaults "$C"
check "cfg: owner value kept"                 jqtrue "$C" '.hud.enabled == true'

echo '[1]' >"$C"
ensure_channel_config_defaults "$C"
check "cfg: non-object left as is"            test "$(cat "$C")" = '[1]'

echo '{"hud":5}' >"$C"
ensure_channel_config_defaults "$C"
check "cfg: non-object section left as is"    jqtrue "$C" '.hud == 5'

echo '{"hud":null,"other":2}' >"$C"
ensure_channel_config_defaults "$C"
check "cfg: explicit null section kept"       jqtrue "$C" '.hud == null and .other == 2'

# --- starter rules in the agent workspace --------------------------------------
check "rules: one reply per question"         grep -q '## One reply per question' "${REPO}/install.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
