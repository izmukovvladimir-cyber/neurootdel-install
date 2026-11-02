# Bash style

- Always: `set -euo pipefail` at the top of every script.
- Quote variables: `"$var"`, never bare `$var`.
- Prefer `[[ ]]` over `[ ]` for tests; supports regex and avoids word-splitting traps.
- Check files exist before reading: `[ -f "$path" ] || { echo "missing: $path" >&2; exit 1; }`.
- Use `mktemp` for temp files, never hard-coded `/tmp/foo`.
- Functions over nested if-chains. Lowercase names, snake_case.
- Errors and progress -> `stderr` (`>&2`). Data output -> `stdout`.
- Trap cleanup: `trap 'rm -f "$tmp"' EXIT`.
- Use `command -v` to test for binaries, not `which`.
- Never chain `cd DIR` with a relative-path read in the same call (`cd DIR; grep X file`, `cd DIR && sed ... file`). The permission checker can't resolve the file path through the `cd` and stalls on an unattended confirmation prompt. Give the full path directly instead: `grep X DIR/file`.
- Guard every `rm` whose path uses a variable: `rm -f "${VAR:?}"/sub/*.png`, not `rm -f "$VAR"/sub/*.png`. The permission checker flags the unguarded form as "possibly-empty variable path" and stalls on an unattended confirmation prompt even when `VAR` is a hardcoded literal assigned earlier in the same command. The `:?` costs nothing when the variable is already safe and is the actual safety net when it isn't.
