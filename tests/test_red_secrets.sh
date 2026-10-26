#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals read by sourced install.sh functions
# Tests for the RED secrets rule and its outbound guard hook, no root needed:
#   fresh install writes the rule block, the guard script and the hook; an old
#   install gets them added once (owner text and other hooks kept, backups made);
#   a re-run adds nothing; the guard blocks a password and lets plain talk through.
# Run: bash tests/test_red_secrets.sh
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
count_is() { [[ "$(grep -cF -- "$2" "$1")" -eq "$3" ]]; }
hook_count() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))).count("secret-outbound-guard"))' "$1"; }
guard_rc() {
    printf '{"tool_name":"mcp__dashi-channel__reply","tool_input":{"chat_id":"1","text":"%s"}}' "$2" \
        | python3 "$1" 2>/dev/null; echo $?
}

FAKE_HOME="${TDIR}/home"
mkdir -p "$FAKE_HOME"
ME="$(id -un)"
cp "${REPO}/install.sh" "${TDIR}/install.sh"

export INSTALL_SH_SOURCED_FOR_TESTING=1
export NEUROOTDEL_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${TDIR}/install.sh"
set +e    # the checks below report failures themselves
AGENT_HOME="$FAKE_HOME"
AGENT_USER="$ME"
fix_owner() { :; }

OPERATOR_NAME="Tester"
TG_USER_ID="42"
OPERATOR_LANGUAGE="ru"
OPERATOR_TIMEZONE="UTC+3"

GMD="${FAKE_HOME}/.claude/CLAUDE.md"
SJ="${FAKE_HOME}/.claude/settings.json"
GUARD="${FAKE_HOME}/.claude/hooks/secret-outbound-guard.py"
SRC="${REPO}/templates/RED-SECRETS-RULE.md"
BEGIN='<!-- red-secrets-rule:begin -->'

# --- sources: nothing private leaks into the public installer ------------------
for f in "$SRC" "${REPO}/templates/secret-outbound-guard.py"; do
    check "source: $(basename "$f") exists"        test -s "$f"
    check "source: $(basename "$f") no private"    bash -c "! grep -qE '/home/|edgelab|Владимир|[0-9]{6,}|t\\.me/|@[A-Za-z_]{4,}' '$f'"
done

# --- fresh install ---------------------------------------------------------------
setup_global_claude >/dev/null 2>&1
check "fresh: rule block once"            count_is "$GMD" "$BEGIN" 1
check "fresh: guard installed"            test -x "$GUARD"
check "fresh: hook once"                  test "$(hook_count "$SJ")" -eq 1
check "fresh: other settings kept"        grep -qF 'CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$SJ"

# --- re-run adds nothing -----------------------------------------------------------
setup_global_claude >/dev/null 2>&1
check "rerun: rule block still once"      count_is "$GMD" "$BEGIN" 1
check "rerun: hook still once"            test "$(hook_count "$SJ")" -eq 1

# --- old install: owner text and own hook, no rule ---------------------------------
rm -rf "${FAKE_HOME:?}/.claude"
mkdir -p "${FAKE_HOME}/.claude"
printf '# Owner rules\nmy line without newline' > "$GMD"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"mine"}]}]}}\n' > "$SJ"
setup_global_claude >/dev/null 2>&1
check "old: owner text kept"              grep -qxF 'my line without newline' "$GMD"
check "old: rule block appended"          count_is "$GMD" "$BEGIN" 1
check "old: CLAUDE.md backup made"        test "$(find "${FAKE_HOME}/.claude" -maxdepth 1 -name 'CLAUDE.md.bak-*-red-secrets' | wc -l)" -eq 1
check "old: own hook kept"                grep -qF '"mine"' "$SJ"
check "old: guard hook added"             test "$(hook_count "$SJ")" -eq 1
check "old: settings backup made"         test -f "${SJ}.bak-install"

# --- broken settings: left untouched, install stops -----------------------------
BAD="${TDIR}/bad.json"
printf '{"hooks":{"PreToolUse":{}}}\n' > "$BAD"
ensure_secret_guard_hook "$BAD" "$GUARD" 2>/dev/null
check "bad: non-array PreToolUse fails"   test $? -ne 0
check "bad: file untouched"               grep -qxF '{"hooks":{"PreToolUse":{}}}' "$BAD"

# --- a guard hook on the wrong tools does not count as wired ---------------------
PART="${TDIR}/partial.json"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 /x/secret-outbound-guard.py"}]}]}}\n' > "$PART"
ensure_secret_guard_hook "$PART" "$GUARD" 2>/dev/null
check "partial: real hook added"          test "$(hook_count "$PART")" -eq 2
check "partial: Bash hook kept"           grep -qF '"Bash"' "$PART"

# --- full matcher but a stale or fake command still gets the real hook ---------------
M3='mcp__dashi-channel__reply|mcp__dashi-channel__edit_message|mcp__gbrain-swarm__notify'
for cmd in 'echo secret-outbound-guard' 'python3 /old/secret-outbound-guard.py'; do
    STALE="${TDIR}/stale.json"
    printf '{"hooks":{"PreToolUse":[{"matcher":"%s","hooks":[{"type":"command","command":"%s"}]}]}}\n' "$M3" "$cmd" > "$STALE"
    ensure_secret_guard_hook "$STALE" "$GUARD" 2>/dev/null
    check "stale: '$cmd' does not count"  grep -qF "\"python3 ${GUARD}\"" "$STALE"
done

# --- guard script: unchanged = no rewrite, changed = backup first ----------------
setup_global_claude >/dev/null 2>&1
check "script: same copy, no backup"      test "$(find "${FAKE_HOME}/.claude/hooks" -name '*.bak-*' | wc -l)" -eq 0
echo '# local edit' >> "$GUARD"
setup_global_claude >/dev/null 2>&1
check "script: changed copy backed up"    test "$(find "${FAKE_HOME}/.claude/hooks" -name '*.bak-*' | wc -l)" -eq 1
check "script: template restored"         cmp -s "${REPO}/templates/secret-outbound-guard.py" "$GUARD"

# --- the guard itself --------------------------------------------------------------
check "guard: password blocked"           test "$(guard_rc "$GUARD" 'root, пароль: Xk9#mm2pQ')" -eq 2
check "guard: bot token blocked"          test "$(guard_rc "$GUARD" "1234567890:AAH-abcdefghijklmnopqrstuvwxyz01234")" -eq 2
check "guard: lowercase latin blocked"    test "$(guard_rc "$GUARD" 'пароль: qwerty')" -eq 2
check "guard: lowercase token blocked"    test "$(guard_rc "$GUARD" 'token: abcdefghijklmnopqrstuvwxyz')" -eq 2
check "guard: hunter2 blocked"            test "$(guard_rc "$GUARD" 'password: hunter2')" -eq 2
check "guard: backticked blocked"         test "$(guard_rc "$GUARD" 'password: `qwerty`')" -eq 2
check "guard: key label blocked"          test "$(guard_rc "$GUARD" 'ключ: abcdefghijklmnopqrstuvwxyz')" -eq 2
check "guard: instruction passes"         test "$(guard_rc "$GUARD" 'пароль: сменить в панели')" -eq 0
check "guard: plain talk passes"         test "$(guard_rc "$GUARD" 'пароли передаём только решением владельца')" -eq 0

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
