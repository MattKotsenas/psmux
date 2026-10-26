# Issue #592: select-pane -t %id -T <title> must be title-only (tmux parity).
# tmux's cmd-select-pane.c sets the title and returns BEFORE any activation;
# psmux used to classify select-pane as a focus command unconditionally, so a
# -T call with a -t target permanently dragged the client to the target's
# window and changed active panes. The fix routes select-pane -T/-P through
# the validated temp-focus path (title lands on the target, focus restores).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SOCK = "i592"
$SESSION = "t592"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

$emptyConf = "$env:TEMP\psmux_592_empty.conf"
"" | Set-Content -Path $emptyConf -Encoding UTF8

function Cleanup {
    & $PSMUX -L $SOCK kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\${SOCK}__*" -Force -EA SilentlyContinue
}

function Fresh-Session {
    Cleanup
    & $PSMUX -L $SOCK -f $emptyConf new-session -d -s $SESSION -n w0 -x 100 -y 30 | Out-Null
    Start-Sleep -Seconds 3
    & $PSMUX -L $SOCK new-window -d -n w1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $PSMUX -L $SOCK select-window -t :1 | Out-Null
    Start-Sleep -Milliseconds 400
}

function Get-WinIndex { (& $PSMUX -L $SOCK display-message -p '#{window_index}' 2>&1 | Out-String).Trim() }
function Get-ActivePane { (& $PSMUX -L $SOCK display-message -p '#{pane_id}' 2>&1 | Out-String).Trim() }
function Get-PaneRow($id) {
    (& $PSMUX -L $SOCK list-panes -a -F '#{window_index} #{pane_id} #{pane_active} [#{pane_title}]' 2>&1 |
        Out-String).Trim() -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($id) } | Select-Object -First 1
}

Write-Host "`n=== Issue #592 Tests: select-pane -T is title-only ===" -ForegroundColor Cyan

# === TEST 1: exact issue recipe - title a pane in another window ===
Write-Host "`n[Test 1] -t %1 -T from window 1 must not change active window" -ForegroundColor Yellow
Fresh-Session
$before = Get-WinIndex
& $PSMUX -L $SOCK select-pane -t '%1' -T "PROBE-TITLE" 2>&1 | Out-Null
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds 400
$after = Get-WinIndex
$row = Get-PaneRow '%1'
if ($rc -eq 0) { Write-Pass "exit code 0" } else { Write-Fail "exit code $rc" }
if ($before -eq "1" -and $after -eq "1") { Write-Pass "active window stayed 1 (was $before, now $after)" }
else { Write-Fail "active window moved: before=$before after=$after" }
if ($row -match '\[PROBE-TITLE\]') { Write-Pass "title applied to %1: $row" }
else { Write-Fail "title not applied to %1: $row" }

# === TEST 2: target non-active pane of the ACTIVE window - active pane must not change ===
Write-Host "`n[Test 2] -t <same-window non-active pane> -T keeps active pane" -ForegroundColor Yellow
& $PSMUX -L $SOCK split-window -d -t $SESSION | Out-Null
Start-Sleep -Seconds 1
$activeBefore = Get-ActivePane
$allPanes = (& $PSMUX -L $SOCK list-panes -F '#{pane_id} #{pane_active}' 2>&1 | Out-String).Trim() -split "`r?`n"
$otherPane = ($allPanes | Where-Object { $_ -match ' 0$' } | Select-Object -First 1) -replace ' 0$',''
if ($otherPane) {
    & $PSMUX -L $SOCK select-pane -t $otherPane -T "TITLE-B" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $activeAfter = Get-ActivePane
    $row = Get-PaneRow $otherPane
    if ($activeBefore -eq $activeAfter) { Write-Pass "active pane unchanged ($activeBefore)" }
    else { Write-Fail "active pane moved: $activeBefore -> $activeAfter" }
    if ($row -match '\[TITLE-B\]') { Write-Pass "title applied to $otherPane" }
    else { Write-Fail "title not applied: $row" }
} else { Write-Fail "could not find a non-active pane to target" }

# === TEST 3: -T with NO -t titles the active pane, no move ===
Write-Host "`n[Test 3] -T without -t titles active pane in place" -ForegroundColor Yellow
$winBefore = Get-WinIndex
$activeBefore = Get-ActivePane
& $PSMUX -L $SOCK select-pane -T "TITLE-SELF" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$winAfter = Get-WinIndex
$activeAfter = Get-ActivePane
$row = Get-PaneRow $activeBefore
if ($winBefore -eq $winAfter -and $activeBefore -eq $activeAfter) { Write-Pass "no focus change" }
else { Write-Fail "focus changed: win $winBefore->$winAfter pane $activeBefore->$activeAfter" }
if ($row -match '\[TITLE-SELF\]') { Write-Pass "active pane titled" }
else { Write-Fail "active pane not titled: $row" }

# === TEST 4: bad target exits 1 with can't find pane, zero side effects ===
Write-Host "`n[Test 4] -t %99 -T errors like tmux (exit 1, no state change)" -ForegroundColor Yellow
$winBefore = Get-WinIndex
$err = & $PSMUX -L $SOCK select-pane -t '%99' -T "NOPE" 2>&1 | Out-String
$rc = $LASTEXITCODE
$winAfter = Get-WinIndex
if ($rc -ne 0) { Write-Pass "non-zero exit ($rc)" } else { Write-Fail "expected non-zero exit, got 0" }
if ($err -match "can't find pane") { Write-Pass "error message: $($err.Trim())" }
else { Write-Fail "unexpected error output: $($err.Trim())" }
if ($winBefore -eq $winAfter) { Write-Pass "active window untouched" }
else { Write-Fail "active window changed on error: $winBefore -> $winAfter" }

# === TEST 5: control - plain select-pane -t (no -T) sets the ACTIVE PANE ===
#
# Changed by issue #693 item 3.  This used to assert that `select-pane -t %1`
# from window 1 SWITCHED the session to window 0, because that is what psmux
# did.  tmux does not: cmd-select-pane.c:274 calls
# `window_set_active_pane(w, wp, 1)` on the TARGET window (`w` is
# `target->wl->window`) and the file never calls `session_select`, so the
# session's current window stays where it is.  A bare `%id` is CMD_FIND_PANE
# and names its own window, so it obeys the same rule.  `select-window` is
# the command that changes windows.
#
# The regression this test guards is still guarded: a plain `-t` (no -T/-P)
# must MOVE the pane, which is what separates it from the #592 attribute only
# forms below.
Write-Host "`n[Test 5] plain select-pane -t %1 sets window 0's active pane and stays on window 1" -ForegroundColor Yellow
& $PSMUX -L $SOCK select-window -t :1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX -L $SOCK select-pane -t '%2' 2>&1 | Out-Null   # park window 0 on %2
Start-Sleep -Milliseconds 300
$winBefore = Get-WinIndex
& $PSMUX -L $SOCK select-pane -t '%1' 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$winAfter = Get-WinIndex
$w0active = (& $PSMUX -L $SOCK list-panes -t ":0" -F '#{pane_id}#{?pane_active,*,}' 2>&1 | Where-Object { $_ -match '\*$' }) -replace '\*$',''
if ($winBefore -eq "1" -and $winAfter -eq "1" -and $w0active -eq '%1') {
    Write-Pass "plain -t moved window 0's active pane to %1 and left the session on window $winAfter (cmd-select-pane.c:274)"
} else { Write-Fail "plain -t: win $winBefore->$winAfter (want 1->1), window 0 active pane $w0active (want %1)" }

# === TEST 6: -P style with -t does not move focus ===
Write-Host "`n[Test 6] -t %2 -P style does not move focus" -ForegroundColor Yellow
& $PSMUX -L $SOCK select-window -t :1 | Out-Null
Start-Sleep -Milliseconds 300
$winBefore = Get-WinIndex
& $PSMUX -L $SOCK select-pane -t '%2' -P 'bg=default,fg=blue' 2>&1 | Out-Null
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds 400
$winAfter = Get-WinIndex
if ($rc -eq 0 -and $winBefore -eq $winAfter) { Write-Pass "no focus move on -P (win stays $winAfter)" }
else { Write-Fail "-P moved focus or failed: rc=$rc win $winBefore->$winAfter" }

# === TEST 7: -T "" clears the title lock without focus move ===
Write-Host "`n[Test 7] -t %1 -T `"`" clears title without focus move" -ForegroundColor Yellow
$winBefore = Get-WinIndex
& $PSMUX -L $SOCK select-pane -t '%1' -T "" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$winAfter = Get-WinIndex
$row = Get-PaneRow '%1'
if ($winBefore -eq $winAfter) { Write-Pass "no focus move on empty -T" }
else { Write-Fail "empty -T moved focus: $winBefore -> $winAfter" }
if ($row -notmatch '\[PROBE-TITLE\]') { Write-Pass "PROBE-TITLE cleared: $row" }
else { Write-Fail "title not cleared: $row" }

# === TEST 8: TCP one-shot path (raw socket) ===
Write-Host "`n[Test 8] raw TCP select-pane -t %1 -T does not move focus" -ForegroundColor Yellow
& $PSMUX -L $SOCK select-window -t :1 | Out-Null
Start-Sleep -Milliseconds 300
$portFile = Get-ChildItem "$psmuxDir\${SOCK}__${SESSION}.port" -EA SilentlyContinue
if ($portFile) {
    $port = (Get-Content $portFile.FullName -Raw).Trim()
    $key = (Get-Content ($portFile.FullName -replace '\.port$','.key') -Raw).Trim()
    $winBefore = Get-WinIndex
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("select-pane -t %1 -T WIRE-TITLE`n"); $writer.Flush()
    Start-Sleep -Milliseconds 600
    $tcp.Close()
    $winAfter = Get-WinIndex
    $row = Get-PaneRow '%1'
    if ($winBefore -eq $winAfter) { Write-Pass "TCP path: no focus move (win stays $winAfter)" }
    else { Write-Fail "TCP path moved focus: $winBefore -> $winAfter" }
    if ($row -match '\[WIRE-TITLE\]') { Write-Pass "TCP path: title applied" }
    else { Write-Fail "TCP path: title not applied: $row" }
} else { Write-Fail "port file not found for TCP test" }

# ============================================================
# Win32 TUI VISUAL VERIFICATION (attached client)
# ============================================================
Write-Host "`n=== Win32 TUI verification ===" -ForegroundColor Cyan
# Kill the E2E session first: with two sessions on the namespace an
# unqualified %id target is ambiguous and can route to the other server.
Cleanup
$TUISESS = "t592tui"
& $PSMUX -L $SOCK kill-session -t $TUISESS 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$SOCK,"-f",$emptyConf,"new-session","-s",$TUISESS -PassThru
Start-Sleep -Seconds 4
& $PSMUX -L $SOCK new-window -d -t $TUISESS | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX -L $SOCK select-window -t "${TUISESS}:1" | Out-Null
Start-Sleep -Milliseconds 500
$winBefore = (& $PSMUX -L $SOCK display-message -t $TUISESS -p '#{window_index}' 2>&1 | Out-String).Trim()
& $PSMUX -L $SOCK select-pane -t '%1' -T "TUI-PROBE" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$winAfter = (& $PSMUX -L $SOCK display-message -t $TUISESS -p '#{window_index}' 2>&1 | Out-String).Trim()
$row = (& $PSMUX -L $SOCK list-panes -a -t $TUISESS -F '#{pane_id} [#{pane_title}]' 2>&1 | Out-String).Trim() -split "`r?`n" |
    Where-Object { $_ -match '%1 ' } | Select-Object -First 1
if ($winBefore -eq "1" -and $winAfter -eq "1") { Write-Pass "TUI: attached client stayed on window 1" }
else { Write-Fail "TUI: attached client moved: $winBefore -> $winAfter" }
if ($row -match '\[TUI-PROBE\]') { Write-Pass "TUI: title applied while attached" }
else { Write-Fail "TUI: title not applied: $row" }
& $PSMUX -L $SOCK kill-session -t $TUISESS 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Cleanup
Remove-Item $emptyConf -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
