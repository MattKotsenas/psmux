#!/bin/sh
# Run on the macOS/Linux client. Uses a plain SSH channel instead of a remote
# ConPTY so Windows 10 cannot consume mouse registration or SGR input bytes.

set -eu

program=${0##*/}

config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
config_file=${PSMUX_WIN_CONFIG:-"$config_home/psmux-win/config"}
configured_host=
configured_psmux=
if [ -r "$config_file" ]; then
    while IFS='=' read -r key value; do
        case $key in
            host) configured_host=$value ;;
            remote_psmux) configured_psmux=$value ;;
        esac
    done <"$config_file"
fi

usage() {
    cat <<EOF
Usage: $program [--socket NAME] [--session NAME] [--psmux PATH] [--] [ssh-options] [user@]host

Examples:
  $program --session work -- user@windows-host
  $program --socket project --session work -- user@windows-host
  $program --session work -- -p 2222 user@windows-host

The remote psmux executable must be on PATH. Do not pass ssh -t/-tt: this
wrapper deliberately uses ssh -T to bypass Windows 10 ConPTY.

When installed as psmux-win, host and remote executable defaults are read from:
  $config_file
EOF
}

session=
socket=
remote_psmux=${configured_psmux:-psmux}
while [ "$#" -gt 0 ]; do
    case $1 in
        --socket|-L)
            [ "$#" -ge 2 ] || { echo "psmux-ssh: --socket requires a value" >&2; exit 2; }
            socket=$2
            shift 2
            ;;
        --session|-s|-t)
            [ "$#" -ge 2 ] || { echo "psmux-ssh: --session requires a value" >&2; exit 2; }
            session=$2
            shift 2
            ;;
        --psmux)
            [ "$#" -ge 2 ] || { echo "psmux-ssh: --psmux requires a value" >&2; exit 2; }
            remote_psmux=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -eq 0 ] && [ -n "$configured_host" ]; then
    set -- "$configured_host"
fi
[ "$#" -gt 0 ] || { usage >&2; exit 2; }

case $session in
    *[!A-Za-z0-9_.-]*)
        echo "psmux-ssh: session names may contain only letters, digits, '.', '_', and '-'" >&2
        exit 2
        ;;
esac

case $socket in
    *[!A-Za-z0-9_.-]*)
        echo "psmux-ssh: socket names may contain only letters, digits, '.', '_', and '-'" >&2
        exit 2
        ;;
esac

case $remote_psmux in
    *[!A-Za-z0-9_./:\\-]*)
        echo "psmux-ssh: --psmux must be a simple executable name or path without spaces" >&2
        exit 2
        ;;
esac

for arg in "$@"; do
    case $arg in
        -t|-tt|-T)
            echo "psmux-ssh: do not pass $arg; the wrapper requires ssh -T" >&2
            exit 2
            ;;
    esac
done

tty_path=${PSMUX_SSH_TTY:-/dev/tty}
stty_bin=${PSMUX_SSH_STTY:-stty}
ssh_bin=${PSMUX_SSH_BIN:-ssh}

if [ ! -r "$tty_path" ] || [ ! -w "$tty_path" ]; then
    echo "psmux-ssh: $tty_path is not a usable terminal" >&2
    exit 1
fi

saved_stty=$("$stty_bin" -g <"$tty_path") || {
    echo "psmux-ssh: could not read local terminal state" >&2
    exit 1
}

# Keep local terminal control bytes out of the SSH stream.  Give the
# backgrounded ssh process an explicit /dev/tty input FD: POSIX shells may
# otherwise replace an asynchronous command's stdin with /dev/null when job
# control is unavailable, making the remote psmux client exit immediately.
exec 3>"$tty_path"
exec 4<"$tty_path"
mouse_on='\033[?1000h\033[?1002h\033[?1006h'
mouse_off='\033[?1006l\033[?1002l\033[?1000l'
cleaned=0
child_pid=

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$cleaned" -eq 0 ]; then
        cleaned=1
        printf '%b' "$mouse_off" >&3 2>/dev/null || true
        "$stty_bin" "$saved_stty" <"$tty_path" 2>/dev/null || true
    fi
    return "$rc"
}

signal_exit() {
    sig=$1
    code=$2
    trap - "$sig"
    if [ -n "$child_pid" ]; then
        kill -"$sig" "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
        child_pid=
    fi
    exit "$code"
}

trap cleanup EXIT
trap 'signal_exit HUP 129' HUP
trap 'signal_exit INT 130' INT
trap 'signal_exit TERM 143' TERM

# Raw, no-echo, and no local signal translation are required so Ctrl+C and all
# other control bytes reach the remote psmux pane exactly as typed.
"$stty_bin" raw -echo -isig <"$tty_path" || {
    echo "psmux-ssh: could not put the local terminal in raw mode" >&2
    exit 1
}
printf '%b' "$mouse_on" >&3

remote_command=$remote_psmux
if [ -n "$socket" ]; then
    remote_command="$remote_command -L $socket"
fi
remote_command="$remote_command attach"
if [ -n "$session" ]; then
    remote_command="$remote_command -t $session"
fi

# Do not exec: the wrapper must regain control to restore stty and mouse modes.
"$ssh_bin" -T "$@" "$remote_command" <&4 &
child_pid=$!
wait "$child_pid"
rc=$?
child_pid=
exit "$rc"
