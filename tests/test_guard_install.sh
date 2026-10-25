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

# --- superpowers switched on (enabledPlugins) ----------------------------------
AGENT_HOME="${TDIR}/home"
mkdir -p "${AGENT_HOME}/.claude/plugins" "${TDIR}/sp/.claude-plugin"
as_agent() { "$@"; }
log() { :; }
ok() { :; }
cat >"${TDIR}/sp/.claude-plugin/marketplace.json" <<'JSON'
{"name": "sp-market", "plugins": [{"name": "sp-plugin", "source": "./"}]}
JSON
SET="${AGENT_HOME}/.claude/settings.json"
echo '{"env":{"A":"1"},"permissions":{"allow":["Read"]}}' >"$SET"
enable_superpowers "${TDIR}/sp"
check "sp: enabledPlugins has plugin"         jqtrue "$SET" '.enabledPlugins["sp-plugin@sp-market"] == true'
check "sp: marketplace is the checkout"       jqtrue "$SET" ".extraKnownMarketplaces[\"sp-market\"].source == {source: \"directory\", path: \"${TDIR}/sp\"}"
check "sp: other settings kept"               jqtrue "$SET" '.env.A == "1" and .permissions.allow == ["Read"]'
check "sp: backup of first change"            test -f "${SET}.bak-install"
cp "$SET" "${TDIR}/set-before"
enable_superpowers "${TDIR}/sp"
check "sp: re-run changes nothing"            cmp -s "$SET" "${TDIR}/set-before"
jq '.enabledPlugins["sp-plugin@sp-market"] = false' "$SET" >"${TDIR}/s2" && cp "${TDIR}/s2" "$SET"
enable_superpowers "${TDIR}/sp"
check "sp: owner false kept"                  jqtrue "$SET" '.enabledPlugins["sp-plugin@sp-market"] == false'
rm -f "$SET" "${SET}.bak-install"
enable_superpowers "${TDIR}/sp"
check "sp: settings created when missing"     jqtrue "$SET" '.enabledPlugins["sp-plugin@sp-market"] == true'
# Mock CLI: records its calls, and `plugin install` writes enablement like the real one.
mkdir -p "${AGENT_HOME}/.local/bin"
cat >"${AGENT_HOME}/.local/bin/claude" <<MOCK
#!/usr/bin/env bash
echo "\$*" >>"${TDIR}/cli-calls"
if [[ "\$2" == install ]]; then
    f="${AGENT_HOME}/.claude/settings.json"
    [[ -f "\$f" ]] || echo '{}' >"\$f"
    jq --arg id "\$3" '.enabledPlugins[\$id] = true' "\$f" >"\$f.t" && mv "\$f.t" "\$f"
fi
MOCK
chmod +x "${AGENT_HOME}/.local/bin/claude"
echo '{"enabledPlugins":{"sp-plugin@sp-market":false}}' >"$SET"
: >"${TDIR}/cli-calls"
enable_superpowers "${TDIR}/sp"
check "sp: owner false survives the CLI"      jqtrue "$SET" '.enabledPlugins["sp-plugin@sp-market"] == false'
check "sp: CLI not called for owner false"    test ! -s "${TDIR}/cli-calls"
echo '{}' >"$SET"
enable_superpowers "${TDIR}/sp"
check "sp: CLI install called (user scope)"   grep -q '^plugin install sp-plugin@sp-market --scope user' "${TDIR}/cli-calls"
echo '{"plugins":{"sp-plugin@sp-market":[{"scope":"project"}]}}' >"${AGENT_HOME}/.claude/plugins/installed_plugins.json"
: >"${TDIR}/cli-calls"
enable_superpowers "${TDIR}/sp"
check "sp: project-only install -> user install" grep -q '^plugin install' "${TDIR}/cli-calls"
echo '{"plugins":{"sp-plugin@sp-market":[{"scope":"user"}]}}' >"${AGENT_HOME}/.claude/plugins/installed_plugins.json"
: >"${TDIR}/cli-calls"
enable_superpowers "${TDIR}/sp"
check "sp: user install present -> no reinstall" bash -c '! grep -q "^plugin install" "$0"' "${TDIR}/cli-calls"
echo 'not json' >"$SET"
: >"${TDIR}/cli-calls"
if enable_superpowers "${TDIR}/sp"; then sp_rc=0; else sp_rc=$?; fi
check "sp: broken settings -> nonzero"        test "$sp_rc" -ne 0
check "sp: broken settings left as is"        test "$(cat "$SET")" = 'not json'
check "sp: broken settings -> CLI not called" test ! -s "${TDIR}/cli-calls"
check "sp: no manifest -> refuses"            bash -c '! (source "$0" >/dev/null 2>&1; enable_superpowers /nonexistent)' "${REPO}/install.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
