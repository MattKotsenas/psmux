#!/bin/sh
# Install the macOS/Linux client helper as ~/.local/bin/psmux-win.

set -eu

usage() {
    cat <<'EOF'
Usage: install-psmux-win.sh --host [user@]windows-host [--psmux REMOTE_PATH]
                            [--bin-dir LOCAL_BIN_DIR]

Example:
  sh install-psmux-win.sh --host user@windows-host \
    --psmux C:/Users/user/.cargo/bin/psmux.exe
EOF
}

host=
remote_psmux=psmux
bin_dir=${HOME}/.local/bin
while [ "$#" -gt 0 ]; do
    case $1 in
        --host)
            [ "$#" -ge 2 ] || { echo "psmux-win install: --host requires a value" >&2; exit 2; }
            host=$2
            shift 2
            ;;
        --psmux)
            [ "$#" -ge 2 ] || { echo "psmux-win install: --psmux requires a value" >&2; exit 2; }
            remote_psmux=$2
            shift 2
            ;;
        --bin-dir)
            [ "$#" -ge 2 ] || { echo "psmux-win install: --bin-dir requires a value" >&2; exit 2; }
            bin_dir=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "psmux-win install: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$host" ] || { echo "psmux-win install: --host is required" >&2; exit 2; }
case $host in
    *[!A-Za-z0-9_.@%:-]*)
        echo "psmux-win install: host contains unsupported characters" >&2
        exit 2
        ;;
esac
case $remote_psmux in
    *[!A-Za-z0-9_./:\\-]*)
        echo "psmux-win install: remote psmux must be a simple path without spaces" >&2
        exit 2
        ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_wrapper=$script_dir/psmux-ssh.sh
[ -r "$source_wrapper" ] || {
    echo "psmux-win install: psmux-ssh.sh must be beside the installer" >&2
    exit 1
}

config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
config_dir=$config_home/psmux-win
config_file=$config_dir/config
target=$bin_dir/psmux-win
stamp=$(date '+%Y%m%d-%H%M%S')

backup_file() {
    backup_source=$1
    backup_target=$backup_source.backup-$stamp
    suffix=0
    while [ -e "$backup_target" ]; do
        suffix=$((suffix + 1))
        backup_target=$backup_source.backup-$stamp-$suffix
    done
    cp "$backup_source" "$backup_target"
}

mkdir -p "$bin_dir" "$config_dir"
if [ -e "$target" ]; then
    backup_file "$target"
fi
if [ -e "$config_file" ]; then
    backup_file "$config_file"
fi

cp "$source_wrapper" "$target"
chmod 755 "$target"

tmp_config=$config_file.tmp.$$
trap 'rm -f "$tmp_config"' EXIT HUP INT TERM
{
    printf 'host=%s\n' "$host"
    printf 'remote_psmux=%s\n' "$remote_psmux"
} >"$tmp_config"
chmod 600 "$tmp_config"
mv "$tmp_config" "$config_file"
trap - EXIT HUP INT TERM

printf 'Installed: %s\n' "$target"
printf 'Config:    %s\n' "$config_file"
printf '\nUsage:\n'
printf '  psmux-win -s SESSION\n'
printf '  psmux-win -L SOCKET -s SESSION\n'
case :$PATH: in
    *:"$bin_dir":*) ;;
    *) printf '\nAdd %s to PATH, then open a new terminal.\n' "$bin_dir" ;;
esac
