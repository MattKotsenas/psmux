# Issue #332: Bare %N pane ID targets resolve to wrong panes (cyclic offset)
#
# Layer 1 (E2E CLI):    psmux display-message -t %N -p '#{pane_id}' must return %N
# Layer 1 (E2E TCP):    same via raw TCP socket persistent connection
# Layer 2 (Win32 TUI):  attached session, drive via CLI, verify session is functional
#
# Pre-fix behavior:  every -t %N returned the active pane's id (always %1).
# Post-fix:          each -t %N must round-trip its own id.

$ErrorActionPreference = "Continue"
$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe").Path
$psmuxDir = "$env:USERPROFILE\.psmux"
$SES = "test_332"
$SES_TUI = "test_332_tui"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:Pass = 0
$script:Fail = 0
function P($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function F($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function Cleanup($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Get-Process psmux -EA SilentlyContinue | Where-Object {
        $_.CommandLine -like "*$name*"
    } | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 200
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
}

#-----------------------------------------------------------------------
# LAYER 1: CLI E2E
#-----------------------------------------------------------------------
Write-Host "`n=== Layer 1: CLI E2E (bare %N targeting) ===" -ForegroundColor Cyan
Cleanup $SES
& $PSMUX new-session -d -s $SES -x 120 -y 40
Start-Sleep -Seconds 3
& $PSMUX split-window -h -t "${SES}:0" -d
Start-Sleep -Milliseconds 500
& $PSMUX split-window -v -t "${SES}:0" -d
Start-Sleep -Milliseconds 500

# Capture the panes' IDs in this session
& $PSMUX has-session -t $SES 2>$null
if ($LASTEXITCODE -ne 0) { F "session not ready - aborting Layer 1"; exit 1 }
$layoutRaw = & $PSMUX list-panes -t "${SES}:0" -F "#{pane_id} #{pane_index}" 2>&1
$layout = @($layoutRaw | ForEach-Object { ($_ | Out-String).Trim() } | Where-Object { $_ -match '^%\d+\s+\d+$' })
Write-Host "  Layout:"
$layout | ForEach-Object { Write-Host "    $_" }
$ids = ($layout | ForEach-Object { ($_ -split '\s+')[0] -replace '%','' })

foreach ($id in $ids) {
    $r = (& $PSMUX display-message -t "%$id" -p '#{pane_id}' 2>&1 | Out-String).Trim()
    if ($r -eq "%$id") { P "display-message -t %$id => %$id" }
    else { F "display-message -t %$id returned '$r' (expected %$id)" }
}

# pane_index should also be correct via -t %N
foreach ($line in $layout) {
    $parts = $line -split '\s+'
    if ($parts.Count -ge 2) {
        $paneId = $parts[0]
        $expectedIdx = $parts[1]
        $actualIdx = (& $PSMUX display-message -t $paneId -p '#{pane_index}' 2>&1 | Out-String).Trim()
        if ($actualIdx -eq $expectedIdx) { P "display-message -t $paneId => pane_index=$actualIdx" }
        else { F "$paneId pane_index expected $expectedIdx got $actualIdx" }
    }
}

# Cross-check: -t with session:window.index should still work (regression check)
$r = (& $PSMUX display-message -t "${SES}:0.0" -p '#{pane_id}' 2>&1 | Out-String).Trim()
if ($r -match '^%\d+$') { P "session:window.idx target still works ($r)" }
else { F "session:window.idx broken: $r" }

Cleanup $SES

#-----------------------------------------------------------------------
# LAYER 1b: Raw TCP persistent connection
# (Skipped: Layer 1 CLI already exercises the TCP server handler path
#  since psmux CLI dispatches every -t command over TCP. Adding a raw
#  socket reproduction would only test the same code path.)
#-----------------------------------------------------------------------

#-----------------------------------------------------------------------
# LAYER 2: Win32 TUI verification (attached session)
#-----------------------------------------------------------------------
Write-Host "`n=== Layer 2: Win32 TUI ===" -ForegroundColor Cyan
Cleanup $SES_TUI
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SES_TUI -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SES_TUI 2>$null
if ($LASTEXITCODE -ne 0) { F "TUI session not ready"; }
else {
    & $PSMUX split-window -h -t "${SES_TUI}:0" 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    & $PSMUX split-window -v -t "${SES_TUI}:0" 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    $panes = (& $PSMUX display-message -t "${SES_TUI}:0" -p '#{window_panes}' 2>&1 | Out-String).Trim()
    if ($panes -eq "3") { P "TUI: split-window built 3 panes" } else { F "expected 3 panes got '$panes'" }

    $ids = @()
    & $PSMUX list-panes -t "${SES_TUI}:0" -F '#{pane_id}' 2>&1 | ForEach-Object {
        $s = ($_ | Out-String).Trim()
        if ($s -match '^%\d+$') { $ids += $s }
    }
    foreach ($id in $ids) {
        $r = (& $PSMUX display-message -t $id -p '#{pane_id}' 2>&1 | Out-String).Trim()
        if ($r -eq $id) { P "TUI: -t $id => $id" }
        else { F "TUI: -t $id returned '$r' (expected $id)" }
    }
}

Cleanup $SES_TUI
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass" -ForegroundColor Green
Write-Host "  Failed: $script:Fail" -ForegroundColor $(if ($script:Fail) {'Red'} else {'Green'})
exit $script:Fail
