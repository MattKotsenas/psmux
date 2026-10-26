# @kill-descendants: gates the descendant sweep when a pane's shell exits on
# its own (prune_exited non-remain-on-exit branch).
#
#   Part A (default on):  backgrounded grandchild is force-terminated when the
#                         pane shell exits. Preserves the #445 leak fix.
#   Part B (off):         `set -g @kill-descendants off` lets the grandchild
#                         survive, matching tmux-on-Unix semantics for
#                         deliberately backgrounded processes.
#   Part C (option I/O):  the option round-trips through set-option/show-options.
#
# The marker grandchild is identified by a unique token in its command line so
# stray powershell processes never match, and it self-exits after 120s as a
# safety net if teardown is skipped.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_EXE -and (Test-Path $env:PSMUX_EXE)) { $env:PSMUX_EXE } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Get-MarkerProcs($token) {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -match $token })
}

function Stop-MarkerProcs($token) {
    Get-MarkerProcs $token | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
}

# Runs one scenario: spawn session, optionally set the option, background a
# marker process from a second window's shell, exit that shell, report whether
# the marker survived. Cleans up the session; caller cleans up the marker.
function Invoke-Scenario {
    param([string]$Session, [string]$Token, [string]$OptionValue)
    & $PSMUX kill-session -t $Session 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    & $PSMUX new-session -d -s $Session 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & $PSMUX has-session -t $Session 2>$null
    if ($LASTEXITCODE -ne 0) { return "SESSION_FAILED" }
    if ($OptionValue) {
        & $PSMUX set-option -t $Session -g "@kill-descendants" $OptionValue 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    & $PSMUX new-window -t $Session 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $spawn = "Start-Process -WindowStyle Hidden powershell -ArgumentList '-NoProfile','-Command','`$env:$Token=1; Start-Sleep 120'"
    & $PSMUX send-keys -t "${Session}:1" $spawn Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    if ((Get-MarkerProcs $Token).Count -eq 0) { return "MARKER_NEVER_STARTED" }
    & $PSMUX send-keys -t "${Session}:1" "exit" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $survivors = (Get-MarkerProcs $Token).Count
    & $PSMUX kill-session -t $Session 2>&1 | Out-Null
    if ($survivors -gt 0) { return "SURVIVED" } else { return "SWEPT" }
}

Write-Host "`n=== @kill-descendants tests ===" -ForegroundColor Cyan

# --- Part A: default (option unset) sweeps the grandchild ---
Write-Host "`n[Test A] default on: grandchild swept on pane self-exit" -ForegroundColor Yellow
$tokenA = "KDESC_DEFAULT_$(Get-Random)"
$resA = Invoke-Scenario -Session "kdesc_on" -Token $tokenA -OptionValue $null
if ($resA -eq "SWEPT") { Write-Pass "default sweeps backgrounded descendant" }
else { Write-Fail "default expected SWEPT, got: $resA" }
Stop-MarkerProcs $tokenA

# --- Part B: off lets the grandchild survive ---
Write-Host "`n[Test B] @kill-descendants off: grandchild survives" -ForegroundColor Yellow
$tokenB = "KDESC_OFF_$(Get-Random)"
$resB = Invoke-Scenario -Session "kdesc_off" -Token $tokenB -OptionValue "off"
if ($resB -eq "SURVIVED") { Write-Pass "off preserves backgrounded descendant (tmux semantics)" }
else { Write-Fail "off expected SURVIVED, got: $resB" }
Stop-MarkerProcs $tokenB

# --- Part C: option round-trips through set-option/show-options ---
Write-Host "`n[Test C] option round-trip via show-options" -ForegroundColor Yellow
& $PSMUX kill-session -t kdesc_opt 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s kdesc_opt 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX set-option -t kdesc_opt -g "@kill-descendants" off 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$val = (& $PSMUX show-options -t kdesc_opt -g -v "@kill-descendants" 2>&1 | Out-String).Trim()
if ($val -eq "off") { Write-Pass "show-options reads back 'off'" }
else { Write-Fail "expected 'off', got: '$val'" }
& $PSMUX set-option -t kdesc_opt -g "@kill-descendants" on 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$val2 = (& $PSMUX show-options -t kdesc_opt -g -v "@kill-descendants" 2>&1 | Out-String).Trim()
if ($val2 -eq "on") { Write-Pass "show-options reads back 'on'" }
else { Write-Fail "expected 'on', got: '$val2'" }
& $PSMUX kill-session -t kdesc_opt 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
