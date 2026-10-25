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
export PYTHONDONTWRITEBYTECODE=1
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

# --- guard.conf ------------------------------------------------------------------
INSTALL_TAG=neurootdel-install
AGENT_USER=neurootdel
GUARD_LIB_DIR="${REPO}/lib"
CONFIG_ROOT="${TDIR}/etc"
OPERATOR_NAME='Анна "Q" $x`y`'
TG_USER_ID=555
OPERATOR_TIMEZONE=Asia/Dubai
GC="${TDIR}/guard.conf"
render_guard_conf "" >"$GC"
check "conf: owner name sanitized"            grep -qx 'OWNER_NAME="Анна Q xy"' "$GC"
check "conf: default alert mode outbox"       grep -qx 'ALERT_MODE="outbox"' "$GC"
check "conf: owner id"                        grep -qx 'OWNER_TG_ID="555"' "$GC"
check "conf: bash can source it"              bash -c '. "$0" && [[ "$AGENT_HOME" == "$1" ]]' "$GC" "$AGENT_HOME"
check "conf: python reads it"                 env NEUROOTDEL_GUARD_CONF="$GC" python3 -c "import sys; sys.path.insert(0, '${REPO}/lib'); import guard_conf as g; c = g.load(); assert c.owner_tg_id == '555' and c.channel_agents == ['jarvis'] and c.label('jarvis') == 'Jarvis', c"
sed -i 's/^CHANNEL_AGENTS=.*/CHANNEL_AGENTS="jarvis coder"/; s/^ALERT_MODE=.*/ALERT_MODE="log"/' "$GC"
render_guard_conf "$GC" >"${GC}.2"
check "conf: re-run keeps agents list"        grep -qx 'CHANNEL_AGENTS="jarvis coder"' "${GC}.2"
check "conf: re-run keeps alert mode"         grep -qx 'ALERT_MODE="log"' "${GC}.2"
NEUROOTDEL_GUARD_ALERTS=telegram render_guard_conf "$GC" >"${GC}.3"
check "conf: env alert mode wins"             grep -qx 'ALERT_MODE="telegram"' "${GC}.3"
NEUROOTDEL_GUARD_ALERTS=bogus render_guard_conf "" >"${GC}.4"
check "conf: bad alert mode -> outbox"        grep -qx 'ALERT_MODE="outbox"' "${GC}.4"
render_guard_conf "" >"$GC"

# --- lib scripts against a fake home -------------------------------------------
export NEUROOTDEL_GUARD_CONF="$GC"
WS="${AGENT_HOME}/.claude-lab/jarvis/.claude"
mkdir -p "${WS}/core/hot" "${AGENT_HOME}/.claude-lab/shared/state"
echo '# rules' >"${WS}/core/rules.md"
printf '# handoff\n\n- open: something\n' >"${WS}/core/hot/handoff.md"
PREFIX=$(printf '%s' "$WS" | sed 's/[^A-Za-z0-9]/-/g')
PROJ="${AGENT_HOME}/.claude/projects/${PREFIX}-dashi-plugin-claude-code-plugin"
mkdir -p "$PROJ"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
OLD=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%S.000Z)
cat >"${PROJ}/s1.jsonl" <<JL
{"type":"assistant","timestamp":"${OLD}","message":{"usage":{"cache_read_input_tokens":300000},"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"${AGENT_HOME}/x.txt"}}]}}
JL
OUT=$(python3 "${REPO}/lib/agent-handoff-flush.py" --dry-run jarvis)
check "flush: dry run sees the agent"         grep -q '^DRY jarvis: would write 1 entries' <<<"$OUT"
OUT=$(python3 "${REPO}/lib/agent-handoff-flush.py" jarvis)
check "flush: writes handoff"                 grep -q '^OK jarvis' <<<"$OUT"
check "flush: hand-written part kept"         grep -q -- '- open: something' "${WS}/core/hot/handoff.md"
check "flush: action listed, home-relative"   grep -q 'Edit x.txt' "${WS}/core/hot/handoff.md"
check "flush: owner timezone in stamp"        grep -q 'Auto-flushed by agent-handoff-flush.py at .* +04' "${WS}/core/hot/handoff.md"
check "flush: newest repeat survives dedup" python3 "${REPO}/tests/helpers/flush_order.py" "$REPO"
OUT=$(bash "${REPO}/lib/agents-reset.sh" --dry-run 2>&1)
RLOG="${AGENT_HOME}/.claude-lab/shared/state/agents-reset/agents-reset.log"
check "reset: dry run logs a decision"        grep -q 'result jarvis: skipped' "$RLOG"
check "reset: dry run wrote no quiet marker"  test ! -e "${AGENT_HOME}/.claude-lab/shared/state/quiet-restart/channel-jarvis"
check "reset: STOP honoured"                  bash -c 'touch "$1/STOP"; bash "$2" --dry-run 2>/dev/null; tail -n1 "$1/agents-reset.log" | grep -q "STOP file present"; rc=$?; rm -f "$1/STOP"; exit $rc' _ "${AGENT_HOME}/.claude-lab/shared/state/agents-reset" "${REPO}/lib/agents-reset.sh"
check "reset: context measured from prefix"   bash -c 'grep -q "agents-reset start" "$0"' "$RLOG"
OUT=$(bash "${REPO}/lib/memory-backup.sh" 2>&1)
check "backup: archive written"               grep -q '^.* OK .*memory-.*\.tar\.gz' <<<"$OUT"
ARCH=$(ls "${AGENT_HOME}/backups/memory/"memory-*.tar.gz 2>/dev/null | head -n1)
check "backup: rules.md inside"               bash -c 'tar -tzf "$0" | grep -qx ".claude-lab/jarvis/.claude/core/rules.md"' "$ARCH"
check "backup: dir is private"                test "$(stat -c %a "${AGENT_HOME}/backups/memory")" = 700
check "reset: --auto runs only on the owner's clock" bash "${REPO}/tests/helpers/auto_window.sh" "$RLOG" "${REPO}/lib/agents-reset.sh"
OUT=$(python3 "${REPO}/lib/include_weight.py" "${AGENT_HOME}/.claude-lab" 2>&1)
check "weight: measures the lab"              test -n "$OUT"
unset NEUROOTDEL_GUARD_CONF

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
