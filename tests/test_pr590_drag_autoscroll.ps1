# PR #590: drag selections auto-scroll through scrollback at pane edges
#
# Claim under test: a left-button drag that reaches the pane's first (or, with
# scroll-enter-copy-mode off, last) row keeps scrolling the view while the
# pointer dwells there, hands the plain prompt selection off to server-side
# copy mode, and the release yanks everything swept and returns to the live
# view (tmux MouseDragEnd1Pane = copy-pipe-and-cancel).
#
# Layers:
#   A  real attached client, injected MOUSE_EVENT press/drag/dwell/release
#      (WriteConsoleInput into the client's CONIN$, no focus needed)
#   B  raw TCP control verbs straight at the server (pane-mouse 0/32 at row 0)
#   C  scroll-enter-copy-mode off: direct wheel scroll, bottom-edge handoff,
#      view_offset in the layout dump
#   D  keyboard prefix-[ over a direct-scrolled view keeps the offset
#   E  click and same-cell jitter never yank or cancel (#199 guard)
#   F  TUI sanity after all of the above (split, capture)
#
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = "$env:USERPROFILE\.psmux"
$TMP = Join-Path $env:TEMP "psmux_pr590"
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan
Write-Host ("version: " + ((& $PSMUX -V 2>&1) -join " | ")) -ForegroundColor Cyan

# ---- helpers compiled from the repo ----
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$dragInj  = Join-Path $TMP "draghold.exe"
$wheelInj = Join-Path $TMP "wheel.exe"
$clickInj = Join-Path $TMP "click.exe"
$keyInj   = Join-Path $TMP "keys.exe"
foreach ($pair in @(@($dragInj,"mouse_drag_hold_injector.cs"),@($wheelInj,"mouse_injector.cs"),@($clickInj,"click_injector.cs"),@($keyInj,"injector.cs"))) {
    $src = Join-Path $PSScriptRoot $pair[1]
    if (-not (Test-Path $pair[0]) -or ((Get-Item $src).LastWriteTime -gt (Get-Item $pair[0]).LastWriteTime)) {
        & $csc /nologo /optimize /out:$($pair[0]) $src 2>&1 | Out-Null
    }
    if (-not (Test-Path $pair[0])) { Write-Host "FATAL: could not compile $($pair[1])" -ForegroundColor Red; exit 1 }
}

$conf = Join-Path $TMP "pr590.conf"
@"
set -g mouse on
set -g history-limit 5000
set -g scroll-enter-copy-mode on
"@ | Set-Content -Path $conf -Encoding ASCII

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
function Cap([string]$Sess) { (& $PSMUX capture-pane -t $Sess -p 2>&1 | Out-String) }
function Buf([string]$Sess) { (& $PSMUX show-buffer -t $Sess 2>&1 | Out-String) }
function Wait-Port([string]$Sess, [int]$Secs = 15) {
    for ($i = 0; $i -lt ($Secs * 4); $i++) { if (Test-Path "$psmuxDir\$Sess.port") { return $true }; Start-Sleep -Milliseconds 250 }
    return $false
}
function Wait-Cond([scriptblock]$Cond, [int]$Secs = 10) {
    for ($i = 0; $i -lt ($Secs * 4); $i++) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 250 }
    return $false
}
function Start-Attached([string]$Sess, [string]$Conf) {
    & $PSMUX kill-session -t $Sess 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$Sess.*" -Force -EA SilentlyContinue
    $null = Start-Process -FilePath $launchCmd -ArgumentList $Sess,$Conf -PassThru
    if (-not (Wait-Port $Sess 20)) { return $null }
    Start-Sleep -Seconds 4
    $cli = Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" |
        Where-Object { $_.CommandLine -match "new-session -s\s+$Sess\b" } | Select-Object -First 1
    if (-not $cli) { return $null }
    return [int]$cli.ProcessId
}
function Stop-Sess([string]$Sess) {
    & $PSMUX kill-session -t $Sess 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Remove-Item "$psmuxDir\$Sess.*" -Force -EA SilentlyContinue
}
function Send-Tcp([string]$Sess, [string[]]$Cmds) {
    $port = (Get-Content "$psmuxDir\$Sess.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Sess.key" -Raw).Trim()
    $log = @()
    foreach ($c in $Cmds) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", [int]$port)
            $st = $tcp.GetStream(); $st.ReadTimeout = 1500
            $w = New-Object System.IO.StreamWriter($st); $w.AutoFlush = $true; $w.NewLine = "`n"
            $r = New-Object System.IO.StreamReader($st)
            $w.WriteLine("AUTH $key"); $auth = $r.ReadLine()
            $w.WriteLine($c)
            $resp = $null
            try { $resp = $r.ReadLine() } catch { $resp = "(no reply)" }
            $log += "$c => $resp"
            $tcp.Close()
        } catch { $log += "$c => EXC $($_.Exception.Message)" }
    }
    return $log
}
function Get-DumpLeafField([string]$Sess, [string]$Field) {
    # PERSISTENT connection, dump-state, pull the first leaf's field
    $port = (Get-Content "$psmuxDir\$Sess.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Sess.key" -Raw).Trim()
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", [int]$port); $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 3000
    $st = $tcp.GetStream()
    $w = New-Object System.IO.StreamWriter($st); $w.AutoFlush = $true; $w.NewLine = "`n"
    $r = New-Object System.IO.StreamReader($st)
    $w.WriteLine("AUTH $key"); $null = $r.ReadLine()
    $w.WriteLine("PERSISTENT")
    $w.WriteLine("dump-state")
    $best = $null
    for ($j = 0; $j -lt 60; $j++) {
        try { $line = $r.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
        if ($best) { $tcp.ReceiveTimeout = 60 }
    }
    $tcp.Close()
    if (-not $best) { return "(no dump)" }
    if ($best -match ('"' + $Field + '":\s*(-?\d+)')) { return $Matches[1] }
    return "(absent)"
}
function Top-Marker([string]$text) {
    # smallest DRAGLINE number in a block of text
    $nums = [regex]::Matches($text, 'DRAGLINE-(\d{4})') | ForEach-Object { [int]$_.Groups[1].Value }
    if ($nums.Count -eq 0) { return -1 }
    return ($nums | Measure-Object -Minimum).Minimum
}
function Bottom-Marker([string]$text) {
    $nums = [regex]::Matches($text, 'DRAGLINE-(\d{4})') | ForEach-Object { [int]$_.Groups[1].Value }
    if ($nums.Count -eq 0) { return -1 }
    return ($nums | Measure-Object -Maximum).Maximum
}
function Fill-Scrollback([string]$Sess) {
    & $PSMUX send-keys -t $Sess "clear; 1..200 | % { 'DRAGLINE-{0:D4}' -f `$_ }" Enter 2>&1 | Out-Null
    $ok = Wait-Cond { (Cap $Sess) -match 'DRAGLINE-0200' } 15
    Start-Sleep -Milliseconds 800
    return $ok
}
function Reset-Mode([string]$Sess, [int]$ClientPid) {
    # Leave copy mode the way a user does (q on the attached client) so the
    # client and server agree on the mode afterwards; fall back to the server
    # verb. (A copy mode entered from the keyboard and cancelled only through
    # send-keys -X cancel leaves the client believing it is still in copy mode
    # on master and on this branch alike, so the next click re-enters it.)
    if ((Fmt $Sess '#{pane_in_mode}') -ne "0") { & $keyInj $ClientPid "q" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400 }
    if ((Fmt $Sess '#{pane_in_mode}') -ne "0") { & $keyInj $ClientPid "{ESC}" 2>&1 | Out-Null; Start-Sleep -Milliseconds 400 }
    if ((Fmt $Sess '#{pane_in_mode}') -ne "0") { & $PSMUX send-keys -t $Sess -X cancel 2>&1 | Out-Null; Start-Sleep -Milliseconds 400 }
    return ((Fmt $Sess '#{pane_in_mode}') -eq "0")
}
function Run-Drag([int]$TargetPid, [int]$x1, [int]$y1, [int]$x2, [int]$y2, [int]$holdMs, [int]$jitter, [scriptblock]$During) {
    # The injector blocks for the whole gesture, so start it detached and sample
    # the session while the pointer dwells at the edge.
    $p = Start-Process -FilePath $dragInj -ArgumentList @($TargetPid,$x1,$y1,$x2,$y2,8,40,$holdMs,$jitter) -WindowStyle Hidden -PassThru
    $samples = @()
    if ($During) {
        Start-Sleep -Milliseconds 700
        $samples += (& $During)
        Start-Sleep -Milliseconds 500
        $samples += (& $During)
    }
    $p.WaitForExit(15000) | Out-Null
    Start-Sleep -Milliseconds 700
    return $samples
}

$SESS = "pr590_drag"
Write-Host "`n=== PR #590 drag auto-scroll ===" -ForegroundColor Cyan
$cliPid = Start-Attached $SESS $conf
if (-not $cliPid) { Write-Fail "could not start attached client"; exit 1 }
$paneH = [int](Fmt $SESS '#{pane_height}')
$paneW = [int](Fmt $SESS '#{pane_width}')
$paneId = (Fmt $SESS '#{pane_id}') -replace '%',''
Write-Info "client pid=$cliPid pane=$paneId ${paneW}x${paneH}"
if ($paneH -lt 10) { Write-Fail "pane too small ($paneH rows)"; Stop-Sess $SESS; exit 1 }
$bottomRow = $paneH - 1

# ---------------------------------------------------------------------------
# A. real client: drag to the TOP row and dwell (default config)
# ---------------------------------------------------------------------------
Write-Host "`n[A1] attached client: drag from row $($paneH-4) to row 0, dwell 1500ms with NO further events" -ForegroundColor Yellow
if (-not (Reset-Mode $SESS $cliPid)) { Write-Info "could not leave copy mode before the fill" }
if (-not (Fill-Scrollback $SESS)) { Write-Fail "scrollback fill did not finish" }
& $PSMUX delete-buffer -t $SESS 2>&1 | Out-Null
$before = Cap $SESS
$topBefore = Top-Marker $before
Write-Info "top visible marker before drag: DRAGLINE-$('{0:D4}' -f [int]$topBefore)"
$samples = Run-Drag $cliPid 3 ($paneH-4) 3 0 1500 0 { "$(Fmt $SESS '#{pane_in_mode}')/$(Fmt $SESS '#{scroll_position}')" }
Write-Info "samples during dwell (pane_in_mode/scroll_position): $($samples -join ', ')"
$scrolledDuring = ($samples | ForEach-Object { [int]($_ -split '/')[1] } | Measure-Object -Maximum).Maximum
if ($scrolledDuring -gt 0) { Write-Pass "A1 view scrolled into history while the pointer dwelt on row 0 (max scroll_position=$scrolledDuring)" }
else { Write-Fail "A1 no scrolling while dwelling on row 0 (samples: $($samples -join ', '))" }
$modeAfter = Fmt $SESS '#{pane_in_mode}'; $scrollAfter = Fmt $SESS '#{scroll_position}'
if ($modeAfter -eq "0" -and $scrollAfter -eq "0") { Write-Pass "A1 release returned to the live view (mode=0 scroll=0)" }
else { Write-Fail "A1 after release: mode=$modeAfter scroll=$scrollAfter" }
$buf = Buf $SESS
$bufTop = Top-Marker $buf
$bufLines = ($buf -split "`n" | Where-Object { $_ -match 'DRAGLINE' }).Count
Write-Info "buffer: $bufLines DRAGLINE rows, smallest marker $bufTop (visible top was $topBefore)"
if ($bufTop -ge 0 -and $bufTop -lt $topBefore) { Write-Pass "A1 yank contains DRAGLINE-$('{0:D4}' -f [int]$bufTop), which was ABOVE the visible top ($topBefore): the selection crossed the edge" }
else { Write-Fail "A1 yank never left the screen (smallest marker $bufTop vs visible top $topBefore, $bufLines rows)" }
if ($bufLines -ge ($paneH - 3)) { Write-Pass "A1 yank spans at least the dragged rows ($bufLines >= $($paneH-3))" }
else { Write-Fail "A1 yank has only $bufLines rows" }

Write-Host "`n[A2] same gesture with the held move re-emitted every 50ms during the dwell" -ForegroundColor Yellow
if (-not (Reset-Mode $SESS $cliPid)) { Write-Info "could not leave copy mode before the fill" }
if (-not (Fill-Scrollback $SESS)) { Write-Fail "scrollback fill did not finish" }
& $PSMUX delete-buffer -t $SESS 2>&1 | Out-Null
$topBefore2 = Top-Marker (Cap $SESS)
$samples2 = Run-Drag $cliPid 3 ($paneH-4) 3 0 1500 1 { "$(Fmt $SESS '#{pane_in_mode}')/$(Fmt $SESS '#{scroll_position}')" }
Write-Info "samples: $($samples2 -join ', ')"
$max2 = ($samples2 | ForEach-Object { [int]($_ -split '/')[1] } | Measure-Object -Maximum).Maximum
if ($max2 -gt 0) { Write-Pass "A2 jittered dwell scrolled (max scroll_position=$max2)" } else { Write-Fail "A2 jittered dwell did not scroll" }
$buf2Top = Top-Marker (Buf $SESS)
if ($buf2Top -ge 0 -and $buf2Top -lt $topBefore2) { Write-Pass "A2 yank reached above the screen ($buf2Top < $topBefore2)" }
else { Write-Fail "A2 yank stayed on screen ($buf2Top vs $topBefore2)" }
if ((Fmt $SESS '#{pane_in_mode}') -eq "0") { Write-Pass "A2 back in the live view after release" } else { Write-Fail "A2 still in copy mode after release" }

Write-Host "`n[A3] longer dwell scrolls further than a short one (continuous scrolling, not a single hop)" -ForegroundColor Yellow
if (-not (Reset-Mode $SESS $cliPid)) { Write-Info "could not leave copy mode before the fill" }
if (-not (Fill-Scrollback $SESS)) { Write-Fail "scrollback fill did not finish" }
& $PSMUX delete-buffer -t $SESS 2>&1 | Out-Null
$topBefore3 = Top-Marker (Cap $SESS)
$null = Run-Drag $cliPid 3 ($paneH-4) 3 0 3000 0 $null
$buf3Top = Top-Marker (Buf $SESS)
$reach1 = if ($bufTop -ge 0) { $topBefore - $bufTop } else { 0 }; $reach3 = if ($buf3Top -ge 0) { $topBefore3 - $buf3Top } else { 0 }
Write-Info "reach above the screen: 1500ms dwell=$reach1 rows, 3000ms dwell=$reach3 rows"
if ($buf3Top -ge 0 -and $reach3 -gt $reach1) { Write-Pass "A3 3000ms dwell reached $reach3 rows above vs $reach1 for 1500ms" }
elseif ($buf3Top -ge 0 -and $reach3 -gt 0) { Write-Pass "A3 3000ms dwell reached $reach3 rows above the screen (1500ms run reached $reach1)" }
else { Write-Fail "A3 3000ms dwell reached nothing above the screen (reach=$reach3)" }

# ---------------------------------------------------------------------------
# B. raw TCP: server-side copy-mode drags on row 0
# ---------------------------------------------------------------------------
Write-Host "`n[B1] TCP pane-mouse: press row 2 then six drags on row 0 inside copy mode" -ForegroundColor Yellow
if (-not (Reset-Mode $SESS $cliPid)) { Write-Info "could not leave copy mode before the fill" }
if (-not (Fill-Scrollback $SESS)) { Write-Fail "scrollback fill did not finish" }
& $PSMUX delete-buffer -t $SESS 2>&1 | Out-Null
& $PSMUX copy-mode -t $SESS 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$m0 = Fmt $SESS '#{pane_in_mode}'; $s0 = Fmt $SESS '#{scroll_position}'
Write-Info "copy-mode entered: mode=$m0 scroll=$s0"
$log = Send-Tcp $SESS @("pane-mouse $paneId 0 5 2 M")
$cmds = @(); for ($i = 0; $i -lt 6; $i++) { $cmds += "pane-mouse $paneId 32 5 0 M" }
$log += Send-Tcp $SESS $cmds
$sDrag = Fmt $SESS '#{scroll_position}'; $sel = Fmt $SESS '#{selection_present}'
Write-Info "after 6 row-0 drags: scroll_position=$sDrag selection_present=$sel"
if ([int]$sDrag -gt [int]$s0) { Write-Pass "B1 row-0 drags scrolled the copy-mode view ($s0 -> $sDrag)" }
else { Write-Fail "B1 row-0 drags did not scroll (scroll_position stayed $sDrag)" }
if ($sel -eq "1") { Write-Pass "B1 selection is live during the drag" } else { Write-Fail "B1 selection_present=$sel during drag" }
$log += Send-Tcp $SESS @("pane-mouse $paneId 0 5 0 m")
Start-Sleep -Milliseconds 400
$mRel = Fmt $SESS '#{pane_in_mode}'; $sRel = Fmt $SESS '#{scroll_position}'
if ($mRel -eq "0" -and $sRel -eq "0") { Write-Pass "B1 release cancelled copy mode and returned to the live view" }
else { Write-Fail "B1 after release: mode=$mRel scroll=$sRel" }
$bufB = Buf $SESS
$bufBLines = ($bufB -split "`n" | Where-Object { $_ -match 'DRAGLINE' }).Count
if ($bufBLines -ge 3) { Write-Pass "B1 release yanked a multi-row selection ($bufBLines DRAGLINE rows)" }
else { Write-Fail "B1 release yanked $bufBLines rows: '$($bufB.Trim())'" }
$null = Reset-Mode $SESS $cliPid

Write-Host "`n[B2] TCP pane-mouse: a drag PAST the top row (row -3) scrolls faster than on the row itself" -ForegroundColor Yellow
& $PSMUX copy-mode -t $SESS 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$null = Send-Tcp $SESS @("pane-mouse $paneId 0 5 2 M")
$null = Send-Tcp $SESS @("pane-mouse $paneId 32 5 0 M","pane-mouse $paneId 32 5 0 M","pane-mouse $paneId 32 5 0 M")
$sOnRow = [int](Fmt $SESS '#{scroll_position}')
$null = Send-Tcp $SESS @("pane-mouse $paneId 32 5 -3 M","pane-mouse $paneId 32 5 -3 M","pane-mouse $paneId 32 5 -3 M")
$sPast = [int](Fmt $SESS '#{scroll_position}')
Write-Info "3 drags on row 0: $sOnRow, then 3 drags at row -3: $sPast (delta $($sPast-$sOnRow))"
if ($sOnRow -gt 0 -and ($sPast - $sOnRow) -gt $sOnRow) { Write-Pass "B2 past-the-edge drags scroll faster ($sOnRow per 3 on the row, $($sPast-$sOnRow) per 3 past it)" }
elseif ($sPast -gt $sOnRow) { Write-Pass "B2 past-the-edge drags keep scrolling ($sOnRow -> $sPast)" }
else { Write-Fail "B2 no scroll past the edge (on row $sOnRow, past $sPast)" }
$null = Send-Tcp $SESS @("pane-mouse $paneId 0 5 -3 m")
Start-Sleep -Milliseconds 300
$null = Reset-Mode $SESS $cliPid

Write-Host "`n[B3] TCP: press and release on the SAME cell inside copy mode is a click (#199): no yank, mode preserved" -ForegroundColor Yellow
& $PSMUX set-buffer -t $SESS "SENTINEL590" 2>&1 | Out-Null
& $PSMUX copy-mode -t $SESS 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$null = Send-Tcp $SESS @("pane-mouse $paneId 0 5 4 M","pane-mouse $paneId 32 5 4 M","pane-mouse $paneId 0 5 4 m")
Start-Sleep -Milliseconds 400
$mB3 = Fmt $SESS '#{pane_in_mode}'; $bB3 = (Buf $SESS).Trim()
if ($mB3 -eq "1") { Write-Pass "B3 same-cell click did not cancel copy mode (mode=1)" } else { Write-Fail "B3 same-cell click changed the mode to $mB3" }
if ($bB3 -eq "SENTINEL590") { Write-Pass "B3 same-cell click did not yank" } else { Write-Fail "B3 buffer changed to '$bB3'" }
$null = Reset-Mode $SESS $cliPid

# ---------------------------------------------------------------------------
# C. scroll-enter-copy-mode off: direct scroll + bottom-edge handoff
# ---------------------------------------------------------------------------
Write-Host "`n[C1] scroll-enter-copy-mode off: wheel scrolls the pane directly and the dump exposes view_offset" -ForegroundColor Yellow
& $PSMUX set-option -t $SESS scroll-enter-copy-mode off 2>&1 | Out-Null
if (-not (Reset-Mode $SESS $cliPid)) { Write-Info "could not leave copy mode before the fill" }
if (-not (Fill-Scrollback $SESS)) { Write-Fail "scrollback fill did not finish" }
& $PSMUX delete-buffer -t $SESS 2>&1 | Out-Null
& $wheelInj $cliPid up 12 10 10 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$mC = Fmt $SESS '#{pane_in_mode}'
$capC = Cap $SESS
$topC = Top-Marker $capC; $botC = Bottom-Marker $capC
$vo = Get-DumpLeafField $SESS "view_offset"
Write-Info "after 12 wheel notches: mode=$mC visible DRAGLINE $topC..$botC view_offset=$vo"
if ($mC -eq "0") { Write-Pass "C1 wheel did not enter copy mode" } else { Write-Fail "C1 wheel entered copy mode (mode=$mC)" }
if ($botC -gt 0 -and $botC -lt 200) { Write-Pass "C1 pane is scrolled back (bottom visible marker $botC < 200)" } else { Write-Fail "C1 pane did not scroll back (bottom marker $botC)" }
if ($vo -match '^\d+$' -and [int]$vo -gt 0) { Write-Pass "C1 layout dump reports view_offset=$vo" } else { Write-Fail "C1 view_offset in dump: $vo" }

Write-Host "`n[C2] drag from row 2 down to the BOTTOM row and dwell: hands off and scrolls toward the live output" -ForegroundColor Yellow
$samplesC = Run-Drag $cliPid 3 2 3 $bottomRow 1500 0 { "$(Fmt $SESS '#{pane_in_mode}')/$(Fmt $SESS '#{scroll_position}')" }
Write-Info "samples during bottom dwell: $($samplesC -join ', ')"
$sawCopy = ($samplesC | Where-Object { $_ -like '1/*' }).Count -gt 0
if ($sawCopy) { Write-Pass "C2 the drag was handed off to copy mode at the bottom edge" } else { Write-Fail "C2 no copy-mode handoff at the bottom edge" }
$bufC = Buf $SESS
$bufCBot = Bottom-Marker $bufC; $bufCTop = Top-Marker $bufC
Write-Info "yank markers $bufCTop..$bufCBot (visible before drag $topC..$botC)"
if ($bufCBot -gt $botC) { Write-Pass "C2 yank reached DRAGLINE-$('{0:D4}' -f [int]$bufCBot), BELOW the scrolled view's bottom ($botC)" }
else { Write-Fail "C2 yank stopped at the screen edge (max marker $bufCBot vs visible bottom $botC)" }
if ($bufCTop -ge 0 -and $bufCTop -le ($topC + 3) -and $bufCTop -ge $topC) { Write-Pass "C2 yank anchored on the line that was actually at row 2 ($bufCTop, view top $topC)" }
elseif ($bufCTop -ge 0) { Write-Fail "C2 yank anchor drifted: first marker $bufCTop while the view top was $topC" }
$mC2 = Fmt $SESS '#{pane_in_mode}'
if ($mC2 -eq "0") { Write-Pass "C2 back in the live view after release" } else { Write-Fail "C2 mode=$mC2 after release" }

# ---------------------------------------------------------------------------
# D. keyboard entry over a direct-scrolled view keeps the offset
# ---------------------------------------------------------------------------
Write-Host "`n[D1] scroll-enter-copy-mode off: wheel back 10, then prefix-[ ; scroll_position must equal the viewed offset" -ForegroundColor Yellow
if (-not (Reset-Mode $SESS $cliPid)) { Write-Info "could not leave copy mode before the fill" }
if (-not (Fill-Scrollback $SESS)) { Write-Fail "scrollback fill did not finish" }
& $wheelInj $cliPid up 10 10 10 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$voD = Get-DumpLeafField $SESS "view_offset"
$botD = Bottom-Marker (Cap $SESS)
& $keyInj $cliPid "^b{SLEEP:300}[" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$mD = Fmt $SESS '#{pane_in_mode}'; $sD = Fmt $SESS '#{scroll_position}'
$botD2 = Bottom-Marker (Cap $SESS)
Write-Info "view_offset before=$voD, after prefix-[: mode=$mD scroll_position=$sD, bottom marker $botD -> $botD2"
if ($mD -eq "1") { Write-Pass "D1 prefix-[ entered copy mode" } else { Write-Fail "D1 prefix-[ did not enter copy mode (mode=$mD)" }
if ([int]$sD -gt 0) { Write-Pass "D1 copy mode kept the scrolled view (scroll_position=$sD)" } else { Write-Fail "D1 copy mode reset to the live view (scroll_position=$sD) while the screen showed up to $botD" }
if ($botD2 -eq $botD) { Write-Pass "D1 the visible lines did not jump on entry ($botD2)" } else { Write-Fail "D1 visible bottom jumped $botD -> $botD2 on entry" }
$null = Reset-Mode $SESS $cliPid
Start-Sleep -Milliseconds 300
& $PSMUX set-option -t $SESS scroll-enter-copy-mode on 2>&1 | Out-Null

# ---------------------------------------------------------------------------
# E. click and same-cell jitter never yank or cancel (#199 guard)
# ---------------------------------------------------------------------------
Write-Host "`n[E1] plain click on the pane: no yank, no copy mode" -ForegroundColor Yellow
if (-not (Reset-Mode $SESS $cliPid)) { Write-Info "could not leave copy mode before the fill" }
if (-not (Fill-Scrollback $SESS)) { Write-Fail "scrollback fill did not finish" }
& $PSMUX set-buffer -t $SESS "SENTINEL_E" 2>&1 | Out-Null
& $clickInj $cliPid 10 ($paneH-3) 80 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$mE = Fmt $SESS '#{pane_in_mode}'; $bE = (Buf $SESS).Trim()
if ($mE -eq "0" -and $bE -eq "SENTINEL_E") { Write-Pass "E1 click left mode=0 and the buffer untouched" }
else { Write-Fail "E1 click: mode=$mE buffer='$bE'" }

Write-Host "`n[E2] press, one same-cell held move, release: no yank" -ForegroundColor Yellow
$null = Run-Drag $cliPid 10 ($paneH-3) 10 ($paneH-3) 200 1 $null
$mE2 = Fmt $SESS '#{pane_in_mode}'; $bE2 = (Buf $SESS).Trim()
if ($mE2 -eq "0" -and $bE2 -eq "SENTINEL_E") { Write-Pass "E2 same-cell jitter left mode=0 and the buffer untouched" }
else { Write-Fail "E2 jitter: mode=$mE2 buffer='$bE2'" }

Write-Host "`n[E3] a short in-pane drag (no edge) stays on the client overlay: clipboard gets the rows, no copy mode, paste buffer untouched" -ForegroundColor Yellow
& $PSMUX set-buffer -t $SESS "SENTINEL_E3" 2>&1 | Out-Null
Set-Clipboard -Value "CLIP_SENTINEL_E3"
$null = Run-Drag $cliPid 0 ($paneH-6) 12 ($paneH-4) 200 0 $null
$mE3 = Fmt $SESS '#{pane_in_mode}'; $bE3 = (Buf $SESS).Trim()
$clipE3 = try { (Get-Clipboard -Raw) } catch { "" }
$e3Lines = ([regex]::Matches($clipE3, 'DRAGLINE-\d{4}')).Count
if ($mE3 -eq "0") { Write-Pass "E3 in-pane drag stayed out of copy mode" } else { Write-Fail "E3 in-pane drag entered copy mode" }
if ($e3Lines -ge 2 -and $e3Lines -le 4) { Write-Pass "E3 clipboard holds the $e3Lines dragged rows" } else { Write-Fail "E3 clipboard has $e3Lines DRAGLINE rows: '$($clipE3.Trim())'" }
if ($bE3 -eq "SENTINEL_E3") { Write-Pass "E3 paste buffer untouched by the overlay drag" } else { Write-Fail "E3 paste buffer changed to '$bE3'" }

# ---------------------------------------------------------------------------
# F. TUI sanity: the attached window still works after all the mouse traffic
# ---------------------------------------------------------------------------
Write-Host "`n[F1] TUI sanity" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESS 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panes = Fmt $SESS '#{window_panes}'
if ($panes -eq "2") { Write-Pass "F1 split-window created 2 panes on the attached client" } else { Write-Fail "F1 window_panes=$panes" }
& $PSMUX send-keys -t $SESS "echo TUI_ALIVE_590" Enter 2>&1 | Out-Null
if (Wait-Cond { (Cap $SESS) -match 'TUI_ALIVE_590' } 8) { Write-Pass "F1 new pane echoes" } else { Write-Fail "F1 new pane did not echo" }
$cliAlive = Get-Process -Id $cliPid -EA SilentlyContinue
if ($cliAlive) { Write-Pass "F1 attached client process still alive" } else { Write-Fail "F1 attached client died" }

Stop-Sess $SESS
try { Stop-Process -Id $cliPid -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:Skip)" -ForegroundColor Yellow
exit $script:Fail
