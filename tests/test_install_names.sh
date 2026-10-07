#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals read by sourced install.sh functions
# Tests for the install names choice of install.sh, no root needed:
#   clean server -> neurootdel + new paths; a server that already carries an
#   edgelab install (user, ~/.claude, sudoers or /etc/dashi-plugin) -> edgelab
#   + old paths; old EDGELAB_* env names still accepted.
# Run: bash tests/test_install_names.sh
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

export INSTALL_SH_SOURCED_FOR_TESTING=1
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e    # the checks below report failures themselves

# fake_root <name> -- an empty filesystem prefix with /etc/passwd (root only).
fake_root() {
    local r="${TDIR}/$1"
    mkdir -p "${r}/etc/sudoers.d" "${r}/home"
    printf 'root:x:0:0:root:/root:/bin/bash\n' > "${r}/etc/passwd"
    printf '%s' "$r"
}

# --- clean server: new names ----------------------------------------------------
R=$(fake_root clean)
check "clean: detect new"            test "$(detect_install_names "$R")" = new
select_install_names "$R"
check "clean: user neurootdel"       test "$AGENT_USER" = neurootdel
check "clean: home"                  test "$AGENT_HOME" = /home/neurootdel
check "clean: config dir"            test "$JARVIS_ENV_DIR" = /etc/vladimir-plugin/jarvis
check "clean: start script"          test "$CHANNEL_START_BIN" = /usr/local/lib/neurootdel/channel-start.sh
check "clean: confirm script"        test "$CHANNEL_CONFIRM_BIN" = /usr/local/lib/neurootdel/channel-confirm.sh
check "clean: apt wrapper"           test "$APT_WRAPPER_BIN" = /usr/local/sbin/neurootdel-apt-install
check "clean: sudoers"               test "$SUDOERS_FILE" = /etc/sudoers.d/neurootdel-agents
check "clean: backups"               test "$LEGACY_BACKUP_ROOT" = /var/backups/neurootdel-install
check "clean: state"                 test "$INSTALL_STATE_ROOT" = /var/lib/neurootdel-install
check "clean: tag"                   test "$INSTALL_TAG" = neurootdel-install

# --- edgelab user only (no files yet): stays edgelab, no second user -------------
R=$(fake_root useronly)
printf 'edgelab:x:1000:1000::/home/edgelab:/bin/bash\n' >> "${R}/etc/passwd"
check "edgelab user: detect legacy"  test "$(detect_install_names "$R")" = legacy
select_install_names "$R"
check "legacy: user edgelab"         test "$AGENT_USER" = edgelab
check "legacy: home"                 test "$AGENT_HOME" = /home/edgelab
check "legacy: config dir"           test "$JARVIS_ENV_DIR" = /etc/dashi-plugin/jarvis
check "legacy: start script"         test "$CHANNEL_START_BIN" = /usr/local/lib/edgelab/channel-start.sh
check "legacy: apt wrapper"          test "$APT_WRAPPER_BIN" = /usr/local/sbin/edgelab-apt-install
check "legacy: sudoers"              test "$SUDOERS_FILE" = /etc/sudoers.d/edgelab-agents
check "legacy: backups"              test "$LEGACY_BACKUP_ROOT" = /var/backups/edgelab-install
check "legacy: state"                test "$INSTALL_STATE_ROOT" = /var/lib/edgelab-install

# --- each old-install marker alone means legacy ----------------------------------
R=$(fake_root claudedir); mkdir -p "${R}/home/edgelab/.claude"
check "home .claude only: legacy"      test "$(detect_install_names "$R")" = legacy
R=$(fake_root sudoers); : > "${R}/etc/sudoers.d/edgelab-agents"
check "sudoers only: legacy"         test "$(detect_install_names "$R")" = legacy
R=$(fake_root dashi); mkdir -p "${R}/etc/dashi-plugin/jarvis"
check "/etc/dashi-plugin only: legacy" test "$(detect_install_names "$R")" = legacy

# --- look-alike user names do not count -------------------------------------------
R=$(fake_root lookalike)
printf 'edgelab2:x:1001:1001::/home/edgelab2:/bin/bash\nxedgelab:x:1002:1002::/x:/bin/sh\n' >> "${R}/etc/passwd"
check "edgelab2/xedgelab: new"       test "$(detect_install_names "$R")" = new

# --- a neurootdel install wins over a leftover edgelab user ----------------------
R=$(fake_root both)
printf 'edgelab:x:1000:1000::/home/edgelab:/bin/bash\n' >> "${R}/etc/passwd"
mkdir -p "${R}/home/neurootdel/.claude"
check "neurootdel ~/.claude + edgelab user: new" test "$(detect_install_names "$R")" = new
R=$(fake_root both2); : > "${R}/etc/sudoers.d/neurootdel-agents"; : > "${R}/etc/sudoers.d/edgelab-agents"
check "both sudoers: live edgelab wins" test "$(detect_install_names "$R")" = legacy
R=$(fake_root both3)
printf 'edgelab:x:1000:1000::/home/edgelab:/bin/bash\n' >> "${R}/etc/passwd"
mkdir -p "${R}/home/edgelab/.claude" "${R}/etc/dashi-plugin/jarvis" "${R}/home/neurootdel/.claude"
check "full edgelab install + neurootdel leftover: legacy" test "$(detect_install_names "$R")" = legacy

check "apply: bad mode refused"      bash -c "source '${REPO}/install.sh'; ! apply_install_names other"

# --- sudoers rendered per mode ------------------------------------------------------
apply_install_names new
render_sudoers > "${TDIR}/sudoers.new"
check "sudoers new: user line"       grep -qE '^neurootdel ALL=\(root\) NOPASSWD: NEUROOTDEL_SYSTEMCTL, NEUROOTDEL_JOURNAL, NEUROOTDEL_APT$' "${TDIR}/sudoers.new"
check "sudoers new: wrapper"         grep -qE '^Cmnd_Alias NEUROOTDEL_APT = /usr/local/sbin/neurootdel-apt-install$' "${TDIR}/sudoers.new"
check "sudoers new: no edgelab"      bash -c "! grep -qi edgelab '${TDIR}/sudoers.new'"
apply_install_names legacy
render_sudoers > "${TDIR}/sudoers.old"
check "sudoers legacy: user line"    grep -qE '^edgelab ALL=\(root\) NOPASSWD: EDGELAB_SYSTEMCTL, EDGELAB_JOURNAL, EDGELAB_APT$' "${TDIR}/sudoers.old"
VISUDO=$(command -v visudo || ls /usr/sbin/visudo 2>/dev/null || true)
if [[ -n "$VISUDO" ]]; then
    check "sudoers new: visudo -cf"  "$VISUDO" -cf "${TDIR}/sudoers.new"
fi

# --- old EDGELAB_* env names ------------------------------------------------------------
OUT=$(EDGELAB_AZV_KEY=old-key bash -c "INSTALL_SH_SOURCED_FOR_TESTING=1 source '${REPO}/install.sh'; printf '%s' \"\$NEUROOTDEL_AZV_KEY\"")
check "env: EDGELAB_AZV_KEY fills NEUROOTDEL_AZV_KEY" test "$OUT" = old-key
OUT=$(EDGELAB_AZV_KEY=old NEUROOTDEL_AZV_KEY=new bash -c "INSTALL_SH_SOURCED_FOR_TESTING=1 source '${REPO}/install.sh'; printf '%s' \"\$NEUROOTDEL_AZV_KEY\"")
check "env: NEUROOTDEL_ wins over EDGELAB_" test "$OUT" = new
OUT=$(EDGELAB_AZV_STAGE_DIR=/tmp/old-stage bash -c "INSTALL_SH_SOURCED_FOR_TESTING=1 source '${REPO}/install.sh'; printf '%s' \"\$AZV_STAGE_DIR\"")
check "env: old stage dir override honoured" test "$OUT" = /tmp/old-stage
OUT=$(env -u NEUROOTDEL_X EDGELAB_X=v bash -c "INSTALL_SH_SOURCED_FOR_TESTING=1 source '${REPO}/install.sh'; env_value X")
check "env_value: falls back to EDGELAB_" test "$OUT" = v

# --- skills find channel.env on both layouts -------------------------------------------
# shellcheck disable=SC1091
OUT=$(NEUROOTDEL_CHANNEL_ENV="${TDIR}/c.env" bash -c "printf 'TELEGRAM_BOT_TOKEN=1:a\nTELEGRAM_ALLOWED_USER_IDS=7\n' > '${TDIR}/c.env'; source '${REPO}/skills/present/scripts/tg-target.sh'; tg_resolve_target >/dev/null 2>&1; printf '%s' \"\$TG_TOKEN_FILE\"")
check "skills: NEUROOTDEL_CHANNEL_ENV used" test "$OUT" = "${TDIR}/c.env"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
