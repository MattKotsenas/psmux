# Issue #593: status bar click hit-testing (tmux parity).
# Three defects fixed and guarded here:
#   1. Only status row 0 was hit-tested: with `set -g status 2`, a window list
#      carrying #[range=window|N] markers on status-format[1] rendered fine but
#      was completely dead to the mouse.
#   2. Ranges were only harvested from status-format[0]; every other line's
#      layout ranges were computed and discarded.
#   3. #[range=window|N] treated N as zero-based and added base-index back.
#      tmux passes N raw to winlink_find_by_index (style.c / server-client.c),
#      so tmux's own default marker #[range=window|#{window_index}] selected
#      one window too high and orphaned the last tab at base-index 1.
# Clicks are injected as native Win32 MOUSE_EVENT INPUT_RECORDs via
# AttachConsole + WriteConsoleInput (tests/click_injector.cs). No focus needed.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SOCK = "i593"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# --- Compile the click injector ---
$injector = "$env:TEMP\psmux_click_injector_593.exe"
if (-not (Test-Path $injector)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }
    & $csc /nologo /optimize /out:$injector "$PSScriptRoot\click_injector.cs" 2>&1 | Out-Null
}
if (-not (Test-Path $injector)) { Write-Fail "could not compile click_injector.cs"; exit 1 }

# conread reads the client's real screen buffer so default-bar clicks can be
# aimed at the actually-rendered tab text instead of guessed columns.
$conread = "$env:TEMP\psmux_conread_593.exe"
if (-not (Test-Path $conread)) {
    $csc2 = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc2)) {
        $csc2 = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }
    & $csc2 /nologo /optimize /out:$conread "$PSScriptRoot\conread.cs" 2>&1 | Out-Null
}

# --- Launcher that scrubs nesting env vars (the test may run inside psmux) ---
$launchCmd = "$env:TEMP\psmux_593_launch.cmd"
@"
@echo off
set PSMUX_SESSION=
set PSMUX_PANE=
set TMUX=
set TMUX_PANE=
set PSMUX=
psmux -L $SOCK -f "%~2" new-session -s %1 -x 120 -y 30
"@ | Set-Content -Path $launchCmd -Encoding ASCII

function Start-Scen {
    param([string]$Name,[string]$Conf,[int]$Windows=3)
    & $PSMUX -L $SOCK kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $null = Start-Process -FilePath $launchCmd -ArgumentList $Name,$Conf -PassThru
    Start-Sleep -Seconds 7
    for ($i=1; $i -lt $Windows; $i++) { & $PSMUX -L $SOCK new-window -t $Name 2>&1 | Out-Null; Start-Sleep -Milliseconds 700 }
    Start-Sleep -Seconds 2
    $cli = Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" |
        Where-Object { $_.CommandLine -match $SOCK -and $_.CommandLine -match "new-session -s\s+$Name\b" }
    if (-not $cli) { return $null }
    return $cli.ProcessId
}

function WinIdx($Name) { (& $PSMUX -L $SOCK display-message -t $Name -p '#{window_index}' 2>&1 | Out-String).Trim() }

function Click {
    param([int]$ClientPid,[int]$X,[int]$Y,[string]$Name)
    & $injector $ClientPid $X $Y | Out-Null
    Start-Sleep -Milliseconds 900
    return WinIdx $Name
}

function Stop-Scen($Name) {
    & $PSMUX -L $SOCK kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
}

# --- Scenario configs ---
$confDefault = "$env:TEMP\psmux_593_default.conf"
"" | Set-Content -Path $confDefault -Encoding UTF8

$confLine1 = "$env:TEMP\psmux_593_line1.conf"
@'
set -g status 2
set -g status-format[0] "#[align=left]#S"
set -g status-format[1] "#[align=left]#[range=window|0]tab0#[norange] #[range=window|1]tab1#[norange] #[range=window|2]tab2#[norange]"
'@ | Set-Content -Path $confLine1 -Encoding UTF8

$confTmuxIdiomB1 = "$env:TEMP\psmux_593_tmuxidiom_b1.conf"
@'
set -g base-index 1
set -g status-format[0] "#[align=left]#{W:#[range=window|#{window_index}]#I:#W #[norange],#[range=window|#{window_index}]#I:#W #[norange]}"
'@ | Set-Content -Path $confTmuxIdiomB1 -Encoding UTF8

Write-Host "`n=== Issue #593 Tests: status range clicks ===" -ForegroundColor Cyan

# === TEST 1: control - default status bar tabs clickable (regression guard) ===
Write-Host "`n[Test 1] default bar tab clicks still work" -ForegroundColor Yellow
$cpid = Start-Scen "s593ctl" $confDefault
if ($cpid) {
    & $PSMUX -L $SOCK select-window -t "s593ctl:2" | Out-Null; Start-Sleep -Milliseconds 400
    # Aim at the rendered tab text: read the real screen, find "1:" / "0:" on
    # the status row (row 29) instead of guessing columns from the bar layout.
    $rows = & $conread $cpid 2>&1
    $statusText = if ($rows.Count -ge 30) { [string]$rows[29] } else { "" }
    $col1 = $statusText.IndexOf(" 1:")
    $col0 = $statusText.IndexOf("] 0:")
    if ($col1 -ge 0 -and $col0 -ge 0) {
        $r = Click $cpid ($col1 + 2) 29 "s593ctl"
        if ($r -eq "1") { Write-Pass "click on rendered '1:' tab -> window 1" } else { Write-Fail "click on '1:' tab gave $r (want 1)" }
        $r = Click $cpid ($col0 + 3) 29 "s593ctl"
        if ($r -eq "0") { Write-Pass "click on rendered '0:' tab -> window 0" } else { Write-Fail "click on '0:' tab gave $r (want 0)" }
    } else {
        Write-Fail "could not locate default tabs on status row: [$statusText]"
    }
} else { Write-Fail "control client did not start" }
Stop-Scen "s593ctl"

# === TEST 2: markers on status-format[1] are clickable (defects 1+2) ===
Write-Host "`n[Test 2] second status row markers clickable" -ForegroundColor Yellow
$cpid = Start-Scen "s593l1" $confLine1
if ($cpid) {
    & $PSMUX -L $SOCK select-window -t "s593l1:2" | Out-Null; Start-Sleep -Milliseconds 400
    $r = Click $cpid 2 29 "s593l1"
    if ($r -eq "0") { Write-Pass "row29 tab0 -> window 0" } else { Write-Fail "row29 tab0 gave $r (want 0)" }
    $r = Click $cpid 7 29 "s593l1"
    if ($r -eq "1") { Write-Pass "row29 tab1 -> window 1" } else { Write-Fail "row29 tab1 gave $r (want 1)" }
    $r = Click $cpid 12 29 "s593l1"
    if ($r -eq "2") { Write-Pass "row29 tab2 -> window 2" } else { Write-Fail "row29 tab2 gave $r (want 2)" }
    $before = WinIdx "s593l1"
    $r = Click $cpid 4 29 "s593l1"
    if ($r -eq $before) { Write-Pass "gap between tabs ignored" } else { Write-Fail "gap click changed $before -> $r" }
    $before = WinIdx "s593l1"
    $r = Click $cpid 2 28 "s593l1"
    if ($r -eq $before) { Write-Pass "markerless row 28 ignored" } else { Write-Fail "row28 click changed $before -> $r" }
} else { Write-Fail "line1 client did not start" }
Stop-Scen "s593l1"

# === TEST 3: tmux default marker idiom at base-index 1 (defect 3) ===
Write-Host "`n[Test 3] #[range=window|#{window_index}] exact at base-index 1" -ForegroundColor Yellow
$cpid = Start-Scen "s593b1" $confTmuxIdiomB1
if ($cpid) {
    & $PSMUX -L $SOCK select-window -t "s593b1:3" | Out-Null; Start-Sleep -Milliseconds 400
    $r = Click $cpid 2 29 "s593b1"
    if ($r -eq "1") { Write-Pass "tab '1:' -> window 1 (off-by-one fixed)" } else { Write-Fail "tab '1:' gave $r (want 1)" }
    $r = Click $cpid 9 29 "s593b1"
    if ($r -eq "2") { Write-Pass "tab '2:' -> window 2" } else { Write-Fail "tab '2:' gave $r (want 2)" }
    $r = Click $cpid 16 29 "s593b1"
    if ($r -eq "3") { Write-Pass "tab '3:' -> window 3 (last tab no longer orphaned)" } else { Write-Fail "tab '3:' gave $r (want 3)" }
} else { Write-Fail "base-index 1 client did not start" }
Stop-Scen "s593b1"

# === TEARDOWN ===
Remove-Item "$psmuxDir\${SOCK}__*" -Force -EA SilentlyContinue
Remove-Item "$env:TEMP\psmux_593_*.conf" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
