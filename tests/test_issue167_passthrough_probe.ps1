# Issue #167 - PASSTHROUGH-mode ConPTY + CreateProcessW probe
#
# psuedocon.rs builds the ConPTY with these flags on Windows 11 22H2+ (build 22621+):
#
#   base_flags = PSUEDOCONSOLE_INHERIT_CURSOR(0x1)
#              | PSEUDOCONSOLE_RESIZE_QUIRK(0x2)
#              | PSEUDOCONSOLE_WIN32_INPUT_MODE(0x4)            = 0x7
#   passthrough = base_flags | PSEUDOCONSOLE_PASSTHROUGH_MODE(0x8) = 0xF
#
# The earlier conpty_probe used flags=0 (none of these). This probe replicates
# the EXACT flag set, with the EXACT current STARTUPINFOEX setup (no
# STARTF_USESTDHANDLES, bInheritHandles=FALSE) and a realistic ~3500-char
# command line, to find whether PASSTHROUGH mode is what trips err 87 on
# build 26200.

$ErrorActionPreference = "Continue"

$probeCs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

class PassthroughProbe {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct STARTUPINFO {
        public uint cb; public IntPtr lpReserved; public IntPtr lpDesktop; public IntPtr lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize; public uint dwXCountChars, dwYCountChars;
        public uint dwFillAttribute, dwFlags; public ushort wShowWindow, cbReserved2;
        public IntPtr lpReserved2; public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X, Y; }

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcessW(string lpApplicationName, StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
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
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new IntPtr(0x00020016);

    // This probe deliberately spawns children under flag combinations that can
    // fail to initialize.  Each failure makes Windows raise a modal "unable to
    // start correctly (0xc0000142)" dialog: 11 to 13 per run of the issue167
    // probe family, which blocks unattended suite runs.
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
    static void SilenceSpawnFailureDialogs() {
        SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    }

    // returns (createPseudoConsoleHr, createProcessErr). HR<0 means CreatePseudoConsole failed.
    static int Spawn(string pwsh, uint conptyFlags, string command, out int hrOut) {
        hrOut = 0;
        IntPtr inR, inW, outR, outW;
        if (!CreatePipe(out inR, out inW, IntPtr.Zero, 0))  { return -1001; }
        if (!CreatePipe(out outR, out outW, IntPtr.Zero, 0)) { return -1002; }

        var size = new COORD { X = 80, Y = 24 };
        IntPtr hpc;
        int hr = CreatePseudoConsole(size, inR, outW, conptyFlags, out hpc);
        hrOut = hr;
        if (hr != 0) {
            CloseHandle(inR); CloseHandle(inW); CloseHandle(outR); CloseHandle(outW);
            return -9999; // CreatePseudoConsole rejected the flags outright
        }

        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        IntPtr attrList = Marshal.AllocHGlobal(attrSize);
        InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize);
        UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);

        // EXACT current psmux STARTUPINFOEX setup: no STARTF_USESTDHANDLES, dwFlags=0
        var siex = new STARTUPINFOEX();
        siex.StartupInfo.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFOEX));
        siex.lpAttributeList = attrList;

        var cmdline = new StringBuilder();
        cmdline.Append("\""); cmdline.Append(pwsh); cmdline.Append("\"");
        cmdline.Append(" -NoLogo -NoProfile -NoExit -Command \""); cmdline.Append(command); cmdline.Append("\"");

        var pi = new PROCESS_INFORMATION();
        bool ok = CreateProcessW(pwsh, cmdline, IntPtr.Zero, IntPtr.Zero,
            false, // bInheritHandles=FALSE, matching psmux
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            IntPtr.Zero, null, ref siex, out pi);
        int err = ok ? 0 : Marshal.GetLastWin32Error();
        if (ok) { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }

        DeleteProcThreadAttributeList(attrList);
        Marshal.FreeHGlobal(attrList);
        ClosePseudoConsole(hpc);
        CloseHandle(inR); CloseHandle(inW); CloseHandle(outR); CloseHandle(outW);
        return err;
    }

    static void Report(string label, string pwsh, uint flags, string command) {
        int hr;
        int err = Spawn(pwsh, flags, command, out hr);
        if (err == -9999) {
            Console.WriteLine("    {0}: CreatePseudoConsole FAILED hr=0x{1:X8}", label, hr);
        } else if (err < 0) {
            Console.WriteLine("    {0}: pipe setup failed ({1})", label, err);
        } else {
            Console.WriteLine("    {0}: CreatePseudoConsole hr=0x{1:X8}  CreateProcessW err={2}{3}",
                label, hr, err, err == 87 ? "  <<< ERROR_INVALID_PARAMETER (issue #167!)" : (err == 0 ? "  (OK)" : ""));
        }
    }

    static void Main(string[] argv) {
        if (argv.Length < 1) { Console.Error.WriteLine("usage: probe <pwsh>"); Environment.Exit(2); return; }
        string pwsh = argv[0];

        SilenceSpawnFailureDialogs();

        string shortCmd = "Start-Sleep -Milliseconds 150";
        // Realistic ~3500-char init (psmux's build_psrl_init produces ~3500 chars).
        string bigCmd = new string('X', 3500).Replace("X", "x"); // 3500 chars, no quotes/specials

        const uint BASE = 0x1 | 0x2 | 0x4;   // INHERIT_CURSOR | RESIZE_QUIRK | WIN32_INPUT_MODE = 0x7
        const uint PASS = 0x8;               // PSEUDOCONSOLE_PASSTHROUGH_MODE

        Console.WriteLine("[A] base flags 0x7, short command:");
        Report("A", pwsh, BASE, shortCmd);
        Console.WriteLine("[B] base|passthrough 0xF, short command  (what psmux uses on build >=22621):");
        Report("B", pwsh, BASE | PASS, shortCmd);
        Console.WriteLine("[C] base flags 0x7, ~3500-char command:");
        Report("C", pwsh, BASE, bigCmd);
        Console.WriteLine("[D] base|passthrough 0xF, ~3500-char command  (closest to real psmux warm pane):");
        Report("D", pwsh, BASE | PASS, bigCmd);
        Console.WriteLine("[E] passthrough ONLY 0x8, short command:");
        Report("E", pwsh, PASS, shortCmd);

        Environment.Exit(0);
    }
}
'@

$probeCsPath = "$env:TEMP\psmux_issue167_passthrough_probe.cs"
$probeExe    = "$env:TEMP\psmux_issue167_passthrough_probe.exe"
$probeCs | Set-Content -Path $probeCsPath -Encoding UTF8

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /optimize /out:$probeExe $probeCsPath 2>&1 | Out-Null
if (-not (Test-Path $probeExe)) { Write-Host "probe build failed" -ForegroundColor Red; exit 1 }

$pwsh = (Get-Command pwsh -EA Stop).Source
Write-Host "Issue #167 PASSTHROUGH probe" -ForegroundColor Cyan
Write-Host "  Windows build: $([Environment]::OSVersion.Version.Build)"
Write-Host "  pwsh        : $pwsh"
Write-Host ""
& $probeExe $pwsh
