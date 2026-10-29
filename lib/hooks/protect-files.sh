#!/usr/bin/env bash
# protect-files.sh -- PreToolUse hook for Edit/Write/MultiEdit (installed by neurootdel-install).
# Blocks edits to secrets, credentials and infra-critical
# files. Exit 2 = block + feedback. Stop: delete the "Edit|Write|MultiEdit" entry from settings.json.
set -euo pipefail

# Install paths from guard.conf one level up; unreadable conf = the defaults below still apply.
CONF="${NEUROOTDEL_GUARD_CONF:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/guard.conf}"
CONFIG_ROOT=/etc/vladimir-plugin
LIB_DIR=/usr/local/lib/neurootdel
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

# Fail closed: an unreadable payload or a path that cannot be canonicalized blocks the write.
if ! file=$(jq -er 'if type == "object" then (.tool_input.file_path // .tool_input.path // "") else error("no payload") end' 2>/dev/null); then
  echo "BLOCKED by protect-files.sh: cannot parse the hook payload." >&2
  exit 2
fi
[ -z "$file" ] && exit 0
# Check the canonical path too: ../ segments and symlinks must not dodge a pattern.
if ! canon=$(realpath -m -- "$file" 2>/dev/null); then
  echo "BLOCKED by protect-files.sh: cannot resolve '$file'." >&2
  exit 2
fi

protected_patterns=(
  '\.env($|\.)'
  '\.credentials\.json$'
  '\.pem$'
  '\.key$'
  '/etc/sudoers'
  '/etc/systemd/system/'
  "${CONFIG_ROOT}/"
  '/opt/richard/'
  "${LIB_DIR}/"
  '~/.ssh/'
  '/\.ssh/'
  'authorized_keys$'
  'id_rsa($|\.)'
  'id_ed25519($|\.)'
)

for pattern in "${protected_patterns[@]}"; do
  if printf '%s\n%s\n' "$file" "$canon" | grep -qE "$pattern"; then
    echo "BLOCKED by protect-files.sh: '$file' matches protected pattern '$pattern'." >&2
    echo "These files require the owner's decision and a shell change, not Edit/Write." >&2
    exit 2
  fi
done

exit 0
