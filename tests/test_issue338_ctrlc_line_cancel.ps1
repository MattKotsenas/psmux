$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue338_ctrlc"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Wait-Session([string]$Name, [int]$TimeoutMs = 12000) {
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue).Trim()
            if ($port -match '^\d+$') { return $true }
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Wait-PaneContent([string]$Target, [string]$Pattern, [int]$TimeoutMs = 10000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

Write-Host "`n=== Issue #338: Ctrl+C line cancel regression ===" -ForegroundColor Cyan

Cleanup
Start-Sleep -Milliseconds 700
& $PSMUX new-session -d -s $SESSION -x 120 -y 30 | Out-Null
if (-not (Wait-Session $SESSION)) {
    Write-Host "FATAL: Session creation failed" -ForegroundColor Red
    exit 1
}
Start-Sleep -Seconds 2

# Test 1: Ctrl+C cancels a typed line (no command execution)
Write-Host "`n[Test 1] Ctrl+C cancels current input line" -ForegroundColor Yellow
$markerFile = Join-Path $env:TEMP "psmux_issue338_marker_$([guid]::NewGuid().ToString('N')).txt"
if (Test-Path $markerFile) { Remove-Item $markerFile -Force -EA SilentlyContinue }

$pendingCmd = "New-Item -ItemType File -Path '$markerFile' -Force | Out-Null"
& $PSMUX send-keys -t $SESSION $pendingCmd 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

if (-not (Test-Path $markerFile)) {
    Write-Pass "Canceled line did not execute (marker file not created)"
} else {
    Write-Fail "Canceled line executed unexpectedly (marker file exists)"
    Remove-Item $markerFile -Force -EA SilentlyContinue
}

if (Wait-PaneContent $SESSION "PS [A-Z]:\\|[A-Z]:\\.*>" 5000) {
    Write-Pass "Prompt is still responsive after Ctrl+C line cancel"
} else {
    Write-Fail "Prompt was not detected after Ctrl+C line cancel"
}

# Test 2: Ctrl+C still interrupts a running command
Write-Host "`n[Test 2] Ctrl+C interrupts running command" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "ping -t 127.0.0.1" Enter 2>&1 | Out-Null
if (Wait-PaneContent $SESSION "Reply from" 10000) {
    & $PSMUX send-keys -t $SESSION C-c 2>&1 | Out-Null
    if (Wait-PaneContent $SESSION "Control-C|Ping statistics|PS [A-Z]:\\|[A-Z]:\\.*>" 8000) {
        Write-Pass "Ctrl+C interrupted running ping command"
    } else {
        Write-Fail "Ctrl+C did not interrupt running ping command"
    }
} else {
    Write-Fail "ping did not start in time"
}

Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
