# PR #572: split-window -Z must zoom after splitting (tmux parity).
# tmux semantics (cmd-split-window.c / window.c):
#   - split-window -Z    -> window_push_zoom(always=1) + window_pop_zoom:
#                           the ACTIVE pane after the split ends up zoomed
#                           (new pane normally; the old pane when -d is given)
#   - split-window (no Z) -> permanently unzooms a zoomed window
#   - already-zoomed + -Z -> stays zoomed
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "tpr572"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Cleanup { & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 500 }
function Fmt($fmt) { (& $PSMUX display-message -t $SESSION -p $fmt 2>&1 | Out-String).Trim() }

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 5000
    try { $resp = $reader.ReadLine() } catch { $resp = "" }
    $tcp.Close()
    return $resp
}

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== PR #572: split-window -Z ===" -ForegroundColor Cyan

# Test 1: CLI split-window -v -Z zooms, new pane active
Write-Host "[Test 1] CLI split-window -v -Z zooms the new pane" -ForegroundColor Yellow
& $PSMUX split-window -v -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panes = Fmt '#{window_panes}'
$zoom = Fmt '#{window_zoomed_flag}'
if ($panes -eq "2" -and $zoom -eq "1") { Write-Pass "2 panes, zoomed=1" }
else { Write-Fail "expected panes=2 zoomed=1, got panes=$panes zoomed=$zoom" }

# Test 2: plain split on a zoomed window permanently unzooms (tmux #82 parity intact)
Write-Host "[Test 2] plain split-window unzooms a zoomed window" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panes = Fmt '#{window_panes}'
$zoom = Fmt '#{window_zoomed_flag}'
if ($panes -eq "3" -and $zoom -eq "0") { Write-Pass "3 panes, zoomed=0 after plain split" }
else { Write-Fail "expected panes=3 zoomed=0, got panes=$panes zoomed=$zoom" }

# Test 3: -h -Z also zooms
Write-Host "[Test 3] split-window -h -Z zooms" -ForegroundColor Yellow
& $PSMUX split-window -h -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$zoom = Fmt '#{window_zoomed_flag}'
if ($zoom -eq "1") { Write-Pass "-h -Z zoomed=1" }
else { Write-Fail "-h -Z expected zoomed=1, got $zoom" }

# Test 4: splitting an ALREADY-zoomed window with -Z stays zoomed
Write-Host "[Test 4] already-zoomed + -Z stays zoomed" -ForegroundColor Yellow
& $PSMUX split-window -v -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$zoom = Fmt '#{window_zoomed_flag}'
$panes = Fmt '#{window_panes}'
if ($zoom -eq "1" -and $panes -eq "5") { Write-Pass "still zoomed after -Z split of zoomed window (panes=$panes)" }
else { Write-Fail "expected zoomed=1 panes=5, got zoomed=$zoom panes=$panes" }

# Tests 5-7 each start in a FRESH window: stacking splits in one window
# exhausts vertical space and the split itself fails (correctly, no zoom).
# Test 5: TCP server path split-window -Z
Write-Host "[Test 5] raw TCP split-window -Z" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$null = Send-TcpCommand -Session $SESSION -Command "split-window -v -Z"
Start-Sleep -Milliseconds 800
$zoom = Fmt '#{window_zoomed_flag}'
$panes = Fmt '#{window_panes}'
if ($zoom -eq "1" -and $panes -eq "2") { Write-Pass "TCP -Z zoomed=1 (panes=$panes)" }
else { Write-Fail "TCP expected zoomed=1 panes=2, got zoomed=$zoom panes=$panes" }

# Test 6: detached -d -Z zooms while the previously active pane stays active (tmux pop_zoom on active)
Write-Host "[Test 6] split-window -d -Z keeps old pane active and zooms it" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$beforeActive = Fmt '#{pane_id}'
& $PSMUX split-window -v -d -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$afterActive = Fmt '#{pane_id}'
$zoom = Fmt '#{window_zoomed_flag}'
$panes = Fmt '#{window_panes}'
if ($zoom -eq "1" -and $beforeActive -eq $afterActive -and $panes -eq "2") { Write-Pass "-d -Z zoomed=1, active pane unchanged ($afterActive)" }
else { Write-Fail "-d -Z expected zoomed=1 panes=2 same active, got zoomed=$zoom panes=$panes active $beforeActive -> $afterActive" }

# Test 7: -Z with -P print info still works and zooms
Write-Host "[Test 7] split-window -P -Z prints info and zooms" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$out = (& $PSMUX split-window -v -P -Z -t $SESSION 2>&1 | Out-String).Trim()
Start-Sleep -Milliseconds 800
$zoom = Fmt '#{window_zoomed_flag}'
$panes = Fmt '#{window_panes}'
if ($out -match ":" -and $zoom -eq "1" -and $panes -eq "2") { Write-Pass "-P printed '$out' and zoomed=1" }
else { Write-Fail "-P -Z expected pane info + zoomed=1 panes=2, got '$out' zoomed=$zoom panes=$panes" }

# Test 8: failed split (no space) must NOT zoom
Write-Host "[Test 8] failed split with -Z does not zoom" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
for ($i = 0; $i -lt 12; $i++) { & $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 150 }
$panesBefore = Fmt '#{window_panes}'
& $PSMUX split-window -v -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panesAfter = Fmt '#{window_panes}'
$zoom = Fmt '#{window_zoomed_flag}'
if ($panesAfter -eq $panesBefore -and $zoom -eq "0") { Write-Pass "no-space split failed and did not zoom (panes=$panesAfter)" }
elseif ($panesAfter -ne $panesBefore -and $zoom -eq "1") { Write-Pass "split still fit ($panesBefore->$panesAfter) and zoomed correctly" }
else { Write-Fail "inconsistent: panes $panesBefore->$panesAfter zoomed=$zoom" }

Cleanup

# === Win32 TUI visual verification (Strategy A) ===
Write-Host "`n=== TUI verification ===" -ForegroundColor Cyan
$T = "tpr572tui"
& $PSMUX kill-session -t $T 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$T -PassThru
Start-Sleep -Seconds 4
& $PSMUX split-window -v -Z -t $T 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$zoom = (& $PSMUX display-message -t $T -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
$panes = (& $PSMUX display-message -t $T -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($zoom -eq "1" -and $panes -eq "2") { Write-Pass "TUI attached: -Z split zoomed (panes=$panes)" }
else { Write-Fail "TUI attached: expected zoomed=1 panes=2, got zoomed=$zoom panes=$panes" }
# unzoom via CLI works after -Z split
& $PSMUX resize-pane -Z -t $T 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$zoom = (& $PSMUX display-message -t $T -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
if ($zoom -eq "0") { Write-Pass "TUI attached: unzoom works after -Z split" }
else { Write-Fail "TUI attached: unzoom expected 0, got $zoom" }
& $PSMUX kill-session -t $T 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
