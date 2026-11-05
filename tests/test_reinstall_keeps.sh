#!/usr/bin/env bash
# shellcheck disable=SC2016  # the child scripts are single-quoted on purpose
# A re-run of the installer without the env of the first run keeps what the first run set:
# owner id (guard.conf + fact gate --owner), owner name (guard.conf, DOCTOR.md, team-rules.md),
# agent model (unit), brief (log line); and no run leaves its template clone in TMPDIR.
# Each "install" is a separate bash process that sources install.sh, like a real re-run.
# Synthetic names and ids only, no root. Run: bash tests/test_reinstall_keeps.sh
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

SB="${TDIR}/sb"   # the "server": guard lib, agent home, unit dir
mkdir -p "${SB}/lib" "${SB}/home/.claude/hooks" "${SB}/home/.claude-lab/jarvis/.claude" \
    "${SB}/home/.claude-lab/shared" "${SB}/systemd" "${SB}/richard"

# One installer run over the sandbox, the steps that write the values under test, in main()'s order.
# Prints the role line of resolve_role_settings.
read -r -d '' RUN <<'CHILD' || true
set -euo pipefail   # errexit on, as in a real run: a missing unit/CLAUDE.md must not stop it
export INSTALL_SH_SOURCED_FOR_TESTING=1 NEUROOTDEL_NONINTERACTIVE=1
source "$REPO/install.sh"
apply_install_names new
GUARD_LIB_DIR="$SB/lib"; AGENT_HOME="$SB/home"
JARVIS_UNIT_FILE="$SB/systemd/channel-jarvis.service"
write_as_user() { mkdir -p "$(dirname "$2")"; install -m "${3:-0644}" "$1" "$2"; }
as_agent() { "$@"; }
step() { :; }; log() { :; }; warn() { :; }; err() { :; }
ok() { printf '%s\n' "$*"; }
collect_inputs >/dev/null
resolve_role_settings
render_jarvis_unit "$JARVIS_UNIT_FILE" /p/plugin /etc/x/channel.env
ws="$AGENT_HOME/.claude-lab/jarvis/.claude"
tmp=$(mktemp); render_agent_claude_md "$tmp"; _write_if_absent "$tmp" "$ws/CLAUDE.md" 0644; rm -f "$tmp"
render_doctor_role "$SB/richard/DOCTOR.md"
ensure_fact_gate_hook "$AGENT_HOME/.claude/settings.json" "$AGENT_HOME/.claude/hooks/fact-number-gate.py" "${TG_USER_ID:-}"
conf="$GUARD_LIB_DIR/guard.conf"; tmp=$(mktemp); render_guard_conf "$conf" >"$tmp"; mv "$tmp" "$conf"
render_template "$TEMPLATES_DIR/shared/team-rules.md" "$AGENT_HOME/.claude-lab/shared/team-rules.md" \
    USER_NAME "$OPERATOR_NAME" LIB "$GUARD_LIB_DIR" CONFIG_ROOT "$CONFIG_ROOT" USER "$AGENT_USER" \
    AGENT_NAME "$MAIN_AGENT_NAME" DOCTOR_NAME "$DOCTOR_NAME"
echo RUN-COMPLETE
CHILD

clean_env() {
    env -u NEUROOTDEL_TG_USER_ID -u NEUROOTDEL_USER_NAME -u NEUROOTDEL_AGENT_MODEL -u NEUROOTDEL_DOCTOR_MODEL \
        -u NEUROOTDEL_AGENT_NAME -u NEUROOTDEL_DOCTOR_NAME -u NEUROOTDEL_BRIEF_DIR \
        -u EDGELAB_TG_USER_ID -u EDGELAB_USER_NAME -u EDGELAB_AGENT_MODEL -u EDGELAB_BRIEF_DIR \
        REPO="$REPO" SB="$SB" TMPDIR="${TDIR}/tmp" NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates" "$@"
}
mkdir -p "${TDIR}/tmp"

# --- run 1: everything given ------------------------------------------------------------------
clean_env NEUROOTDEL_TG_USER_ID=777000111 NEUROOTDEL_USER_NAME="Тест-Владелец" \
    NEUROOTDEL_AGENT_NAME="Тестовый Агент" NEUROOTDEL_DOCTOR_NAME="Тестовый Доктор" \
    NEUROOTDEL_AGENT_MODEL=claude-sonnet-5-5 NEUROOTDEL_DOCTOR_MODEL=claude-opus-5-5 \
    NEUROOTDEL_BRIEF_DIR="~/brief-test/" bash -c "$RUN" >"${TDIR}/run1.log" 2>&1 || true
check "run1: owner id in guard.conf"          grep -qx 'OWNER_TG_ID="777000111"' "${SB}/lib/guard.conf"
check "run1: fact gate --owner"               grep -q 'fact-number-gate.py agent --owner 777000111"' "${SB}/home/.claude/settings.json"
check "run1: agent model in unit"             grep -q -- '--model claude-sonnet-5-5 ' "${SB}/systemd/channel-jarvis.service"

# --- run 2: nothing given (Enter on every question) -------------------------------------------
clean_env bash -c "$RUN" >"${TDIR}/run2.log" 2>&1 || true
# D1
check "D1 rerun: owner id kept in guard.conf" grep -qx 'OWNER_TG_ID="777000111"' "${SB}/lib/guard.conf"
check "D1 rerun: fact gate keeps --owner"     grep -q 'fact-number-gate.py agent --owner 777000111"' "${SB}/home/.claude/settings.json"
# D2
check "D2 rerun: agent model kept in unit"    grep -q -- '--model claude-sonnet-5-5 ' "${SB}/systemd/channel-jarvis.service"
# D3
check "D3 rerun: owner name kept in guard.conf" grep -qx 'OWNER_NAME="Тест-Владелец"' "${SB}/lib/guard.conf"
check "D3 rerun: owner name kept in DOCTOR.md" bash -c 'grep -q "Тест-Владелец" "$0" && ! grep -q "friend" "$0"' "${SB}/richard/DOCTOR.md"
check "D3 rerun: owner name kept in team-rules" bash -c 'grep -q "Тест-Владелец" "$0" && ! grep -q "friend" "$0"' "${SB}/home/.claude-lab/shared/team-rules.md"
# D5
check "D5 rerun: CLAUDE.md still has the brief" grep -qF -- '- Где бриф и созвоны клиента: ~/brief-test/' "${SB}/home/.claude-lab/jarvis/.claude/CLAUDE.md"
check "D5 rerun: log reports the kept brief"  grep -q 'brief: ~/brief-test/' "${TDIR}/run2.log"
check "rerun: names kept"                     grep -q 'Roles: Тестовый Агент (claude-sonnet-5-5), Тестовый Доктор (' "${TDIR}/run2.log"

# --- run 3: a new value given still wins ------------------------------------------------------
clean_env NEUROOTDEL_TG_USER_ID=888000222 NEUROOTDEL_USER_NAME="Другой" NEUROOTDEL_AGENT_MODEL=claude-opus-4-8 \
    bash -c "$RUN" >"${TDIR}/run3.log" 2>&1 || true
check "run3: new owner id wins"               grep -qx 'OWNER_TG_ID="888000222"' "${SB}/lib/guard.conf"
check "run3: new gate owner wins"             grep -q 'fact-number-gate.py agent --owner 888000222"' "${SB}/home/.claude/settings.json"
check "run3: new name wins"                   grep -qx 'OWNER_NAME="Другой"' "${SB}/lib/guard.conf"
check "run3: new agent model wins"            grep -q -- '--model claude-opus-4-8 ' "${SB}/systemd/channel-jarvis.service"

# --- fresh server: defaults as before ---------------------------------------------------------
SB2="${TDIR}/sb2"
mkdir -p "${SB2}/lib" "${SB2}/home/.claude/hooks" "${SB2}/home/.claude-lab/jarvis/.claude" \
    "${SB2}/home/.claude-lab/shared" "${SB2}/systemd" "${SB2}/richard"
SB="$SB2" clean_env SB="$SB2" bash -c "$RUN" >"${TDIR}/fresh.log" 2>&1 || true
check "fresh: name default friend"            grep -qx 'OWNER_NAME="friend"' "${SB2}/lib/guard.conf"
check "fresh: no owner id"                    grep -qx 'OWNER_TG_ID=""' "${SB2}/lib/guard.conf"
check "fresh: default agent model"            grep -q -- '--model claude-opus-5-5 ' "${SB2}/systemd/channel-jarvis.service"
check "fresh: brief not given"                grep -q 'brief: не передан' "${TDIR}/fresh.log"
check "fresh: run completes under errexit"    grep -qx 'RUN-COMPLETE' "${TDIR}/fresh.log"
check "rerun: run completes under errexit"    grep -qx 'RUN-COMPLETE' "${TDIR}/run2.log"

# --- D4: install_skills leaves no template clone in TMPDIR ------------------------------------
read -r -d '' SKILLS <<'CHILD' || true
set -uo pipefail
export INSTALL_SH_SOURCED_FOR_TESTING=1
source "$REPO/install.sh"
set +e
apply_install_names new
AGENT_USER="$(id -un)"; AGENT_HOME="$SB/home"; INSTALLER_ROOT="$SB/inst"
git() {   # the template clone: a dir with a skills/ tree, no network
    if [[ "$1" == clone ]]; then mkdir -p "${!#}/skills/demo"; return 0; fi
    return 0
}
install_skill_bundle() { return 0; }
fix_owner() { :; }; link_skills_into_plugin() { :; }
step() { :; }; log() { :; }; warn() { :; }; err() { :; }; ok() { :; }
install_skills
CHILD
mkdir -p "${SB}/inst/skills" "${TDIR}/tmp4"
clean_env TMPDIR="${TDIR}/tmp4" bash -c "$SKILLS" >"${TDIR}/skills.log" 2>&1
check "D4: no tmp dir left after install_skills" test -z "$(ls -A "${TDIR}/tmp4")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
