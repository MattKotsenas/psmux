# Issue #497: select-window -t session:@id rejected by client-side existence check
# The CLI pre-send check (cli_window_exists) validated the window part of a
# session-qualified target against window indexes and names only, so @id targets
# were rejected with "can't find window: @N" before ever reaching the server,
# whose FocusWindowById path fully supports them. This test proves all three
# target vocabularies (id, index, name) work for select-window, and that
# genuinely nonexistent targets in every vocabulary still fail with exit 1.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue497"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Get-ActiveWindow {
    (& $PSMUX display-message -t $SESSION -p '#{window_index}|#{window_name}' 2>&1 | Out-String).Trim()
}

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    exit 1
}

& $PSMUX new-window -t "${SESSION}:" -n two
Start-Sleep -Milliseconds 800
& $PSMUX new-window -t "${SESSION}:" -n three
Start-Sleep -Milliseconds 800

# Map out the real window ids so the test does not assume id numbering
$winList = & $PSMUX list-windows -t $SESSION -F '#{window_id}|#{window_index}|#{window_name}' 2>&1
$windows = @{}
foreach ($line in $winList) {
    $p = "$line".Trim().Split('|')
    if ($p.Count -eq 3 -and $p[0] -match '^@\d+$') { $windows[$p[2]] = @{ id = $p[0]; index = $p[1] } }
}
if ($windows.Count -lt 3) {
    Write-Fail "Expected 3 windows, got: $($winList -join ' / ')"
    Cleanup
    exit 1
}
$idTwo = $windows["two"].id
$idThree = $windows["three"].id

Write-Host "`n=== Issue #497 Tests (windows: two=$idTwo three=$idThree) ===" -ForegroundColor Cyan

# === TEST 1: select-window -t session:@id (the reported bug) ===
Write-Host "`n[Test 1] select-window -t ${SESSION}:$idTwo" -ForegroundColor Yellow
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$out = & $PSMUX select-window -t "${SESSION}:$idTwo" 2>&1
$ec = $LASTEXITCODE
Start-Sleep -Milliseconds 500
$active = Get-ActiveWindow
if ($ec -eq 0) { Write-Pass "exit code 0 (was 1 with 'can't find window')" }
else { Write-Fail "exit=$ec output=$out" }
if ($active -match "two") { Write-Pass "window actually switched to 'two' (active: $active)" }
else { Write-Fail "active window is '$active', expected 'two'" }

# === TEST 2: =session:@id form (exact-match session prefix) ===
Write-Host "`n[Test 2] select-window -t =${SESSION}:$idThree" -ForegroundColor Yellow
$out = & $PSMUX select-window -t "=${SESSION}:$idThree" 2>&1
$ec = $LASTEXITCODE
Start-Sleep -Milliseconds 500
$active = Get-ActiveWindow
if ($ec -eq 0 -and $active -match "three") { Write-Pass "=session:@id switched to 'three' (active: $active)" }
else { Write-Fail "exit=$ec active='$active' output=$out" }

# === TEST 3: index form regression guard ===
Write-Host "`n[Test 3] select-window -t ${SESSION}:0 (index form still works)" -ForegroundColor Yellow
$out = & $PSMUX select-window -t "${SESSION}:0" 2>&1
$ec = $LASTEXITCODE
Start-Sleep -Milliseconds 500
$active = Get-ActiveWindow
if ($ec -eq 0 -and $active -match "^0\|") { Write-Pass "index form switched to window 0 (active: $active)" }
else { Write-Fail "exit=$ec active='$active' output=$out" }

# === TEST 4: name form regression guard ===
Write-Host "`n[Test 4] select-window -t ${SESSION}:two (name form still works)" -ForegroundColor Yellow
$out = & $PSMUX select-window -t "${SESSION}:two" 2>&1
$ec = $LASTEXITCODE
Start-Sleep -Milliseconds 500
$active = Get-ActiveWindow
if ($ec -eq 0 -and $active -match "two") { Write-Pass "name form switched to 'two' (active: $active)" }
else { Write-Fail "exit=$ec active='$active' output=$out" }

# === TEST 5: nonexistent @id still errors (validation not weakened) ===
Write-Host "`n[Test 5] select-window -t ${SESSION}:@999 fails with exit 1" -ForegroundColor Yellow
$out = & $PSMUX select-window -t "${SESSION}:@999" 2>&1 | Out-String
$ec = $LASTEXITCODE
if ($ec -ne 0 -and $out -match "can't find window") { Write-Pass "nonexistent id rejected (exit=$ec)" }
else { Write-Fail "expected exit 1 + can't find window, got exit=$ec output=$out" }

# === TEST 6: nonexistent index still errors ===
Write-Host "`n[Test 6] select-window -t ${SESSION}:77 fails with exit 1" -ForegroundColor Yellow
$out = & $PSMUX select-window -t "${SESSION}:77" 2>&1 | Out-String
$ec = $LASTEXITCODE
if ($ec -ne 0 -and $out -match "can't find window") { Write-Pass "nonexistent index rejected (exit=$ec)" }
else { Write-Fail "expected exit 1 + can't find window, got exit=$ec output=$out" }

# === TEST 7: bare @id (unqualified) regression guard ===
Write-Host "`n[Test 7] select-window -t $idThree (bare id, no session prefix)" -ForegroundColor Yellow
$out = & $PSMUX select-window -t "${SESSION}:0" 2>&1
Start-Sleep -Milliseconds 300
$env:PSMUX_TARGET_SESSION = $null
$out = & $PSMUX select-window -t "$idThree" 2>&1
$ec = $LASTEXITCODE
Start-Sleep -Milliseconds 500
$active = Get-ActiveWindow
if ($ec -eq 0 -and $active -match "three") { Write-Pass "bare id switched to 'three' (active: $active)" }
else { Write-Fail "exit=$ec active='$active' output=$out" }

# === TEST 8: session:@id.pane form (pane suffix stripped before validation) ===
Write-Host "`n[Test 8] select-window -t ${SESSION}:$idTwo.0" -ForegroundColor Yellow
$out = & $PSMUX select-window -t "${SESSION}:$idTwo.0" 2>&1
$ec = $LASTEXITCODE
Start-Sleep -Milliseconds 500
$active = Get-ActiveWindow
if ($ec -eq 0 -and $active -match "two") { Write-Pass "id.pane form switched to 'two' (active: $active)" }
else { Write-Fail "exit=$ec active='$active' output=$out" }

# === TEST 9: TCP server path (raw socket select-window with @id) ===
Write-Host "`n[Test 9] TCP path: select-window -t ${SESSION}:$idThree via raw socket" -ForegroundColor Yellow
try {
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $authResp = $reader.ReadLine()
    if ($authResp -ne "OK") { throw "AUTH failed: $authResp" }
    $writer.Write("select-window -t ${SESSION}:$idThree`n"); $writer.Flush()
    Start-Sleep -Milliseconds 500
    $tcp.Close()
    $active = Get-ActiveWindow
    if ($active -match "three") { Write-Pass "TCP select-window with @id switched to 'three' (active: $active)" }
    else { Write-Fail "TCP path: active window is '$active', expected 'three'" }
} catch {
    Write-Fail "TCP path error: $_"
}

# === TEARDOWN ===
Cleanup

# ============================================================
# Win32 TUI VISUAL VERIFICATION
# ============================================================
Write-Host "`n" ("=" * 60)
Write-Host "Win32 TUI VISUAL VERIFICATION"
Write-Host ("=" * 60)

$SESSION_TUI = "issue497_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX new-window -t "${SESSION_TUI}:" -n tuiwin 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$tuiList = & $PSMUX list-windows -t $SESSION_TUI -F '#{window_id}|#{window_name}' 2>&1
$tuiId = $null
foreach ($line in $tuiList) {
    $p = "$line".Trim().Split('|')
    if ($p.Count -eq 2 -and $p[1] -eq "tuiwin") { $tuiId = $p[0] }
}

if ($tuiId) {
    & $PSMUX select-window -t "${SESSION_TUI}:0" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $out = & $PSMUX select-window -t "${SESSION_TUI}:$tuiId" 2>&1
    $ec = $LASTEXITCODE
    Start-Sleep -Milliseconds 800
    $active = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_name}' 2>&1 | Out-String).Trim()
    if ($ec -eq 0) { Write-Pass "TUI: select-window session:@id exit 0 on attached session" }
    else { Write-Fail "TUI: select-window session:@id exit=$ec output=$out" }
    if ($active -eq "tuiwin") { Write-Pass "TUI: attached window switched to 'tuiwin'" }
    else { Write-Fail "TUI: active window '$active', expected 'tuiwin'" }

    # Attached session still responsive after the id-target select
    $panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1 | Out-String).Trim()
    if ($panes -match '^\d+$') { Write-Pass "TUI: session still responsive (window_panes=$panes)" }
    else { Write-Fail "TUI: session unresponsive after id select" }
} else {
    Write-Fail "TUI: could not resolve window id for 'tuiwin' (list: $($tuiList -join ' / '))"
}

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
