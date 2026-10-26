# Win32 TUI proof for the kill-window bad-target fix.
# Strategy A: real attached window, state driven via CLI.
# Strategy B: real keystrokes through the command prompt (prefix+:) via
#             WriteConsoleInput, because kill-window is a command-prompt
#             command and that input path cannot be reached by CLI commands.

$ErrorActionPreference = "Continue"
$PSMUX = "$PSScriptRoot\..\target\debug\psmux.exe"
if (-not (Test-Path $PSMUX)) { $PSMUX = (Get-Command psmux -EA Stop).Source }
$NS = "kwtui$PID"
$SESSION = "kwtui"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Get-WindowCount {
    $out = (& $PSMUX -L $NS display-message -t $SESSION -p '#{session_windows}' 2>&1 | Out-String).Trim()
    if ($out -match '^\d+$') { return [int]$out } else { return -1 }
}

# Compile the injector once
$injectorExe = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
}

$proc = $null
try {
    $env:PSMUX_NO_WARM = "1"
    $proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"new-session","-s",$SESSION -PassThru
    $deadline = (Get-Date).AddSeconds(25)
    do { Start-Sleep -Milliseconds 500; & $PSMUX -L $NS has-session -t $SESSION 2>$null } while ($LASTEXITCODE -ne 0 -and (Get-Date) -lt $deadline)
    if ($LASTEXITCODE -ne 0) { Write-Fail "setup: attached session never came up"; exit 1 }
    Start-Sleep -Seconds 2

    & $PSMUX -L $NS new-window -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    if ((Get-WindowCount) -ne 2) { Write-Fail "setup: expected 2 windows"; exit 1 }

    Write-Host "`n=== Strategy A: CLI-driven checks on the attached TUI ===" -ForegroundColor Cyan

    # A1: bad target via CLI against the live attached session
    & $PSMUX -L $NS kill-window -t "${SESSION}:doesnotexist" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $c = Get-WindowCount
    if ($c -eq 2) { Write-Pass "TUI session: bad target killed nothing (2 windows intact)" }
    else { Write-Fail "TUI session: bad target changed windows to $c" }

    # A2: session still healthy and interactive
    & $PSMUX -L $NS send-keys -t $SESSION "echo TUIPROOF_ALIVE" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $cap = (& $PSMUX -L $NS capture-pane -t $SESSION -p 2>&1 | Out-String)
    if ($cap -match "TUIPROOF_ALIVE") { Write-Pass "TUI session still interactive after failed kill" }
    else { Write-Fail "TUI session not responding after failed kill" }

    Write-Host "`n=== Strategy B: command prompt via WriteConsoleInput ===" -ForegroundColor Cyan

    # B1: prefix+: kill-window -t badname ENTER -> nothing dies
    & $injectorExe $proc.Id "^b{SLEEP:400}:{SLEEP:600}kill-window -t ${SESSION}:stillnotawindow{ENTER}"
    Start-Sleep -Seconds 2
    $c = Get-WindowCount
    if ($c -eq 2) { Write-Pass "command prompt: bad target killed nothing" }
    else { Write-Fail "command prompt: bad target changed windows to $c" }

    # B2: prefix+: kill-window ENTER (no target) -> active window dies
    & $injectorExe $proc.Id "^b{SLEEP:400}:{SLEEP:600}kill-window{ENTER}"
    Start-Sleep -Seconds 2
    $c = Get-WindowCount
    if ($c -eq 1) { Write-Pass "command prompt: untargeted kill-window still kills the active window" }
    else { Write-Fail "command prompt: untargeted kill expected 1 window, got $c" }
}
finally {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue }
    Get-ChildItem $psmuxDir -Filter "$NS*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    Remove-Item Env:PSMUX_NO_WARM -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
