#!/usr/bin/env bats
# #1635 (student report):
#   T1 -- present / quick-reminders read the bot token from channel.env
#         (where the installer puts it), old gateway path as fallback
#   T2 -- sudoers has no apt wildcard; apt only via the root-owned wrapper
#   T3 -- workspace skills are linked into the plugin project

REPO="${BATS_TEST_DIRNAME}/.."
TOKEN="123456789:AAFakeTokenForTestsOnly_abcdefghijk"

setup() {
    TDIR="$(mktemp -d)"
    mkdir -p "$TDIR/bin" "$TDIR/home"
    # Stubs: crontab stores what it is fed, curl records its argv.
    cat > "$TDIR/bin/crontab" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-l" ]]; then cat "$TDIR/crontab" 2>/dev/null || true; exit 0; fi
cat > "$TDIR/crontab"
EOF
    cat > "$TDIR/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TDIR/curl.args"
EOF
    chmod +x "$TDIR/bin/crontab" "$TDIR/bin/curl"
    cat > "$TDIR/channel.env" <<EOF
# comment
TELEGRAM_BOT_TOKEN=${TOKEN}
TELEGRAM_ALLOWED_USER_IDS=111222333,444555666
TELEGRAM_ALLOWED_CHAT_IDS=111222333
EOF
    echo "<html></html>" > "$TDIR/deck.html"
}

teardown() {
    rm -rf "$TDIR"
}

run_skill() {
    env -i PATH="$TDIR/bin:/usr/bin:/bin" HOME="$TDIR/home" \
        EDGELAB_CHANNEL_ENV="${CHANNEL_ENV_OVERRIDE:-$TDIR/channel.env}" "$@"
}

# --- T1: token location ----------------------------------------------------------

@test "T1 quick-reminders: cron line reads the token from channel.env, token not in crontab" {
    run run_skill bash "$REPO/skills/quick-reminders/scripts/create.sh" "tomorrow 9am" "stretch"
    [ "$status" -eq 0 ]
    grep -qF "sed -n 's/^TELEGRAM_BOT_TOKEN=//p' '$TDIR/channel.env'" "$TDIR/crontab"
    grep -qF 'chat_id=111222333' "$TDIR/crontab"
    run grep -qF "$TOKEN" "$TDIR/crontab"
    [ "$status" -ne 0 ]
}

@test "T1 quick-reminders: the cron token command yields the token" {
    run_skill bash "$REPO/skills/quick-reminders/scripts/create.sh" "tomorrow 9am" "x"
    cmd=$(sed -n 's/.*TOKEN=\$(\(.*\)) && curl.*/\1/p' "$TDIR/crontab")
    [ -n "$cmd" ]
    run sh -c "$cmd"
    [ "$output" = "$TOKEN" ]
}

@test "T1 quick-reminders: old gateway install still works (fallback path)" {
    mkdir -p "$TDIR/home/claude-gateway/secrets"
    echo "$TOKEN" > "$TDIR/home/claude-gateway/secrets/bot-token"
    echo '{"allowlist_user_ids":[777888999]}' > "$TDIR/home/claude-gateway/config.json"
    CHANNEL_ENV_OVERRIDE="$TDIR/missing.env" run run_skill bash "$REPO/skills/quick-reminders/scripts/create.sh" "tomorrow 9am" "x"
    [ "$status" -eq 0 ]
    grep -qF "< '$TDIR/home/claude-gateway/secrets/bot-token'" "$TDIR/crontab"
    grep -qF 'chat_id=777888999' "$TDIR/crontab"
}

@test "T1 quick-reminders: no token anywhere -> clear error, nothing scheduled" {
    CHANNEL_ENV_OVERRIDE="$TDIR/missing.env" run run_skill bash "$REPO/skills/quick-reminders/scripts/create.sh" "tomorrow 9am" "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no bot token found"* ]]
    [ ! -f "$TDIR/crontab" ]
}

@test "T1 present: send.sh posts with the channel.env token to the owner id" {
    run run_skill bash "$REPO/skills/present/scripts/send.sh" "$TDIR/deck.html"
    [ "$status" -eq 0 ]
    grep -qF "chat_id=111222333" "$TDIR/curl.args"
    grep -qF "https://api.telegram.org/bot${TOKEN}/sendDocument" "$TDIR/curl.args"
}

@test "T1 present: PRESENT_CHAT_ID still overrides the owner id" {
    run run_skill PRESENT_CHAT_ID=999 bash "$REPO/skills/present/scripts/send.sh" "$TDIR/deck.html"
    [ "$status" -eq 0 ]
    grep -qF "chat_id=999" "$TDIR/curl.args"
}

@test "T1 both skills ship the same tg-target.sh" {
    cmp "$REPO/skills/present/scripts/tg-target.sh" "$REPO/skills/quick-reminders/scripts/tg-target.sh"
}

@test "T1 no skill doc reads the token only from the old gateway path" {
    run grep -rn 'cat.*claude-gateway/secrets/bot-token' "$REPO/skills"
    [ "$status" -ne 0 ]
}

# --- T2: sudoers + apt wrapper -------------------------------------------------

wrapper_with_stub() {
    # The wrapper calls /usr/bin/apt-get by absolute path; tests swap in a stub.
    cat > "$TDIR/bin/apt-get" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TDIR/apt.args"
EOF
    chmod +x "$TDIR/bin/apt-get"
    sed "s#/usr/bin/apt-get#$TDIR/bin/apt-get#g" "$REPO/templates/agent-apt-install.sh" > "$TDIR/wrapper"
    chmod +x "$TDIR/wrapper"
}

@test "T2 wrapper rejects apt options and non-package arguments" {
    wrapper_with_stub
    local bad
    for bad in "-o" "--option" "-oAPT::Update::Pre-Invoke::=id" "APT::Update::Pre-Invoke::=id" \
               "./evil.deb" "/tmp/evil.deb" "foo=1.0" "foo;id" 'foo$(id)' "Foo" "foo:amd64" ""; do
        run "$TDIR/wrapper" install curl "$bad"
        [ "$status" -eq 2 ] || { echo "accepted: '$bad'"; return 1; }
    done
    [ ! -f "$TDIR/apt.args" ]
}

@test "T2 wrapper rejects other subcommands and update with arguments" {
    wrapper_with_stub
    run "$TDIR/wrapper" remove curl;          [ "$status" -eq 2 ]
    run "$TDIR/wrapper" update -o X=y;        [ "$status" -eq 2 ]
    run "$TDIR/wrapper" install;              [ "$status" -eq 2 ]
    run "$TDIR/wrapper";                      [ "$status" -eq 2 ]
    [ ! -f "$TDIR/apt.args" ]
}

@test "T2 wrapper accepts plain package names and passes them after --" {
    wrapper_with_stub
    run "$TDIR/wrapper" install python3-venv libc6 g++ docker.io
    [ "$status" -eq 0 ]
    [ "$(tr '\n' ' ' < "$TDIR/apt.args")" = "install -y --no-install-recommends -- python3-venv libc6 g++ docker.io " ]
    run "$TDIR/wrapper" update
    [ "$status" -eq 0 ]
    [ "$(cat "$TDIR/apt.args")" = "update" ]
}

@test "T2 sudoers: no apt/apt-get rule, only the wrapper" {
    export INSTALL_SH_SOURCED_FOR_TESTING=1
    # shellcheck disable=SC1091
    source "$REPO/install.sh"
    apply_install_names legacy
    render_sudoers > "$TDIR/sudoers"
    run grep -E '/usr/bin/apt(-get)?([ ,]|$)' "$TDIR/sudoers"
    [ "$status" -eq 1 ]
    grep -qE '^Cmnd_Alias EDGELAB_APT = /usr/local/sbin/edgelab-apt-install$' "$TDIR/sudoers"
    grep -qE '^edgelab ALL=\(root\) NOPASSWD: EDGELAB_SYSTEMCTL, EDGELAB_JOURNAL, EDGELAB_APT$' "$TDIR/sudoers"
}

@test "T2 sudoers: generated file passes visudo -cf" {
    local visudo
    visudo=$(command -v visudo || ls /usr/sbin/visudo 2>/dev/null || true)
    [ -n "$visudo" ] || skip "visudo not installed"
    export INSTALL_SH_SOURCED_FOR_TESTING=1
    # shellcheck disable=SC1091
    source "$REPO/install.sh"
    render_sudoers > "$TDIR/sudoers"
    run "$visudo" -cf "$TDIR/sudoers"
    [ "$status" -eq 0 ]
}

# --- T3: skills attached to the plugin session ------------------------------------

@test "T3 link_skills_into_plugin: symlink created, real dir left alone" {
    export INSTALL_SH_SOURCED_FOR_TESTING=1
    # shellcheck disable=SC1091
    source "$REPO/install.sh"
    # Only `install -d ... <dir>` is called; ownership is not testable unprivileged.
    eval 'install() { mkdir -p "${@: -1}"; }'
    eval 'warn() { echo "WARN $*"; }; log() { :; }'
    mkdir -p "$TDIR/ws/skills/present" "$TDIR/plugin-root/.claude"
    run link_skills_into_plugin "$TDIR/ws/skills" "$TDIR/plugin-root"
    [ "$status" -eq 0 ]
    [ -L "$TDIR/plugin-root/.claude/skills" ]
    [ -d "$TDIR/plugin-root/.claude/skills/present" ]

    rm "$TDIR/plugin-root/.claude/skills"; mkdir "$TDIR/plugin-root/.claude/skills"
    run link_skills_into_plugin "$TDIR/ws/skills" "$TDIR/plugin-root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"real directory"* ]]
    [ ! -L "$TDIR/plugin-root/.claude/skills" ]
}

@test "1635: quick-reminders accepts the time forms SKILL.md advertises" {
    script="$BATS_TEST_DIRNAME/../skills/quick-reminders/scripts/create.sh"
    expr=$(grep -o "sed -E '[^']*'" "$script" | head -1)
    [ -n "$expr" ]
    for t in "in 10m" "in 2h" "in 3d" "in 2 minutes" "tomorrow 9am"; do
        n=$(printf '%s' "$t" | eval "$expr")
        date -d "$n" +%s >/dev/null
    done
}
