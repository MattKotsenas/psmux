# Issue #491: Ctrl+C inside psmux closes a running wsl.exe session
# From PowerShell/WT, Ctrl+C inside wsl just interrupts the foreground linux
# command; the wsl session survives. Inside psmux it kills wsl entirely.
# Proof: launch attached psmux, run wsl.exe in the pane, inject a real Ctrl+C
# keystroke, then check whether we are still inside linux (uname works).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue491"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# Dedicated exe name: test_keystroke_injection.ps1 clobbers the shared
# $env:TEMP\psmux_injector.exe with a limited inline variant. Always rebuild
# from tests/injector.cs (the full key map).
$injectorExe = "$env:TEMP\psmux_injector_full.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /optimize /out:$injectorExe tests\injector.cs 2>&1 | Out-Null

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #491: Ctrl+C must not kill wsl ===" -ForegroundColor Cyan

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

# Start wsl in the pane
& $PSMUX send-keys -t $SESSION "wsl.exe" Enter
# WSL cold start can be slow
$inWsl = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    & $PSMUX send-keys -t $SESSION 'echo READY_$(uname)' Enter
    Start-Sleep -Seconds 2
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match "READY_Linux") { $inWsl = $true; break }
}
if (-not $inWsl) {
    Write-Fail "could not start wsl in pane (setup failure, not the bug)"
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    exit 1
}
Write-Host "  wsl is running inside the pane" -ForegroundColor DarkGray

# === TEST 1: Ctrl+C at idle bash prompt must NOT kill wsl ===
Write-Host "`n[Test 1] Ctrl+C at idle wsl prompt" -ForegroundColor Yellow
& $injectorExe $proc.Id "^c"
Start-Sleep -Seconds 3
& $PSMUX send-keys -t $SESSION 'echo ALIVE1_$(uname)' Enter
Start-Sleep -Seconds 3
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "ALIVE1_Linux") { Write-Pass "wsl survived Ctrl+C at idle prompt" }
else { Write-Fail "BUG: wsl died after Ctrl+C at idle prompt. Capture:`n$cap" }

# === TEST 2: Ctrl+C interrupts a foreground linux command but wsl survives ===
Write-Host "`n[Test 2] Ctrl+C interrupts sleep but wsl survives" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "sleep 300" Enter
Start-Sleep -Seconds 2
& $injectorExe $proc.Id "^c"
Start-Sleep -Seconds 3
& $PSMUX send-keys -t $SESSION 'echo ALIVE2_$(uname)' Enter
Start-Sleep -Seconds 3
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match "ALIVE2_Linux") { Write-Pass "wsl survived Ctrl+C during sleep (sleep interrupted)" }
else { Write-Fail "BUG: wsl died after Ctrl+C during sleep. Capture:`n$cap" }

# === TEST 3: wsl under a Git Bash (MSYS) parent survives Ctrl+C ===
# This is the scenario that actually reproduced the bug: the CTRL_C_EVENT
# console broadcast made the Cygwin/MSYS shell SIGINT its native foreground
# child, which Cygwin implements as a hard kill of wsl.exe.
Write-Host "`n[Test 3] wsl under Git Bash parent survives Ctrl+C" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "exit" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
if (Test-Path "C:\Program Files\Git\bin\bash.exe") {
    & $PSMUX send-keys -t $SESSION 'C:\PROGRA~1\Git\bin\bash.exe -i' Enter
    Start-Sleep -Seconds 4
    & $PSMUX send-keys -t $SESSION 'wsl.exe' Enter
    $inWsl2 = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 2
        & $PSMUX send-keys -t $SESSION 'echo READY2_$(uname)' Enter
        Start-Sleep -Seconds 2
        $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
        if ($cap -match "READY2_Linux") { $inWsl2 = $true; break }
    }
    if ($inWsl2) {
        & $injectorExe $proc.Id "^c"
        Start-Sleep -Seconds 3
        & $PSMUX send-keys -t $SESSION 'echo ALIVE3_$(uname)' Enter
        Start-Sleep -Seconds 3
        $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
        if ($cap -match "ALIVE3_Linux") { Write-Pass "wsl under Git Bash survived Ctrl+C" }
        else { Write-Fail "BUG: wsl under Git Bash died after Ctrl+C. Capture:`n$cap" }
    } else {
        Write-Fail "could not start wsl inside Git Bash (setup failure)"
    }
} else {
    Write-Host "  [SKIP] Git Bash not installed" -ForegroundColor DarkYellow
}

# === TEARDOWN ===
& $PSMUX send-keys -t $SESSION "exit" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
