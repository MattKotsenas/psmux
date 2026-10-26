# Runner forensics: who we are, what we kill, and what was true at the instant
# we stopped existing.
#
# ── THE FAILURE THIS EXISTS FOR (issue #680) ────────────────────────────────
# Twice in two days the whole test run vanished mid stride with no crash record
# anywhere. Run 2026-09-20_00-19-17 stopped after 587 of 731 suites, its last
# line being
#     [2026-09-20 06:04:50.125] --- [588/731] Queuing test_newsession_flags ---
# and run 2026-09-21_03-10-11 stopped 20 seconds into a suite with a 240 second
# timeout, its last line being
#     [2026-09-21 03:13:06.856] HEARTBEAT test_issue530_registry_accumulation 20s/240s
# Both times the launcher process was gone too, and no psmux was left running.
# No bugcheck, no Application Error 1000, no 1026, no WER report.
#
# The decisive detail is in spawn_trace.log, not in progress.log. The spawn
# attribution watcher is a SEPARATE process with its OWN console (it is started
# with Start-Process -WindowStyle Hidden, and the trace records the conhost.exe
# it spawned for itself). It polls the runner pid and writes a "# stopped ..."
# footer on every voluntary exit, including the one it takes when it notices the
# runner is gone. Neither trace has that footer. So the watcher did not leave,
# it was terminated, in the same second as the runner, although it shares no
# console with it and sits in none of the per suite job objects.
#
# That rules out the two explanations that fit the runner's silence on their
# own: a console control event (it would not reach a process on a different
# console) and a suite's job object (the watcher is not in one). What is left is
# something that killed a whole tree rooted at or above the runner.
#
# Measured 2026-09-21 with a disposable three process stand in for the runner,
# its own console child and its launcher:
#
#   holder in a job with KILL_ON_JOB_CLOSE, holder killed
#       -> runner gone, own console child gone, and NOTHING recorded:
#          no console ctrl handler line, no PowerShell.Exiting line,
#          no finally block, no voluntary stop from the child
#   taskkill /F /T on the holder (no job at all)
#       -> identical: same three deaths, same total silence
#   holder NOT in a job, holder killed
#       -> runner and child both survive, heartbeats continue
#   runner killed on its own
#       -> the child notices and writes its voluntary stop line
#
# So the observed signature has exactly two shapes that produce it, a job object
# with kill on close somewhere above the runner, and a tree kill aimed at an
# ancestor, and NEITHER of them can be recorded by the dying process: both are
# TerminateProcess, which runs no handler, no finally and no exit event.
#
# ── WHAT THIS FILE THEREFORE DOES ───────────────────────────────────────────
# Three things, because no one of them is sufficient:
#
#   1. IDENTITY, written once at start into the run directory: the runner's pid
#      and start time, its full ancestry with creation times and command lines,
#      whether it is inside a job object and with which limit flags, its console
#      window and every process attached to that console. If the next occurrence
#      is a job close, the flags recorded here say so before it happens.
#
#   2. A KILL LEDGER. Every kill the runner issues is logged with the target
#      pid, image and creation time, and a TREE kill whose target is the runner
#      or one of its ancestors is REFUSED rather than issued. The ancestry is
#      matched on pid AND creation time, so a recycled pid cannot make an
#      unrelated process look like an ancestor, nor hide one.
#
#   3. A WATCHDOG, in its own process, detached from the runner's console and
#      broken out of the runner's job where the job permits it. It only ever
#      observes. When the runner disappears without writing the end marker it
#      records the moment, which ancestors went with it, what the log said last,
#      and the event log of the preceding two minutes. It exits by itself when
#      the run ends and it never kills anything.
#
# Last gasp handlers (console ctrl, PowerShell.Exiting, AppDomain ProcessExit,
# try/finally) are registered as well. They are cheap and they catch the ordinary
# deaths. They will NOT catch this one, which is precisely why item 3 exists.

# ── Native helpers ───────────────────────────────────────────────────────────
if (-not ('PsmuxForensics' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class PsmuxForensics {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool IsProcessInJob(IntPtr hProcess, IntPtr hJob, out bool result);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr hJob, int infoClass, IntPtr info, uint len, IntPtr ret);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] static extern uint GetConsoleProcessList(uint[] list, uint count);

    [StructLayout(LayoutKind.Sequential)]
    struct BASIC {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IOC { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)]
    struct EXT { public BASIC Basic; public IOC Io; public UIntPtr p1, p2, p3, p4; }

    public static bool InJob() {
        bool r;
        if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out r)) { return false; }
        return r;
    }

    // Limit flags of the job this process is in. With nested jobs this is the
    // innermost one, which is all user mode can see; an outer job is invisible
    // from here, so "no kill on close" is never proof that nothing above us
    // kills on close.
    public static string JobLimitFlags() {
        var info = new EXT();
        int len = Marshal.SizeOf(info);
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
            if (!QueryInformationJobObject(IntPtr.Zero, 9, buf, (uint)len, IntPtr.Zero)) {
                return "query-failed-" + Marshal.GetLastWin32Error();
            }
            info = (EXT)Marshal.PtrToStructure(buf, typeof(EXT));
            uint f = info.Basic.LimitFlags;
            string s = "0x" + f.ToString("X8");
            if ((f & 0x00002000) != 0) { s += " KILL_ON_JOB_CLOSE"; }
            if ((f & 0x00000800) != 0) { s += " BREAKAWAY_OK"; }
            if ((f & 0x00001000) != 0) { s += " SILENT_BREAKAWAY_OK"; }
            if ((f & 0x00000008) != 0) { s += " ACTIVE_PROCESS_LIMIT=" + info.Basic.ActiveProcessLimit; }
            if ((f & 0x00000400) != 0) { s += " DIE_ON_UNHANDLED_EXCEPTION"; }
            if (f == 0) { s += " (none)"; }
            return s;
        } finally { Marshal.FreeHGlobal(buf); }
    }

    public static long ConsoleWindow() { return GetConsoleWindow().ToInt64(); }

    // Every process attached to this console. A console control event is
    // delivered to all of them, so this is the list of processes that a window
    // close or a Ctrl+C aimed at this console would reach.
    public static int[] ConsoleProcesses() {
        uint n = GetConsoleProcessList(new uint[1], 1);
        if (n == 0) { return new int[0]; }
        var buf = new uint[n + 8];
        uint got = GetConsoleProcessList(buf, (uint)buf.Length);
        if (got == 0) { return new int[0]; }
        if (got > buf.Length) { got = (uint)buf.Length; }
        var res = new int[got];
        for (int i = 0; i < got; i++) { res[i] = (int)buf[i]; }
        return res;
    }

    // ── Last gasp console control handler ────────────────────────────────────
    // Registered AFTER the abort handler, so it runs FIRST (handlers fire in
    // reverse registration order) and returns false, leaving the abort handler
    // to decide the outcome. It only writes a line.
    delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);
    static HandlerRoutine _h;     // must stay rooted or the GC frees it under Windows
    static string _gaspFile;

    public static void InstallGasp(string file) {
        _gaspFile = file;
        _h = new HandlerRoutine(OnCtrl);
        SetConsoleCtrlHandler(_h, true);
    }

    static bool OnCtrl(uint t) {
        string what;
        switch (t) {
            case 0: what = "CTRL_C_EVENT"; break;
            case 1: what = "CTRL_BREAK_EVENT"; break;
            case 2: what = "CTRL_CLOSE_EVENT"; break;
            case 5: what = "CTRL_LOGOFF_EVENT"; break;
            case 6: what = "CTRL_SHUTDOWN_EVENT"; break;
            default: what = "CTRL_UNKNOWN_" + t; break;
        }
        Gasp("console control event " + what);
        return false;   // never veto: the abort handler owns that decision
    }

    public static void Gasp(string why) {
        try {
            if (_gaspFile == null) { return; }
            File.AppendAllText(_gaspFile,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " LASTGASP " + why + "\r\n");
        } catch { }
    }
}
'@ -ErrorAction SilentlyContinue
}

# ── State ────────────────────────────────────────────────────────────────────
$script:ForensicDir      = $null
$script:ForensicIdentity = $null   # <run dir>\runner_identity.log
$script:ForensicKills    = $null   # <run dir>\kills.log
$script:ForensicGasp     = $null   # <run dir>\last_gasp.log
$script:ForensicEndMark  = $null   # <run dir>\runner_end.marker
$script:ForensicOwnChain = @{}     # pid -> start ticks, the runner and its ancestors
$script:ForensicWatchdog = $null
$script:ForensicEnabled  = $false

function Write-Forensic {
    param([string]$Message, [string]$File)
    if (-not $File) { return }
    try {
        [System.IO.File]::AppendAllText($File,
            ("[{0}] {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message))
    } catch { }
}

# Pid plus creation time, the same anchor psmux uses for its own .pid files and
# the launcher uses for its run lock. A pid on its own is worthless here: the
# whole point is to survive pid reuse.
function Get-ProcAnchor {
    param([int]$TargetPid)
    if ($TargetPid -le 0) { return $null }
    try {
        $p = Get-Process -Id $TargetPid -ErrorAction Stop
        $ticks = 0L
        try { $ticks = $p.StartTime.Ticks } catch { }
        return [pscustomobject]@{ Pid = $TargetPid; Name = $p.ProcessName; Ticks = $ticks }
    } catch { return $null }
}

# ── 1. Identity ──────────────────────────────────────────────────────────────
function Initialize-RunForensics {
    param([string]$RunDir, [string]$RunId)

    $script:ForensicDir      = $RunDir
    $script:ForensicIdentity = Join-Path $RunDir 'runner_identity.log'
    $script:ForensicKills    = Join-Path $RunDir 'kills.log'
    $script:ForensicGasp     = Join-Path $RunDir 'last_gasp.log'
    $script:ForensicEndMark  = Join-Path $RunDir 'runner_end.marker'
    $script:ForensicEnabled  = $true

    # -Resume reuses the run directory, so a stale end marker from the previous
    # attempt would tell the new watchdog the run is already over. Clear it, and
    # separate this attempt's identity from the last one's in the same file.
    Remove-Item $script:ForensicEndMark -Force -ErrorAction SilentlyContinue

    $me = Get-Process -Id $PID
    $myTicks = 0L
    try { $myTicks = $me.StartTime.Ticks } catch { }

    Write-Forensic "===== runner identity, run $RunId =====" $script:ForensicIdentity
    Write-Forensic ("runner pid={0} name={1} started={2} host={3} ps={4}" -f `
        $PID, $me.ProcessName,
        $(try { $me.StartTime.ToString('yyyy-MM-dd HH:mm:ss.fff') } catch { '<unknown>' }),
        $env:COMPUTERNAME, $PSVersionTable.PSVersion) $script:ForensicIdentity

    # Ancestry, with creation time and command line at every level. Captured now
    # because by the time anything reads this the chain is usually dead, and a
    # bare pid after the fact is meaningless.
    $script:ForensicOwnChain = @{}
    $script:ForensicOwnChain[$PID] = $myTicks
    $cur = $PID
    $depth = 0
    while ($depth -lt 16 -and $cur -gt 0) {
        $ci = $null
        try {
            $ci = Get-CimInstance -Query ("SELECT ProcessId,ParentProcessId,Name,CommandLine,CreationDate FROM Win32_Process WHERE ProcessId={0}" -f $cur) -ErrorAction SilentlyContinue
        } catch { }
        if (-not $ci) { Write-Forensic ("ancestry[{0}] pid={1} <not readable>" -f $depth, $cur) $script:ForensicIdentity; break }
        $cl = (([string]$ci.CommandLine) -replace '\s+', ' ').Trim()
        if ($cl.Length -gt 400) { $cl = $cl.Substring(0, 400) + '...' }
        $created = try { $ci.CreationDate.ToString('yyyy-MM-dd HH:mm:ss.fff') } catch { '<unknown>' }
        Write-Forensic ("ancestry[{0}] pid={1} name={2} created={3} cmd=[{4}]" -f `
            $depth, $ci.ProcessId, $ci.Name, $created, $cl) $script:ForensicIdentity
        $a = Get-ProcAnchor ([int]$ci.ProcessId)
        if ($a) { $script:ForensicOwnChain[[int]$ci.ProcessId] = $a.Ticks }
        $next = [int]$ci.ParentProcessId
        if ($next -eq $cur) { break }
        $cur = $next
        $depth++
    }

    # Job membership. This is the single most valuable line in the file: if the
    # next disappearance is a job close, the flags here name the mechanism.
    $inJob = $false
    try { $inJob = [PsmuxForensics]::InJob() } catch { }
    $flags = '<unavailable>'
    if ($inJob) { try { $flags = [PsmuxForensics]::JobLimitFlags() } catch { } }
    Write-Forensic ("job inJob={0} limitFlags={1}" -f $inJob, $flags) $script:ForensicIdentity
    if ($inJob -and $flags -match 'KILL_ON_JOB_CLOSE') {
        Write-Forensic "job WARNING this run is inside a job object that KILLS ON CLOSE: whoever holds that job handle can end this whole tree instantly, with nothing written anywhere" $script:ForensicIdentity
        Write-Host "  [FORENSICS] this run is inside a KILL_ON_JOB_CLOSE job object; the run dies if that handle closes" -ForegroundColor DarkYellow
    } elseif ($inJob) {
        # Worth saying out loud even when the innermost job looks harmless.
        # QueryInformationJobObject can only describe the job a process is
        # directly in, so an OUTER job that kills on close is invisible from
        # here, and a run launched from a shell that lives inside one ends the
        # moment that shell's owner goes away.
        Write-Host "  [FORENSICS] this run is inside a job object; if an OUTER job kills on close, the run ends when its owner does" -ForegroundColor DarkGray
    }
    Write-Forensic "job note nested jobs hide the outer ones, so flags above describe the INNERMOST job only" $script:ForensicIdentity

    # Console identity, and everyone attached to it. A console control event
    # reaches every pid on this list and nothing else.
    $cw = 0
    try { $cw = [PsmuxForensics]::ConsoleWindow() } catch { }
    Write-Forensic ("console window=0x{0:X} title=[{1}]" -f $cw, $(try { [PsmuxWinAudit]::GetTitle() } catch { '<unknown>' })) $script:ForensicIdentity
    try {
        foreach ($cp in [PsmuxForensics]::ConsoleProcesses()) {
            $n = try { (Get-Process -Id $cp -ErrorAction Stop).ProcessName } catch { '<gone>' }
            Write-Forensic ("console attached pid={0} name={1}" -f $cp, $n) $script:ForensicIdentity
        }
    } catch { }

    # Environment that says who launched this. An agent session leaks its
    # identity through these; the launcher scrubs them, so their absence here is
    # itself a fact worth recording.
    foreach ($n in 'CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','CLAUDE_CODE_CHILD_SESSION','WT_SESSION','TERM_PROGRAM','SSH_CONNECTION','PSMUX_RUN_NOPAUSE','PSMUX_TEST_SANDBOX','CI') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { Write-Forensic ("env {0}=[{1}]" -f $n, $v) $script:ForensicIdentity }
    }

    # ── Last gasp handlers ───────────────────────────────────────────────────
    # The console handler is native, so it runs on the thread Windows injects and
    # needs nothing from PowerShell. PowerShell.Exiting is the engine's own hook
    # and runs on the pipeline thread.
    #
    # NOT AppDomain.ProcessExit or AppDomain.UnhandledException: a PowerShell
    # script block attached to those runs on a CLR thread with no runspace, and
    # measured 2026-09-21 it throws
    #     PSInvalidOperationException: There is no Runspace available to run
    #     scripts in this thread
    # ON EVERY CLEAN EXIT, printing an unhandled exception and changing the
    # runner's exit code. A forensic hook that breaks the ordinary path to
    # describe the extraordinary one is worse than no hook.
    try { [PsmuxForensics]::InstallGasp($script:ForensicGasp) } catch { }
    try {
        Register-EngineEvent PowerShell.Exiting -Action {
            try { [PsmuxForensics]::Gasp('PowerShell.Exiting') } catch { }
        } -ErrorAction SilentlyContinue | Out-Null
    } catch { }

    Write-Forensic ("kill ledger: every kill this runner issues is recorded here; a TREE kill aimed at pid {0} or any ancestor above is refused" -f $PID) $script:ForensicKills

    Start-RunnerWatchdog -RunDir $RunDir
}

# ── 2. Kill ledger ───────────────────────────────────────────────────────────
# Returns $true when the caller may proceed. A tree kill aimed at this runner or
# one of its ancestors is refused: that is the exact shape that would end a run
# with nothing written, so it must never be issued, and if something ever asks
# for it the refusal is the evidence.
function Test-KillTargetSafe {
    param(
        [int]$TargetPid,
        [string]$Reason,
        [switch]$Tree
    )
    if (-not $script:ForensicEnabled) { return $true }

    $kind = if ($Tree) { 'TREE' } else { 'single' }

    if ($TargetPid -le 4) {
        Write-Forensic ("KILL-REFUSED {0} target={1} reason=[{2}] why=system-pid" -f $kind, $TargetPid, $Reason) $script:ForensicKills
        return $false
    }

    $anchor = Get-ProcAnchor $TargetPid
    $desc = if ($anchor) {
        "image={0} created={1}" -f $anchor.Name, $(if ($anchor.Ticks) { ([datetime]$anchor.Ticks).ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '<unknown>' })
    } else { 'image=<already gone>' }

    if ($script:ForensicOwnChain.ContainsKey($TargetPid)) {
        $known = [long]$script:ForensicOwnChain[$TargetPid]
        $now   = if ($anchor) { [long]$anchor.Ticks } else { 0L }
        if ($known -ne 0 -and $now -ne 0 -and $known -ne $now) {
            # Same pid, different process: the ancestor died and Windows handed
            # the number to something else. Not ours, and not protected.
            Write-Forensic ("KILL-ALLOW {0} target={1} {2} reason=[{3}] note=pid-was-an-ancestor-but-has-been-recycled" -f `
                $kind, $TargetPid, $desc, $Reason) $script:ForensicKills
            return $true
        }
        $what = if ($TargetPid -eq $PID) { 'the runner itself' } else { 'an ancestor of the runner' }
        Write-Forensic ("KILL-REFUSED {0} target={1} {2} reason=[{3}] why={4}" -f $kind, $TargetPid, $desc, $Reason, $what) $script:ForensicKills
        Write-Host ("  [FORENSICS] REFUSED a {0} kill of pid {1}: it is {2}" -f $kind, $TargetPid, $what) -ForegroundColor Red
        try { [PsmuxForensics]::Gasp("refused a $kind kill of pid $TargetPid ($what) for [$Reason]") } catch { }
        return $false
    }

    Write-Forensic ("KILL {0} target={1} {2} reason=[{3}]" -f $kind, $TargetPid, $desc, $Reason) $script:ForensicKills
    return $true
}

function Write-KillNote {
    param([string]$Message)
    if (-not $script:ForensicEnabled) { return }
    Write-Forensic $Message $script:ForensicKills
}

# ── 3. Watchdog ──────────────────────────────────────────────────────────────
# Started detached from this console and, where the job permits it, broken out
# of this runner's job, so that whatever ends the run does not end the only
# witness to it. It observes and never kills.
function Start-RunnerWatchdog {
    param([string]$RunDir)

    $script:ForensicWatchdog = $null
    $wd = Join-Path $PSScriptRoot 'runner_watchdog.ps1'
    if (-not (Test-Path $wd)) {
        Write-Forensic "watchdog NOT started: runner_watchdog.ps1 is missing" $script:ForensicIdentity
        return
    }

    $me = Get-Process -Id $PID
    $ticks = 0L
    try { $ticks = $me.StartTime.Ticks } catch { }
    $chain = (($script:ForensicOwnChain.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key):$($_.Value)" }) -join ',')

    $pwsh = (Get-Process -Id $PID).Path
    if (-not $pwsh) { $pwsh = 'pwsh' }
    $cmdline = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -RunDir "{2}" -RunnerPid {3} -RunnerTicks {4} -Chain "{5}"' -f `
        $pwsh, $wd, $RunDir, $PID, $ticks, $chain

    $wpid = 0
    $how = ''
    $outsideJob = $false

    # ── (a) Win32_Process.Create ─────────────────────────────────────────────
    # Measured 2026-09-21, and the reason this is FIRST rather than a fallback:
    #   CreateProcess CREATE_BREAKAWAY_FROM_JOB  -> inJob=True  (still in a job)
    #   Win32_Process.Create                     -> inJob=False (parent WmiPrvSE)
    # Breakaway only lifts a process out of its INNERMOST job, so where jobs are
    # nested (an agent tool shell is, here) the child lands in the outer job and
    # dies with the tree exactly like the runner. WMI creates the process from a
    # service host instead, which is in none of our jobs and on none of our
    # consoles. ShowWindow=SW_HIDE keeps its console off the desktop so the
    # leftover audit has nothing new to look at.
    try {
        $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 } -ErrorAction Stop
        $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = $cmdline; CurrentDirectory = $RunDir; ProcessStartupInformation = $si
        } -ErrorAction Stop
        if ($res -and $res.ReturnValue -eq 0 -and $res.ProcessId -gt 0) {
            $wpid = [int]$res.ProcessId
            $how = 'Win32_Process.Create hidden (parented to WmiPrvSE, outside every job of ours)'
            $outsideJob = $true
        } else {
            Write-Forensic ("watchdog WMI launch returned {0}" -f $(if ($res) { $res.ReturnValue } else { '<null>' })) $script:ForensicIdentity
        }
    } catch {
        Write-Forensic ("watchdog WMI launch failed: {0}" -f $_.Exception.Message) $script:ForensicIdentity
    }

    # (b) Native fallback. CREATE_NO_WINDOW, never DETACHED_PROCESS: measured
    #     2026-09-21, a pwsh started DETACHED_PROCESS gets no valid standard
    #     handles and dies on startup without writing a byte, which is a
    #     spectacularly bad property in a witness.
    if ($wpid -le 0) {
    try {
        if (-not ('PsmuxDetach' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PsmuxDetach {
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO {
        public int cb; public string r1, r2, r3;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    // lpCommandLine is written to by CreateProcessW, so it must be a writable
    // buffer: a StringBuilder, never a managed string.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
    const uint CREATE_NO_WINDOW          = 0x08000000;
    const uint CREATE_NEW_PROCESS_GROUP  = 0x00000200;

    // Returns the new pid, or -lastError when CreateProcess refused.
    public static int Spawn(string cmdline, string cwd, bool breakaway) {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        PROCESS_INFORMATION pi;
        uint flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP;
        if (breakaway) { flags |= CREATE_BREAKAWAY_FROM_JOB; }
        var buf = new System.Text.StringBuilder(cmdline, cmdline.Length + 8);
        if (!CreateProcessW(null, buf, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, cwd, ref si, out pi)) {
            return -Marshal.GetLastWin32Error();
        }
        int id = pi.dwProcessId;
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return id;
    }
}
'@ -ErrorAction Stop
        }
        $r = [PsmuxDetach]::Spawn($cmdline, $RunDir, $true)
        if ($r -gt 0) { $wpid = $r; $how = 'CreateProcess CREATE_BREAKAWAY_FROM_JOB|CREATE_NO_WINDOW (leaves the innermost job only)' }
        else {
            Write-Forensic ("watchdog breakaway launch refused: win32 error {0}" -f (-$r)) $script:ForensicIdentity
            # (c) Same call without the breakaway bit: off this console, but
            #     still in our job, so it will die with the tree. Recorded as
            #     such, because a witness that dies with the event is no witness.
            $r2 = [PsmuxDetach]::Spawn($cmdline, $RunDir, $false)
            if ($r2 -gt 0) { $wpid = $r2; $how = 'CreateProcess CREATE_NO_WINDOW (still inside our job)' }
            else { Write-Forensic ("watchdog plain launch refused: win32 error {0}" -f (-$r2)) $script:ForensicIdentity }
        }
    } catch {
        Write-Forensic ("watchdog native launch failed: {0}" -f $_.Exception.Message) $script:ForensicIdentity
    }
    }

    if ($wpid -gt 0) {
        $script:ForensicWatchdog = $wpid
        if ($script:AuditOwnPids -is [hashtable]) { $script:AuditOwnPids[$wpid] = $true }
        Write-Forensic ("watchdog pid={0} outsideOurJobs={1} via {2}" -f $wpid, $outsideJob, $how) $script:ForensicIdentity
        Write-Host ("  Runner watchdog pid {0} ({1})" -f $wpid, $how) -ForegroundColor DarkGray
    } else {
        Write-Forensic "watchdog NOT started: every launch path was refused" $script:ForensicIdentity
        Write-Host "  (runner watchdog did not start; a silent disappearance will go unrecorded)" -ForegroundColor DarkYellow
    }
}

# ── End marker ───────────────────────────────────────────────────────────────
# The watchdog treats the runner going away WITHOUT this file as the event worth
# recording. Written on every deliberate end, including an abort and a fatal
# error, so only a death nobody chose produces a snapshot.
function Complete-RunForensics {
    param([string]$Status = 'finished')
    if (-not $script:ForensicEnabled) { return }
    try {
        [System.IO.File]::WriteAllText($script:ForensicEndMark,
            ("{0} {1} pid={2}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Status, $PID))
    } catch { }
    Write-Forensic ("run ended: {0}" -f $Status) $script:ForensicIdentity
}
