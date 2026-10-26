# Issue #669: with `pane-border-status top`, mouse RELEASE and DRAG reached the
# pane's application one row BELOW the PRESS (goranvasilj).
#
# The label row `pane-border-status top` reserves is taken out of the pane's
# content by the client before it sends a press as `pane-mouse`, but the
# release, the drag and the wheel travel as RAW screen coordinates for the
# server to convert. The server used to subtract the pane's layout slot top,
# which IS the label row, so every raw-converted event sat one row low.
#
# Reported on a detached 80x24 session driven with raw control-port verbs, and
# felt by the user through an attached client and a real mouse. Both are tested
# here, against the ground truth of an SGR mouse echo child that logs its own
# raw stdin (tests/mouse_echo_child.cs).
#
# Layers: raw control-port verbs (pure server route, no client at all) and real
#         MOUSE_EVENT records injected into an attached client's console.
#
# Run:  pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue669_border_status_top_mouse_rows.ps1
#       PSMUX_EXE selects the binary under test.

$ErrorActionPreference = "Continue"
$env:PSMUX_NO_WARM = "1"
$PSMUX = if ($env:PSMUX_EXE) { $env:PSMUX_EXE } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$NS = "i669m"
$S  = "s669"

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan
Write-Host ("version: " + (& $PSMUX -V)) -ForegroundColor Cyan

$TMP = Join-Path $env:TEMP "i669_suite"
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }

$child    = Join-Path $TMP "echo_child.exe"
$clickInj = Join-Path $TMP "click.exe"
$dragInj  = Join-Path $TMP "drag.exe"
$childLog = Join-Path $TMP "echo.txt"
foreach ($pair in @(@($child,"mouse_echo_child.cs"),@($clickInj,"click_injector.cs"),@($dragInj,"mouse_drag_hold_injector.cs"))) {
    if (-not (Test-Path $pair[0])) { & $csc /nologo /optimize /out:$($pair[0]) (Join-Path $PSScriptRoot $pair[1]) 2>&1 | Out-Null }
    if (-not (Test-Path $pair[0])) { Write-Host "FATAL: could not compile $($pair[1])" -ForegroundColor Red; exit 1 }
}

function Port-File {
    Get-ChildItem $psmuxDir -Filter "*$S.port" -EA SilentlyContinue |
        Where-Object { $_.Name -like "*$NS*" } | Select-Object -First 1
}
# Tear the namespace down and WAIT for its port file to go: a previous run's
# server is still reaping while the next `new-session` runs, and the server
# that loses that race exits after its first command has already been answered.
function Stop-Ns {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Port-File)) { break }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Milliseconds 700
}
function LogCount { if (Test-Path $childLog) { (Get-Content $childLog).Count } else { 0 } }
function New-Events([int]$before) {
    $all = if (Test-Path $childLog) { Get-Content $childLog } else { @() }
    if ($all.Count -le $before) { return @() }
    $out = @()
    foreach ($line in $all[$before..($all.Count-1)]) {
        foreach ($m in [regex]::Matches($line, '<ESC>\[<(\d+);(\d+);(\d+)([Mm])')) {
            $out += [pscustomobject]@{
                Btn  = [int]$m.Groups[1].Value
                Col  = [int]$m.Groups[2].Value
                Row  = [int]$m.Groups[3].Value
                Kind = $m.Groups[4].Value
                Raw  = $m.Value
            }
        }
    }
    return $out
}
function Send-Tcp([string[]]$Cmds) {
    # One command per connection: the control protocol serves a single command
    # unless the client sends PERSISTENT after AUTH.
    $pf = Port-File
    if (-not $pf) { return "NOPORT" }
    $port = (Get-Content $pf.FullName -Raw).Trim()
    $key  = (Get-Content ($pf.FullName -replace '\.port$','.key') -Raw).Trim()
    foreach ($c in $Cmds) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", [int]$port)
            $st = $tcp.GetStream(); $st.ReadTimeout = 1500
            $w = New-Object System.IO.StreamWriter($st); $w.AutoFlush = $true; $w.NewLine = "`n"
            $r = New-Object System.IO.StreamReader($st)
            $w.WriteLine("AUTH $key"); $null = $r.ReadLine()
            $w.WriteLine($c)
            try { $null = $r.ReadLine() } catch {}
            Start-Sleep -Milliseconds 150
            $tcp.Close()
        } catch { return "EXCEPTION $($_.Exception.Message)" }
    }
    return "sent"
}
# The child is started by typing its path at the pane's shell, so it is ready
# only once that shell has reached a prompt AND the child has printed its
# banner. Poll for the banner and retype once rather than guessing a sleep.
function Wait-Child([string]$Cmd, [int]$Secs = 25) {
    & $PSMUX -L $NS send-keys -t $S $Cmd Enter 2>&1 | Out-Null
    $retried = $false
    for ($i = 0; $i -lt ($Secs * 2); $i++) {
        Start-Sleep -Milliseconds 500
        if (((& $PSMUX -L $NS capture-pane -t $S -p 2>&1) | Out-String) -match 'MOUSE_ECHO_READY') { return $true }
        if (-not $retried -and $i -eq $Secs) {
            $retried = $true
            & $PSMUX -L $NS send-keys -t $S $Cmd Enter 2>&1 | Out-Null
        }
    }
    return $false
}
function Set-BorderStatus([string]$v) {
    if ($v -eq "off") { & $PSMUX -L $NS set-option -t $S pane-border-status off 2>&1 | Out-Null }
    else { & $PSMUX -L $NS set-option -t $S pane-border-status $v 2>&1 | Out-Null }
    Start-Sleep -Milliseconds 1200
}

# =====================================================================
Write-Host "`n[A] raw control-port verbs, detached 80x24 session" -ForegroundColor Yellow
# =====================================================================
Stop-Ns
Remove-Item $childLog -Force -EA SilentlyContinue
$env:PSMUX_MOUSE_ECHO_LOG = $childLog
& $PSMUX -L $NS new-session -d -s $S -x 80 -y 24 2>&1 | Out-Null
for ($i = 0; $i -lt 60; $i++) { if (Port-File) { break }; Start-Sleep -Milliseconds 250 }
if (-not (Port-File)) { Write-Fail "detached session $S did not come up in namespace $NS"; exit 1 }
Start-Sleep -Seconds 2
& $PSMUX -L $NS set-option -t $S -g mouse on 2>&1 | Out-Null
$paneId = ((& $PSMUX -L $NS list-panes -t $S -F '#{pane_id}') | Select-Object -First 1).Trim()
$paneNum = $paneId.TrimStart('%')
if (Wait-Child "`$env:PSMUX_MOUSE_ECHO_LOG='$childLog'; & '$child'") {
    Write-Pass "mouse-reporting child is running in $paneId"
} else {
    Write-Fail "mouse-reporting child did not start"
    Write-Info ((& $PSMUX -L $NS capture-pane -t $S -p 2>&1) | Out-String)
    Stop-Ns
    exit 1
}

# Screen row 5 with a label at the top is content row 4, so SGR row 5.
# With no label, and with the label at the bottom, it is SGR row 6.
foreach ($case in @(
    @{ Status = "off";    PressRow = 6; DragRow = 7 },
    @{ Status = "top";    PressRow = 5; DragRow = 6 },
    @{ Status = "bottom"; PressRow = 6; DragRow = 7 }
)) {
    $st = $case.Status
    Set-BorderStatus $st
    Write-Info "pane-border-status $st : $(((& $PSMUX -L $NS list-panes -t $S -F '#{pane_id} top=#{pane_top} bot=#{pane_bottom} h=#{pane_height}')) -join '; ')"

    $rows = @{}
    foreach ($verb in @(@("mouse-down 10 5","press"), @("mouse-up 10 5","release"), @("mouse-drag 10 6","drag"))) {
        $b = LogCount
        $null = Send-Tcp @($verb[0])
        Start-Sleep -Milliseconds 700
        $ev = New-Events $b | Select-Object -Last 1
        if ($null -eq $ev) { $rows[$verb[1]] = $null; Write-Skip "$st : '$($verb[0])' forwarded nothing" }
        else { $rows[$verb[1]] = $ev; Write-Info "$st : '$($verb[0])' -> $($ev.Raw)" }
    }

    if ($null -ne $rows["press"] -and $rows["press"].Row -eq $case.PressRow) {
        Write-Pass "$st : press on screen row 5 reported SGR row $($rows['press'].Row)"
    } elseif ($null -ne $rows["press"]) {
        Write-Fail "$st : press reported SGR row $($rows['press'].Row), expected $($case.PressRow)"
    }
    if ($null -ne $rows["release"] -and $null -ne $rows["press"]) {
        if ($rows["release"].Row -eq $rows["press"].Row) {
            Write-Pass "$st : release on the same screen row reported the same SGR row ($($rows['release'].Row))"
        } else {
            Write-Fail "$st : release reported SGR row $($rows['release'].Row) for the row the press reported as $($rows['press'].Row) (#669)"
        }
    }
    if ($null -ne $rows["drag"]) {
        if ($rows["drag"].Row -eq $case.DragRow) {
            Write-Pass "$st : drag to screen row 6 reported SGR row $($rows['drag'].Row)"
        } else {
            Write-Fail "$st : drag to screen row 6 reported SGR row $($rows['drag'].Row), expected $($case.DragRow) (#669)"
        }
    }
}
Stop-Ns

# =====================================================================
Write-Host "`n[B] attached client, real MOUSE_EVENT records" -ForegroundColor Yellow
# =====================================================================
$conf = Join-Path $TMP "i669.conf"
"set -g mouse on" | Set-Content -Path $conf -Encoding ASCII
# A launcher that scrubs the nesting variables, so the client starts even when
# this script runs from inside another psmux/tmux pane.
$launch = Join-Path $TMP "launch.cmd"
@"
@echo off
set PSMUX_SESSION=
set PSMUX_PANE=
set TMUX=
set TMUX_PANE=
set PSMUX=
set PSMUX_NO_WARM=1
set NO_COLOR=
set PSMUX_MOUSE_ECHO_LOG=$childLog
"$PSMUX" -L $NS -f "$conf" new-session -s $S -x 80 -y 24
"@ | Set-Content -Path $launch -Encoding ASCII

Remove-Item $childLog -Force -EA SilentlyContinue
$null = Start-Process -FilePath $launch -PassThru
$cli = $null
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    $cli = Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" |
           Where-Object { $_.CommandLine -match "-L $NS" -and $_.CommandLine -match "new-session -s $S" } |
           Select-Object -First 1
    if ($cli) { break }
}
if (-not $cli) {
    Write-Skip "no attached client started; the console-injection layer cannot run here"
} else {
    Start-Sleep -Seconds 4
    $cpid = [int]$cli.ProcessId
    Write-Info "attached client pid=$cpid"
    if (Wait-Child "& '$child'") {
        Write-Pass "mouse-reporting child is running under the attached client"

        foreach ($st in @("off", "top", "bottom")) {
            Set-BorderStatus $st

            # One real click: press and release at the SAME cell.
            $b = LogCount
            & $clickInj $cpid 10 5 120 | Out-Null
            Start-Sleep -Milliseconds 1000
            $ev = New-Events $b
            $press   = $ev | Where-Object { $_.Kind -ceq 'M' -and $_.Btn -eq 0 } | Select-Object -First 1
            $release = $ev | Where-Object { $_.Kind -ceq 'm' } | Select-Object -First 1
            if ($null -eq $press -or $null -eq $release) {
                Write-Skip "$st : the injected click delivered no press/release pair (focus refused)"
            } elseif ($press.Row -eq $release.Row) {
                Write-Pass "$st : real click press $($press.Raw) and release $($release.Raw) share a row"
            } else {
                Write-Fail "$st : real click press $($press.Raw) but release $($release.Raw) — release is $($release.Row - $press.Row) row(s) off (#669)"
            }

            # One real drag: press on row 5, motion to row 6, release there.
            $b = LogCount
            & $dragInj $cpid 10 5 10 6 2 60 150 | Out-Null
            Start-Sleep -Milliseconds 1400
            $ev = New-Events $b
            $dpress  = $ev | Where-Object { $_.Kind -ceq 'M' -and $_.Btn -eq 0 } | Select-Object -First 1
            $motions = @($ev | Where-Object { $_.Kind -ceq 'M' -and $_.Btn -eq 32 })
            $drel    = $ev | Where-Object { $_.Kind -ceq 'm' } | Select-Object -Last 1
            if ($null -eq $dpress -or $motions.Count -eq 0) {
                Write-Skip "$st : the injected drag delivered no press/motion (focus refused)"
            } else {
                $lastMotion = $motions[-1]
                if ($lastMotion.Row -eq ($dpress.Row + 1)) {
                    Write-Pass "$st : drag one screen row below the press reported one SGR row below it ($($dpress.Raw) -> $($lastMotion.Raw))"
                } else {
                    Write-Fail "$st : drag reported $($lastMotion.Raw) for one row below press $($dpress.Raw) (#669)"
                }
                if ($null -ne $drel) {
                    if ($drel.Row -eq $lastMotion.Row) {
                        Write-Pass "$st : the drag's release landed on the row the drag ended on ($($drel.Raw))"
                    } else {
                        Write-Fail "$st : the drag ended on $($lastMotion.Raw) but released at $($drel.Raw) (#669)"
                    }
                }
            }
        }
    } else {
        Write-Fail "mouse-reporting child did not start under the attached client"
        Write-Info ((& $PSMUX -L $NS capture-pane -t $S -p 2>&1) | Out-String)
    }
    Stop-Ns
    try { Stop-Process -Id $cpid -Force -EA SilentlyContinue } catch {}
}

Stop-Ns
Write-Host "`n=== Issue #669 summary ===" -ForegroundColor Cyan
Write-Host "  Passed:  $script:Pass" -ForegroundColor Green
Write-Host "  Failed:  $script:Fail" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $script:Skip" -ForegroundColor Yellow
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
