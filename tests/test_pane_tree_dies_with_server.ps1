# A pane's processes end with the pane, the window, the session and the server.
#
# tmux: when a pane is destroyed or the server exits, the pty master is closed
# and the pane's process group gets SIGHUP (window.c window_pane_destroy closes
# wp->fd; server.c server_loop/server_exit tears every pane down), so a shell
# and what it runs die with it.  On Windows the pane's pseudoconsole conhost
# plays the pty: when its owner goes away, conhost ends every client attached
# to it.  What must NOT die with the server is what a pane deliberately
# detaches: a psmux server started from inside a pane (`tmux new -d` inside tmux
# keeps running) and a program it started with Start-Process (ShellExecute), both
# of which leave the pane's job.  (kill-server itself still ends the latter
# through psmux's descendant reap, as it did before.)
#
# Background: a sweep on 2026-10-02 ended with 48 pwsh -> htop -> pstop trees
# and 51 idle pane shells alive with their servers dead.  None of the endings
# below leaks on cb783dc (90 cells, 3 repetitions of the full matrix, plus a
# graceful kill-server raced against TerminateProcess and a job kill), so this
# suite pins that contract.  What it also pins is a real defect found on the
# way: every ConPTY pipe end was created INHERITABLE, so each child the server
# spawns through std Command (pipe-pane, run-shell, if-shell, hooks, status
# jobs) took copies of every pane's pty pipes.  On cb783dc a 3 pane server
# held 22 inheritable pipe handles and a pipe-pane child held 6 of them.
#
# Every server lives in an isolated PSMUX_DATA_DIR and a unique `-L ptd_<rand>`
# namespace, cleaned up with `-L <ns> kill-server`; a process of this suite is
# stopped by exact PID (with its start time checked) and only if it was
# recorded as part of a pane tree this suite created.  pstop rows SKIP when
# pstop is not installed.
#
# Binary: PSMUX_TEST_BIN, else target\release of this checkout prepended to PATH.

$ErrorActionPreference = "Continue"
if ($env:PSMUX_TEST_BIN) {
    $env:PATH = (Split-Path $env:PSMUX_TEST_BIN) + ";" + $env:PATH
} else {
    $rel = (Resolve-Path "$PSScriptRoot\..\target\release" -EA SilentlyContinue).Path
    if ($rel) { $env:PATH = "$rel;" + $env:PATH }
}
$PSMUX = (Get-Command psmux -EA SilentlyContinue).Source
if (-not $PSMUX) { Write-Host "FATAL: psmux binary not found" -ForegroundColor Red; exit 1 }
Write-Host "binary: $PSMUX ($(& $PSMUX -V | Select-Object -Last 1))" -ForegroundColor Cyan

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_TARGET_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX_NO_WARM') {
    Remove-Item "Env:\$v" -EA SilentlyContinue
}
$rig = Join-Path $env:TEMP ("psmux-ptd-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $rig | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $rig 'data'
New-Item -ItemType Directory -Force -Path $env:PSMUX_DATA_DIR | Out-Null

Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class PtdNative {
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern bool DuplicateHandle(IntPtr sp, IntPtr sh, IntPtr tp, out IntPtr th, uint a, bool i, uint o);
  [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr h);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int c, out IntPtr v, int l, out int r);
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int c, IntPtr b, int l, out int r);
  [DllImport("ntdll.dll")] static extern int NtQueryObject(IntPtr h, int c, IntPtr b, int l, out int r);
  // The conhost a process is attached to (ProcessConsoleHostProcess).
  public static int ConsoleHost(int pid) {
    IntPtr h = OpenProcess(0x1000, false, pid); if (h == IntPtr.Zero) return 0;
    try { IntPtr v; int r; if (NtQueryInformationProcess(h, 49, out v, IntPtr.Size, out r) != 0) return 0; return (int)(v.ToInt64() & ~3L); }
    finally { CloseHandle(h); }
  }
  public class H { public int Pid; public long Handle; public long Obj; public uint Attr; }
  public static List<H> Handles(HashSet<int> pids) {
    int len = 1 << 22; IntPtr buf; int ret;
    while (true) { buf = Marshal.AllocHGlobal(len); int st = NtQuerySystemInformation(64, buf, len, out ret);
      if (st == unchecked((int)0xC0000004)) { Marshal.FreeHGlobal(buf); len = Math.Max(len * 2, ret + 65536); continue; }
      if (st != 0) { Marshal.FreeHGlobal(buf); return new List<H>(); } break; }
    var list = new List<H>(); long n = Marshal.ReadIntPtr(buf).ToInt64(); IntPtr p = buf + 16;
    for (long i = 0; i < n; i++, p += 40) { int pid = (int)Marshal.ReadIntPtr(p, 8).ToInt64(); if (!pids.Contains(pid)) continue;
      list.Add(new H { Pid = pid, Obj = Marshal.ReadIntPtr(p, 0).ToInt64(), Handle = Marshal.ReadIntPtr(p, 16).ToInt64(), Attr = (uint)Marshal.ReadInt32(p, 32) }); }
    Marshal.FreeHGlobal(buf); return list;
  }
  // True when the handle is a pipe (File object, FILE_TYPE_PIPE).
  public static bool IsPipe(int pid, long handle) {
    IntPtr proc = OpenProcess(0x0040, false, pid); if (proc == IntPtr.Zero) return false;
    IntPtr dup; bool ok = DuplicateHandle(proc, new IntPtr(handle), GetCurrentProcess(), out dup, 0, false, 2); CloseHandle(proc);
    if (!ok) return false;
    try {
      IntPtr b = Marshal.AllocHGlobal(1024); int r; string tn = "";
      if (NtQueryObject(dup, 2, b, 1024, out r) == 0) tn = Marshal.PtrToStringUni(Marshal.ReadIntPtr(b, 8), Marshal.ReadInt16(b) / 2);
      Marshal.FreeHGlobal(b);
      return tn == "File" && GetFileType(dup) == 3;
    } finally { CloseHandle(dup); }
  }
}
'@

function New-Ns { "ptd_" + [guid]::NewGuid().ToString('N').Substring(0, 10) }
function Snap { $h = @{}; foreach ($p in Get-CimInstance Win32_Process) { $h[[int]$p.ProcessId] = $p }; $h }
function Get-Desc($snap, [int]$root) {
    # descendants by PID; every link is checked: the parent was created no later than the child
    $out = @(); $q = [System.Collections.Queue]::new(); $q.Enqueue($root)
    while ($q.Count) {
        $id = $q.Dequeue(); $par = $snap[$id]; if (-not $par) { continue }
        foreach ($p in $snap.Values) {
            if ([int]$p.ParentProcessId -eq $id -and [int]$p.ProcessId -ne $id -and $p.CreationDate -ge $par.CreationDate) { $out += $p; $q.Enqueue([int]$p.ProcessId) }
        }
    }
    $out
}
function Rec($p) { [pscustomobject]@{ Pid = [int]$p.ProcessId; Name = $p.Name; Start = $p.CreationDate } }
function Test-Alive($r) {
    $g = Get-Process -Id $r.Pid -EA SilentlyContinue
    $g -and ([Math]::Abs(($g.StartTime - $r.Start).TotalSeconds) -lt 2)
}
function Fmt($list) { if (-not $list) { '-' } else { ($list | ForEach-Object { "$($_.Name -replace '\.exe$',''):$($_.Pid)" }) -join ' ' } }

# The pane's process tree: shell, every descendant, and the conhost it is attached to.
function Get-PaneTree([int]$panePid) {
    $snap = Snap
    if (-not $snap[$panePid]) { return @() }
    $t = @(Rec $snap[$panePid]) + @(Get-Desc $snap $panePid | ForEach-Object { Rec $_ })
    $ch = [PtdNative]::ConsoleHost($panePid)
    if ($ch -and $snap[$ch]) { $t += Rec $snap[$ch] }
    $t
}
function Wait-TreeGone($tree, [int]$ms = 10000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do { $alive = @($tree | Where-Object { Test-Alive $_ }); if (-not $alive.Count) { return @() }; Start-Sleep -Milliseconds 250 } while ($sw.ElapsedMilliseconds -lt $ms)
    $alive
}
$script:AllRecorded = New-Object System.Collections.Generic.List[object]
$script:Namespaces = New-Object System.Collections.Generic.List[string]

$pstop = (Get-Command pstop -EA SilentlyContinue | Select-Object -First 1).Source
$htop = (Get-Command htop -EA SilentlyContinue | Select-Object -First 1).Source
$payloads = [ordered]@{
    'ping -t'          = 'ping -t 127.0.0.1'
    'pstop'            = $(if ($pstop) { 'pstop' } else { $null })
    'htop shim -> pstop' = $(if ($htop) { 'htop' } else { $null })
}
$endings = @('kill-pane', 'kill-window', 'kill-session', 'kill-server', 'TerminateProcess of the server', 'respawn-pane -k')

Write-Host "`n=== pane trees end with their pane, window, session and server ===" -ForegroundColor Cyan
foreach ($pl in $payloads.Keys) {
    $cmd = $payloads[$pl]
    if (-not $cmd) { foreach ($en in $endings) { Write-Skip "$pl / ${en}: not installed" }; continue }
    foreach ($en in $endings) {
        $ns = New-Ns; $script:Namespaces.Add($ns)
        & $PSMUX -L $ns new-session -d -s s -x 120 -y 30 2>$null
        Start-Sleep -Milliseconds 1500
        $target = 's'
        if ($en -eq 'kill-pane') { & $PSMUX -L $ns split-window -t s 2>$null; Start-Sleep -Milliseconds 800; $target = (& $PSMUX -L $ns display-message -p -t s '#{pane_id}') }
        if ($en -eq 'kill-window') { & $PSMUX -L $ns new-window -t s 2>$null; Start-Sleep -Milliseconds 800; $target = (& $PSMUX -L $ns display-message -p -t s '#{window_id}') }
        $spid = [int](& $PSMUX -L $ns display-message -p -t s '#{pid}')
        $pane = [int](& $PSMUX -L $ns display-message -p -t $target '#{pane_pid}')
        & $PSMUX -L $ns send-keys -t $target $cmd Enter 2>$null
        # wait until the payload is running under the pane shell
        $sw = [Diagnostics.Stopwatch]::StartNew(); $tree = @()
        do { Start-Sleep -Milliseconds 300; $tree = @(Get-PaneTree $pane) } while ($sw.ElapsedMilliseconds -lt 8000 -and @($tree | Where-Object { $_.Name -match '^(PING|pstop|htop)\.exe$' }).Count -lt $(if ($pl -match 'htop') { 2 } else { 1 }))
        foreach ($r in $tree) { $script:AllRecorded.Add($r) }
        if (@($tree | Where-Object { $_.Name -match '^(PING|pstop)\.exe$' }).Count -lt 1) { Write-Fail "$pl / ${en}: the payload never started (tree: $(Fmt $tree))"; & $PSMUX -L $ns kill-server 2>$null; continue }
        switch ($en) {
            'kill-pane'    { & $PSMUX -L $ns kill-pane -t $target 2>$null }
            'kill-window'  { & $PSMUX -L $ns kill-window -t $target 2>$null }
            'kill-session' { & $PSMUX -L $ns kill-session -t s 2>$null }
            'kill-server'  { & $PSMUX -L $ns kill-server 2>$null }
            'TerminateProcess of the server' { Stop-Process -Id $spid -Force -EA SilentlyContinue }
            'respawn-pane -k' { & $PSMUX -L $ns respawn-pane -k -t s 2>$null }
        }
        $left = @(Wait-TreeGone $tree 10000)
        if ($left.Count) { Write-Fail "$pl / ${en}: survivors after 10 s: $(Fmt $left) (tree was $(Fmt $tree))" }
        else { Write-Pass "$pl / ${en}: the whole pane tree ended ($(Fmt $tree))" }
        & $PSMUX -L $ns kill-server 2>$null
    }
}

Write-Host "`n=== a server that dies while its panes are still starting takes them along ===" -ForegroundColor Cyan
# The 51 idle shells: `new-session -d` and then the server's death within about
# 150 ms (the runner's by-name kill, a suite killing its fresh server) left the
# warm pool spares that were being created at that instant alive for good, each
# with its conhost, which never noticed its owner had gone.  cb783dc leaked in
# 14 of 15 rounds at gap 0 and 11 of 15 at gap 150 ms, 0 at 400 ms and later.
$raceRounds = 8; $raceLeaks = 0; $raceLeft = @(); $raceFrozen = @()
foreach ($i in 1..$raceRounds) {
    $ns = New-Ns; $script:Namespaces.Add($ns)
    $t0 = Get-Date
    & $PSMUX -L $ns new-session -d -s r 2>$null
    if ($i % 2 -eq 0) { Start-Sleep -Milliseconds 120 }
    $srvs = @(Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" | Where-Object { $_.CommandLine -match "-L $ns(\s|$)" })
    foreach ($s in $srvs) { Stop-Process -Id $s.ProcessId -Force -EA SilentlyContinue }
    $srvIds = @($srvs | ForEach-Object { [int]$_.ProcessId })
    Start-Sleep -Seconds 4
    $left = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe' OR Name='conhost.exe'" |
        Where-Object { $srvIds -contains [int]$_.ParentProcessId -and $_.CreationDate -ge $t0 })
    foreach ($p in $left) {
        # A shell created suspended (the Store pwsh alias refuses the atomic job
        # list, so it is assigned to its job right after creation) whose server
        # died inside that CreateProcessW call stays frozen: every thread
        # suspended, it never ran and holds no conhost.  That residual is
        # counted apart; anything that RUNS fails the suite.
        $g = Get-Process -Id $p.ProcessId -EA SilentlyContinue
        $frozen = $g -and $p.Name -ne 'conhost.exe' -and @($g.Threads | Where-Object { $_.WaitReason -ne 'Suspended' }).Count -eq 0
        if ($frozen) { $raceFrozen += $p } else { $raceLeft += $p }
    }
    if (@($left | Where-Object { $raceFrozen -notcontains $_ }).Count) { $raceLeaks++ }
}
if ($raceLeaks -eq 0) { Write-Pass "$raceRounds servers killed 0 to 120 ms after new-session -d left no running pane shell or conhost behind" }
else { Write-Fail ("{0} of {1} servers killed right after new-session -d left running processes behind: {2}" -f $raceLeaks, $raceRounds, (($raceLeft | ForEach-Object { "$($_.Name):$($_.ProcessId)" }) -join ' ')) }
if ($raceFrozen.Count) { Write-Info ("frozen, never started shells (server killed inside their suspended CreateProcessW): {0}" -f (($raceFrozen | ForEach-Object { "$($_.Name):$($_.ProcessId)" }) -join ' ')) }
foreach ($p in @($raceLeft) + @($raceFrozen)) { $script:AllRecorded.Add((Rec $p)) }

Write-Host "`n=== the server keeps no inheritable pty pipe handle ===" -ForegroundColor Cyan
$ns = New-Ns; $script:Namespaces.Add($ns)
& $PSMUX -L $ns new-session -d -s s -x 120 -y 30 2>$null
Start-Sleep -Milliseconds 1500
& $PSMUX -L $ns split-window -t s 2>$null; & $PSMUX -L $ns new-window -t s 2>$null
# Children the server spawns through std Command: a pipe-pane sink and a run-shell from a hook.
& $PSMUX -L $ns pipe-pane -t 's:0.0' 'ping -n 30 127.0.0.1 >NUL' 2>$null
& $PSMUX -L $ns set-hook -g after-split-window "run-shell -b 'ping -n 30 127.0.0.1'" 2>$null
& $PSMUX -L $ns split-window -t s 2>$null
Start-Sleep -Milliseconds 2500
$spid = [int](& $PSMUX -L $ns display-message -p -t s '#{pid}')
$snap = Snap
$jobKids = @(Get-Desc $snap $spid | Where-Object { $_.Name -match '^(pwsh|cmd|PING)\.exe$' -and $_.CommandLine -notmatch 'PredictionSource None' })
$pids = [System.Collections.Generic.HashSet[int]]::new(); [void]$pids.Add($spid); foreach ($k in $jobKids) { [void]$pids.Add([int]$k.ProcessId) }
$hs = [PtdNative]::Handles($pids)
$inh = @($hs | Where-Object { $_.Pid -eq $spid -and ($_.Attr -band 2) -and [PtdNative]::IsPipe($spid, $_.Handle) })
if ($inh.Count -eq 0) { Write-Pass "the server holds 0 inheritable pipe handles" }
else { Write-Fail "the server holds $($inh.Count) inheritable pipe handles (each one rides into every pipe-pane, run-shell, if-shell and hook child)" }
$objs = @{}; foreach ($h in $hs) { if ($h.Pid -eq $spid -and $h.Obj -and [PtdNative]::IsPipe($spid, $h.Handle)) { $objs[$h.Obj] = 1 } }
if (-not $jobKids.Count) { Write-Fail "no pipe-pane or run-shell child was found under the server" }
elseif (-not $objs.Count) { Write-Skip "kernel object addresses are hidden (not elevated): cannot match handles across processes" }
else {
    $shared = @($hs | Where-Object { $_.Pid -ne $spid -and $objs.ContainsKey($_.Obj) } | Group-Object Pid)
    if ($shared.Count -eq 0) { Write-Pass "no pipe-pane or run-shell child ($(($jobKids | ForEach-Object { "$($_.Name):$($_.ProcessId)" }) -join ' ')) holds any of the server's pipe handles" }
    else { Write-Fail ("server spawned children hold copies of the server's pipe handles: " + (($shared | ForEach-Object { "pid $($_.Name) x$($_.Count)" }) -join ', ')) }
}
foreach ($k in $jobKids) { $script:AllRecorded.Add((Rec $k)) }
& $PSMUX -L $ns kill-server 2>$null

Write-Host "`n=== what a pane deliberately detaches survives the server ===" -ForegroundColor Cyan
$ns = New-Ns; $script:Namespaces.Add($ns)
$inner = New-Ns; $script:Namespaces.Add($inner)
$marker = Join-Path $rig 'detached_pid.txt'
& $PSMUX -L $ns new-session -d -s s -x 120 -y 30 2>$null
Start-Sleep -Milliseconds 1500
$spid = [int](& $PSMUX -L $ns display-message -p -t s '#{pid}')
& $PSMUX -L $ns send-keys -t s "psmux -L $inner new-session -d -s nested" Enter 2>$null
& $PSMUX -L $ns send-keys -t s "(Start-Process ping -ArgumentList '-n','40','127.0.0.1' -WindowStyle Hidden -PassThru).Id | Set-Content '$marker'" Enter 2>$null
$sw = [Diagnostics.Stopwatch]::StartNew(); $innerSrv = $null
do { Start-Sleep -Milliseconds 300; $innerSrv = (& $PSMUX -L $inner display-message -p -t nested '#{pid}' 2>$null) } while ($sw.ElapsedMilliseconds -lt 10000 -and -not ($innerSrv -match '^\d+$'))
$sw.Restart(); while ($sw.ElapsedMilliseconds -lt 10000 -and -not (Test-Path $marker)) { Start-Sleep -Milliseconds 300 }; Start-Sleep -Milliseconds 300
$detached = if (Test-Path $marker) { [int](Get-Content $marker | Select-Object -First 1) } else { 0 }
if (-not ($innerSrv -match '^\d+$')) { Write-Fail "the nested server never came up in namespace $inner" }
else {
    $innerRec = Rec ((Snap)[[int]$innerSrv])
    $detRec = if ($detached) { Rec ((Snap)[$detached]) } else { $null }
    Stop-Process -Id $spid -Force -EA SilentlyContinue
    & $PSMUX -L $ns kill-server 2>$null
    Start-Sleep -Seconds 3
    if (Test-Alive $innerRec) { Write-Pass "a psmux server started inside the pane (pid $($innerRec.Pid)) survives the outer server's death" }
    else { Write-Fail "the nested detached psmux server died with the outer server" }
    if (-not $detRec) { Write-Fail "the pane's Start-Process child was not recorded" }
    elseif (Test-Alive $detRec) { Write-Pass "a program the pane started with Start-Process (pid $($detRec.Pid)) survives the server's death"; $script:AllRecorded.Add($detRec) }
    else { Write-Fail "the pane's Start-Process child died with the server" }
}
& $PSMUX -L $inner kill-server 2>$null

# Cleanup: namespaces, then any recorded process of this suite still alive, by PID.
foreach ($n in $script:Namespaces) { & $PSMUX -L $n kill-server 2>$null }
Start-Sleep -Seconds 1
$stray = @($script:AllRecorded | Where-Object { Test-Alive $_ })
foreach ($r in $stray) { Stop-Process -Id $r.Pid -Force -EA SilentlyContinue }
if ($stray.Count) { Write-Info "stopped by PID after the checks: $(Fmt $stray)" }
Remove-Item -Recurse -Force $rig -EA SilentlyContinue

Write-Host "`nPASS: $script:Pass  FAIL: $script:Fail  SKIP: $script:Skip"
exit $(if ($script:Fail) { 1 } else { 0 })
