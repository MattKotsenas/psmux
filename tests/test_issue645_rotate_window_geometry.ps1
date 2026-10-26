# Issue #645: rotate-window moved the panes between slots but left every pane
# at the size of the slot it had just LEFT.
#
# Reporter's recipe, measured on 3.3.8 (7f67a71):
#
#   psmux new-session -d -s q -x 200 -y 50 cmd.exe
#   psmux split-window -t q:0.0 -l 2 cmd.exe
#   psmux rotate-window -U -t q:0
#   psmux list-panes -t q:0 -F "#{pane_index} h=#{pane_height} top=#{pane_top} bot=#{pane_bottom}"
#
#   after split   0 h=47 top=0  bot=46
#                 1 h=2  top=48 bot=49
#   after rotate  0 h=2  top=0  bot=46      <-- the height stayed with the pane
#                 1 h=47 top=48 bot=49
#
#   psmux split-window -t q:0.0 -l 5 cmd.exe
#   psmux: split-window: pane too small to split vertically (2 rows, need 5)
#
# window_layout came back 1a2b,200x50,0,0[200x47,0,0,4,200x2,0,48,1], so the
# CELLS were right: pane_top/bottom/left/right and the layout read the tree,
# pane_height/pane_width read Pane::last_rows / last_cols, which only change
# when something resizes the PTY. Nothing did. `mode con` in the pane filling
# 47 rows still reported a 2 line console, and an attached client drew 20 lines
# of output into nowhere.
#
# tmux (cmd-rotate-window.c:90-103) re-points each pane at the next pane's
# layout cell and then resizes it to that cell:
#
#     wp->layout_cell = wp2->layout_cell;
#     wp->xoff = wp2->xoff; wp->yoff = wp2->yoff;
#     window_pane_resize(wp, wp2->sx, wp2->sy);
#
# The layout tree is never touched, so the window's shape is identical before
# and after and only the occupants move. Both halves are asserted here.
#
# Two more parity defects found in the same path and covered below:
#   * the server read the flag unnegated, so `-U` ran a `-D` rotation and bare
#     `rotate-window` rotated the wrong way (tmux tests for -D alone);
#   * rotating the ROOT SPLIT'S CHILDREN dragged whole subtrees into cells
#     sized for something else, so on a nested layout a 34/4/10 column came
#     back as 39/8/1.
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }

# Inherited routing would aim every call at whatever session owns this shell.
$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null

$S = "i645-" + [guid]::NewGuid().ToString('N').Substring(0, 8)

Write-Host "`n=== Issue #645: rotate-window pane geometry ===" -ForegroundColor Cyan
Write-Host "  binary: $PSMUX"

# NOTE: `-D` handed to a PowerShell ADVANCED function binds to -Debug and is
# silently dropped, which makes a -D test quietly measure -U. Everything below
# calls the binary directly for that reason.

function Kill-Rig { & $PSMUX kill-session -t $S 2>&1 | Out-Null }

function Wait-Session {
    for ($i = 0; $i -lt 24; $i++) {
        & $PSMUX has-session -t $S 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# One line per pane: "<index> <id> <h>x<w> @<top>,<left>". Slot geometry comes
# from the layout tree, h/w from the pane itself; #645 is the two disagreeing.
function Get-Panes {
    @(& $PSMUX list-panes -t "${S}:0" -F '#{pane_index} #{pane_id} #{pane_height}x#{pane_width} @#{pane_top},#{pane_left} b#{pane_bottom},#{pane_right}' 2>&1)
}
function Get-Ids { (@(& $PSMUX list-panes -t "${S}:0" -F '#{pane_id}' 2>&1) -join ',') }
function Get-Layout { ((& $PSMUX display-message -t "${S}:0" -p '#{window_layout}' 2>&1) | Out-String).Trim() }

# The invariant #645 broke: the pane in a slot must carry that slot's size.
# pane_bottom/pane_right are the slot's far edges, so the slot is
# (bottom-top+1) x (right-left+1) and pane_height/pane_width must match it.
function Test-GeometryAgrees($what) {
    $bad = @()
    foreach ($l in Get-Panes) {
        if ($l -match '^(\d+) (%\d+) (\d+)x(\d+) @(\d+),(\d+) b(\d+),(\d+)$') {
            $idx = $Matches[1]; $id = $Matches[2]
            $h = [int]$Matches[3]; $w = [int]$Matches[4]
            $top = [int]$Matches[5]; $left = [int]$Matches[6]
            $bot = [int]$Matches[7]; $right = [int]$Matches[8]
            $slotH = $bot - $top + 1
            $slotW = $right - $left + 1
            if ($h -ne $slotH -or $w -ne $slotW) {
                $bad += "pane $idx ($id) reports ${h}x${w} but its slot is ${slotH}x${slotW} (rows $top..$bot, cols $left..$right)"
            }
        } else {
            $bad += "unparsable list-panes line: '$l'"
        }
    }
    if ($bad.Count -eq 0) { Write-Pass "$what : every pane carries its own slot's size" }
    else { foreach ($b in $bad) { Write-Fail "$what : $b" } }
}

function Send-Tcp([string]$Cmd) {
    $port = (Get-Content "$psmuxDir\$S.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$S.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $tcp.NoDelay = $true
    $st = $tcp.GetStream(); $w = [System.IO.StreamWriter]::new($st); $r = [System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush()
    if ($r.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $w.Write("$Cmd`n"); $w.Flush(); $st.ReadTimeout = 10000
    try { $resp = $r.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close(); return $resp
}

# ── TEST 1: the reporter's exact recipe ───────────────────────────────────
Write-Head "Test 1: the reporter's recipe, 47/2 column, rotate -U"
Kill-Rig; Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $S -x 200 -y 50 cmd.exe 2>&1 | Out-Null
if (-not (Wait-Session)) { Write-Fail "session did not come up"; exit 1 }
Start-Sleep -Seconds 1
& $PSMUX split-window -t "${S}:0.0" -l 2 cmd.exe 2>&1 | Out-Null
Start-Sleep -Seconds 2
$before = Get-Panes
Write-Info ("after split: " + ($before -join ' | '))
Test-GeometryAgrees "after the split"
$startIds = (Get-Ids) -split ','
$idTall = $startIds[0]
$idShort = $startIds[1]

& $PSMUX rotate-window -U -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 900
$after = Get-Panes
Write-Info ("after rotate -U: " + ($after -join ' | '))
Test-GeometryAgrees "after rotate -U"
if ((Get-Ids) -eq "$idShort,$idTall") { Write-Pass "-U moved the second pane into the first slot (tmux first-pane-to-last-cell)" }
else { Write-Fail "-U put the wrong panes in the slots: $(Get-Ids), expected $idShort,$idTall" }
# The reporter's numbers, spelled out.
if ($after[0] -match '^0 \S+ 47x200 @0,0 b46,199$') { Write-Pass "pane 0 is h=47 top=0 bot=46 (was h=2 before the fix)" }
else { Write-Fail "pane 0 line is '$($after[0])', expected '0 <id> 47x200 @0,0 b46,199'" }
if ($after[1] -match '^1 \S+ 2x200 @48,0 b49,199$') { Write-Pass "pane 1 is h=2 top=48 bot=49" }
else { Write-Fail "pane 1 line is '$($after[1])', expected '1 <id> 2x200 @48,0 b49,199'" }

Write-Head "Test 2: the knock on effects the reporter hit"
$r = & $PSMUX split-window -t "${S}:0.0" -l 5 cmd.exe 2>&1
$rc = $LASTEXITCODE
$txt = (($r | Out-String) -replace '\s+', ' ').Trim()
if ($rc -eq 0 -and $txt -notmatch 'too small') { Write-Pass "split-window on the 47 row pane is accepted (rc=$rc)" }
else { Write-Fail "split-window still refused: rc=$rc out='$txt'" }
Kill-Rig; Start-Sleep -Milliseconds 500

# ── TEST 3: the child console really is resized ───────────────────────────
Write-Head "Test 3: the shell in the rotated pane gets the new console size"
& $PSMUX new-session -d -s $S -x 200 -y 50 cmd.exe 2>&1 | Out-Null
if (-not (Wait-Session)) { Write-Fail "session did not come up"; exit 1 }
Start-Sleep -Seconds 1
& $PSMUX split-window -t "${S}:0.0" -l 2 cmd.exe 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX rotate-window -U -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $PSMUX send-keys -t "${S}:0.0" "mode con" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3
$cap = @(& $PSMUX capture-pane -p -t "${S}:0.0" 2>&1)
$lines = ($cap | Where-Object { $_ -match 'Lines:\s*(\d+)' } | ForEach-Object { [int]([regex]::Match($_, 'Lines:\s*(\d+)').Groups[1].Value) })
if ($lines -and $lines[0] -eq 47) { Write-Pass "mode con in the pane filling 47 rows reports a 47 line console" }
else { Write-Fail "mode con reported '$lines' lines (before the fix the console stayed at 2 and the output scrolled away)" }
# capture-pane trims trailing blank rows, so the count is "what the shell has
# written", not the pane height. Before the fix the whole screen was 2 rows and
# `mode con`'s own 13 line answer could not fit in it.
if ($cap.Count -gt 2) { Write-Pass "capture-pane returns $($cap.Count) lines from the 47 row pane (it was capped at 2 before the fix)" }
else { Write-Fail "capture-pane returned only $($cap.Count) lines, so the pane's screen is still 2 rows" }
Kill-Rig; Start-Sleep -Milliseconds 500

# ── TEST 4: -D, and -U/-D are inverses ────────────────────────────────────
Write-Head "Test 4: three panes, -U and -D directions and their round trip"
& $PSMUX new-session -d -s $S -x 200 -y 50 cmd.exe 2>&1 | Out-Null
if (-not (Wait-Session)) { Write-Fail "session did not come up"; exit 1 }
Start-Sleep -Seconds 1
& $PSMUX split-window -t "${S}:0.0" -l 10 cmd.exe 2>&1 | Out-Null; Start-Sleep -Seconds 2
& $PSMUX split-window -t "${S}:0.0" -l 5 cmd.exe 2>&1 | Out-Null; Start-Sleep -Seconds 2
$start = Get-Ids
$startLayout = Get-Layout
$startPanes = Get-Panes
Write-Info "start ids: $start"
Write-Info "start layout: $startLayout"
Test-GeometryAgrees "three panes, after the splits"
$a = $start -split ','

& $PSMUX rotate-window -U -t "${S}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 900
$want = "$($a[1]),$($a[2]),$($a[0])"
if ((Get-Ids) -eq $want) { Write-Pass "-U rotates [A,B,C] to [B,C,A] (tmux cmd-rotate-window.c else branch)" }
else { Write-Fail "-U gave $(Get-Ids), tmux gives $want" }
Test-GeometryAgrees "three panes, after -U"

& $PSMUX rotate-window -D -t "${S}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 900
if ((Get-Ids) -eq $start) { Write-Pass "-D undoes -U" }
else { Write-Fail "-D after -U gave $(Get-Ids), expected the original $start" }

& $PSMUX rotate-window -D -t "${S}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 900
$want = "$($a[2]),$($a[0]),$($a[1])"
if ((Get-Ids) -eq $want) { Write-Pass "-D rotates [A,B,C] to [C,A,B] (tmux -D branch)" }
else { Write-Fail "-D gave $(Get-Ids), tmux gives $want" }
Test-GeometryAgrees "three panes, after -D"

# Back to the start, then check that bare rotate-window is -U, not -D.
& $PSMUX rotate-window -D -t "${S}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 700
& $PSMUX rotate-window -D -t "${S}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 700
if ((Get-Ids) -eq $start) {
    & $PSMUX rotate-window -t "${S}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 900
    $want = "$($a[1]),$($a[2]),$($a[0])"
    if ((Get-Ids) -eq $want) { Write-Pass "bare rotate-window is -U, matching tmux's default branch" }
    else { Write-Fail "bare rotate-window gave $(Get-Ids), tmux's default (-U) gives $want" }
} else {
    Write-Fail "three -D rotations of three panes did not return to $start (got $(Get-Ids))"
}

# ── TEST 5: a nested layout keeps its shape ───────────────────────────────
Write-Head "Test 5: the layout tree is untouched by a rotate"
# The rig above is V[ V[a,b], c ]: `split -l 10` then `split -l 5`.
# Rotating the root's children turned 34/4/10 into 39/8/1.
& $PSMUX rotate-window -D -t "${S}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 900
$backLayout = Get-Layout
if ((Get-Ids) -eq $start) { Write-Pass "the panes are back where they started" }
else { Write-Info "ids are $(Get-Ids) (start was $start)" }
if ($backLayout -eq $startLayout) { Write-Pass "window_layout is byte identical after a full -U/-D round trip" }
else { Write-Fail "window_layout drifted: '$backLayout' vs '$startLayout'" }
if ((Get-Panes) -join '|' -eq ($startPanes -join '|')) { Write-Pass "every pane's geometry is back to the starting numbers" }
else { Write-Fail "geometry drifted: $((Get-Panes) -join ' | ') vs $($startPanes -join ' | ')" }
# The cells themselves must not move even mid rotation.
$cellsBefore = (Get-Panes | ForEach-Object { ($_ -split ' ')[3..4] -join ' ' }) -join '|'
& $PSMUX rotate-window -U -t "${S}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 900
$cellsAfter = (Get-Panes | ForEach-Object { ($_ -split ' ')[3..4] -join ' ' }) -join '|'
if ($cellsBefore -eq $cellsAfter) { Write-Pass "the slots keep their positions and sizes across a rotate" }
else { Write-Fail "the slots moved: '$cellsBefore' -> '$cellsAfter'" }
Test-GeometryAgrees "nested layout, after -U"
Kill-Rig; Start-Sleep -Milliseconds 500

# ── TEST 6: horizontal split, so width is exercised too ───────────────────
Write-Head "Test 6: a horizontal row, where the defect lands on pane_width"
& $PSMUX new-session -d -s $S -x 200 -y 50 cmd.exe 2>&1 | Out-Null
if (-not (Wait-Session)) { Write-Fail "session did not come up"; exit 1 }
Start-Sleep -Seconds 1
& $PSMUX split-window -h -t "${S}:0.0" -l 20 cmd.exe 2>&1 | Out-Null
Start-Sleep -Seconds 2
Test-GeometryAgrees "horizontal row, after the split"
& $PSMUX rotate-window -U -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 900
$row = Get-Panes
Write-Info ("after rotate -U: " + ($row -join ' | '))
Test-GeometryAgrees "horizontal row, after -U"
if ($row[0] -match '^0 \S+ 50x179 @0,0 b49,178$') { Write-Pass "the pane in the wide slot reports w=179, not the 20 it had" }
else { Write-Fail "pane 0 line is '$($row[0])', expected '0 <id> 50x179 @0,0 b49,178'" }
Kill-Rig; Start-Sleep -Milliseconds 500

# ── TEST 7: TCP route ─────────────────────────────────────────────────────
Write-Head "Test 7: the same over the TCP server route"
& $PSMUX new-session -d -s $S -x 200 -y 50 cmd.exe 2>&1 | Out-Null
if (-not (Wait-Session)) { Write-Fail "session did not come up"; exit 1 }
Start-Sleep -Seconds 1
& $PSMUX split-window -t "${S}:0.0" -l 2 cmd.exe 2>&1 | Out-Null
Start-Sleep -Seconds 2
$ids = (Get-Ids) -split ','
$resp = Send-Tcp "rotate-window -U"
Start-Sleep -Milliseconds 900
Write-Info "TCP response: '$resp'"
Test-GeometryAgrees "TCP rotate-window -U"
if ((Get-Ids) -eq "$($ids[1]),$($ids[0])") { Write-Pass "TCP rotate-window -U moved the panes" }
else { Write-Fail "TCP rotate-window -U left ids as $(Get-Ids)" }
Kill-Rig; Start-Sleep -Milliseconds 500

# ── TEST 8: zoomed window ─────────────────────────────────────────────────
Write-Head "Test 8: rotating a zoomed window"
& $PSMUX new-session -d -s $S -x 200 -y 50 cmd.exe 2>&1 | Out-Null
if (-not (Wait-Session)) { Write-Fail "session did not come up"; exit 1 }
Start-Sleep -Seconds 1
& $PSMUX split-window -t "${S}:0.0" -l 2 cmd.exe 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX select-pane -t "${S}:0.0" 2>&1 | Out-Null
& $PSMUX resize-pane -Z -t "${S}:0.0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 900
$zoomed = ((& $PSMUX display-message -t "${S}:0" -p '#{window_zoomed_flag}' 2>&1) | Out-String).Trim()
Write-Info "window_zoomed_flag=$zoomed"
$r = & $PSMUX rotate-window -U -t "${S}:0" 2>&1
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds 900
if ($rc -eq 0) { Write-Pass "rotate-window on a zoomed window exits 0 (rc=$rc)" }
else { Write-Fail "rotate-window on a zoomed window failed: rc=$rc out='$((($r|Out-String)-replace '\s+',' ').Trim())'" }
& $PSMUX resize-pane -Z -t "${S}:0.0" 2>&1 | Out-Null
Start-Sleep -Seconds 1
Test-GeometryAgrees "after unzooming a rotated window"
Kill-Rig; Start-Sleep -Milliseconds 500

# ── TEST 9: single pane is a no-op ────────────────────────────────────────
Write-Head "Test 9: a one pane window"
& $PSMUX new-session -d -s $S -x 200 -y 50 cmd.exe 2>&1 | Out-Null
if (-not (Wait-Session)) { Write-Fail "session did not come up"; exit 1 }
Start-Sleep -Seconds 2
$one = Get-Panes
$r = & $PSMUX rotate-window -U -t "${S}:0" 2>&1
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds 700
$r2 = & $PSMUX rotate-window -D -t "${S}:0" 2>&1
Start-Sleep -Milliseconds 700
if ($rc -eq 0) { Write-Pass "rotate-window on a single pane exits 0" }
else { Write-Fail "rotate-window on a single pane gave rc=$rc" }
if ((Get-Panes) -join '|' -eq ($one -join '|')) { Write-Pass "a single pane window is unchanged by -U and -D" }
else { Write-Fail "single pane changed: $((Get-Panes) -join ' | ') vs $($one -join ' | ')" }
Kill-Rig; Start-Sleep -Milliseconds 500

# ── Win32 TUI VISUAL VERIFICATION ─────────────────────────────────────────
Write-Host ("`n" + ("=" * 62)) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 62) -ForegroundColor Cyan
# The reporter's real complaint is visual: "a pane reporting 2 rows covers 47
# rows of screen". capture-pane cannot see that, so attach a REAL client, fill
# the pane that landed in the big slot with numbered lines, and read the
# client's own console back with tests/conread.cs.
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$conread = "$env:TEMP\psmux_i645_conread.exe"
$src = Join-Path $PSScriptRoot "conread.cs"
if ((Test-Path $csc) -and (-not (Test-Path $conread) -or ((Get-Item $src).LastWriteTime -gt (Get-Item $conread).LastWriteTime))) {
    & $csc /nologo /optimize /out:$conread $src 2>&1 | Out-Null
}
if (-not (Test-Path $conread)) {
    Write-Info "conread could not be built; skipping the visual section"
} else {
    & $PSMUX new-session -d -s $S cmd.exe 2>&1 | Out-Null
    if (-not (Wait-Session)) { Write-Fail "TUI: session did not come up" }
    Start-Sleep -Seconds 1
    & $PSMUX split-window -t "${S}:0.0" -l 2 cmd.exe 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $proc = Start-Process -FilePath $PSMUX -ArgumentList @("attach", "-t", $S) -PassThru
    Write-Info "client pid $($proc.Id)"
    Start-Sleep -Seconds 5
    & $PSMUX rotate-window -U -t "${S}:0" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    Test-GeometryAgrees "TUI: after rotate on a live attached window"
    & $PSMUX send-keys -t "${S}:0.0" "for /L %i in (1,1,20) do @echo ZZZ%i" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $screen = @((& $conread $proc.Id 2>&1 | Out-String) -split "`r?`n")
    $hit = @($screen | Where-Object { $_ -match 'ZZZ\d' })
    Write-Info "rows of the client screen carrying ZZZ output: $($hit.Count)"
    if ($hit.Count -ge 15) {
        Write-Pass "the client draws $($hit.Count) lines from the pane in the big slot (before the fix: 0, its console was 2 rows)"
    } else {
        Write-Fail "the client drew only $($hit.Count) ZZZ lines; the pane in the big slot is still small"
    }
    & $PSMUX send-keys -t "${S}:0.0" "mode con" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $cap = @(& $PSMUX capture-pane -p -t "${S}:0.0" 2>&1)
    $m = ($cap | Where-Object { $_ -match 'Lines:\s*\d+' } | Select-Object -First 1)
    $slotH = 0
    foreach ($l in Get-Panes) { if ($l -match '^0 \S+ (\d+)x') { $slotH = [int]$Matches[1] } }
    if ($m -and [int]([regex]::Match($m, 'Lines:\s*(\d+)').Groups[1].Value) -eq $slotH) {
        Write-Pass "TUI: the child console is $slotH lines, matching the slot it now fills"
    } else {
        Write-Fail "TUI: child console line count '$m' does not match the slot height $slotH"
    }
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 900
    if (-not (Get-Process -Id $proc.Id -EA SilentlyContinue)) { Write-Pass "TUI: client process $($proc.Id) closed" }
    else { Write-Fail "TUI: client process $($proc.Id) is still running" }
    Kill-Rig
}

Kill-Rig
Start-Sleep -Milliseconds 400

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
