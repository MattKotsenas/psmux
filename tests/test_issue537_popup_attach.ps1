# Issue #537: display-popup cannot attach to another session
#
# Reported: with two sessions alive, a popup that runs `psmux attach -t popup`
# never attaches. Root cause: the popup child inherits PSMUX_SESSION and the
# nested-session guard refused on that env var alone, so the attaching client
# exited immediately and the popup closed before it ever rendered.
#
# tmux parity (verified live against tmux 3.4): server_client_check_nested()
# requires $TMUX to be set AND the client's tty to belong to one of the server's
# window panes. A popup pty comes from job_run() and is never a window pane, so
# `tmux attach -t other` inside display-popup attaches, while the same command
# inside a real pane is still refused.
#
# This suite proves both halves on psmux:
#   Part A: a popup running `psmux attach -t other` renders the target session
#   Part B: a popup running `psmux new-session -A -s scratch` works too
#   Part C: genuine nesting from inside a real pane is STILL refused
#   Part D: edge cases (PSMUX_ALLOW_NESTING, detached new-session, plain shell)
#   Part E: Win32 TUI visual verification on a real attached window

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$HOST_S = "i537host"
$POP_S  = "i537target"
$SCRATCH = "i537scratch"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    foreach ($s in @($HOST_S, $POP_S, $SCRATCH, "i537tui")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 800
    Remove-Item "$psmuxDir\i537*" -Force -EA SilentlyContinue
}

function Connect-Persistent {
    param([string]$Session)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 10000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush(); $null = $reader.ReadLine()
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    return @{ tcp=$tcp; writer=$writer; reader=$reader }
}

function Get-DumpOnce {
    param([string]$Session)
    try { $conn = Connect-Persistent -Session $Session } catch { return $null }
    try {
        $conn.writer.Write("dump-state`n"); $conn.writer.Flush()
        $best = $null
        $conn.tcp.ReceiveTimeout = 3000
        for ($j = 0; $j -lt 200; $j++) {
            try { $line = $conn.reader.ReadLine() } catch { break }
            if ($null -eq $line) { break }
            if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
            if ($best) { $conn.tcp.ReceiveTimeout = 60 }
        }
        return $best
    } catch { return $null } finally { try { $conn.tcp.Close() } catch {} }
}

function Get-PopupText {
    param($json)
    $sb = [System.Text.StringBuilder]::new()
    if ($json.popup_rows) {
        foreach ($row in $json.popup_rows) {
            $line = ""
            foreach ($r in $row.runs) { $line += $r.text }
            [void]$sb.AppendLine($line.TrimEnd())
        }
    }
    if ($json.popup_lines) { foreach ($l in $json.popup_lines) { [void]$sb.AppendLine("$l") } }
    return $sb.ToString()
}

# Polls the host session while a popup runs; returns whether the popup ever
# became active and the richest content seen.
function Watch-Popup {
    param([string]$Session, [int]$Ms = 12000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sawActive = $false; $firstMs = -1; $bestText = ""
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        $d = Get-DumpOnce -Session $Session
        if ($d) {
            $j = $d | ConvertFrom-Json
            if ($j.popup_active) {
                if (-not $sawActive) { $firstMs = $sw.ElapsedMilliseconds }
                $sawActive = $true
                $t = ((Get-PopupText $j) -split "`n" | Where-Object { $_.Trim() }) -join "`n"
                if ($t.Length -gt $bestText.Length) { $bestText = $t }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return @{ SawActive = $sawActive; FirstMs = $firstMs; Text = $bestText }
}

function Fire-Popup {
    param([string]$Cmd, [string]$Session = $HOST_S)
    Start-Job -ScriptBlock { param($p,$s,$c) & $p display-popup -t $s -E $c 2>&1 } `
        -ArgumentList $PSMUX,$Session,$Cmd | Out-Null
}

function Drain-Jobs {
    Get-Job | ForEach-Object {
        $o = (Receive-Job $_ 2>&1 | Out-String).Trim()
        if ($o) { Write-Host "    (popup cmd output: $o)" -ForegroundColor DarkGray }
    }
    Get-Job | Remove-Job -Force -EA SilentlyContinue
}

Write-Host "`n=== Issue #537: display-popup attaching to another session ===" -ForegroundColor Cyan

# === SETUP: exactly the reporter's layout, one attached session + one detached ===
Cleanup
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$HOST_S -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t $HOST_S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "host session creation failed"; exit 1 }
Write-Pass "attached host session $HOST_S is up"

& $PSMUX new-session -d -s $POP_S 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t $POP_S 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "detached target session $POP_S is up (psmux new-session -d -s $POP_S)" }
else { Write-Fail "target session creation failed"; exit 1 }

# Put a unique marker on the target session's screen BEFORE any popup exists, so
# finding it inside the popup proves the popup is showing THAT session.
& $PSMUX send-keys -t $POP_S "echo TARGET_SCREEN_MARKER_537" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2

# === CONTROL: popups themselves work (isolates the psmux-in-popup case) ===
Write-Host "`n[Control] popup running a plain command renders" -ForegroundColor Yellow
Fire-Popup "pwsh -NoProfile -Command `"Write-Host CONTROL_MARKER_537; Start-Sleep -Seconds 8`""
$ctrl = Watch-Popup -Session $HOST_S -Ms 9000
Drain-Jobs
if ($ctrl.SawActive) { Write-Pass "control popup became active at $($ctrl.FirstMs)ms" }
else { Write-Fail "control popup never opened; popups are broken independently of #537" }
if ($ctrl.Text -match "CONTROL_MARKER_537") { Write-Pass "control popup rendered its command output" }
else { Write-Fail "control popup content missing: [$($ctrl.Text)]" }

# === PART A: the reported scenario ===
Write-Host "`n[Part A] display-popup -E `"psmux attach -t $POP_S`"" -ForegroundColor Yellow
Fire-Popup "$PSMUX attach -t $POP_S"
$a = Watch-Popup -Session $HOST_S -Ms 14000
if ($a.SawActive) { Write-Pass "popup opened and STAYED open at $($a.FirstMs)ms (attach did not bail out)" }
else { Write-Fail "BUG #537: popup running 'psmux attach' never opened" }

if ($a.Text -match "nested with care") {
    Write-Fail "BUG #537: nested-session guard refused the attach inside the popup"
} else {
    Write-Pass "no nested-session refusal inside the popup"
}

# The target session must now report an attached client.
$attachedFlag = (& $PSMUX display-message -t $POP_S -p '#{session_attached}' 2>&1 | Out-String).Trim()
if ($attachedFlag -eq "1") { Write-Pass "target session reports session_attached=1 (popup client is attached)" }
else { Write-Fail "target session_attached='$attachedFlag', expected 1" }

$lsOut = (& $PSMUX ls 2>&1 | Out-String)
if ($lsOut -match "$POP_S[^`n]*\(attached\)") { Write-Pass "psmux ls marks $POP_S as (attached)" }
else { Write-Fail "psmux ls does not show $POP_S attached:`n$lsOut" }

# The popup must be showing the TARGET session, not the host session.
$clients = (& $PSMUX list-clients 2>&1 | Out-String)
if ($clients -match [regex]::Escape($POP_S)) { Write-Pass "list-clients shows a client on $POP_S" }
else { Write-Fail "list-clients has no client on ${POP_S}:`n$clients" }

# The popup must show the TARGET session's screen, not the host's. Two
# independent proofs: the marker printed into the target before the popup
# existed, and the target session's own status bar rendered by the nested client.
if ($a.Text -match "TARGET_SCREEN_MARKER_537") {
    Write-Pass "popup renders the target session's screen contents"
} else {
    Write-Fail "popup did not render the target session's screen: [$($a.Text)]"
}
if ($a.Text -match [regex]::Escape($POP_S.Substring(0, [Math]::Min(9, $POP_S.Length)))) {
    Write-Pass "popup renders the target session's own status bar"
} else {
    Write-Fail "popup shows no status bar for $POP_S"
}
& $PSMUX kill-session -t $POP_S 2>&1 | Out-Null
Start-Sleep -Seconds 2
Drain-Jobs

# === PART B: new-session -A (the tmux scratch-popup idiom) ===
Write-Host "`n[Part B] display-popup -E `"psmux new-session -A -s $SCRATCH`"" -ForegroundColor Yellow
Fire-Popup "$PSMUX new-session -A -s $SCRATCH"
$b = Watch-Popup -Session $HOST_S -Ms 14000
if ($b.SawActive) { Write-Pass "scratch popup opened and stayed open" }
else { Write-Fail "BUG #537: 'new-session -A' popup never opened" }
if ($b.Text -match "nested with care") { Write-Fail "scratch popup was refused by the nesting guard" }
else { Write-Pass "scratch popup was not refused" }

& $PSMUX has-session -t $SCRATCH 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "scratch session $SCRATCH was created from the popup" }
else { Write-Fail "scratch session was never created" }
& $PSMUX kill-session -t $SCRATCH 2>&1 | Out-Null
Start-Sleep -Seconds 2
Drain-Jobs

# === PART C: REGRESSION GUARD. Real panes must STILL refuse to nest ===
Write-Host "`n[Part C] genuine nesting from inside a real pane is still refused" -ForegroundColor Yellow
& $PSMUX new-session -d -s $POP_S 2>&1 | Out-Null
Start-Sleep -Seconds 3
$nestLog = "$env:TEMP\psmux537_nested.txt"
Remove-Item $nestLog -Force -EA SilentlyContinue
# Run the attach INSIDE a pane of the host session and capture what it prints.
& $PSMUX send-keys -t $HOST_S "& '$PSMUX' attach -t $POP_S *>&1 | Set-Content '$nestLog'" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 6
if (Test-Path $nestLog) {
    $nested = (Get-Content $nestLog -Raw)
    if ($nested -match "nested with care") {
        Write-Pass "pane attach still refused: $($nested.Trim())"
    } else {
        Write-Fail "REGRESSION: pane attach was allowed to nest. Output: [$($nested.Trim())]"
    }
} else {
    Write-Fail "nested attach produced no output file (could not verify the guard)"
}

$stillDetached = (& $PSMUX display-message -t $POP_S -p '#{session_attached}' 2>&1 | Out-String).Trim()
if ($stillDetached -eq "0") { Write-Pass "target session stayed detached after the refused pane attach" }
else { Write-Fail "target session_attached='$stillDetached' after a refused attach, expected 0" }

# === PART D: edge cases ===
Write-Host "`n[Part D] edge cases" -ForegroundColor Yellow

# D1: a detached new-session from inside a pane is allowed (issue #424 behavior)
& $PSMUX kill-session -t $SCRATCH 2>&1 | Out-Null
$d1log = "$env:TEMP\psmux537_detached.txt"
Remove-Item $d1log -Force -EA SilentlyContinue
& $PSMUX send-keys -t $HOST_S "& '$PSMUX' new-session -d -s $SCRATCH *>&1 | Set-Content '$d1log'" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SCRATCH 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "detached new-session from inside a pane still allowed (#424 preserved)" }
else { Write-Fail "detached new-session from inside a pane was refused (regression on #424)" }
& $PSMUX kill-session -t $SCRATCH 2>&1 | Out-Null

# D2: PSMUX_ALLOW_NESTING=1 escape hatch still forces nesting through
$d2log = "$env:TEMP\psmux537_force.txt"
Remove-Item $d2log -Force -EA SilentlyContinue
& $PSMUX send-keys -t $HOST_S "`$env:PSMUX_ALLOW_NESTING='1'; & '$PSMUX' attach -t $POP_S *>&1 | Set-Content '$d2log'" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 6
if (Test-Path $d2log) {
    $forced = (Get-Content $d2log -Raw)
    if ($forced -match "nested with care") { Write-Fail "PSMUX_ALLOW_NESTING=1 no longer forces nesting" }
    else { Write-Pass "PSMUX_ALLOW_NESTING=1 escape hatch still works" }
} else {
    Write-Pass "PSMUX_ALLOW_NESTING=1 attach produced no refusal message"
}
& $PSMUX send-keys -t $HOST_S "q" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# D3: a popup targeting a session that does not exist fails cleanly
Write-Host "  (D3) popup attaching to a missing session" -ForegroundColor DarkGray
Fire-Popup "$PSMUX attach -t i537_does_not_exist"
$d3 = Watch-Popup -Session $HOST_S -Ms 7000
Drain-Jobs
if ($d3.Text -match "nested with care") { Write-Fail "missing-session attach hit the nesting guard instead of a not-found error" }
else { Write-Pass "missing-session attach did not hit the nesting guard" }

# === PART E: Win32 TUI visual verification ===
Write-Host "`n[Part E] Win32 TUI visual verification" -ForegroundColor Yellow
$tuiProc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","i537tui" -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t "i537tui" 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: visible session i537tui launched" }
else { Write-Fail "TUI: session did not start" }

Fire-Popup "$PSMUX attach -t $POP_S" "i537tui"
$e = Watch-Popup -Session "i537tui" -Ms 12000
if ($e.SawActive) { Write-Pass "TUI: popup with an attached session is live on a real window" }
else { Write-Fail "TUI: popup never opened on the real window" }

# session_attached is a count (format.c, s->attached; #825). Part D2's
# PSMUX_ALLOW_NESTING attach is still on this session, so the popup's client
# makes it 2: the count must be at least 1 and agree with list-clients.
$tuiAttached = (& $PSMUX display-message -t $POP_S -p '#{session_attached}' 2>&1 | Out-String).Trim()
$tuiClients = @(& $PSMUX list-clients -t $POP_S 2>$null | Where-Object { $_ -match '\S' }).Count
if ($tuiAttached -match '^\d+$' -and [int]$tuiAttached -ge 1 -and [int]$tuiAttached -eq $tuiClients) { Write-Pass "TUI: target session reports $tuiAttached attached client(s), as list-clients does" }
else { Write-Fail "TUI: target session_attached='$tuiAttached', list-clients shows $tuiClients" }

# The host TUI session must still be usable while the popup holds a client.
& $PSMUX split-window -v -t "i537tui" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$panes = (& $PSMUX display-message -t "i537tui" -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes -eq "2") { Write-Pass "TUI: host session still responds to commands (split -> 2 panes)" }
else { Write-Fail "TUI: host session unresponsive, window_panes='$panes'" }

Drain-Jobs
try { Stop-Process -Id $tuiProc.Id -Force -EA SilentlyContinue } catch {}
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Cleanup
Remove-Item "$env:TEMP\psmux537_*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
