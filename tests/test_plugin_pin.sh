#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329  # globals read by sourced fns, overrides
# Tests for checkout_plugin: every install gets the plugin at ONE pinned commit.
# Uses a local source repo instead of GitHub; no root, no network.
# Run: bash tests/test_plugin_pin.sh
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
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${REPO}/install.sh"
set +e
as_agent() { "$@"; }
log() { :; }
ok() { :; }

g() { git -c user.email=t@t -c user.name=t "$@"; }

SRC="${TDIR}/src"
g init -q "$SRC"
echo one > "${SRC}/f"; g -C "$SRC" add f; g -C "$SRC" commit -qm one
A=$(git -C "$SRC" rev-parse HEAD)
echo two > "${SRC}/f"; g -C "$SRC" commit -qam two
B=$(git -C "$SRC" rev-parse HEAD)
echo three > "${SRC}/f"; g -C "$SRC" commit -qam three   # main moves past the pins

ROOT="${TDIR}/plugin"
git init -q "$ROOT"
git -C "$ROOT" remote add origin "file://${SRC}"

head_is() { [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$1" ]]; }

check "default pin is a full commit id" bash -c '[[ "$1" =~ ^[0-9a-f]{40}$ ]]' _ "$PLUGIN_COMMIT_DEFAULT"
check "plugin_commit: default when no override" bash -c '[[ "$1" == "$2" ]]' _ "$(NEUROOTDEL_PLUGIN_COMMIT='' plugin_commit)" "$PLUGIN_COMMIT_DEFAULT"

NEUROOTDEL_PLUGIN_COMMIT="$A" checkout_plugin "$ROOT" >/dev/null 2>&1
check "fresh: HEAD is the pinned commit, not the newest" head_is "$A"
check "fresh: detached HEAD (no branch to pull)" bash -c '! git -C "$1" symbolic-ref -q HEAD' _ "$ROOT"

NEUROOTDEL_PLUGIN_COMMIT="$A" checkout_plugin "$ROOT" >/dev/null 2>&1
check "rerun at the pin: stays" head_is "$A"

NEUROOTDEL_PLUGIN_COMMIT="$B" checkout_plugin "$ROOT" >/dev/null 2>&1
check "new pin, clean checkout: moves to it" head_is "$B"

echo local-edit > "${ROOT}/f"
out=$(NEUROOTDEL_PLUGIN_COMMIT="$A" checkout_plugin "$ROOT" 2>&1)
check "local edits: checkout kept" head_is "$B"
check "local edits: edit not lost" grep -qx local-edit "${ROOT}/f"
check "local edits: warned" grep -q "local edits" <<<"$out"
git -C "$ROOT" checkout -q -- f

if ( NEUROOTDEL_PLUGIN_COMMIT="main" checkout_plugin "$ROOT" ) >/dev/null 2>&1; then
    check "branch name as pin is refused (exit)" false
else
    check "branch name as pin is refused (exit)" true
fi
check "refused pin leaves HEAD alone" head_is "$B"

if ( NEUROOTDEL_PLUGIN_COMMIT="0123456789012345678901234567890123456789" checkout_plugin "$ROOT" ) >/dev/null 2>&1; then
    check "unknown commit: install stops" false
else
    check "unknown commit: install stops" true
fi

FRESH="${TDIR}/fresh"
git init -q "$FRESH"; git -C "$FRESH" remote add origin "file://${SRC}"
NEUROOTDEL_PLUGIN_COMMIT="$A" checkout_plugin "$FRESH" >/dev/null 2>&1
check "empty repo with origin: pinned" bash -c '[[ "$(git -C "$1" rev-parse HEAD)" == "$2" ]]' _ "$FRESH" "$A"
check "install_jarvis uses checkout_plugin" grep -q '^    checkout_plugin "\$plugin_root"$' "${REPO}/install.sh"
check "no clone of a moving branch left" bash -c '! grep -q "clone --depth 1 --branch \"\$PLUGIN_REF\"" "$1"' _ "${REPO}/install.sh"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
