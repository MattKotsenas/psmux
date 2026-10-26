# Issue #581: cursor misaligned in a Claude Code teammate layout.
#
# Reproduced on the released v3.3.7 (05cc5d4): with a teammate-style layout
# (tall left pane, three short right panes) and the ACTIVE short pane's inner
# TUI parking its cursor at the pane's LAST row (Claude Code's input box), the
# hardware cursor was drawn rows BELOW the pane, past the border, steadily
# (measured (81,23) where (69,20) was correct, 40/40 samples). Fixed by
# 30f15fe (the #507 cursor-computation rework): verified (69,20) 40/40 at that
# commit and on master, while the parent tag build misplaces.
#
# Oracle: the client console's hardware cursor via tests/cursorprobe.cs
# (GetConsoleScreenBufferInfo.dwCursorPosition), sampled while a neighbor pane
# streams output to force repaints.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "t581cur"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$PROBE = "$env:TEMP\cursorprobe.exe"
if (-not (Test-Path $PROBE)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $src = Join-Path $PSScriptRoot "cursorprobe.cs"
    & $csc /nologo /optimize /out:$PROBE $src 2>&1 | Out-Null
}
if (-not (Test-Path $PROBE)) { Write-Host "SKIP: cursorprobe compile failed" -ForegroundColor Yellow; exit 0 }

$env:PSMUX_NO_WARM = "1"
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "`n=== Issue #581: hardware cursor stays inside the active pane ===" -ForegroundColor Cyan

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
$ok = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match 'PS [A-Z]:\\') { $ok = $true; break }
}
if (-not $ok) { Write-Fail "pane never became ready"; exit 1 }

# teammate-style layout: tall left pane + right column of three short panes
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2

$rects = & $PSMUX list-panes -t $SESSION -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}' 2>&1
$p3 = ($rects | Where-Object { $_ -match '^%3 ' }) -split ' '
if (-not $p3 -or $p3.Count -lt 5) { Write-Fail "could not resolve pane %3 geometry"; exit 1 }
$p3left = [int]$p3[1]; $p3top = [int]$p3[2]; $p3h = [int]$p3[4]

# ACTIVE short right pane, inner cursor parked at its LAST row (Claude Code
# input-box shape); neighbor streams to force repaints
& $PSMUX select-pane -t "%3" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t "%3" "Write-Host -NoNewline ([char]27+'[$($p3h);3H> INPUT'); Start-Sleep 30" Enter 2>&1 | Out-Null
& $PSMUX send-keys -t "%4" "1..300 | ForEach-Object { `"line `$_`" ; Start-Sleep -Milliseconds 30 }" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3

$expX = $p3left + 2 + 7    # col 3 (1-based) + '> INPUT' (7 chars) -> 0-based
$expY = $p3top + $p3h - 1  # the pane's last row
$stamp = Get-Date -Format 'HHmmssff'
$json = "$env:TEMP\cursorprobe_t581_$stamp.json"
& $PROBE $proc.Id $json 40 100
Start-Sleep -Milliseconds 500
$data = Get-Content $json -Raw | ConvertFrom-Json
$trace = @($data.trace)
$good = @($trace | Where-Object { $_[0] -eq $expX -and $_[1] -eq $expY })
$below = @($trace | Where-Object { $_[1] -gt $expY })
Write-Host "  expected ($expX,$expY): $($good.Count)/$($trace.Count) samples; below-the-pane: $($below.Count)"
$trace | Group-Object { "$($_[0]),$($_[1])" } | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { Write-Host "    pos($($_.Name)) $($_.Count)x" }

if ($trace.Count -ge 30 -and $good.Count -ge ($trace.Count * 0.9)) {
    Write-Pass "cursor pinned at the active pane's input position"
} elseif ($below.Count -gt ($trace.Count * 0.2)) {
    Write-Fail "cursor drawn BELOW the active pane (issue #581 shape): $($below.Count)/$($trace.Count) samples"
} else {
    Write-Fail "cursor not at the expected position (see distribution above)"
}

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
