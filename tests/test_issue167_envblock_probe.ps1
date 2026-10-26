# Issue #167 - Malformed environment-block -> CreateProcessW err 87 probe
#
# The env-SIZE theory is refuted (sungamma's block is tiny; a 31876-wchar
# synthetic block spawns fine). But PSMUX_BARE_ENV=1 (which skips psmux's
# registry-merged env in get_base_env) fixes the failure. So the trigger is a
# malformed ENTRY, not size. psmux's environment_block() emits, verbatim and
# sorted-by-lowercased-key, whatever get_base_env() collected -- including
# values read straight out of HKCU\Environment via reg_value_to_string(), which
# strips only TRAILING nulls.
#
# This probe feeds CreateProcessW a real ConPTY spawn with deliberately
# malformed env blocks to learn which malformation yields ERROR_INVALID_PARAMETER
# (87). Whatever reproduces 87 is what environment_block() must defend against.

$ErrorActionPreference = "Continue"

$probeCs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

class EnvBlockProbe {
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
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr hpc);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, IntPtr lpPipeAttributes, uint nSize);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr l, int c, int f, ref IntPtr s);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr a, IntPtr v, IntPtr cb, IntPtr p, IntPtr r);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr l);

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint CREATE_UNICODE_ENVIRONMENT  = 0x00000400;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new IntPtr(0x00020016);

    // This probe deliberately feeds CreateProcessW malformed env blocks, so
    // some children are created but cannot initialize.  Each one makes Windows
    // raise a modal "unable to start correctly (0xc0000142)" dialog: 11 to 13
    // per run of the issue167 probe family, which blocks unattended suite runs.
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

    // Build a UTF-16 env block from raw entries (each entry already "KEY=VALUE",
    // may contain interior \0 to simulate corruption). Double-null terminated.
    static IntPtr BuildBlock(List<string> entries) {
        var chars = new List<char>();
        foreach (var e in entries) { chars.AddRange(e.ToCharArray()); chars.Add('\0'); }
        chars.Add('\0');
        var arr = chars.ToArray();
        IntPtr p = Marshal.AllocHGlobal(arr.Length * 2);
        Marshal.Copy(arr, 0, p, arr.Length);
        return p;
    }

    static int Spawn(string pwsh, IntPtr envBlock) {
        IntPtr inR, inW, outR, outW;
        CreatePipe(out inR, out inW, IntPtr.Zero, 0);
        CreatePipe(out outR, out outW, IntPtr.Zero, 0);
        var size = new COORD { X = 80, Y = 24 };
        IntPtr hpc;
        uint flags = 0x1 | 0x2 | 0x4 | 0x8; // base|passthrough, exactly like psmux on 22621+
        int hr = CreatePseudoConsole(size, inR, outW, flags, out hpc);
        if (hr != 0) { CloseHandle(inR);CloseHandle(inW);CloseHandle(outR);CloseHandle(outW); return -9000-(hr&0xFFFF); }

        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        IntPtr attrList = Marshal.AllocHGlobal(attrSize);
        InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize);
        UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);

        var siex = new STARTUPINFOEX();
        siex.StartupInfo.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFOEX));
        siex.lpAttributeList = attrList;

        var cmd = new StringBuilder();
        cmd.Append("\"").Append(pwsh).Append("\" -NoLogo -NoProfile -NoExit -Command \"Start-Sleep -Milliseconds 120\"");

        var pi = new PROCESS_INFORMATION();
        bool ok = CreateProcessW(pwsh, cmd, IntPtr.Zero, IntPtr.Zero, false,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            envBlock, null, ref siex, out pi);
        int err = ok ? 0 : Marshal.GetLastWin32Error();
        if (ok) { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }

        DeleteProcThreadAttributeList(attrList); Marshal.FreeHGlobal(attrList);
        ClosePseudoConsole(hpc);
        CloseHandle(inR);CloseHandle(inW);CloseHandle(outR);CloseHandle(outW);
        return err;
    }

    static List<string> BaseGood() {
        // A small, valid, sorted-by-lowercase set sufficient to launch pwsh.
        return new List<string> {
            "ComSpec=C:\\Windows\\System32\\cmd.exe",
            "PATH=" + Environment.GetEnvironmentVariable("PATH"),
            "PATHEXT=.COM;.EXE;.BAT;.CMD",
            "SystemDrive=C:",
            "SystemRoot=C:\\Windows",
            "TEMP=" + Environment.GetEnvironmentVariable("TEMP"),
            "USERPROFILE=" + Environment.GetEnvironmentVariable("USERPROFILE"),
            "windir=C:\\Windows",
        };
    }

    static void Run(string label, string pwsh, List<string> entries) {
        IntPtr block = BuildBlock(entries);
        int err = Spawn(pwsh, block);
        Marshal.FreeHGlobal(block);
        string note = err == 87 ? "  <<< ERROR_INVALID_PARAMETER (issue #167 reproduced!)"
                    : err == 0 ? "  (OK)" : "";
        Console.WriteLine("  {0,-46} err={1}{2}", label, err, note);
    }

    static void Main(string[] argv) {
        string pwsh = argv[0];

        SilenceSpawnFailureDialogs();

        Console.WriteLine("Baselines and malformations (ConPTY passthrough 0xF, bInheritHandles=FALSE):");

        Run("1. valid sorted block (control)", pwsh, BaseGood());

        var unsorted = BaseGood();
        unsorted.Reverse(); // grossly out of order
        Run("2. UNSORTED block", pwsh, unsorted);

        var interiorNul = BaseGood();
        interiorNul.Add("BADVAR=foo\0bar\0baz"); // interior NUL inside a value
        Run("3. interior NUL inside a value", pwsh, interiorNul);

        var emptyName = BaseGood();
        emptyName.Insert(0, "=hidden"); // entry beginning with '=' (empty name marker)
        Run("4. leading '=name' entry (=C: style)", pwsh, emptyName);

        var trulyEmptyName = BaseGood();
        trulyEmptyName.Insert(0, "=");   // a bare '=' (empty name, empty value)
        Run("5. bare '=' empty-name empty-value entry", pwsh, trulyEmptyName);

        var noEquals = BaseGood();
        noEquals.Add("JUSTANAMEWITHNOEQUALS"); // entry with no '='
        Run("6. entry with NO '=' separator", pwsh, noEquals);

        var huge = BaseGood();
        huge.Add("HUGE=" + new string('q', 40000)); // single var > 32767
        Run("7. single var > 32767 chars", pwsh, huge);

        var dupCase = BaseGood();
        dupCase.Add("path=C:\\dup"); // duplicate of PATH differing only in case
        dupCase.Add("Path=C:\\dup2");
        Run("8. duplicate keys differing only in case", pwsh, dupCase);

        Environment.Exit(0);
    }
}
'@

$probeCsPath = "$env:TEMP\psmux_issue167_envblock_probe.cs"
$probeExe    = "$env:TEMP\psmux_issue167_envblock_probe.exe"
$probeCs | Set-Content -Path $probeCsPath -Encoding UTF8
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /optimize /out:$probeExe $probeCsPath 2>&1 | Out-Null
if (-not (Test-Path $probeExe)) { Write-Host "probe build failed" -ForegroundColor Red; exit 1 }

$pwsh = (Get-Command pwsh -EA Stop).Source
Write-Host "Issue #167 env-block malformation probe" -ForegroundColor Cyan
Write-Host "  build: $([Environment]::OSVersion.Version.Build)   pwsh: $pwsh"
Write-Host ""
& $probeExe $pwsh
