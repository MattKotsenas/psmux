# Issue #448: Harden server cleanup — reap live orphaned servers, store PID.
#
# Follow-up to the #444 spawn-race fix. Two structural gaps this test proves fixed:
#   1. A LIVE but orphaned server (a duplicate / a crashed client's headless
#      server) kept running forever because cleanup_stale_port_files only removed
#      registry files for servers proven DEAD. Now a startup reaper terminates
#      untracked live psmux server PROCESSES by identity.
#   2. The registry stored the TCP port but no PID. Now a `<base>.pid` is written
#      alongside `<base>.port`, giving each entry a stable process anchor.
#
# NOTE ON METHOD: a live psmux server self-heals its own registry files every ~5s
# (periodic ensure_session_registry_files). Deleting a server's registry files
# therefore creates only a TRANSIENT orphan. That is exactly the window in which
# the real reaper catches spawn-race duplicate LOSERS, so every orphan-then-reap
# step below acts immediately (sub-second) to stay inside that window, mirroring
# how a real `psmux` invocation reaps whatever is orphaned at that instant.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# .pid registry bodies are "pid" OR "pid:creation_filetime" (PR #404 format).
# Always strip the creation-time suffix before handing the value to Get-Process.
function Parse-Pid($raw) {
    if ($null -eq $raw) { return $null }
    return ([string]$raw).Trim().Split(':')[0]
}
function Is-PidAlive($procId) {
    $procId = Parse-Pid $procId
    if (-not ($procId -match '^\d+$')) { return $false }
    $p = Get-Process -Id ([int]$procId) -EA SilentlyContinue
    return ($null -ne $p -and -not $p.HasExited)
}
function Is-PsmuxPid($procId) {
    $procId = Parse-Pid $procId
    if (-not ($procId -match '^\d+$')) { return $false }
    $p = Get-Process -Id ([int]$procId) -EA SilentlyContinue
    return ($null -ne $p -and $p.ProcessName -eq 'psmux')
}
function ListenPid($port) {
    $line = (netstat -ano | Select-String -Pattern ":$port\s" | Select-String -Pattern "LISTENING" | Select-Object -First 1)
    if ($line) { return ($line.ToString() -split '\s+')[-1] }
    return $null
}
function Cleanup-Sessions {
    foreach ($s in @("reap_pidproof","reap_orphan","reap_legit","reap_young")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
        Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
}

Cleanup-Sessions
Write-Host "`n=== Issue #448: Orphan-server reaper + PID registry ===" -ForegroundColor Cyan

# === TEST 1: .pid file is written and matches the live server process ===
Write-Host "`n[Test 1] Registry stores the server PID (.pid) and it matches the listener" -ForegroundColor Yellow
& $PSMUX new-session -d -s reap_pidproof
Start-Sleep -Seconds 3
$pidFile  = "$psmuxDir\reap_pidproof.pid"
$portFile = "$psmuxDir\reap_pidproof.port"
if (Test-Path $pidFile) {
    Write-Pass ".pid file exists for the session"
    $recordedPid = Parse-Pid (Get-Content $pidFile -Raw)
    $port        = (Get-Content $portFile -Raw).Trim()
    $listenPid   = ListenPid $port
    if ($recordedPid -eq $listenPid) { Write-Pass ".pid ($recordedPid) matches the PID listening on port $port" }
    else { Write-Fail ".pid=$recordedPid but listener on $port is $listenPid" }
    if (Is-PsmuxPid $recordedPid) { Write-Pass "recorded PID is a live psmux process" }
    else { Write-Fail "recorded PID $recordedPid is not a live psmux process" }
} else {
    Write-Fail ".pid file was NOT written (claim #2 still present)"
}

# === TEST 2: an aged, live, orphaned server is reaped at startup ===
Write-Host "`n[Test 2] A live orphaned server (untracked) is terminated by the reaper" -ForegroundColor Yellow
& $PSMUX new-session -d -s reap_orphan
Start-Sleep -Seconds 3
$orphanPid  = (Get-Content "$psmuxDir\reap_orphan.pid" -Raw).Trim()
$orphanPort = (Get-Content "$psmuxDir\reap_orphan.port" -Raw).Trim()
Write-Host "    orphan server PID=$orphanPid port=$orphanPort; aging past 10s grace..." -ForegroundColor DarkGray
Start-Sleep -Seconds 12
# Orphan it: remove ALL registry files, then trigger the reaper IMMEDIATELY
# via any psmux command. The server rewrites its own registry files every few
# seconds (self-heal), and a server that has done so is tracked again, so the
# reaper is RIGHT to spare it. Sweep 2026-10-07_01-38-07 failed here once in
# about a dozen runs, never standalone: the rewrite landed between the delete
# and the reaper. So a survivor whose registry came back is that race and is
# orphaned again; a survivor with no registry file is a real reaper failure.
$reaped = $false; $selfHealed = 0
for ($attempt = 1; $attempt -le 3 -and -not $reaped; $attempt++) {
    Remove-Item "$psmuxDir\reap_orphan.*" -Force -EA SilentlyContinue
    if ($attempt -eq 1) {
        if (Is-PidAlive $orphanPid) { Write-Pass "orphan process still alive after registry removal (untracked live server)" }
        else { Write-Fail "orphan process died before reaper could run" }
    }
    & $PSMUX list-sessions 2>&1 | Out-Null   # runs cleanup + reaper at startup
    Start-Sleep -Seconds 2
    if (-not (Is-PidAlive $orphanPid)) { $reaped = $true; break }
    if (Test-Path "$psmuxDir\reap_orphan.port") {
        $selfHealed++
        Write-Host "    attempt ${attempt}: the server self-healed its registry before the reaper ran; orphaning it again" -ForegroundColor DarkGray
        continue
    }
    break
}
if ($reaped) { Write-Pass "reaper TERMINATED the orphaned server $orphanPid (self-heal races: $selfHealed)" }
else {
    Write-Fail "orphaned server $orphanPid survived the reaper with no registry file referencing it (self-heal races: $selfHealed)"
    Stop-Process -Id ([int](Parse-Pid $orphanPid)) -Force -EA SilentlyContinue
}

# === TEST 3: a legitimate session is NEVER reaped ===
Write-Host "`n[Test 3] A legitimate (tracked) session server is preserved" -ForegroundColor Yellow
& $PSMUX new-session -d -s reap_legit
Start-Sleep -Seconds 3
$legitPid = (Get-Content "$psmuxDir\reap_legit.pid" -Raw).Trim()
# Fire several reaper passes; a tracked server must survive all of them.
for ($i = 0; $i -lt 3; $i++) { & $PSMUX list-sessions 2>&1 | Out-Null; Start-Sleep -Milliseconds 300 }
if (Is-PidAlive $legitPid) { Write-Pass "legit server $legitPid survived repeated reaper passes" }
else { Write-Fail "reaper killed a legitimate session server $legitPid" }
& $PSMUX has-session -t reap_legit 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "legit session still reachable after reaper" }
else { Write-Fail "legit session became unreachable" }

# === TEST 4: grace window spares a genuinely young (mid-boot) server ===
Write-Host "`n[Test 4] Grace window spares a just-spawned (young) orphan" -ForegroundColor Yellow
$env:PSMUX_NO_WARM = "1"   # force a cold spawn so the PROCESS is genuinely young
& $PSMUX new-session -d -s reap_young
Start-Sleep -Seconds 3
$env:PSMUX_NO_WARM = $null
$youngPid = (Get-Content "$psmuxDir\reap_young.pid" -Raw).Trim()
$youngNum = Parse-Pid $youngPid    # .pid holds pid:creation_filetime; Get-Process needs the pid alone
$p = Get-Process -Id ([int]$youngNum) -EA SilentlyContinue
$age = if ($p) { ((Get-Date) - $p.StartTime).TotalSeconds } else { 999 }
Write-Host ("    young cold server PID=$youngPid age={0:N1}s" -f $age) -ForegroundColor DarkGray
Remove-Item "$psmuxDir\reap_young.*" -Force -EA SilentlyContinue
& $PSMUX list-sessions 2>&1 | Out-Null   # reaper runs; process is < 10s old
Start-Sleep -Seconds 1
if ($age -lt 10 -and (Is-PidAlive $youngPid)) { Write-Pass "young orphan (age $([math]::Round($age,1))s) SPARED by grace window (mid-boot safe)" }
elseif ($age -ge 10) { Write-Host "  [SKIP] process was not young enough to exercise grace (age $([math]::Round($age,1))s)" -ForegroundColor DarkYellow }
else { Write-Fail "young orphan $youngPid was reaped despite grace window" }
Stop-Process -Id ([int]$youngNum) -Force -EA SilentlyContinue   # manual cleanup of the young orphan

# ===========================================================================
# Win32 TUI VISUAL VERIFICATION — a real visible window stays functional while
# the reaper runs on every CLI command driving it.
# ===========================================================================
Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

$SESSION_TUI = "reap_tui_proof"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

# The visible TUI's own server must have a .pid anchor.
if (Test-Path "$psmuxDir\$SESSION_TUI.pid") { Write-Pass "TUI: visible session has a .pid anchor" }
else { Write-Fail "TUI: visible session missing .pid" }
$tuiServerPid = (Get-Content "$psmuxDir\$SESSION_TUI.pid" -Raw).Trim()

# Drive the TUI via CLI (each call runs the reaper at startup) and confirm the
# session keeps responding and its server is never mistaken for an orphan.
& $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes (reaper did not disrupt it)" }
else { Write-Fail "TUI: expected 2 panes, got '$panes'" }

& $PSMUX new-window -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$wins = (& $PSMUX display-message -t $SESSION_TUI -p '#{session_windows}' 2>&1).Trim()
if ([int]$wins -ge 2) { Write-Pass "TUI: new-window worked after multiple reaper passes ($wins windows)" }
else { Write-Fail "TUI: expected >=2 windows, got '$wins'" }

if (Is-PidAlive $tuiServerPid) { Write-Pass "TUI: server $tuiServerPid alive after all reaper passes" }
else { Write-Fail "TUI: server $tuiServerPid was killed" }

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Cleanup-Sessions

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
