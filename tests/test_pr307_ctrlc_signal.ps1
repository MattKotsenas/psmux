# PR #307: Ctrl+C signal delivery reliability test
# Tests whether send-keys C-c reliably interrupts a running process
# The PR claims GenerateConsoleCtrlEvent can lose signals because FreeConsole
# is called before the async dispatch completes.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "pr307_ctrlc"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 15000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue)
            if ($port -and $port.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# === SETUP ===
Cleanup
Start-Sleep -Seconds 1
& $PSMUX new-session -d -s $SESSION
if (-not (Wait-Session $SESSION)) {
    Write-Host "FATAL: Session creation failed" -ForegroundColor Red
    exit 1
}
Write-Host "Session $SESSION created" -ForegroundColor Green

# Wait for shell prompt
Start-Sleep -Seconds 3

Write-Host "`n=== PR #307: Ctrl+C Signal Delivery Test ===" -ForegroundColor Cyan

# ================================================================
# TEST 1: Basic Ctrl+C delivery - single attempt
# ================================================================
Write-Host "`n[Test 1] Basic Ctrl+C delivery" -ForegroundColor Yellow

& $PSMUX send-keys -t $SESSION "ping -n 100 127.0.0.1" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2

$capBefore = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
$pingStarted = $capBefore -match "Reply from"
if ($pingStarted) { Write-Host "    ping is running..." }
else { Write-Host "    WARNING: ping may not have started yet" -ForegroundColor DarkYellow }

& $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
Start-Sleep -Seconds 1

$capAfter = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
$interrupted = ($capAfter -match "Control-C") -or ($capAfter -match "Ping statistics") -or ($capAfter -match "PS [A-Z]:\\")

if ($interrupted) { Write-Pass "Ctrl+C interrupted ping" }
else { Write-Fail "Ctrl+C may not have interrupted ping" }

# Clear
& $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION "cls" Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# ================================================================
# TEST 2: Rapid-fire Ctrl+C reliability (stress test)
# N iterations of: start process -> send C-c -> check interrupted
# ================================================================
Write-Host "`n[Test 2] Rapid Ctrl+C reliability ($iterations iterations)" -ForegroundColor Yellow
$iterations = 30
$delivered = 0
$dropped = 0

for ($i = 1; $i -le $iterations; $i++) {
    # Start a blocking command
    & $PSMUX send-keys -t $SESSION "ping -n 50 127.0.0.1" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1200
    
    # Send Ctrl+C
    & $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    
    # Check if interrupted
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    $ok = ($cap -match "Control-C") -or ($cap -match "Ping statistics") -or ($cap -match "PS [A-Z]:\\.*>\s*$")
    
    if ($ok) { 
        $delivered++
    } else {
        $dropped++
        Write-Host "    Iteration ${i}: SIGNAL MAY HAVE BEEN DROPPED" -ForegroundColor Red
        # Recovery: send another C-c
        & $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    
    # Clear for next iteration
    & $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200
    & $PSMUX send-keys -t $SESSION "cls" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
}

$rate = [math]::Round(($delivered / $iterations) * 100, 1)
Write-Host "    Delivered: $delivered/$iterations ($rate%)"

if ($dropped -eq 0) { Write-Pass "All $iterations Ctrl+C signals delivered (100%)" }
elseif ($dropped -le 2) { Write-Fail "Some signals dropped: $dropped/$iterations ($rate% delivery). PR #307 fix may help." }
else { Write-Fail "Significant signal loss: $dropped/$iterations ($rate% delivery). PR #307 fix NEEDED." }

# ================================================================
# TEST 3: Ctrl+C with very fast timing (minimal delay)
# This is the scenario most likely to trigger the race condition
# ================================================================
Write-Host "`n[Test 3] Fast Ctrl+C (minimal delay, 20 iterations)" -ForegroundColor Yellow
$fastDelivered = 0
$fastDropped = 0

for ($i = 1; $i -le 20; $i++) {
    & $PSMUX send-keys -t $SESSION "ping -n 50 127.0.0.1" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600  # Less wait time = more pressure on async dispatch
    
    & $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    $ok = ($cap -match "Control-C") -or ($cap -match "Ping statistics") -or ($cap -match "PS [A-Z]:\\.*>\s*$")
    
    if ($ok) { $fastDelivered++ }
    else {
        $fastDropped++
        Write-Host "    Fast iteration ${i}: DROPPED" -ForegroundColor Red
        & $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    
    & $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 100
    & $PSMUX send-keys -t $SESSION "cls" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
}

$fastRate = [math]::Round(($fastDelivered / 20) * 100, 1)
Write-Host "    Fast delivery: $fastDelivered/20 ($fastRate%)"

if ($fastDropped -eq 0) { Write-Pass "All fast Ctrl+C signals delivered" }
else { Write-Fail "Fast signal loss: $fastDropped/20. Race condition confirmed." }

# ================================================================
# TEST 4: Ctrl+C with Python script (different process type)
# ================================================================
Write-Host "`n[Test 4] Ctrl+C with Python process" -ForegroundColor Yellow

# Check if python is available
$pythonCmd = if (Get-Command python -EA SilentlyContinue) { "python" } 
             elseif (Get-Command python3 -EA SilentlyContinue) { "python3" } 
             else { $null }

if ($pythonCmd) {
    & $PSMUX send-keys -t $SESSION "$pythonCmd -c ""import time; [print(f'tick {i}') or time.sleep(0.5) for i in range(100)]""" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    
    & $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    $pyInterrupted = ($cap -match "KeyboardInterrupt") -or ($cap -match "PS [A-Z]:\\")
    
    if ($pyInterrupted) { Write-Pass "Ctrl+C interrupted Python script" }
    else { Write-Fail "Ctrl+C may not have interrupted Python" }
    
    & $PSMUX send-keys -t $SESSION "" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200
    & $PSMUX send-keys -t $SESSION "cls" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
} else {
    Write-Host "    [SKIP] Python not available" -ForegroundColor DarkGray
}

# ================================================================
# TEST 5: Win32 TUI Visual Verification
# ================================================================
Write-Host "`n[Test 5] TUI Visual Verification" -ForegroundColor Yellow

$TUI_SESSION = "pr307_tui"
& $PSMUX kill-session -t $TUI_SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$TUI_SESSION -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $TUI_SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI session alive" }
else { Write-Fail "TUI session failed to start" }

# Send a ping in the TUI session and Ctrl+C it
& $PSMUX send-keys -t $TUI_SESSION "ping -n 20 127.0.0.1" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX send-keys -t $TUI_SESSION C-c 2>&1 | Out-Null
Start-Sleep -Seconds 1

$tuiCap = & $PSMUX capture-pane -t $TUI_SESSION -p 2>&1 | Out-String
$tuiOk = ($tuiCap -match "Control-C") -or ($tuiCap -match "Ping statistics") -or ($tuiCap -match "PS [A-Z]:\\")

if ($tuiOk) { Write-Pass "TUI: Ctrl+C interrupted process in attached session" }
else { Write-Fail "TUI: Ctrl+C may not have worked in attached session" }

# Cleanup TUI
& $PSMUX kill-session -t $TUI_SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total Ctrl+C signals tested: $($iterations + 20 + 2) (approx)"
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""
if ($dropped -gt 0 -or $fastDropped -gt 0) {
    Write-Host "  VERDICT: Signal loss detected. PR #307 fix IS NEEDED." -ForegroundColor Red
} else {
    Write-Host "  VERDICT: No signal loss detected in $($iterations + 20) iterations." -ForegroundColor Green
    Write-Host "  However, PR #307 is a correctness fix for a RACE CONDITION." -ForegroundColor Yellow
    Write-Host "  The current code sleeps AFTER FreeConsole which is logically wrong." -ForegroundColor Yellow
    Write-Host "  Moving sleep BEFORE FreeConsole is the correct sequence." -ForegroundColor Yellow
}
exit $script:TestsFailed
