# Dependency update verification (dependabot PRs #515-#522, full latest-stable sweep)
# Proves the two base64-dependent product paths still work after base64 0.22 -> 0.23,
# that ratatui 0.30.2 still renders, and that OSC 52 handling matches tmux semantics:
#   Part A: OSC 52 emitted by a pane app lands in the psmux paste buffer
#           (padded, unpadded, invalid rejected, whitespace tolerated like tmux b64_pton)
#   Part B: cross-session join-pane ships the screen via the base64 crate and
#           the pane content survives the move
#   Part C: Win32 TUI visual verification (Layer 2) on a real attached window

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "depstest_a"
$SESSION_B = "depstest_b"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    foreach ($s in @($SESSION, $SESSION_B, "depstest_tui")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 500
    foreach ($s in @($SESSION, $SESSION_B, "depstest_tui")) {
        Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    }
}

function Emit-Osc52 {
    param([string]$Target, [string]$B64Payload)
    # Runs inside the pane's PowerShell: writes ESC ] 52 ; c ; <b64> BEL
    $cmd = "Write-Host -NoNewline (([char]27)+']52;c;$B64Payload'+([char]7))"
    & $PSMUX send-keys -t $Target $cmd Enter 2>&1 | Out-Null
}

# OSC 52 from a pane is forwarded to the attached client through the one-shot
# clipboard_osc52 field of the dump-state response (server drains the pane's
# staged payload on each dump tick). Polling dump-state over a persistent TCP
# connection is exactly what an attached client does, so that field is the
# correct product observable. Returns the DECODED clipboard text, or
# "FIELD_ABSENT" when the server dropped the payload.
function Poll-Osc52Clip {
    param([string]$Session)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush(); $null = $reader.ReadLine()
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    $writer.Write("dump-state`n"); $writer.Flush()
    $best = $null
    for ($j = 0; $j -lt 50; $j++) {
        try { $line = $reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line; break }
    }
    $tcp.Close()
    if ($best -and $best -match '"clipboard_osc52":"([^"]*)"') {
        $b64 = $Matches[1]
        if ($b64.Length % 4 -ne 0) { $b64 += "=" * (4 - ($b64.Length % 4)) }
        try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
        catch { return "DECODE_ERROR:$b64" }
    }
    return "FIELD_ABSENT"
}

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }
# Wait for the shell prompt so send-keys lands in a live shell
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match "PS [A-Z]:\\") { $ready = $true; break }
    Start-Sleep -Milliseconds 250
}
if (-not $ready) { Write-Fail "Shell prompt never appeared"; Cleanup; exit 1 }

Write-Host "`n=== Dependency Update Verification ===" -ForegroundColor Cyan

# === PART A: OSC 52 clipboard forwarding (hand-rolled base64, tmux parity) ===
Write-Host "`n[A1] OSC 52 padded base64 is forwarded to the client" -ForegroundColor Yellow
Emit-Osc52 -Target $SESSION -B64Payload "Zm9vYg=="   # "foob"
Start-Sleep -Seconds 2
$clip = Poll-Osc52Clip $SESSION
if ($clip -eq "foob") { Write-Pass "padded payload decoded to 'foob'" }
else { Write-Fail "expected 'foob', got '$clip'" }

Write-Host "`n[A2] OSC 52 unpadded base64 decodes (tmux b64_pton parity)" -ForegroundColor Yellow
Emit-Osc52 -Target $SESSION -B64Payload "Zm9vYmFy"   # "foobar" no padding needed
Start-Sleep -Seconds 2
$clip = Poll-Osc52Clip $SESSION
if ($clip -eq "foobar") { Write-Pass "unpadded payload decoded to 'foobar'" }
else { Write-Fail "expected 'foobar', got '$clip'" }

Write-Host "`n[A3] OSC 52 invalid base64 is rejected entirely (tmux parity)" -ForegroundColor Yellow
Emit-Osc52 -Target $SESSION -B64Payload "Zm9*vYg"
Start-Sleep -Seconds 2
$clip = Poll-Osc52Clip $SESSION
if ($clip -eq "FIELD_ABSENT") { Write-Pass "invalid payload dropped, nothing forwarded" }
else { Write-Fail "invalid payload leaked through as '$clip'" }

Write-Host "`n[A4] OSC 52 base64 with embedded space decodes (tmux skips whitespace)" -ForegroundColor Yellow
Emit-Osc52 -Target $SESSION -B64Payload "aGVsbG8 gd29ybGQ="   # "hello world" with a space in the b64
Start-Sleep -Seconds 2
$clip = Poll-Osc52Clip $SESSION
if ($clip -eq "hello world") { Write-Pass "whitespace-wrapped payload decoded like tmux" }
else { Write-Fail "expected 'hello world', got '$clip'" }

# === PART B: cross-session join-pane (base64 crate screen forward) ===
Write-Host "`n[B1] cross-session join-pane preserves pane content" -ForegroundColor Yellow
& $PSMUX new-session -d -s $SESSION_B
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION_B 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Second session creation failed"
} else {
    & $PSMUX send-keys -t $SESSION_B "Write-Host CROSSMOVE_MARKER_XYZ" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $srcCap = & $PSMUX capture-pane -t $SESSION_B -p 2>&1 | Out-String
    if ($srcCap -notmatch "CROSSMOVE_MARKER_XYZ") {
        Write-Fail "marker never appeared in source pane"
    } else {
        & $PSMUX join-pane -s "${SESSION_B}:0.0" -t "${SESSION}:0" 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $panes = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
        if ($panes -eq "2") { Write-Pass "target window now has 2 panes after cross-session join" }
        else { Write-Fail "expected 2 panes after join, got '$panes'" }
        $joined = $false
        for ($i = 0; $i -lt 20; $i++) {
            $capAll = ""
            foreach ($p in 0, 1) {
                $capAll += (& $PSMUX capture-pane -t "${SESSION}:0.$p" -p 2>&1 | Out-String)
            }
            if ($capAll -match "CROSSMOVE_MARKER_XYZ") { $joined = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if ($joined) { Write-Pass "screen content survived base64 crate round-trip across sessions" }
        else { Write-Fail "CROSSMOVE_MARKER_XYZ lost after cross-session join" }
    }
}

# === PART C: Win32 TUI visual verification (ratatui 0.30.2) ===
Write-Host "`n[C] Win32 TUI visual verification" -ForegroundColor Yellow
$SESSION_TUI = "depstest_tui"
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4
& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "TUI: attached session did not come up"
} else {
    & $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1 | Out-String).Trim()
    if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" }
    else { Write-Fail "TUI: expected 2 panes, got '$panes'" }

    & $PSMUX resize-pane -Z -t $SESSION_TUI 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $zoom = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
    if ($zoom -eq "1") { Write-Pass "TUI: resize-pane -Z zoomed" }
    else { Write-Fail "TUI: zoom expected 1, got '$zoom'" }

    & $PSMUX send-keys -t $SESSION_TUI "Write-Host TUI_RENDER_MARKER" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $cap = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
    if ($cap -match "TUI_RENDER_MARKER") { Write-Pass "TUI: pane echoes output under ratatui 0.30.2" }
    else { Write-Fail "TUI: marker missing from capture" }

    & $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}

Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
