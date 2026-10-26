#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/install-psmux-win-$$
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/home" "$tmp/config" "$tmp/fake-bin"

# Force every installation to use the same timestamp. Reinstalls must create
# distinct backups instead of overwriting the first one.
cat >"$tmp/fake-bin/date" <<'EOF'
#!/bin/sh
printf '%s\n' '20260720-120000'
EOF
chmod +x "$tmp/fake-bin/date"
test_path=$tmp/fake-bin:$PATH

HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" PATH="$test_path" \
    sh "$repo/scripts/install-psmux-win.sh" \
        --host user@windows-host \
        --psmux C:/Users/user/.cargo/bin/psmux.exe \
        --bin-dir "$tmp/bin" >/dev/null

[ -x "$tmp/bin/psmux-win" ] || {
    echo 'FAIL: psmux-win was not installed executable' >&2
    exit 1
}
grep -Fx 'host=user@windows-host' "$tmp/config/psmux-win/config" >/dev/null
grep -Fx 'remote_psmux=C:/Users/user/.cargo/bin/psmux.exe' "$tmp/config/psmux-win/config" >/dev/null

HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" PATH="$test_path" \
    sh "$repo/scripts/install-psmux-win.sh" \
        --host user@windows-host \
        --psmux psmux \
        --bin-dir "$tmp/bin" >/dev/null

[ -f "$tmp/bin/psmux-win.backup-20260720-120000" ] || {
    echo 'FAIL: reinstall did not back up the launcher' >&2
    exit 1
}
[ -f "$tmp/config/psmux-win/config.backup-20260720-120000" ] || {
    echo 'FAIL: reinstall did not back up the config' >&2
    exit 1
}
grep -Fx 'remote_psmux=psmux' "$tmp/config/psmux-win/config" >/dev/null

HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" PATH="$test_path" \
    sh "$repo/scripts/install-psmux-win.sh" \
        --host second@windows-host \
        --psmux C:/psmux/psmux.exe \
        --bin-dir "$tmp/bin" >/dev/null

bin_backup_count=0
for backup in "$tmp/bin"/psmux-win.backup-*; do
    [ -e "$backup" ] || continue
    bin_backup_count=$((bin_backup_count + 1))
done
config_backup_count=0
for backup in "$tmp/config/psmux-win"/config.backup-*; do
    [ -e "$backup" ] || continue
    config_backup_count=$((config_backup_count + 1))
done
[ "$bin_backup_count" -eq 2 ] || {
    echo "FAIL: expected 2 launcher backups, found $bin_backup_count" >&2
    exit 1
}
[ "$config_backup_count" -eq 2 ] || {
    echo "FAIL: expected 2 config backups, found $config_backup_count" >&2
    exit 1
}
grep -Fx 'remote_psmux=C:/Users/user/.cargo/bin/psmux.exe' \
    "$tmp/config/psmux-win/config.backup-20260720-120000" >/dev/null
grep -Fx 'remote_psmux=psmux' \
    "$tmp/config/psmux-win/config.backup-20260720-120000-1" >/dev/null
grep -Fx 'host=second@windows-host' "$tmp/config/psmux-win/config" >/dev/null

echo 'PASS: installer creates files and preserves every reinstall backup'
