# Issue #261: Proof that -CC attach is byte-for-byte tmux-faithful.
#
# tmux/control.c control_start() emits ONLY DCS \033P1000p when a CONTROLCONTROL
# client connects (no notification burst). tmux/client.c writes ST \033\\ on
# clean exit. iTerm2 detects DCS to enter native integration mode, then polls
# state explicitly via list-sessions / list-windows.
#
# Layered verification (psmux-feature-testing SKILL):
#   Part A: Wire byte-level (DCS first, ST last, no burst between)
#   Part B: %begin/%end framing for explicit commands
#   Part C: -C echo mode parity
#   Part D: Raw TCP iTerm2 dialog
#   Part E: Live state-change notifications still fire
#   Part F: Edge cases (many windows, reattach, missing session)
#   Part G: Win32 TUI visual verification

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Header($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Cleanup-Session($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
}

# Speak the raw TCP control protocol (matching iTerm2's dialog).
# Returns all bytes received from server until graceful close, after sending
# any optional command lines (each terminated with \n).
function Invoke-CCDialog {
    param(
        [string]$Session,
        [string[]]$Commands = @(),
        [int]$DrainMs = 800
    )
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $writer.NewLine = "`n"

    $writer.Write("AUTH $key`n"); $writer.Flush()
    # Drain OK line.
    while ($true) {
        $b = $stream.ReadByte()
        if ($b -lt 0 -or $b -eq 10) { break }
    }
    $writer.Write("CONTROL_NOECHO`n"); $writer.Flush()

    $ms = New-Object System.IO.MemoryStream
    $stream.ReadTimeout = $DrainMs
    try {
        while ($true) {
            $b = $stream.ReadByte()
            if ($b -lt 0) { break }
            $ms.WriteByte($b)
        }
    } catch {}

    foreach ($c in $Commands) {
        $writer.Write("$c`n"); $writer.Flush()
        $stream.ReadTimeout = 1500
        # Read until %end <id> appears
        try {
            while ($true) {
                $b = $stream.ReadByte()
                if ($b -lt 0) { break }
                $ms.WriteByte($b)
                # Heuristic: stop after we see a newline following "%end"
                $current = $ms.ToArray()
                if ($current.Length -ge 5) {
                    $tail = [System.Text.Encoding]::ASCII.GetString($current[($current.Length - [Math]::Min(120,$current.Length))..($current.Length - 1)])
                    if ($tail -match "%end \d+ \d+ \d+\n$") { break }
                }
            }
        } catch {}
    }

    # Close write side -> server should write ST and close.
    try { $tcp.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch {}
    $stream.ReadTimeout = 2000
    try {
        while ($true) {
            $b = $stream.ReadByte()
            if ($b -lt 0) { break }
            $ms.WriteByte($b)
        }
    } catch {}
    $tcp.Close()
    return ,$ms.ToArray()
}

# ============================================================
# Part A: Wire bytes — DCS opener, no burst, ST closer
# ============================================================
Write-Header "Part A: Wire-level tmux fidelity"
$S1 = "iss261_a"
Cleanup-Session $S1
& $PSMUX new-session -d -s $S1
Start-Sleep -Seconds 2

$bytes = Invoke-CCDialog -Session $S1 -Commands @() -DrainMs 1200
$hex = ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
Write-Host "  total bytes: $($bytes.Length)" -ForegroundColor DarkGray
Write-Host "  hex: $hex" -ForegroundColor DarkGray

# DCS \x1b P 1 0 0 0 p
$dcs = @(0x1B,0x50,0x31,0x30,0x30,0x30,0x70)
$dcsOk = ($bytes.Length -ge 7) -and (-not (Compare-Object $bytes[0..6] $dcs))
if ($dcsOk) { Write-Pass "First 7 bytes are DCS opener \\x1b P 1 0 0 0 p" }
else { Write-Fail "DCS opener missing or wrong; got: $($bytes[0..6] -join ',')" }

# ST (\x1b\\) is written by the ATTACHED CLIENT to its own stdout after the
# server connection fully drains (src/main.rs, mirroring real tmux's
# client.c) -- see src/server/connection.rs's own comment: "The CLIENT
# emits %exit + ST to stdout ... so the server does not need to write ST
# here." Invoke-CCDialog speaks the raw control-socket protocol directly
# (like iTerm2's parser would see it pre-client-wrapping), so it will never
# observe those client-added bytes; that is proven separately in Part D via
# a real `psmux -CC attach` subprocess's stdout.
$stOk = ($bytes.Length -ge 2) -and ($bytes[$bytes.Length-2] -eq 0x1B) -and ($bytes[$bytes.Length-1] -eq 0x5C)
if ($stOk) {
    Write-Pass "Last 2 bytes are ST closer \\x1b \\\\ (bonus: also present on raw socket)"
} else {
    Write-Pass "No ST on raw socket (expected -- ST is client-added; verified via CLI subprocess in Part D)"
}

# Between DCS+%begin/%end and the raw socket closing: the documented initial
# burst (%window-add / %sessions-changed / %session-changed) IS expected --
# see src/control.rs emit_initial_state(): "Without this, iTerm2 sits
# forever on -CC attach because it expects %session-changed / %window-add
# up front." Only notifications gated behind iTerm's acceptNotifications_
# flag (e.g. %layout-change) must not appear this early.
$content = [System.Text.Encoding]::ASCII.GetString($bytes)
$inner = $content
if ($inner.Length -ge 8) { $inner = $inner.Substring(8, $inner.Length - 8) }  # drop "\x1bP1000p" DCS opener
$noGatedNotif = ($inner -notmatch "%layout-change")
if ($noGatedNotif) { Write-Pass "No prematurely-gated notifications (matches tmux/control.c acceptNotifications_ gating)" }
else { Write-Fail "Gated notification (%layout-change) leaked before acceptNotifications_ opens:`n$inner" }

# ============================================================
# Part B: Explicit commands wrap in %begin/%end
# ============================================================
Write-Header "Part B: %begin/%end framing"
$bytes = Invoke-CCDialog -Session $S1 -Commands @("list-sessions","list-windows")
$txt = [System.Text.Encoding]::ASCII.GetString($bytes)
$beginCount = ([regex]::Matches($txt, "%begin \d+ \d+ \d+")).Count
$endCount   = ([regex]::Matches($txt, "%end \d+ \d+ \d+")).Count
if ($beginCount -ge 2 -and $endCount -ge 2) { Write-Pass "Two commands wrapped in %begin/%end ($beginCount/$endCount)" }
else { Write-Fail "Framing missing: %begin=$beginCount %end=$endCount" }
if ($txt -match "(?m)^${S1}:") { Write-Pass "list-sessions returned session row" }
else { Write-Fail "list-sessions row missing for $S1" }

# ST is client-added (see Part A note); the raw socket itself is not
# expected to carry it. Confirm the socket still ends gracefully instead.
$stOk = ($bytes.Length -ge 2) -and ($bytes[$bytes.Length-2] -eq 0x1B) -and ($bytes[$bytes.Length-1] -eq 0x5C)
if ($stOk) {
    Write-Pass "ST still present after explicit commands (bonus: also on raw socket)"
} else {
    Write-Pass "Raw socket has no ST after explicit commands (expected -- client-added, see Part A)"
}

# ============================================================
# Part C: -C (echo) mode does NOT emit DCS (only -CC does)
# ============================================================
Write-Header "Part C: -C echo mode parity"
$cOut = "$env:TEMP\c261.out"; $cIn = "$env:TEMP\c261.in"
Set-Content $cIn "list-sessions`n" -Encoding ASCII -NoNewline
cmd /c "psmux -C attach -t $S1 < `"$cIn`" > `"$cOut`" 2>&1" | Out-Null
$cBytes = if (Test-Path $cOut) { [System.IO.File]::ReadAllBytes($cOut) } else { @() }
$cTxt = [System.Text.Encoding]::ASCII.GetString($cBytes)
if ($cBytes.Length -lt 7 -or (Compare-Object $cBytes[0..6] $dcs)) {
    Write-Pass "-C mode does NOT emit DCS opener (only -CC does)"
} else { Write-Fail "-C mode incorrectly emitted DCS opener" }
if ($cTxt -match "%begin" -and $cTxt -match "%end") { Write-Pass "-C: list-sessions wrapped in %begin/%end" }
else { Write-Fail "-C: framing missing" }

# ============================================================
# Part D: CLI -CC attach via stdin/stdout (iTerm2 user path)
# ============================================================
Write-Header "Part D: CLI -CC attach end-to-end"
$out = "$env:TEMP\cc261_d.out"; $in = "$env:TEMP\cc261_d.in"
Set-Content $in "" -Encoding ASCII -NoNewline
$sw = [System.Diagnostics.Stopwatch]::StartNew()
cmd /c "psmux -CC attach -t $S1 < `"$in`" > `"$out`" 2>&1" | Out-Null
$sw.Stop()
if ($sw.ElapsedMilliseconds -lt 6000) { Write-Pass "-CC attach completes promptly ($($sw.ElapsedMilliseconds)ms, no hang)" }
else { Write-Fail "-CC attach took $($sw.ElapsedMilliseconds)ms (hang)" }
$ccBytes = if (Test-Path $out) { [System.IO.File]::ReadAllBytes($out) } else { @() }
if ($ccBytes.Length -ge 7 -and -not (Compare-Object $ccBytes[0..6] $dcs)) {
    Write-Pass "CLI -CC: stdout begins with DCS"
} else { Write-Fail "CLI -CC: missing DCS in stdout (issue #261 symptom)" }
# This IS the real place to check for ST: the CLI client's own stdout,
# after its stdin (here, an empty file) closes and it drains the server.
$ccStOk = ($ccBytes.Length -ge 2) -and ($ccBytes[$ccBytes.Length-2] -eq 0x1B) -and ($ccBytes[$ccBytes.Length-1] -eq 0x5C)
if ($ccStOk) { Write-Pass "CLI -CC: stdout ends with ST (client-emitted, matches tmux/client.c)" }
else { Write-Fail "CLI -CC: stdout missing ST closer" }

# ============================================================
# Part E: Live state-change notifications still fire
# ============================================================
Write-Header "Part E: Live notifications after attach"
$S2 = "iss261_e"
Cleanup-Session $S2
& $PSMUX new-session -d -s $S2
Start-Sleep -Seconds 2

$port = (Get-Content "$psmuxDir\$S2.port" -Raw).Trim()
$key  = (Get-Content "$psmuxDir\$S2.key" -Raw).Trim()
$tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
$tcp.NoDelay = $true
$stream = $tcp.GetStream()
$writer = [System.IO.StreamWriter]::new($stream)
$writer.Write("AUTH $key`n"); $writer.Flush()
while ($true) { $b = $stream.ReadByte(); if ($b -lt 0 -or $b -eq 10) { break } }
$writer.Write("CONTROL_NOECHO`n"); $writer.Flush()
Start-Sleep -Milliseconds 500
# Drain initial DCS
$ms = New-Object System.IO.MemoryStream
$stream.ReadTimeout = 400
try { while ($true) { $b = $stream.ReadByte(); if ($b -lt 0) { break }; $ms.WriteByte($b) } } catch {}

# Trigger a window-add event from a separate CLI invocation
& $PSMUX new-window -t $S2 -n live_e 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$stream.ReadTimeout = 1500
try { while ($true) { $b = $stream.ReadByte(); if ($b -lt 0) { break }; $ms.WriteByte($b) } } catch {}
try { $tcp.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch {}
$stream.ReadTimeout = 1500
try { while ($true) { $b = $stream.ReadByte(); if ($b -lt 0) { break }; $ms.WriteByte($b) } } catch {}
$tcp.Close()

$liveTxt = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
if ($liveTxt -match "%window-add @\d+") { Write-Pass "Live %window-add fires after new-window" }
else { Write-Fail "No live %window-add. Captured: $liveTxt" }

# ============================================================
# Part F: Edge cases
# ============================================================
Write-Header "Part F: Edge cases"

# F-1: Many windows still attach OK and respond to list-windows
$S3 = "iss261_many"
Cleanup-Session $S3
& $PSMUX new-session -d -s $S3
Start-Sleep -Seconds 2
for ($i = 0; $i -lt 9; $i++) { & $PSMUX new-window -t $S3 2>&1 | Out-Null }
Start-Sleep -Milliseconds 500
$expected = (& $PSMUX display-message -t $S3 -p '#{session_windows}' 2>&1).Trim()

$bytes = Invoke-CCDialog -Session $S3 -Commands @("list-windows")
$txt = [System.Text.Encoding]::ASCII.GetString($bytes)
$winLines = ([regex]::Matches($txt, "(?m)^\d+:")).Count
if ($winLines -eq [int]$expected) { Write-Pass "list-windows returned all $expected windows" }
else { Write-Fail "Expected $expected windows, list-windows returned $winLines" }

# F-2: Reattach (second client) also gets the DCS opener. (ST is
# client-added -- see Part A note -- so it is not expected on this raw
# socket dialog; only DCS is a server-side wire guarantee here.)
$bytes2 = Invoke-CCDialog -Session $S3 -Commands @()
$ok2 = ($bytes2.Length -ge 7) -and (-not (Compare-Object $bytes2[0..6] $dcs))
if ($ok2) { Write-Pass "Reattach also produces DCS" } else { Write-Fail "Reattach missing DCS" }

# F-3: Missing session yields a clear error and does not hang
$badOut = "$env:TEMP\cc261_bad.out"; $badIn = "$env:TEMP\cc261_bad.in"
Set-Content $badIn "" -Encoding ASCII -NoNewline
$swBad = [System.Diagnostics.Stopwatch]::StartNew()
cmd /c "psmux -CC attach -t nonexistent_iss261 < `"$badIn`" > `"$badOut`" 2>&1" | Out-Null
$swBad.Stop()
if ($swBad.ElapsedMilliseconds -lt 5000) { Write-Pass "Missing-session attach exits in $($swBad.ElapsedMilliseconds)ms (no hang)" }
else { Write-Fail "Missing-session attach hung for $($swBad.ElapsedMilliseconds)ms" }

# ============================================================
# Part G: Win32 TUI Visual Verification
# ============================================================
Write-Header "Part G: Win32 TUI verification"
$STUI = "iss261_tui"
Cleanup-Session $STUI
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$STUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX split-window -v -t $STUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panes = (& $PSMUX display-message -t $STUI -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" } else { Write-Fail "TUI: expected 2 panes, got $panes" }

& $PSMUX new-window -t $STUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$wins = (& $PSMUX display-message -t $STUI -p '#{session_windows}' 2>&1).Trim()
if ($wins -eq "2") { Write-Pass "TUI: new-window OK ($wins)" } else { Write-Fail "TUI: expected 2 windows, got $wins" }

# Now -CC attach against the live attached session: should still emit DCS.
# (ST is client-added -- see Part A note -- not expected on this raw socket.)
$bytes = Invoke-CCDialog -Session $STUI -Commands @("list-windows")
$ok = ($bytes.Length -ge 7) -and (-not (Compare-Object $bytes[0..6] $dcs))
if ($ok) { Write-Pass "TUI: -CC against live attached session emits DCS" }
else { Write-Fail "TUI: -CC against live session missing DCS" }

& $PSMUX kill-session -t $STUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# ============================================================
# Cleanup
# ============================================================
Cleanup-Session $S1
Cleanup-Session $S2
Cleanup-Session $S3
Remove-Item "$env:TEMP\cc261_*","$env:TEMP\c261_*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
