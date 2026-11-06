#!/usr/bin/env bats
# Tests for the template helper in install.sh. v3.0.0 (b6e4a3c) replaced fill_template with
# render_template SRC DST KEY VAL... (same contract: literal {{KEY}} replace via python3);
# the cases below are the same, aimed at the helper the installer uses today.

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
    SRC="${TDIR}/src.tpl"
    DST="${TDIR}/dst.out"
}

teardown() {
    rm -rf "$TDIR"
}

@test "render_template: single placeholder substitution" {
    echo "Hello {{NAME}}!" > "$SRC"
    render_template "$SRC" "$DST" "NAME" "Dashi"
    run cat "$DST"
    [ "$output" = "Hello Dashi!" ]
}

@test "render_template: multiple placeholders" {
    printf "agent={{AGENT}} user={{USER}} tz={{TZ}}\n" > "$SRC"
    render_template "$SRC" "$DST" "AGENT" "jarvis" "USER" "boss" "TZ" "UTC"
    run cat "$DST"
    [[ "$output" = *"agent=jarvis"* ]]
    [[ "$output" = *"user=boss"* ]]
    [[ "$output" = *"tz=UTC"* ]]
}

@test "render_template: values with forward slashes are escaped for sed" {
    echo "path={{PATH}}" > "$SRC"
    render_template "$SRC" "$DST" "PATH" "/home/edgelab/.claude"
    run cat "$DST"
    [ "$output" = "path=/home/edgelab/.claude" ]
}

@test "render_template: values with ampersand are escaped" {
    echo "name={{BRAND}}" > "$SRC"
    render_template "$SRC" "$DST" "BRAND" "Foo & Bar"
    run cat "$DST"
    [ "$output" = "name=Foo & Bar" ]
}

@test "render_template: missing source file returns non-zero" {
    run render_template "/no/such/file.tpl" "$DST" "X" "y"
    [ "$status" -ne 0 ]
    [ "$status" -ne 127 ]   # 127 = no such function: that is not the helper refusing
    [ ! -e "$DST" ]
}

@test "render_template: unmatched placeholders are left as-is" {
    echo "hi {{NAME}} see {{LATER}}" > "$SRC"
    render_template "$SRC" "$DST" "NAME" "boss"
    run cat "$DST"
    [ "$output" = "hi boss see {{LATER}}" ]
}
