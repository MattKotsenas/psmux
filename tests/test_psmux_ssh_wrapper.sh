#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
wrapper="$repo/scripts/psmux-ssh.sh"
tmp=${TMPDIR:-/tmp}/psmux-ssh-wrapper-$$
mkdir -p "$tmp/bin"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cat >"$tmp/bin/stty" <<'EOF'
#!/bin/sh
if [ "${1-}" = "-g" ]; then
    printf '%s\n' 'saved-terminal-state'
else
    printf '%s\n' "$*" >>"$MOCK_STTY_LOG"
fi
EOF

cat >"$tmp/bin/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$MOCK_SSH_ARGS"
if [ "${MOCK_SSH_SIGNAL-}" = "INT" ]; then
    kill -INT "$PPID"
    sleep 5
fi
exit "${MOCK_SSH_STATUS:-0}"
EOF
chmod +x "$tmp/bin/stty" "$tmp/bin/ssh"

tty_file="$tmp/tty"
stty_log="$tmp/stty.log"
ssh_args="$tmp/ssh.args"
expected_hex='1b5b3f31303030681b5b3f31303032681b5b3f31303036681b5b3f313030366c1b5b3f313030326c1b5b3f313030306c'

run_wrapper() {
    : >"$tty_file"
    : >"$stty_log"
    : >"$ssh_args"
    MOCK_STTY_LOG="$stty_log" \
    MOCK_SSH_ARGS="$ssh_args" \
    MOCK_SSH_STATUS="${MOCK_SSH_STATUS:-0}" \
    MOCK_SSH_SIGNAL="${MOCK_SSH_SIGNAL-}" \
    PSMUX_WIN_CONFIG="$tmp/no-config" \
    PSMUX_SSH_TTY="$tty_file" \
    PSMUX_SSH_STTY="$tmp/bin/stty" \
    PSMUX_SSH_BIN="$tmp/bin/ssh" \
        sh "$wrapper" --socket project --session work -- -p 2222 user@host
}

assert_cleanup() {
    actual_hex=$(od -An -tx1 "$tty_file" | tr -d ' \n')
    [ "$actual_hex" = "$expected_hex" ] || {
        echo "FAIL: mouse cleanup bytes: $actual_hex" >&2
        exit 1
    }
    grep -Fx 'raw -echo -isig' "$stty_log" >/dev/null || {
        echo 'FAIL: raw terminal mode was not set' >&2
        exit 1
    }
    grep -Fx 'saved-terminal-state' "$stty_log" >/dev/null || {
        echo 'FAIL: saved terminal mode was not restored' >&2
        exit 1
    }
}

MOCK_SSH_STATUS=0
unset MOCK_SSH_SIGNAL
run_wrapper
assert_cleanup
grep -Fx -- '-T' "$ssh_args" >/dev/null
grep -Fx -- 'psmux -L project attach -t work' "$ssh_args" >/dev/null
echo 'PASS: normal exit restores terminal and uses the no-ConPTY SSH command'

MOCK_SSH_STATUS=23
set +e
run_wrapper
rc=$?
set -e
[ "$rc" -eq 23 ] || { echo "FAIL: SSH exit status was $rc, expected 23" >&2; exit 1; }
assert_cleanup
echo 'PASS: SSH failure preserves status and restores terminal'

MOCK_SSH_STATUS=0
MOCK_SSH_SIGNAL=INT
set +e
run_wrapper
rc=$?
set -e
[ "$rc" -eq 130 ] || { echo "FAIL: INT exit status was $rc, expected 130" >&2; exit 1; }
assert_cleanup
echo 'PASS: INT restores terminal exactly once'

config_file="$tmp/psmux-win.conf"
printf '%s\n' 'host=configured@windows' 'remote_psmux=C:/psmux/psmux.exe' >"$config_file"
: >"$tty_file"
: >"$stty_log"
: >"$ssh_args"
MOCK_STTY_LOG="$stty_log" \
MOCK_SSH_ARGS="$ssh_args" \
MOCK_SSH_STATUS=0 \
PSMUX_WIN_CONFIG="$config_file" \
PSMUX_SSH_TTY="$tty_file" \
PSMUX_SSH_STTY="$tmp/bin/stty" \
PSMUX_SSH_BIN="$tmp/bin/ssh" \
    sh "$wrapper" -L other -s session2
assert_cleanup
grep -Fx -- 'configured@windows' "$ssh_args" >/dev/null
grep -Fx -- 'C:/psmux/psmux.exe -L other attach -t session2' "$ssh_args" >/dev/null
echo 'PASS: installed-command config supplies host and remote executable defaults'
