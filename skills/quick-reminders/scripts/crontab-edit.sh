# crontab-edit.sh -- sourced by the skill scripts, never run directly.
#
# Crontab edits that never wipe other lines: the current crontab is read first, and a read error
# (anything but "no crontab for <user>") writes nothing. The callers hold the lock
# ${QR_WAKE_DIR:-~/.claude-lab/shared/state/reminders}/.crontab.lock around every call.

# qr_crontab_read -- the current crontab on stdout; empty when the user has none; 1 on any other error.
qr_crontab_read() {
    local out err rc=0
    err=$(mktemp) || return 1
    out=$(crontab -l 2>"$err") || rc=$?
    if ((rc != 0)) && grep -qi 'no crontab for' "$err"; then
        rc=0
        out=""
    fi
    rm -f -- "${err:?}"
    ((rc == 0)) || return 1
    [[ -z "$out" ]] || printf '%s\n' "$out"
}

# qr_crontab_drop TAG -- removes the lines that contain TAG. Removing the last line leaves an empty
# crontab and is a success. 1 when the crontab could not be read (nothing written) or written.
qr_crontab_drop() {
    local cur
    cur=$(qr_crontab_read) || return 1
    { [[ -z "$cur" ]] || printf '%s\n' "$cur"; } | { grep -vF -- "$1" || [[ $? -eq 1 ]]; } | crontab -
}

# qr_crontab_add LINE -- appends LINE. 1 when the crontab could not be read (nothing written) or written.
qr_crontab_add() {
    local cur
    cur=$(qr_crontab_read) || return 1
    { [[ -z "$cur" ]] || printf '%s\n' "$cur"; printf '%s\n' "$1"; } | crontab -
}
