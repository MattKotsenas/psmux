# Issue #440: pipe-pane was a stub - the spawned child received no pane output
# (log stayed 0 bytes), and the -t target was not honored (active pane was always
# used). This test proves, end to end, that:
#   1. pane output is actually fed to the piped command's stdin (Defect 1)
#   2. `-t <target>` pipes the requested (possibly background) pane, not the
#      active one (Defect 2)
#   3. toggle-off (`pipe-pane` / `pipe-pane -o` with an existing pipe) stops it
#   4. Win32 TUI: a real visible window can be piped and produces output
#
# Verification is via a small sink script that appends each stdin line to a file
# whose absolute path is embedded literally (so it does NOT depend on the psmux
# server inheriting an environment variable).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "test_issue440"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function New-Sink {
    param([string]$LogPath, [string]$SinkPath)
    @"
`$p = '$LogPath'
`$sr = [Console]::In
while (`$null -ne (`$line = `$sr.ReadLine())) { Add-Content -Path `$p -Value `$line }
"@ | Set-Content -Path $SinkPath -Encoding UTF8
}

function Count-Matches($file, $pattern) {
    $c = Get-Content $file -Raw -EA SilentlyContinue
    if ($null -eq $c) { return 0 }
    return ([regex]::Matches($c, $pattern)).Count
}

function Cleanup {
    param([string]$Name = $SESSION)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

Write-Host "`n=== Issue #440: pipe-pane feeds pane output + honors -t ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# TEST 1 (Defect 1): pane output actually reaches the piped command
# ---------------------------------------------------------------------------
Write-Host "`n[Test 1] Defect 1: pane output is fed to the pipe command" -ForegroundColor Yellow
$log1  = "$env:TEMP\test_issue440_t1.log"
$sink1 = "$env:TEMP\test_issue440_t1_sink.ps1"
New-Sink $log1 $sink1
Cleanup
Remove-Item $log1 -Force -EA SilentlyContinue

& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX new-window -t $SESSION -n ticks pwsh -NoProfile -Command "1..20 | ForEach-Object { `"TICK `$_`"; Start-Sleep -Milliseconds 400 }"
Start-Sleep -Milliseconds 700
& $PSMUX pipe-pane -o "pwsh -NoProfile -File `"$sink1`""
if ($LASTEXITCODE -eq 0) { Write-Pass "pipe-pane returned exit 0" } else { Write-Fail "pipe-pane exit $LASTEXITCODE" }
Start-Sleep -Seconds 9
$n1 = Count-Matches $log1 "TICK"
if ($n1 -gt 0) { Write-Pass "pipe received $n1 TICK lines (was 0 before the fix)" }
else { Write-Fail "pipe received nothing - Defect 1 still present" }
Cleanup

# ---------------------------------------------------------------------------
# TEST 2 (Defect 2): -t targets a BACKGROUND pane, not the active one
# ---------------------------------------------------------------------------
Write-Host "`n[Test 2] Defect 2: -t honors the target (background) pane" -ForegroundColor Yellow
$log2  = "$env:TEMP\test_issue440_t2.log"
$sink2 = "$env:TEMP\test_issue440_t2_sink.ps1"
New-Sink $log2 $sink2
Remove-Item $log2 -Force -EA SilentlyContinue

& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
$base = (& $PSMUX display-message -t $SESSION -p '#{window_index}' 2>&1).Trim()
& $PSMUX rename-window -t $SESSION "activewin"
& $PSMUX new-window -t $SESSION -n ticks pwsh -NoProfile -Command "1..25 | ForEach-Object { `"BGTICK `$_`"; Start-Sleep -Milliseconds 400 }"
Start-Sleep -Milliseconds 700
$activeIdx = $base
$ticksIdx  = ([int]$base + 1)
& $PSMUX select-window -t "${SESSION}:${activeIdx}"
Start-Sleep -Milliseconds 400
$activeName = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
if ($activeName -eq "activewin") { Write-Pass "active window is activewin (target is a background pane)" }
else { Write-Fail "expected active=activewin, got $activeName" }
# noise in the ACTIVE window after the pipe attaches - must NOT be captured
& $PSMUX send-keys -t "${SESSION}:${activeIdx}" "1..25 | % { echo ACTIVE_NOISE_`$_; Start-Sleep -Milliseconds 400 }" Enter
& $PSMUX pipe-pane -t "${SESSION}:${ticksIdx}" -o "pwsh -NoProfile -File `"$sink2`""
Start-Sleep -Seconds 11
$bg = Count-Matches $log2 "BGTICK"
$act = Count-Matches $log2 "ACTIVE_NOISE"
if ($bg -gt 0) { Write-Pass "target (background) pane produced $bg BGTICK lines" }
else { Write-Fail "target pane produced nothing" }
if ($act -eq 0) { Write-Pass "active pane output was NOT captured ($act ACTIVE_NOISE)" }
else { Write-Fail "active pane leaked into the pipe ($act ACTIVE_NOISE)" }
Cleanup

# ---------------------------------------------------------------------------
# TEST 3: toggle-off stops the pipe
# ---------------------------------------------------------------------------
Write-Host "`n[Test 3] toggle-off stops piping" -ForegroundColor Yellow
$log3  = "$env:TEMP\test_issue440_t3.log"
$sink3 = "$env:TEMP\test_issue440_t3_sink.ps1"
New-Sink $log3 $sink3
Remove-Item $log3 -Force -EA SilentlyContinue

& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX new-window -t $SESSION -n ticks pwsh -NoProfile -Command "1..40 | ForEach-Object { `"TOGTICK `$_`"; Start-Sleep -Milliseconds 300 }"
Start-Sleep -Milliseconds 700
& $PSMUX pipe-pane -o "pwsh -NoProfile -File `"$sink3`""
Start-Sleep -Seconds 3
$before = Count-Matches $log3 "TOGTICK"
& $PSMUX pipe-pane -o "pwsh -NoProfile -File `"$sink3`""   # toggle off
Start-Sleep -Milliseconds 300
$atOff = Count-Matches $log3 "TOGTICK"
Start-Sleep -Seconds 3
$afterOff = Count-Matches $log3 "TOGTICK"
if ($before -gt 0) { Write-Pass "pipe captured $before lines before toggle-off" }
else { Write-Fail "nothing captured before toggle-off" }
if (($afterOff - $atOff) -le 2) { Write-Pass "no new output after toggle-off (grew $($afterOff-$atOff))" }
else { Write-Fail "pipe kept running after toggle-off (grew $($afterOff-$atOff))" }
Cleanup

# ---------------------------------------------------------------------------
# TEST 4: Win32 TUI visual verification (real visible window, driven by CLI)
# ---------------------------------------------------------------------------
Write-Host "`n[Test 4] Win32 TUI: pipe a real visible window" -ForegroundColor Yellow
$SESSION_TUI = "test_issue440_tui"
$log4  = "$env:TEMP\test_issue440_t4.log"
$sink4 = "$env:TEMP\test_issue440_t4_sink.ps1"
New-Sink $log4 $sink4
Cleanup $SESSION_TUI
Remove-Item $log4 -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4
& $PSMUX pipe-pane -t $SESSION_TUI -o "pwsh -NoProfile -File `"$sink4`""
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION_TUI "echo TUI_PIPE_MARKER" Enter
Start-Sleep -Seconds 2
$tui = Count-Matches $log4 "TUI_PIPE_MARKER"
if ($tui -gt 0) { Write-Pass "TUI: piped window output reached the sink ($tui match)" }
else { Write-Fail "TUI: no piped output captured" }
Cleanup $SESSION_TUI
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# cleanup temp files
Remove-Item "$env:TEMP\test_issue440_*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
