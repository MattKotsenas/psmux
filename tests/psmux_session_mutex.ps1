# Shared helper: the kernel object name of psmux's single-server-per-name
# guard, reproduced in PowerShell so a test can ask "is this session name
# held?" without spawning psmux.
#
# Product side: src/platform.rs session_mutex_name
#
#     Local\psmux-session-<data_root_tag>-<base>
#
# where <base> is the session name (or `<ns>__<name>` under -L) with `\` and `/`
# mapped to `_`, and <data_root_tag> (issue #599, src/paths.rs data_root_tag) is
# Rust's DefaultHasher (SipHash-1-3, zero keys) over the normalised data root
# (PSMUX_DATA_DIR or ~\.psmux, no trailing separator, `/` folded to `\`, lower
# cased), rendered as 16 lower case hex digits. Rust's `str::hash` feeds the
# UTF-8 bytes followed by a single 0xff terminator, so that byte is part of the
# input here too.
#
# Before #599 the name was `Local\psmux-session-<base>`; two suites probed that
# literal and started reporting every live session as unguarded once the tag
# was inserted (sweep 2026-08-27_15-06-34). This helper is the one place that
# knows the layout.
#
# Usage:
#     . "$PSScriptRoot\psmux_session_mutex.ps1"
#     Test-PsmuxSessionNameHeld 'work'            # $true while a server owns it
#     Get-PsmuxSessionMutexName 'work'            # the full object name

if (-not ('PsmuxSip13' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;

public static class PsmuxSip13 {
    static ulong Rotl(ulong x, int b) { return (x << b) | (x >> (64 - b)); }

    static void Round(ref ulong v0, ref ulong v1, ref ulong v2, ref ulong v3) {
        unchecked {
            v0 += v1; v1 = Rotl(v1, 13); v1 ^= v0; v0 = Rotl(v0, 32);
            v2 += v3; v3 = Rotl(v3, 16); v3 ^= v2;
            v0 += v3; v3 = Rotl(v3, 21); v3 ^= v0;
            v2 += v1; v1 = Rotl(v1, 17); v1 ^= v2; v2 = Rotl(v2, 32);
        }
    }

    // SipHash-1-3 with k0 = k1 = 0: what Rust's DefaultHasher::new() runs.
    public static ulong Hash(byte[] data) {
        unchecked {
            ulong v0 = 0x736f6d6570736575UL;
            ulong v1 = 0x646f72616e646f6dUL;
            ulong v2 = 0x6c7967656e657261UL;
            ulong v3 = 0x7465646279746573UL;
            int len = data.Length;
            int end = len - (len % 8);
            for (int i = 0; i < end; i += 8) {
                ulong m = BitConverter.ToUInt64(data, i);
                v3 ^= m;
                Round(ref v0, ref v1, ref v2, ref v3);
                v0 ^= m;
            }
            ulong b = ((ulong)len) << 56;
            for (int i = end; i < len; i++) {
                b |= ((ulong)data[i]) << (8 * (i - end));
            }
            v3 ^= b;
            Round(ref v0, ref v1, ref v2, ref v3);
            v0 ^= b;
            v2 ^= 0xff;
            Round(ref v0, ref v1, ref v2, ref v3);
            Round(ref v0, ref v1, ref v2, ref v3);
            Round(ref v0, ref v1, ref v2, ref v3);
            return v0 ^ v1 ^ v2 ^ v3;
        }
    }

    // Rust `str::hash`: the UTF-8 bytes, then a 0xff terminator.
    public static string RustStrHashHex(string s) {
        byte[] utf8 = Encoding.UTF8.GetBytes(s);
        byte[] data = new byte[utf8.Length + 1];
        Array.Copy(utf8, data, utf8.Length);
        data[utf8.Length] = 0xff;
        return Hash(data).ToString("x16");
    }
}
'@
}

function Get-PsmuxDataRoot {
    # src/paths.rs psmux_dir(): PSMUX_DATA_DIR without a trailing separator,
    # else ~\.psmux.
    if ($env:PSMUX_DATA_DIR) {
        return $env:PSMUX_DATA_DIR.TrimEnd('\', '/')
    }
    return (Join-Path $env:USERPROFILE '.psmux')
}

function Get-PsmuxDataRootTag {
    # src/paths.rs data_root_tag(): hash of normalized_data_root().
    $normalized = (Get-PsmuxDataRoot).Replace('/', '\').ToLowerInvariant()
    return [PsmuxSip13]::RustStrHashHex($normalized)
}

function Get-PsmuxSessionMutexName {
    param([Parameter(Mandatory)][string]$Base)
    $sanitized = $Base.Replace('\', '_').Replace('/', '_')
    return "Local\psmux-session-$(Get-PsmuxDataRootTag)-$sanitized"
}

# $true when a live psmux server owns the guard for $Base right now.
function Test-PsmuxSessionNameHeld {
    param([Parameter(Mandatory)][string]$Base)
    $obj = Get-PsmuxSessionMutexName $Base
    $created = $false
    try {
        $m = [System.Threading.Mutex]::new($false, $obj, [ref]$created)
        $owned = $m.WaitOne(0)
        if ($owned) { $m.ReleaseMutex() }
        $m.Dispose()
        return (-not $owned)
    } catch { return $false }
}
