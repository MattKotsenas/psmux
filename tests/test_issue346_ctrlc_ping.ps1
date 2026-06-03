#requires -Version 5
$ErrorActionPreference = 'Continue'
$script:Pass = 0; $script:Fail = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:Fail++ }

$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION    = 'issue346_cli'
$SESSION_TUI = 'issue346_tui'
$psmuxDir = "$env:USERPROFILE\.psmux"

function Cleanup([string]$name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
}
function Cleanup-PingProcs {
    Get-Process PING -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}

# Compile injector
$injectorExe = "$env:TEMP\psmux_injector.exe"
$cscDir = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$csc = Join-Path $cscDir "csc.exe"
if (-not (Test-Path $csc)) { $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" }
& $csc /nologo /optimize /out:$injectorExe "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
if (-not (Test-Path $injectorExe)) { F "injector compile"; exit 1 } else { P "injector compiled" }

Write-Host "`n=== Issue #346: Ctrl+C does not stop ping /t in psmux pane ===" -ForegroundColor Cyan

#-----------------------------------------------------------------------
# Layer 1: CLI baseline (send-keys C-c against ping /t)
#-----------------------------------------------------------------------
Write-Host "`n=== Layer 1: send-keys C-c interrupts ping /t ===" -ForegroundColor Cyan
Cleanup $SESSION
Cleanup-PingProcs
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $SESSION -x 120 -y 30 | Out-Null
Start-Sleep -Seconds 3

& $PSMUX send-keys -t $SESSION "ping /t 127.0.0.1" Enter | Out-Null
Start-Sleep -Seconds 4
$capBefore = (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
if ($capBefore -match 'Reply from 127\.0\.0\.1') { P "ping /t produced output before C-c" }
else { F "ping /t never started" }

$pingsBefore = @(Get-Process PING -EA SilentlyContinue).Count
if ($pingsBefore -ge 1) { P "ping process running (count=$pingsBefore)" } else { F "no ping process before C-c" }

& $PSMUX send-keys -t $SESSION C-c | Out-Null
Start-Sleep -Seconds 3

$capAfter = (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
if ($capAfter -match 'Control-C|Ping statistics') { P "Control-C / Ping statistics rendered after C-c" }
else { F "no Control-C marker after C-c" }

$pingsAfter = @(Get-Process PING -EA SilentlyContinue).Count
if ($pingsAfter -eq 0) { P "ping process killed by C-c (Layer 1 send-keys path works)" }
else { F "ping process still alive after C-c (count=$pingsAfter)"; Cleanup-PingProcs }

Cleanup $SESSION

#-----------------------------------------------------------------------
# Layer 2/3: Attached TUI + WriteConsoleInput Ctrl+C injection
# This tests the INTERACTIVE keystroke path (input.rs is_ctrl_c_key_event),
# which is what the issue reporter actually used.
#-----------------------------------------------------------------------
Write-Host "`n=== Layer 2/3: attached TUI + injected Ctrl+C ===" -ForegroundColor Cyan
Cleanup $SESSION_TUI
Cleanup-PingProcs

# Launch attached psmux with a new session in a real console window.
$proc = Start-Process -FilePath $PSMUX -ArgumentList 'new-session','-s',$SESSION_TUI,'-x','120','-y','30' -PassThru
Start-Sleep -Seconds 4
if ($proc.HasExited) { F "psmux exited before injection"; exit 1 }
P "attached psmux PID=$($proc.Id) alive"

# Type 'ping /t 127.0.0.1' + Enter through the real TUI (not via send-keys)
$keys = 'ping /t 127.0.0.1{ENTER}'
& $injectorExe $proc.Id $keys | Out-Null
Start-Sleep -Seconds 5

# Verify ping is running underneath
$pingsRunning = @(Get-Process PING -EA SilentlyContinue).Count
if ($pingsRunning -ge 1) { P "ping process spawned by TUI keystrokes (count=$pingsRunning)" }
else { F "ping never started in TUI" }

$capTui = (& $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String)
if ($capTui -match 'Reply from 127\.0\.0\.1') { P "ping output visible in TUI pane capture" }
else { F "ping output not in pane capture" }

# THE CORE BUG REPRO: inject Ctrl+C via WriteConsoleInput into the TUI.
# This is the same path the user pressed on their keyboard.
& $injectorExe $proc.Id '^c' | Out-Null
Start-Sleep -Seconds 4

$pingsAfterCtrlC = @(Get-Process PING -EA SilentlyContinue).Count
$capAfter = (& $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String)
$controlCRendered = ($capAfter -match 'Control-C') -or ($capAfter -match 'Ping statistics')

if ($pingsAfterCtrlC -eq 0) {
    P "INTERACTIVE Ctrl+C killed ping in TUI pane (count=$pingsAfterCtrlC)"
} else {
    F "BUG REPRODUCED: ping still alive after interactive Ctrl+C (count=$pingsAfterCtrlC)"
    Write-Host "  --- pane capture after C-c ---" -ForegroundColor DarkYellow
    $capAfter.Trim().Split("`n") | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
}
if ($controlCRendered) {
    P "Control-C / Ping statistics rendered in TUI pane"
} else {
    F "BUG: no Control-C / Ping statistics marker in TUI capture after Ctrl+C"
}

# Cleanup
Cleanup-PingProcs
Cleanup $SESSION_TUI
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass" -ForegroundColor Green
Write-Host "  Failed: $script:Fail" -ForegroundColor $(if ($script:Fail) {'Red'} else {'Green'})
exit $script:Fail
