#!/usr/bin/env bats
# Tests for install_skill_bundle helper in install.sh

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
    SRC_SKILL="${TDIR}/src/my-skill"
    DST_PARENT="${TDIR}/skills"
    mkdir -p "$SRC_SKILL"
    echo "test skill" > "${SRC_SKILL}/SKILL.md"
    echo "helper" > "${SRC_SKILL}/helper.sh"
}

teardown() {
    rm -rf "$TDIR"
}

@test "install_skill_bundle: fresh install copies skill into destination" {
    install_skill_bundle "$SRC_SKILL" "$DST_PARENT" "my-skill"
    [ -f "${DST_PARENT}/my-skill/SKILL.md" ]
    [ -f "${DST_PARENT}/my-skill/helper.sh" ]
    run cat "${DST_PARENT}/my-skill/SKILL.md"
    [ "$output" = "test skill" ]
}

@test "install_skill_bundle: existing skill is replaced atomically" {
    # Pre-populate the destination with stale content
    mkdir -p "${DST_PARENT}/my-skill"
    echo "old" > "${DST_PARENT}/my-skill/SKILL.md"
    echo "stale" > "${DST_PARENT}/my-skill/old-file.txt"

    install_skill_bundle "$SRC_SKILL" "$DST_PARENT" "my-skill"

    run cat "${DST_PARENT}/my-skill/SKILL.md"
    [ "$output" = "test skill" ]
    # stale file must be removed (rsync --delete via stage)
    [ ! -f "${DST_PARENT}/my-skill/old-file.txt" ]
}

@test "install_skill_bundle: missing source returns non-zero" {
    run install_skill_bundle "/no/such/src" "$DST_PARENT" "ghost"
    [ "$status" -ne 0 ]
}

# v3.0.0 dropped the global INSTALLED_SKILLS (install_skills keeps its own list). What the
# helper itself tracks now is its staging dir, in TMPDIRS for the EXIT cleanup.
@test "install_skill_bundle: staging dir is in TMPDIRS and gone after success" {
    TMPDIRS=()
    install_skill_bundle "$SRC_SKILL" "$DST_PARENT" "my-skill"
    [ "${#TMPDIRS[@]}" -eq 1 ]
    [ "${TMPDIRS[0]}" = "${DST_PARENT}/.my-skill.staging.$$" ]
    [ ! -e "${TMPDIRS[0]}" ]
    [ ! -e "${DST_PARENT}/my-skill.prev" ]
}

@test "install_skill_bundle: dst_parent is created if missing" {
    local nested="${TDIR}/a/b/c/skills"
    install_skill_bundle "$SRC_SKILL" "$nested" "my-skill"
    [ -d "${nested}/my-skill" ]
}
