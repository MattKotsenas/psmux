# Issue #450: prefix+c "won't open a new shell" / broken empty window.
#
# Root cause: the warm (spare) shell pool had no liveness checking. When the
# pooled spare died while idling (shell crash such as a pwsh FailFast on a
# broken console read, external kill, dead conhost), new-window transplanted
# the corpse. The dead-pane reaper pruned the window within one ~250ms tick,
# so the user saw prefix+c open nothing, or a brief flash of the dead pane
# (the reporter's screenshot caught the pwsh crash dump for 1/4 second).
#
# Fix under test:
#   1. consume-time gate: create_window/split verify the spare is alive
#      before transplanting, falling back to a cold spawn otherwise
#   2. reap-tick self-heal: a dead spare is replaced automatically
#
# This test kills the pooled spare in various timings and asserts prefix+c
# and split-window ALWAYS deliver a working shell.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue450"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# --- injector (real prefix+c keystrokes; the reporter's exact gesture) ---
$injectorExe = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $injectorExe)) { Write-Host "cannot build injector"; exit 1 }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

# Attached session: warm consume only happens on the interactive path,
# and this doubles as the Win32 TUI visual verification window.
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$serverPid = (Get-NetTCPConnection -LocalPort ([int]$port) -State Listen -EA SilentlyContinue | Select-Object -First 1).OwningProcess
Write-Host "session up: server=$serverPid client=$($proc.Id)"

function Get-Spares {
    $panes = (& $PSMUX list-panes -s -t $SESSION -F '#{pane_pid}' 2>&1) | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $shells = Get-CimInstance Win32_Process -Filter "ParentProcessId=$serverPid" |
        Where-Object { $_.Name -match "powershell|pwsh" } | ForEach-Object { $_.ProcessId }
    ,@($shells | Where-Object { $panes -notcontains $_ })
}

function Invoke-PrefixC {
    $before = [int](& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1 | Out-String).Trim()
    & $injectorExe $proc.Id "^b{SLEEP:250}c"
    Start-Sleep -Milliseconds 700
    $after = [int](& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1 | Out-String).Trim()
    $win = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1 | Out-String).Trim()
    $target = "${SESSION}:$win"
    $panePid = (& $PSMUX display-message -t $target -p '#{pane_pid}' 2>&1 | Out-String).Trim()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prompt = $false; $crash = $false
    while ($sw.ElapsedMilliseconds -lt 10000) {
        $cap = & $PSMUX capture-pane -t $target -p 2>&1 | Out-String
        if ($cap -match "handle is invalid|Process terminated|FailFast") { $crash = $true; break }
        if ($cap -match "PS [A-Z]:\\") { $prompt = $true; break }
        Start-Sleep -Milliseconds 200
    }
    $alive = ($panePid -match '^\d+$') -and ($null -ne (Get-Process -Id ([int]$panePid) -EA SilentlyContinue))
    return @{ Created = ($after -gt $before); Prompt = $prompt; Crash = $crash; Alive = $alive; Win = $win; PanePid = $panePid }
}

Write-Host "`n=== Issue #450 Tests ===" -ForegroundColor Cyan

# --- Test 1: healthy warm fast path preserved (live spare is transplanted) ---
Write-Host "`n[Test 1] live spare is still transplanted (warm fast path)" -ForegroundColor Yellow
$spares = Get-Spares
if ($spares.Count -ge 1) {
    $r = Invoke-PrefixC
    if ($r.Created -and $r.Prompt -and ($spares -contains [int]$r.PanePid)) {
        Write-Pass "prefix+c transplanted the live spare (pane pid $($r.PanePid))"
    } elseif ($r.Created -and $r.Prompt) {
        Write-Fail "window healthy but spare $spares not consumed (pane $($r.PanePid)) - warm path lost?"
    } else {
        Write-Fail "prefix+c failed on healthy pool (created=$($r.Created) prompt=$($r.Prompt))"
    }
    & $PSMUX kill-window -t "${SESSION}:$($r.Win)" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
} else {
    Write-Fail "no spare shell found in pool"
}

# --- Test 2: dead spare, settled (reap self-heal path) ---
Write-Host "`n[Test 2] spare killed, 800ms settle, prefix+c must deliver a shell" -ForegroundColor Yellow
$spares = Get-Spares
if ($spares.Count -ge 1) {
    Stop-Process -Id $spares[0] -Force
    Start-Sleep -Milliseconds 800
    $r = Invoke-PrefixC
    if ($r.Created -and $r.Prompt -and $r.Alive -and -not $r.Crash) {
        Write-Pass "healthy window delivered after spare death (pane $($r.PanePid))"
    } else {
        Write-Fail "BUG #450: created=$($r.Created) prompt=$($r.Prompt) alive=$($r.Alive) crash=$($r.Crash)"
    }
    & $PSMUX kill-window -t "${SESSION}:$($r.Win)" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
} else { Write-Fail "no spare to kill" }

# --- Test 3: dead spare, immediate prefix+c (consume-time gate path) ---
Write-Host "`n[Test 3] spare killed, IMMEDIATE prefix+c (x3)" -ForegroundColor Yellow
for ($i = 1; $i -le 3; $i++) {
    $spares = Get-Spares
    if ($spares.Count -lt 1) { Write-Fail "iter ${i}: no spare in pool (self-heal broken?)"; continue }
    Stop-Process -Id $spares[0] -Force
    $r = Invoke-PrefixC
    if ($r.Created -and $r.Prompt -and $r.Alive -and -not $r.Crash) {
        Write-Pass "iter ${i}: healthy window despite freshly killed spare"
    } else {
        Write-Fail "iter ${i}: BUG #450: created=$($r.Created) prompt=$($r.Prompt) alive=$($r.Alive) crash=$($r.Crash)"
    }
    & $PSMUX kill-window -t "${SESSION}:$($r.Win)" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}

# --- Test 4: pool self-heals (fresh spare appears after a kill) ---
Write-Host "`n[Test 4] pool self-heal: dead spare is replaced" -ForegroundColor Yellow
$spares = Get-Spares
if ($spares.Count -ge 1) {
    $victim = $spares[0]
    Stop-Process -Id $victim -Force
    Start-Sleep -Seconds 2
    $healed = Get-Spares
    if ($healed.Count -ge 1 -and ($healed -notcontains $victim)) {
        Write-Pass "fresh spare $($healed -join ',') replaced dead $victim"
    } else {
        Write-Fail "pool did not self-heal (spares now: $($healed -join ',') victim: $victim)"
    }
} else { Write-Fail "no spare to kill" }

# --- Test 5: split-window with a dead spare (CLI path) ---
Write-Host "`n[Test 5] split-window with freshly killed spare" -ForegroundColor Yellow
$spares = Get-Spares
if ($spares.Count -ge 1) {
    Stop-Process -Id $spares[0] -Force
    & $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $panes = [int](& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prompt = $false
    while ($sw.ElapsedMilliseconds -lt 10000) {
        $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
        if ($cap -match "PS [A-Z]:\\") { $prompt = $true; break }
        Start-Sleep -Milliseconds 200
    }
    $ppid = (& $PSMUX display-message -t $SESSION -p '#{pane_pid}' 2>&1 | Out-String).Trim()
    $alive = ($ppid -match '^\d+$') -and ($null -ne (Get-Process -Id ([int]$ppid) -EA SilentlyContinue))
    if ($panes -eq 2 -and $prompt -and $alive) { Write-Pass "split delivered live shell despite dead spare" }
    else { Write-Fail "split broken: panes=$panes prompt=$prompt alive=$alive" }
    & $PSMUX kill-pane -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Seconds 2
} else { Write-Fail "no spare to kill" }

# --- Test 6: Win32 TUI visual verification (session still fully functional) ---
Write-Host "`n[Test 6] TUI verification after all the churn" -ForegroundColor Yellow
$wins = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1 | Out-String).Trim()
if ($wins -match '^\d+$') { Write-Pass "session responds (windows=$wins)" }
else { Write-Fail "session unresponsive" }
& $PSMUX send-keys -t $SESSION "echo ISSUE450_TUI_OK" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "ISSUE450_TUI_OK") { Write-Pass "active pane executes commands" }
else { Write-Fail "active pane did not echo marker" }
$clientAlive = $null -ne (Get-Process -Id $proc.Id -EA SilentlyContinue)
if ($clientAlive) { Write-Pass "attached TUI client still alive" }
else { Write-Fail "attached TUI client died" }

# --- teardown ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
