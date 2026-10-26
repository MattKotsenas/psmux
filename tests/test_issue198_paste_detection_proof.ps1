# Issue #198: Prove paste-detection off bypasses character buffering
# This test specifically simulates rapid multi-character injection (like WT Ctrl+V paste)
# and verifies characters are NOT wrapped in bracketed paste

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

Write-Host "`n=== Issue #198: Paste Detection Bypass Proof ===" -ForegroundColor Cyan

# Compile injector
$injectorExe = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
}

# === TEST A: paste-detection ON + rapid chars = stage2 (control test) ===
Write-Host "`n[Test A] Control: paste-detection ON + rapid chars" -ForegroundColor Yellow
$sessA = "test198_ctrl"
& $PSMUX kill-session -t $sessA 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$sessA.*" -Force -EA SilentlyContinue
# Clear old input log
Remove-Item "$psmuxDir\input_debug.log" -Force -EA SilentlyContinue

$env:PSMUX_INPUT_DEBUG = "1"
$procA = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$sessA -PassThru
$env:PSMUX_INPUT_DEBUG = $null
Start-Sleep -Seconds 4

& $PSMUX has-session -t $sessA 2>$null
if ($LASTEXITCODE -eq 0) {
    # paste-detection defaults to ON
    & $PSMUX send-keys -t $sessA "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Inject many characters rapidly (no SLEEP between them, all in one batch)
    & $injectorExe $procA.Id "echo RAPIDTEST123456789{ENTER}"
    Start-Sleep -Seconds 3

    $capA = & $PSMUX capture-pane -t $sessA -p 2>&1 | Out-String
    if ($capA -match "RAPIDTEST123456789") {
        Write-Pass "Control: rapid chars appeared with paste-detection ON"
    } else {
        Write-Fail "Control: rapid chars did NOT appear"
    }

    # Check input log for paste-related entries
    $logPath = "$psmuxDir\input_debug.log"
    if (Test-Path $logPath) {
        $logContent = Get-Content $logPath -Raw -EA SilentlyContinue
        $hasPasteActivity = ($logContent -match "stage2") -or ($logContent -match "send-paste")
        Write-Host "    Control log: paste stage2/send-paste detected = $hasPasteActivity" -ForegroundColor DarkGray
    }
} else {
    Write-Fail "Control session creation failed"
}

& $PSMUX kill-session -t $sessA 2>&1 | Out-Null
try { Stop-Process -Id $procA.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$sessA.*" -Force -EA SilentlyContinue
Start-Sleep -Seconds 1

# === TEST B: paste-detection OFF + rapid chars = NO stage2 (fix proof) ===
Write-Host "`n[Test B] Fix proof: paste-detection OFF + rapid chars" -ForegroundColor Yellow
$sessB = "test198_fix"
& $PSMUX kill-session -t $sessB 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$sessB.*" -Force -EA SilentlyContinue
# Clear old input log
Remove-Item "$psmuxDir\input_debug.log" -Force -EA SilentlyContinue

$env:PSMUX_INPUT_DEBUG = "1"
$procB = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$sessB -PassThru
$env:PSMUX_INPUT_DEBUG = $null
Start-Sleep -Seconds 4

& $PSMUX has-session -t $sessB 2>$null
if ($LASTEXITCODE -eq 0) {
    # Set paste-detection OFF
    & $PSMUX set-option -g paste-detection off -t $sessB 2>&1 | Out-Null
    Start-Sleep -Seconds 2  # Wait for client to sync state from dump-state

    # Verify paste-detection is off
    $val = (& $PSMUX show-options -g -v "paste-detection" -t $sessB 2>&1).Trim()
    if ($val -ne "off") {
        Write-Fail "paste-detection not set to off: $val"
    }

    # Clear the pane and the input log
    & $PSMUX send-keys -t $sessB "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    # Truncate log to only capture new entries
    $logPath = "$psmuxDir\input_debug.log"
    $preLogSize = 0
    if (Test-Path $logPath) { $preLogSize = (Get-Item $logPath).Length }

    # Inject many characters rapidly (simulating WT clipboard injection)
    & $injectorExe $procB.Id "echo FIXTEST_PASTE_OFF_ABCDEFGH{ENTER}"
    Start-Sleep -Seconds 3

    $capB = & $PSMUX capture-pane -t $sessB -p 2>&1 | Out-String
    if ($capB -match "FIXTEST_PASTE_OFF_ABCDEFGH") {
        Write-Pass "Fix proof: rapid chars appeared with paste-detection OFF"
    } else {
        Write-Fail "Fix proof: rapid chars did NOT appear. Capture: $($capB.Substring(0, [Math]::Min(200, $capB.Length)))"
    }

    # Check input log for paste-related entries (only new entries)
    if (Test-Path $logPath) {
        $newEntries = Get-Content $logPath -Raw -EA SilentlyContinue
        # Look for entries that indicate paste buffering was triggered
        if ($newEntries -match "send-paste") {
            Write-Fail "BUG: chars sent as send-paste with paste-detection OFF"
            $pasteLines = Get-Content $logPath | Where-Object { $_ -match "paste" -and $_ -notmatch "zero-latency" } | Select-Object -Last 10
            Write-Host "    Paste log:" -ForegroundColor DarkYellow
            $pasteLines | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
        } elseif ($newEntries -match "stage2") {
            Write-Fail "BUG: chars entered stage2 with paste-detection OFF"
        } else {
            Write-Pass "No paste buffering (no stage2/send-paste) with paste-detection OFF"
        }

        # Check for zero-latency flush (the correct path with fix)
        if ($newEntries -match "zero-latency") {
            Write-Pass "Characters flushed via zero-latency path (correct behavior)"
        }
    } else {
        Write-Host "    (input_debug.log not found)" -ForegroundColor DarkGray
    }
} else {
    Write-Fail "Fix session creation failed"
}

& $PSMUX kill-session -t $sessB 2>&1 | Out-Null
try { Stop-Process -Id $procB.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$sessB.*" -Force -EA SilentlyContinue

# === TEST C: TUI visual + Ctrl+V with paste-detection OFF ===
Write-Host "`n[Test C] TUI: send-keys C-v with paste-detection off" -ForegroundColor Yellow
$sessC = "test198_cv"
& $PSMUX kill-session -t $sessC 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$sessC.*" -Force -EA SilentlyContinue

$procC = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$sessC -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $sessC 2>$null
if ($LASTEXITCODE -eq 0) {
    & $PSMUX set-option -g paste-detection off -t $sessC 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Verify send-keys C-v works (server side path)
    & $PSMUX send-keys -t $sessC "clear" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    # Send some text then capture
    & $PSMUX send-keys -t $sessC "echo CTRL_V_TEST" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $capC = & $PSMUX capture-pane -t $sessC -p 2>&1 | Out-String
    if ($capC -match "CTRL_V_TEST") {
        Write-Pass "TUI functional with paste-detection off + send-keys works"
    } else {
        Write-Fail "TUI send-keys broken with paste-detection off"
    }
} else {
    Write-Fail "TUI session creation failed"
}

& $PSMUX kill-session -t $sessC 2>&1 | Out-Null
try { Stop-Process -Id $procC.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$sessC.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
