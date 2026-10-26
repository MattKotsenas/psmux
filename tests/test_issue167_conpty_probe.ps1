# Issue #167 — Targeted ConPTY + CreateProcessW probe
#
# Replicates psuedocon.rs's exact spawn pattern to identify which combination
# of flags trips ERROR_INVALID_PARAMETER (87) on the affected machines.
#
# The candidate is the STARTUPINFOEXW setup at psuedocon.rs:217-220:
#
#     si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
#     si.StartupInfo.hStdInput  = INVALID_HANDLE_VALUE;
#     si.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
#     si.StartupInfo.hStdError  = INVALID_HANDLE_VALUE;
#
# Combined with `bInheritHandles = FALSE` — which **violates the MSDN contract**:
#
#   "If [STARTF_USESTDHANDLES] is specified ... the function's bInheritHandles
#    parameter must be set to TRUE."
#                                        — CreateProcessW MSDN reference
#
# Most Windows builds tolerate the violation when stdio handles are
# INVALID_HANDLE_VALUE, but newer/restricted security configurations
# (Win 11 26200, Microsoft account profiles with stricter token policies)
# enforce the rule strictly and reject with err 87.
#
# This probe creates an actual ConPTY (matching what psmux does) and tries
# CreateProcessW with both flag combinations — STARTF_USESTDHANDLES on vs off.
# If toggling that flag reproduces the failure mode, we have the smoking gun.

$ErrorActionPreference = "Continue"

$probeCs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

class ConPtyProbe {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct STARTUPINFOEX {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
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
    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X, Y; }

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
        ref STARTUPINFOEX lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    // This probe deliberately spawns children that cannot initialize (that is
    // the whole point -- it is hunting which flag combination trips err 87).
    // Every such child makes Windows raise a modal "The application was unable
    // to start correctly (0xc0000142)" dialog.  Measured: 11 to 13 popups per
    // run of the issue167 probe family, which blocks unattended suite runs and
    // buries the desktop.
    //
    // A child inherits the parent's error mode UNLESS the parent passes
    // CREATE_DEFAULT_ERROR_MODE -- and this probe does not.  So setting a
    // silent error mode here is inherited by every child we spawn.  The
    // CreateProcessW return value and GetLastError, which is the only thing
    // this probe actually measures, are completely unaffected.
    [DllImport("kernel32.dll")]
    static extern uint SetErrorMode(uint uMode);
    const uint SEM_FAILCRITICALERRORS = 0x0001;
    const uint SEM_NOGPFAULTERRORBOX  = 0x0002;
    const uint SEM_NOOPENFILEERRORBOX = 0x8000;
    static void SilenceSpawnFailureDialogs() {
        SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint flags, out IntPtr hpc);

    [DllImport("kernel32.dll")]
    static extern void ClosePseudoConsole(IntPtr hpc);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, IntPtr lpPipeAttributes, uint nSize);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint CREATE_UNICODE_ENVIRONMENT  = 0x00000400;
    const uint STARTF_USESTDHANDLES        = 0x00000100;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new IntPtr(0x00020016);

    static int Spawn(string pwsh, bool useStdHandles, bool inheritHandles) {
        // Create input/output pipes
        IntPtr inR, inW, outR, outW;
        if (!CreatePipe(out inR, out inW, IntPtr.Zero, 0))  { return -1001; }
        if (!CreatePipe(out outR, out outW, IntPtr.Zero, 0)) { return -1002; }

        // Create the pseudo console
        var size = new COORD { X = 80, Y = 24 };
        IntPtr hpc;
        int hr = CreatePseudoConsole(size, inR, outW, 0, out hpc);
        if (hr != 0) {
            return -2000 - (hr & 0xFFFF);
        }

        // Build the attribute list
        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        IntPtr attrList = Marshal.AllocHGlobal(attrSize);
        if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize)) {
            return -3000 - Marshal.GetLastWin32Error();
        }
        if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) {
            return -4000 - Marshal.GetLastWin32Error();
        }

        var siex = new STARTUPINFOEX();
        siex.StartupInfo.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFOEX));
        siex.lpAttributeList = attrList;

        if (useStdHandles) {
            siex.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
            siex.StartupInfo.hStdInput  = INVALID_HANDLE_VALUE;
            siex.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
            siex.StartupInfo.hStdError  = INVALID_HANDLE_VALUE;
        }
        // else: dwFlags=0, stdio fields default zero

        var cmdline = new StringBuilder();
        cmdline.Append("\""); cmdline.Append(pwsh); cmdline.Append("\"");
        cmdline.Append(" -NoLogo -NoProfile -NoExit -Command \"Start-Sleep -Milliseconds 200\"");

        var pi = new PROCESS_INFORMATION();
        bool ok = CreateProcessW(
            pwsh, cmdline,
            IntPtr.Zero, IntPtr.Zero,
            inheritHandles,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            IntPtr.Zero, null,
            ref siex,
            out pi);

        int err = ok ? 0 : Marshal.GetLastWin32Error();
        if (ok) {
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
        }

        DeleteProcThreadAttributeList(attrList);
        Marshal.FreeHGlobal(attrList);
        ClosePseudoConsole(hpc);
        CloseHandle(inR); CloseHandle(inW);
        CloseHandle(outR); CloseHandle(outW);
        return err;
    }

    static void Main(string[] argv) {
        if (argv.Length < 1) { Console.Error.WriteLine("usage: probe <pwsh>"); Environment.Exit(2); return; }
        string pwsh = argv[0];

        SilenceSpawnFailureDialogs();

        Console.WriteLine("[1] STARTF_USESTDHANDLES=ON,  bInheritHandles=FALSE (current psmux code)");
        int e1 = Spawn(pwsh, true, false);
        Console.WriteLine("    => err = {0}", e1);

        Console.WriteLine("[2] STARTF_USESTDHANDLES=OFF, bInheritHandles=FALSE (proposed fix)");
        int e2 = Spawn(pwsh, false, false);
        Console.WriteLine("    => err = {0}", e2);

        Console.WriteLine("[3] STARTF_USESTDHANDLES=ON,  bInheritHandles=TRUE  (MSDN-compliant)");
        int e3 = Spawn(pwsh, true, true);
        Console.WriteLine("    => err = {0}", e3);

        Console.WriteLine("[4] STARTF_USESTDHANDLES=OFF, bInheritHandles=TRUE");
        int e4 = Spawn(pwsh, false, true);
        Console.WriteLine("    => err = {0}", e4);

        Environment.Exit(0);
    }
}
'@

$probeCsPath = "$env:TEMP\psmux_issue167_conpty_probe.cs"
$probeExe    = "$env:TEMP\psmux_issue167_conpty_probe.exe"
$probeCs | Set-Content -Path $probeCsPath -Encoding UTF8

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /optimize /out:$probeExe $probeCsPath 2>&1 | Out-Null
if (-not (Test-Path $probeExe)) { Write-Host "probe build failed" -ForegroundColor Red; exit 1 }

$pwsh = (Get-Command pwsh -EA Stop).Source
Write-Host "Probing CreateProcessW with various STARTUPINFOEX flag combinations" -ForegroundColor Cyan
Write-Host "  pwsh = $pwsh"
Write-Host ""
& $probeExe $pwsh
