#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # globals read by sourced fns, test overrides
# Tests for the «Агент за вечер» activation step (--solo) of install.sh, no root needed.
# A fake activation server (python3 http.server on 127.0.0.1) answers like the real one:
# 200 + tar.gz for a good key, 403 + JSON message otherwise, plus hostile archives.
# Run: bash tests/test_azv_activation.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "${TDIR:?}"
}
trap cleanup EXIT

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

GOOD_KEY="AZV-GOOD-0000-0000-0001"
BOUND_KEY="AZV-BOUN-0000-0000-0002"
EVIL_KEY="AZV-EVIL-0000-0000-0003"
LINK_KEY="AZV-LINK-0000-0000-0004"

cat > "${TDIR}/server.py" <<'PY'
import io, json, sys, tarfile
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[1]

def tgz(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, kind, data in entries:
            info = tarfile.TarInfo(name)
            if kind == "link":
                info.type, info.linkname = tarfile.SYMTYPE, data
                tar.addfile(info)
            else:
                raw = data.encode()
                info.size = len(raw)
                tar.addfile(info, io.BytesIO(raw))
    return buf.getvalue()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        with open(LOG, "ab") as f:
            f.write(body + b"\n")
        key = json.loads(body).get("key", "")
        if key == "AZV-GOOD-0000-0000-0001":
            self.reply(200, tgz([("soul/CLAUDE.md", "f", "# Душа\n"),
                                 ("skills/task-01.md", "f", "задача\n")]), "application/gzip")
        elif key == "AZV-EVIL-0000-0000-0003":
            self.reply(200, tgz([("../escaped.md", "f", "x")]), "application/gzip")
        elif key == "AZV-LINK-0000-0000-0004":
            self.reply(200, tgz([("soul/x", "link", "/etc/passwd")]), "application/gzip")
        else:
            msg = {"error": "bound_other",
                   "message": "Ключ привязан к другому серверу. Переезд делает куратор."}
            self.reply(403, json.dumps(msg, ensure_ascii=False).encode(), "application/json")

    def reply(self, code, data, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY

REQ_LOG="${TDIR}/requests.log"
: > "$REQ_LOG"
exec 3< <(python3 "${TDIR}/server.py" "$REQ_LOG")
SERVER_PID=$!
read -r PORT <&3

printf 'abc123machineid\n' > "${TDIR}/machine-id"
export NEUROOTDEL_AZV_URL="http://127.0.0.1:${PORT}/agent/activate"
export NEUROOTDEL_AZV_MACHINE_ID_FILE="${TDIR}/machine-id"
export NEUROOTDEL_NONINTERACTIVE=1
export INSTALL_SH_SOURCED_FOR_TESTING=1

# run_step <out-prefix> <key> <fn...>: runs fns in a subshell with install.sh sourced.
run_step() {
    local out=$1 key=$2; shift 2
    local rc=0
    (
        export NEUROOTDEL_AZV_KEY="$key"
        export NEUROOTDEL_AZV_STAGE_DIR="${TDIR}/${out}/stage"
        export NEUROOTDEL_AZV_AGENT_DIR="${TDIR}/${out}/agent/azv"
        mkdir -p "${TDIR}/${out}"
        # shellcheck disable=SC1091
        source "${REPO}/install.sh"
        fix_owner() { :; }   # chown needs root; ownership is not under test here
        as_agent() { "$@"; }  # sudo -u needs root; the user switch is not under test here
        for fn in "$@"; do
            "$fn"
        done
    ) > "${TDIR}/${out}.out" 2> "${TDIR}/${out}.err" || rc=$?
    echo "$rc"
}
requests() { wc -l < "$REQ_LOG"; }

# --- machine hash: sha256(machine-id + salt), whitespace stripped
expected=$(printf '%s%s' "abc123machineid" "agent-za-vecher-v1" | sha256sum | cut -d' ' -f1)
got=$(
    # shellcheck disable=SC1091
    source "${REPO}/install.sh"; azv_machine_hash
)
check "machine_hash = sha256(machine-id + salt)" test "$got" = "$expected"

# --- good key: archive unpacked to stage, then copied into the agent dir
rc=$(run_step good "$GOOD_KEY" azv_activate azv_install_payload)
check "good key: exit 0" test "$rc" = 0
check "good key: stage has soul/CLAUDE.md" test -f "${TDIR}/good/stage/soul/CLAUDE.md"
check "good key: agent dir has skills/task-01.md" test -f "${TDIR}/good/agent/azv/skills/task-01.md"
check "good key: stage dir is 0700" test "$(stat -c %a "${TDIR}/good/stage")" = 700
# payload is written as the agent user (mkdir + tar), never by root directly
(
    # shellcheck disable=SC1091
    source "${REPO}/install.sh"
    AZV_STAGE_DIR="${TDIR}/good/stage"
    AZV_AGENT_DIR="${TDIR}/via/azv"
    as_agent() { echo "AS_AGENT $1" >> "${TDIR}/via.log"; "$@"; }
    azv_install_payload
) >/dev/null 2>&1 || true
check "payload: dir made as agent"   grep -qx "AS_AGENT mkdir" "${TDIR}/via.log"
check "payload: files unpacked as agent" grep -qx "AS_AGENT tar" "${TDIR}/via.log"
check "payload: files arrived"       test -f "${TDIR}/via/azv/soul/CLAUDE.md"
check "request carries key and machine_hash" \
    grep -qF "{\"key\":\"${GOOD_KEY}\",\"machine_hash\":\"${expected}\"}" "$REQ_LOG"

# --- refused key: server message shown, install stops
before=$(requests)
rc=$(run_step bound "$BOUND_KEY" azv_activate)
check "refused key: non-zero exit" test "$rc" != 0
check "refused key: server message shown" grep -qF "другому серверу" "${TDIR}/bound.err"
check "refused key: code shown" grep -qF "403" "${TDIR}/bound.err"
check "refused key: nothing unpacked" test ! -e "${TDIR}/bound/stage"
check "refused key: one request" test "$(requests)" = "$((before + 1))"

# --- no key: clear message, no request at all
before=$(requests)
rc=$(run_step nokey "" azv_activate)
check "no key: non-zero exit" test "$rc" != 0
check "no key: says key is required" grep -qF "Без личного ключа" "${TDIR}/nokey.err"
check "no key: server not called" test "$(requests)" = "$before"

# --- malformed key: refused locally
rc=$(run_step badkey 'AZV"; rm -rf /' azv_activate)
check "malformed key: non-zero exit" test "$rc" != 0
check "malformed key: says format" grep -qF "AZV-XXXX" "${TDIR}/badkey.err"
check "malformed key: server not called" test "$(requests)" = "$before"

# --- path traversal and symlink archives are refused
rc=$(run_step evil "$EVIL_KEY" azv_activate)
check "traversal archive: refused" test "$rc" != 0
check "traversal archive: nothing escaped" test ! -e "${TDIR}/evil/escaped.md"
check "traversal archive: says damaged" grep -qF "повреждён" "${TDIR}/evil.err"
rc=$(run_step link "$LINK_KEY" azv_activate)
check "symlink archive: refused" test "$rc" != 0
check "symlink archive: nothing unpacked" test ! -e "${TDIR}/link/stage"

# --- server down
rc=$(NEUROOTDEL_AZV_URL="http://127.0.0.1:1/agent/activate" run_step down "$GOOD_KEY" azv_activate)
check "server down: non-zero exit" test "$rc" != 0
check "server down: says not answering" grep -qF "не отвечает" "${TDIR}/down.err"

# --- missing machine-id
rc=$(NEUROOTDEL_AZV_MACHINE_ID_FILE="${TDIR}/nope" run_step nomid "$GOOD_KEY" azv_activate)
check "no machine-id: non-zero exit" test "$rc" != 0

# --- main(): without --solo the old order is untouched, with --solo the key comes first
STEPS=(banner preflight install_apt_deps require_step_packages install_node ensure_agent_user
       check_node_for_agent install_claude_cli install_bun collect_inputs install_jarvis
       install_richard setup_global_claude install_skills install_superpowers install_sudoers
       install_memory_cron enable_services final_instructions azv_activate azv_install_payload)
trace_main() {
    (
        # shellcheck disable=SC1091
        source "${REPO}/install.sh"
        for fn in "${STEPS[@]}"; do
            eval "${fn}() { echo ${fn}; }"
        done
        main "$@"
    )
}
plain=$(trace_main | tr '\n' ' ')
solo=$(trace_main --solo | tr '\n' ' ')
expected_plain="banner preflight install_apt_deps require_step_packages install_node ensure_agent_user check_node_for_agent install_claude_cli install_bun collect_inputs install_jarvis install_richard setup_global_claude install_skills install_superpowers install_sudoers install_memory_cron enable_services final_instructions "
check "no --solo: old step order unchanged" test "$plain" = "$expected_plain"
check "no --solo: activation never runs" test "${plain/azv_/}" = "$plain"
check "--solo: activation right after preflight" \
    test "${solo:0:40}" = "banner preflight azv_activate install_ap"
check "--solo: payload installed after skills" \
    grep -qF "install_skills azv_install_payload install_superpowers" <<<"$solo"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
