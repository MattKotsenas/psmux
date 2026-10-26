# Two root-caused regressions found while reviewing PR #590 and PR #587.
#
# 1) send-keys -X cancel left the pane-local copy state behind
#    `exit_copy_mode` clears `pane.copy_state` (48b83a5: "so re-entering this
#    pane won't restore a stale copy mode").  The server's `send-keys -X`
#    arms, added two days later in 4964aaf, hand-rolled the exit from the
#    PRE-fix body and never cleared it.  `switch_with_copy_save` restores any
#    pane whose `copy_state.is_some()`, and an attached client sends
#    `select-pane` before EVERY mouse click, so one plain click after an
#    external `send-keys -X cancel` silently re-entered copy mode.
#    Four arms shared the defect: cancel, copy-selection-and-cancel,
#    copy-pipe-and-cancel, copy-end-of-line-and-cancel.
#
# 2) `new-window -- prog args...` named the window `--`
#    9bfdfc3 (#582) kept the `--` marker at the head of the command string so
#    build_command execs the argv directly.  build_command decodes the marker;
#    the naming path did not, so `resolve_shell_program` returned `--`.
#    tmux names the window after the program.
#
# Layers: raw TCP control verbs (server, no client), a real attached client
# with injected MOUSE_EVENT clicks, and CLI window naming.
#
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = "$env:USERPROFILE\.psmux"
$TMP = Join-Path $env:TEMP "psmux_cancelname"
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$clickInj = Join-Path $TMP "click.exe"
$keyInj = Join-Path $TMP "keys.exe"
foreach ($pair in @(@($clickInj,"click_injector.cs"),@($keyInj,"injector.cs"))) {
    $src = Join-Path $PSScriptRoot $pair[1]
    if (-not (Test-Path $pair[0])) { & $csc /nologo /optimize /out:$($pair[0]) $src 2>&1 | Out-Null }
    if (-not (Test-Path $pair[0])) { Write-Host "FATAL: cannot compile $($pair[1])" -ForegroundColor Red; exit 1 }
}

$conf = Join-Path $TMP "cancelname.conf"
"set -g mouse on`nset -g history-limit 5000" | Set-Content -Path $conf -Encoding ASCII
$launchCmd = Join-Path $TMP "launch.cmd"
@"
@echo off
set PSMUX_SESSION=
set PSMUX_PANE=
set TMUX=
set TMUX_PANE=
set PSMUX=
set PSMUX_NO_WARM=1
set NO_COLOR=
"$PSMUX" -f "%~2" new-session -s %1 -x 120 -y 30
"@ | Set-Content -Path $launchCmd -Encoding ASCII

function Fmt([string]$Sess, [string]$F) { (& $PSMUX display-message -t $Sess -p $F 2>&1 | Out-String).Trim() }
function Kill-Sess([string]$Sess) {
    & $PSMUX kill-session -t $Sess 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$Sess.*" -Force -EA SilentlyContinue
}

# ---------------------------------------------------------------------------
# Part A: server only, no client. select-pane must not resurrect copy mode.
# ---------------------------------------------------------------------------
Write-Host "`n=== Part A: server-side, no client ===" -ForegroundColor Cyan
$SA = "cancel_srv"
Kill-Sess $SA
& $PSMUX new-session -d -s $SA -x 120 -y 30
Start-Sleep -Seconds 3
& $PSMUX set-option -t $SA mouse on 2>&1 | Out-Null
& $PSMUX send-keys -t $SA "1..200 | % { 'L-{0:D4}' -f `$_ }" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3
$paneId = (Fmt $SA '#{pane_id}') -replace '%',''

$port = (Get-Content "$psmuxDir\$SA.port" -Raw).Trim()
$authKey = (Get-Content "$psmuxDir\$SA.key" -Raw).Trim()
$tcp = New-Object System.Net.Sockets.TcpClient
$tcp.Connect("127.0.0.1", [int]$port); $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 2000
$stream = $tcp.GetStream()
$wr = New-Object System.IO.StreamWriter($stream); $wr.AutoFlush = $true; $wr.NewLine = "`n"
$rd = New-Object System.IO.StreamReader($stream)
$wr.WriteLine("AUTH $authKey"); $null = $rd.ReadLine()
$wr.WriteLine("PERSISTENT")

# copy-end-of-line itself stays in copy mode in tmux (window-copy.c
# window_copy_do_copy_end_of_line returns REDRAW unless cancel is set); the
# exit arm that shares the defect is its -and-cancel form.
foreach ($exitCmd in @("cancel", "copy-selection-and-cancel", "copy-end-of-line-and-cancel")) {
    & $PSMUX copy-mode -t $SA 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $entered = Fmt $SA '#{pane_in_mode}'
    & $PSMUX send-keys -t $SA -X $exitCmd 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    $afterExit = Fmt $SA '#{pane_in_mode}'
    # select-pane is what every mouse click sends first.
    $wr.Write("select-pane -t %$paneId`n")
    Start-Sleep -Milliseconds 700
    $afterFocus = Fmt $SA '#{pane_in_mode}'
    Write-Info "-X $exitCmd : entered=$entered afterExit=$afterExit afterSelectPane=$afterFocus"
    if ($entered -ne "1") { Write-Fail "-X $exitCmd : could not enter copy mode first" }
    elseif ($afterExit -ne "0") { Write-Fail "-X $exitCmd : did not leave copy mode (mode=$afterExit)" }
    elseif ($afterFocus -eq "0") { Write-Pass "-X $exitCmd : select-pane did NOT resurrect copy mode" }
    else { Write-Fail "-X $exitCmd : select-pane put the pane back into copy mode (stale pane.copy_state)" }
}

# The feature copy_state exists for must still work: a pane genuinely left in
# copy mode keeps it across a focus change.
& $PSMUX copy-mode -t $SA 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$wr.Write("select-pane -t %$paneId`n")
Start-Sleep -Milliseconds 700
$stillIn = Fmt $SA '#{pane_in_mode}'
if ($stillIn -eq "1") { Write-Pass "a pane really in copy mode still keeps it across select-pane" }
else { Write-Fail "select-pane dropped a genuine copy mode (mode=$stillIn)" }
& $PSMUX send-keys -t $SA -X cancel 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

# tmux parity: plain copy-end-of-line copies and stays in copy mode.
& $PSMUX copy-mode -t $SA 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX send-keys -t $SA -X copy-end-of-line 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$eolMode = Fmt $SA '#{pane_in_mode}'
if ($eolMode -eq "1") { Write-Pass "-X copy-end-of-line stays in copy mode, as in tmux" }
else { Write-Fail "-X copy-end-of-line left copy mode (mode=$eolMode); tmux stays" }
& $PSMUX send-keys -t $SA -X cancel 2>&1 | Out-Null
$tcp.Close()
Kill-Sess $SA

# ---------------------------------------------------------------------------
# Part B: real attached client, injected click after an external -X cancel.
# ---------------------------------------------------------------------------
Write-Host "`n=== Part B: attached client, injected MOUSE_EVENT click ===" -ForegroundColor Cyan
$SB = "cancel_tui"
Kill-Sess $SB
$null = Start-Process -FilePath $launchCmd -ArgumentList $SB,$conf -PassThru
for ($i = 0; $i -lt 80; $i++) { if (Test-Path "$psmuxDir\$SB.port") { break }; Start-Sleep -Milliseconds 250 }
Start-Sleep -Seconds 4
$cli = Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" |
    Where-Object { $_.CommandLine -match "new-session -s\s+$SB\b" } | Select-Object -First 1
if (-not $cli) {
    Write-Fail "attached client did not start"
} else {
    $cpid = [int]$cli.ProcessId
    & $PSMUX send-keys -t $SB "1..200 | % { 'L-{0:D4}' -f `$_ }" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $paneH = [int](Fmt $SB '#{pane_height}')
    $clickRow = [Math]::Max(1, $paneH - 4)

    & $keyInj $cpid "^b{SLEEP:300}[" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $mIn = Fmt $SB '#{pane_in_mode}'
    & $PSMUX send-keys -t $SB -X cancel 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $mCancel = Fmt $SB '#{pane_in_mode}'
    & $clickInj $cpid 10 $clickRow 80 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1000
    $mClick = Fmt $SB '#{pane_in_mode}'
    Write-Info "prefix-[=$mIn  after -X cancel=$mCancel  after plain click=$mClick"
    if ($mIn -ne "1") { Write-Fail "prefix-[ did not enter copy mode (injection failed)" }
    elseif ($mCancel -ne "0") { Write-Fail "-X cancel did not leave copy mode" }
    elseif ($mClick -eq "0") { Write-Pass "a plain click after -X cancel stays out of copy mode" }
    else { Write-Fail "BUG: a plain click after -X cancel re-entered copy mode" }

    # A click must still be able to ENTER copy mode nowhere by itself, and the
    # session must remain usable.
    & $PSMUX send-keys -t $SB "echo STILL_ALIVE" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $cap = (& $PSMUX capture-pane -t $SB -p 2>&1 | Out-String)
    if ($cap -match "STILL_ALIVE") { Write-Pass "pane still accepts input after the click" }
    else { Write-Fail "pane stopped echoing after the click" }
    try { Stop-Process -Id $cpid -Force -EA SilentlyContinue } catch {}
}
Kill-Sess $SB

# ---------------------------------------------------------------------------
# Part C: `new-window -- prog` names the window after the program (tmux parity)
# ---------------------------------------------------------------------------
Write-Host "`n=== Part C: -- argv window naming ===" -ForegroundColor Cyan
$SC = "dashdash_name"
Kill-Sess $SC
& $PSMUX new-session -d -s $SC -x 120 -y 30
Start-Sleep -Seconds 3
& $PSMUX new-window -t $SC -- cmd /k echo CHILDARGS -t worker 2>&1 | Out-Null
Start-Sleep -Seconds 3
$wins = (& $PSMUX list-windows -t $SC 2>&1 | Out-String)
$name = Fmt "${SC}:1" '#{window_name}'
Write-Info "windows: $(($wins -split "`r?`n" | Where-Object { $_ -match '\S' }) -join ' | ')"
if ($name -eq "cmd") { Write-Pass "window named after the program ('cmd'), not the -- marker" }
elseif ($name -eq "--") { Write-Fail "BUG: window is named '--' (the argv marker leaked into the name)" }
else { Write-Fail "unexpected window name '$name'" }

# The #582 behaviour this must not disturb: the child keeps its own -t.
$ppid = Fmt "${SC}:1" '#{pane_pid}'
$childCmd = ""
if ($ppid -match '^\d+$') {
    $childCmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -EA SilentlyContinue).CommandLine
}
if ($childCmd -match '-t worker') { Write-Pass "child argv still carries '-t worker' (#582 intact)" }
else { Write-Fail "child argv lost '-t worker': '$childCmd'" }
$capC = (& $PSMUX capture-pane -t "${SC}:1" -p 2>&1 | Out-String)
if ($capC -match 'CHILDARGS -t worker') { Write-Pass "child printed its own -t argument" }
else { Write-Fail "child output missing: '$($capC.Trim())'" }

# A plain (non---) command still names the window after the program.
& $PSMUX new-window -t $SC "ping -n 20 127.0.0.1" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$name2 = Fmt "${SC}:2" '#{window_name}'
if ($name2 -match '^ping') { Write-Pass "plain command form still names the window 'ping'" }
else { Write-Fail "plain command form named the window '$name2'" }
Kill-Sess $SC

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
exit $script:Fail
