# repro_spawn_dll_init_failed.ps1
#
# Tries to reproduce pwsh panes dying at birth with 0xC0000142
# (STATUS_DLL_INIT_FAILED), the "application was unable to start correctly"
# dialog.
#
# Hypothesis under test
# ---------------------
# crates\portable-pty-psmux\src\win\psuedocon.rs parks the process-wide std
# handles on NULL around CreateProcessW, serialized by console_state_lock():
#
#     let _console_guard = crate::console_state_lock();
#     SetStdHandle(STD_INPUT_HANDLE,  ptr::null_mut());
#     SetStdHandle(STD_OUTPUT_HANDLE, ptr::null_mut());
#     SetStdHandle(STD_ERROR_HANDLE,  ptr::null_mut());
#
# The NULLing is process wide but the lock only covers callers that take it.
# Any spawn reaching CreateProcessW during that window inherits NULL std
# handles, and a pwsh child born that way cannot initialize ConsoleHost.dll,
# which is exactly 0xC0000142.
#
# So: spawn many DEFAULT-SHELL panes (pwsh) while hammering the console state
# with send-keys C-c, which drives the FreeConsole/AttachConsole path.  If the
# hypothesis holds, some births die with 0xC0000142.
#
# This script only GENERATES the load.  Attribution comes from
# tests\watch_spawn_failures.ps1, which must be running concurrently.
#
# Safety: touches only its own session, torn down with kill-session -t.
# It never kills processes by name and never calls kill-server.

param(
    [int]$Spawns   = 25,
    [int]$StormSec = 45,
    [string]$Session = "spawnrace",
    [switch]$NoStorm,        # control arm: same spawns, no console hammering
    [int]$Parallel = 1,      # concurrent spawner jobs; >1 races births directly
    [int]$GapMs    = 350     # delay between spawns within one spawner
)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

function Say($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }

# --- teardown of any previous run, scoped to this session only ---
& $PSMUX kill-session -t $Session 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
Remove-Item "$psmuxDir\$Session.*" -Force -EA SilentlyContinue

# Cold spawns.  The warm pane pool would hand out pre-built shells and hide the
# birth race entirely.
$env:PSMUX_NO_WARM = "1"

Say "=== repro: pwsh pane births under console pressure ===" Cyan
Say ("spawns={0}  storm={1}  session={2}" -f $Spawns, $(if($NoStorm){'OFF (control arm)'}else{"${StormSec}s"}), $Session) DarkGray

& $PSMUX new-session -d -s $Session
Start-Sleep -Seconds 3
& $PSMUX has-session -t $Session 2>$null
if ($LASTEXITCODE -ne 0) {
    Say "session creation failed, aborting" Red
    $env:PSMUX_NO_WARM = $null
    exit 1
}
Say "session up" Green

$hammer = $null
if (-not $NoStorm) {
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Session.key"  -Raw).Trim()

    # send-keys C-c drives the server's console attach/detach path, which is
    # what makes the std handle slots move underneath a concurrent spawn.
    $hammer = Start-Job -ScriptBlock {
        param($port, $key, $sess, $secs)
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
            $tcp.NoDelay = $true
            $stream = $tcp.GetStream()
            $writer = [System.IO.StreamWriter]::new($stream)
            $reader = [System.IO.StreamReader]::new($stream)
            $writer.Write("AUTH $key`n"); $writer.Flush()
            $null = $reader.ReadLine()
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt $secs) {
                $writer.Write("send-keys -t ${sess}:0 C-c`n"); $writer.Flush()
                Start-Sleep -Milliseconds 15
            }
            $tcp.Close()
        } catch { }
    } -ArgumentList $port, $key, $Session, $StormSec
    Start-Sleep -Milliseconds 500
    Say "console storm running" Yellow
}

# --- the spawns under test: default shell, so these are real pwsh births ---
# With -Parallel > 1 the spawners run concurrently, so several CreateProcessW
# calls are in flight at once.  That is what actually races the process-wide
# std handle parking; a serialized loop gives each birth the window to itself
# and will not reproduce a birth race.
$ok = 0
if ($Parallel -le 1) {
    for ($i = 1; $i -le $Spawns; $i++) {
        & $PSMUX new-window -t $Session 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok++ }
        Start-Sleep -Milliseconds $GapMs
        if ($i % 5 -eq 0) { Say ("  spawned {0}/{1}" -f $i, $Spawns) DarkGray }
    }
} else {
    $per = [math]::Ceiling($Spawns / $Parallel)
    Say ("  {0} concurrent spawners x {1} each, gap {2}ms" -f $Parallel, $per, $GapMs) DarkGray
    $jobs = @()
    for ($j = 0; $j -lt $Parallel; $j++) {
        $jobs += Start-Job -ScriptBlock {
            param($exe, $sess, $n, $gap)
            $good = 0
            for ($k = 0; $k -lt $n; $k++) {
                & $exe new-window -t $sess 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $good++ }
                if ($gap -gt 0) { Start-Sleep -Milliseconds $gap }
            }
            $good
        } -ArgumentList $PSMUX, $Session, $per, $GapMs
    }
    foreach ($j in $jobs) {
        $r = Receive-Job -Job $j -Wait -EA SilentlyContinue
        if ($r -is [int]) { $ok += $r }
    }
    $jobs | Remove-Job -Force -EA SilentlyContinue
}

Start-Sleep -Seconds 3

# How many panes actually survived?  A pane whose shell died at birth still
# leaves a pane slot, so compare reported panes against live pwsh children.
$wins = (& $PSMUX display-message -t $Session -p '#{session_windows}' 2>&1 | Out-String).Trim()
Say ("windows reported by psmux: {0} (expected about {1})" -f $wins, ($Spawns + 1)) Cyan

if ($hammer) {
    Receive-Job -Job $hammer -Wait -EA SilentlyContinue | Out-Null
    Remove-Job $hammer -Force -EA SilentlyContinue
}

# --- teardown, scoped ---
& $PSMUX kill-session -t $Session 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
Remove-Item "$psmuxDir\$Session.*" -Force -EA SilentlyContinue
$env:PSMUX_NO_WARM = $null

Say ("done. new-window calls returning 0: {0}/{1}" -f $ok, $Spawns) Cyan
Say "check the watcher output for 0xC0000142 records" DarkGray
