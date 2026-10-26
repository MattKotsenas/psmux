# Issue #167: psmux silently exits ("flashes black"), error 87 from CreateProcessW
#
# Two reporters, both blocked on CreateProcessW returning ERROR_INVALID_PARAMETER (87)
# when the server tries to spawn the warm pwsh.exe pane.
#
# Key data points from the conversation:
#   - sungamma: Microsoft account fails, local account on SAME PC works.
#     pwd shows C:\Users\xwtal in both cases.
#   - TheFranconianCoder: Win 11 build 26200, English path, one machine fails.
#   - Commit 1861eb7 (auto-retry without PASSTHROUGH_MODE) did NOT fix it.
#
# So the cause is NOT just PSEUDOCONSOLE_PASSTHROUGH_MODE. The auto-retry
# falls through to spawn_command WITHOUT passthrough and CreateProcessW
# still rejects with err 87.
#
# Hypothesis 1 (HIGHEST PROBABILITY): The environment block exceeds the
# Windows limit (32,767 chars total) when the calling process has a large
# PATH + many MSA-injected env vars (OneDrive*, WindowsApps_*, etc).
#
# Hypothesis 2: The lpCommandLine exceeds 32,767 chars after expansion.
#
# Hypothesis 3: The env block contains an entry that breaks Windows'
# case-insensitive sort requirement (entries with `=` prefix, embedded
# nulls, very long values).
#
# Hypothesis 4: CreateProcessW rejects WindowsApps execution-alias paths
# in lpApplicationName.
#
# This script collects diagnostic data from the current machine to see
# how close we are to the various Windows limits, and probes CreateProcessW
# directly to find which hypothesis triggers err 87.

$ErrorActionPreference = "Continue"
$script:Issues = @()

function Note($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:Issues += $msg }
function Bad($msg)  { Write-Host "  [BAD ] $msg" -ForegroundColor Red;    $script:Issues += $msg }
function Ok($msg)   { Write-Host "  [ OK ] $msg" -ForegroundColor Green }

Write-Host ""
Write-Host "=== Issue #167 diagnostic probe ===" -ForegroundColor Cyan
Write-Host ""

# === H1: Environment block size ===
Write-Host "[H1] Environment block size" -ForegroundColor Yellow
$envVars = Get-ChildItem env: | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }
$blockSize = ($envVars -join "`0").Length + 2  # NUL-separated + double-NUL terminator
$blockSizeWChars = $blockSize  # already in chars; CreateProcessW unicode = 2 bytes each
Note "Number of env vars         : $($envVars.Count)"
Note "Total env block size (chars): $blockSizeWChars (Windows hard limit: 32767)"
Note "Total env block size (bytes): $($blockSizeWChars * 2) (UTF-16, the unit CreateProcessW counts)"

if ($blockSizeWChars -gt 32767) {
    Bad "Env block exceeds 32767 chars — would trigger err 87 on CreateProcessW"
} elseif ($blockSizeWChars -gt 30000) {
    Warn "Env block close to limit (>30000 chars)"
} else {
    Ok "Env block well under limit"
}

# Show longest env vars
Write-Host ""
Note "Top 5 longest env vars:"
Get-ChildItem env: |
    Sort-Object { $_.Value.Length } -Descending |
    Select-Object -First 5 |
    ForEach-Object { Note ("    {0,-30} {1} chars" -f $_.Name, $_.Value.Length) }

# Show vars beginning with `=` (Windows hidden vars: =ExitCode, =C:, =D:, etc)
Write-Host ""
$equalsVars = Get-ChildItem env: | Where-Object { $_.Name.StartsWith('=') }
if ($equalsVars) {
    Note "Equals-prefixed vars (Windows internal, must sort first):"
    $equalsVars | ForEach-Object { Note ("    {0}" -f $_.Name) }
} else {
    Note "No equals-prefixed env vars present"
}

# === H2: Command line size (synthesised psmux warm-pane command) ===
Write-Host ""
Write-Host "[H2] Command line size for psmux warm-pane spawn" -ForegroundColor Yellow

# Approximate the build_psrl_init() output size by reading the constants.
# We can't easily extract the exact string without running psmux, but we
# can approximate.
$pwshPath = (Get-Command pwsh -EA SilentlyContinue).Source
if ($pwshPath) {
    $synth = "`"$pwshPath`" -NoLogo -NoProfile -NoExit -Command `"" + ("X" * 3500) + "`""
    Note "Synthetic pwsh cmd line size ≈ $($synth.Length) chars"
    Note "  (the actual psrl_init is ≈3500 chars; +pwsh path + flags)"
    Note "Windows lpCommandLine limit: 32767 chars"
    if ($synth.Length -gt 32767) {
        Bad "Cmd line would exceed 32767"
    } else {
        Ok "Cmd line fits with room to spare"
    }
} else {
    Warn "pwsh.exe not on PATH — cannot synthesise"
}

# === H3: Microsoft account markers ===
Write-Host ""
Write-Host "[H3] Microsoft account markers" -ForegroundColor Yellow
$msaMarkers = @(
    'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer',
    'USERDOMAIN_ROAMINGPROFILE',
    'WSLENV',
    'GIT_ASKPASS'  # often set by VS Code with MSA sign-in
)
$present = @()
foreach ($m in $msaMarkers) {
    if (Test-Path "env:$m") {
        $present += $m
        $val = (Get-Item "env:$m").Value
        Note "  $m = $($val.Substring(0, [Math]::Min(80, $val.Length)))"
    }
}
if ($present.Count -gt 0) {
    Note "MSA-style env vars present: $($present -join ', ')"
    Note "(Helps confirm/deny H1: MSA accounts often inflate env block)"
}

# === H4: pwsh.exe path scrutiny ===
Write-Host ""
Write-Host "[H4] pwsh.exe path scrutiny" -ForegroundColor Yellow
if ($pwshPath) {
    Note "pwsh.exe path : $pwshPath"
    if ($pwshPath -match 'WindowsApps') {
        Bad "pwsh.exe is in WindowsApps — Microsoft Store appx execution alias"
        Bad "  These paths often have ACL restrictions that fail CreateProcessW"
    } elseif ($pwshPath -match 'Program Files') {
        Ok "pwsh.exe is in standard Program Files"
    } else {
        Note "pwsh.exe is in non-standard location (Scoop / portable / dev build?)"
    }

    # Check that the path contains spaces (and hence requires quoting)
    if ($pwshPath -match ' ') {
        Note "pwsh.exe path contains spaces — must be quoted in cmdline"
    }
} else {
    Bad "pwsh.exe not on PATH"
}

# === H5: CWD validity ===
Write-Host ""
Write-Host "[H5] CWD/USERPROFILE checks" -ForegroundColor Yellow
$cwd = (Get-Location).ProviderPath
$userprofile = $env:USERPROFILE
Note "Current dir           : $cwd"
Note "USERPROFILE           : $userprofile"
Note "USERPROFILE exists    : $(Test-Path $userprofile -PathType Container)"
Note "CWD exists            : $(Test-Path $cwd -PathType Container)"

# Check if CWD is on a OneDrive sync path
if ($env:OneDrive -and $cwd.StartsWith($env:OneDrive)) {
    Warn "CWD is inside OneDrive sync folder — may have placeholder/offline issues"
}

# === Direct CreateProcessW probe ===
Write-Host ""
Write-Host "[H6] Direct CreateProcessW probe" -ForegroundColor Yellow

if (-not $pwshPath) {
    Warn "Skipping CreateProcessW probe (no pwsh)"
} else {
    # Compile a tiny C# probe that calls CreateProcessW with the same args
    # psmux uses, and reports the exact failure mode if any.
    $probeCs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

class Probe {
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO {
        public uint cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize;
        public uint dwXCountChars, dwYCountChars;
        public uint dwFillAttribute, dwFlags;
        public ushort wShowWindow, cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread;
        public uint dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcessW(
        string lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentProcessId();

    // This probe deliberately spawns children under conditions that can fail to
    // initialize (oversized env blocks, WindowsApps alias paths).  Each failure
    // makes Windows raise a modal "unable to start correctly (0xc0000142)"
    // dialog: 11 to 13 per run of the issue167 probe family, which blocks
    // unattended suite runs.
    //
    // A child inherits the parent's error mode UNLESS the parent passes
    // CREATE_DEFAULT_ERROR_MODE -- and this probe does not.  Setting a silent
    // error mode here is therefore inherited by every child.  CreateProcessW's
    // return value and GetLastError, the only things this probe measures, are
    // unaffected.
    [DllImport("kernel32.dll")]
    static extern uint SetErrorMode(uint uMode);
    const uint SEM_FAILCRITICALERRORS = 0x0001;
    const uint SEM_NOGPFAULTERRORBOX  = 0x0002;
    const uint SEM_NOOPENFILEERRORBOX = 0x8000;

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    static void Main(string[] argv) {
        if (argv.Length < 1) { Console.Error.WriteLine("usage: probe <pwsh_path> [synthbig]"); return; }
        string pwsh = argv[0];
        bool synthBig = argv.Length > 1 && argv[1] == "synthbig";

        SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);

        // Mirror psmux's invocation pattern.
        string command = "Write-Host PROBE_OK; Start-Sleep 1";
        var args = new StringBuilder();
        args.Append("\""); args.Append(pwsh); args.Append("\"");
        args.Append(" -NoLogo -NoProfile -NoExit -Command \""); args.Append(command); args.Append("\"");

        IntPtr envBlock = IntPtr.Zero;
        if (synthBig) {
            // Build a synthetic env block close to the 32767 wchar limit.
            // Each entry is ~250 chars, ~125 entries -> 31250 chars
            var sb = new StringBuilder();
            for (int i = 0; i < 125; i++) {
                sb.Append("PROBE_VAR_"); sb.Append(i.ToString("D3"));
                sb.Append("=");
                sb.Append(new string('X', 240));
                sb.Append('\0');
            }
            sb.Append('\0');
            envBlock = Marshal.StringToHGlobalUni(sb.ToString());
            Console.WriteLine("[probe] synthetic env block: {0} wchars", sb.Length);
        }

        var si = new STARTUPINFO();
        si.cb = (uint)Marshal.SizeOf(si);
        var pi = new PROCESS_INFORMATION();
        const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        const uint CREATE_NO_WINDOW = 0x08000000;

        bool ok = CreateProcessW(
            pwsh,
            args,
            IntPtr.Zero, IntPtr.Zero, false,
            CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
            envBlock,
            null,
            ref si,
            out pi
        );

        if (!ok) {
            int err = Marshal.GetLastWin32Error();
            Console.WriteLine("[probe] CreateProcessW FAILED err={0}", err);
            Environment.Exit(err);
        }
        Console.WriteLine("[probe] CreateProcessW OK pid={0}", pi.dwProcessId);
        // The child is spawned with -NoExit, so once its command finishes it
        // sits at a prompt forever.  Two leaked per run and accumulated across
        // days (survivors found up to 84h old, each holding a conhost and its
        // share of desktop heap).  Reap it: this probe only needs to know
        // whether CreateProcessW succeeded, not to keep the shell around.
        TerminateProcess(pi.hProcess, 0);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        if (envBlock != IntPtr.Zero) Marshal.FreeHGlobal(envBlock);
        Environment.Exit(0);
    }
}
'@

    $probeExe = "$env:TEMP\psmux_issue167_probe.exe"
    $probeCsPath = "$env:TEMP\psmux_issue167_probe.cs"
    $probeCs | Set-Content -Path $probeCsPath -Encoding UTF8
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$probeExe $probeCsPath 2>&1 | Out-Null

    if (Test-Path $probeExe) {
        Note "Built probe.exe"
        Note "Run #1: normal env (inherited)"
        $r1 = & $probeExe $pwshPath 2>&1
        $exit1 = $LASTEXITCODE
        $r1 | ForEach-Object { Note ("    $_") }
        if ($exit1 -eq 0) { Ok "Normal-env spawn OK" }
        elseif ($exit1 -eq 87) { Bad "Normal-env spawn FAILED with err 87 (matches issue!)" }
        else { Warn "Normal-env spawn failed with err $exit1" }

        Note "Run #2: synthetic large env block (~31250 wchars)"
        $r2 = & $probeExe $pwshPath synthbig 2>&1
        $exit2 = $LASTEXITCODE
        $r2 | ForEach-Object { Note ("    $_") }
        if ($exit2 -eq 0) { Ok "Large-env spawn OK" }
        elseif ($exit2 -eq 87) { Bad "Large-env spawn FAILED with err 87 (CONFIRMS H1)" }
        else { Warn "Large-env spawn failed with err $exit2" }
    } else {
        Warn "csc.exe failed to compile probe"
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
if ($script:Issues.Count -eq 0) {
    Write-Host "  No issues detected on this machine." -ForegroundColor Green
} else {
    Write-Host "  $($script:Issues.Count) potential issues:" -ForegroundColor Yellow
    $script:Issues | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}
