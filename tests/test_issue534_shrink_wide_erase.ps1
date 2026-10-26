# Issue #534: shrinking a row through a wide character's continuation, then
# erase-in-line, panics the vt100 grid.
#
# Root causes (all four confirmed by the parser suite):
#   1. Row::resize did not clear a wide cell whose continuation it truncated
#   2. Row::erase computed `cols() - if wide {2} else {1}`, underflowing u16
#   3. Screen::text computed `size.cols - width`, underflowing for a wide glyph
#      in a one column row (NOT in the report, found by sweeping shrink targets)
#   4. Grid::col_wrap carried the same `cols - width` pattern
#
# Severity depends on the build profile, measured rather than assumed:
#   debug   (overflow-checks on)  -> hard panic, the emulator's host dies
#   release (psmux ships release) -> no panic, but the row keeps a cell claiming
#                                    a width it cannot hold, which then survives
#                                    a contents_formatted round trip
#
# This script drives the psmux side: a pane holding CJK and emoji text is
# resized down through the width of those glyphs and back, repeatedly, and the
# server must stay alive and keep answering with a coherent grid. Unlike the
# #533 column geometry, this path IS psmux's own: pane resizes call the grid's
# set_size directly, so conhost is not in the way.
#
# tmux 3.4 parity oracle, shrinking a window holding CJK:
#   width=4 -> alive, content [CJK CJK]
#   width=3 -> alive, content [CJK]
#   width=2 -> alive, content [CJK]
#   width=1 -> alive, content []      <- glyph dropped, never a broken half

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue534"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkGray }

function Cleanup($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
}

function Test-Alive($name) {
    & $PSMUX has-session -t $name 2>$null
    return ($LASTEXITCODE -eq 0)
}

Write-Host "`n=== Issue #534: shrink through a wide char, then erase ===" -ForegroundColor Cyan

# === SETUP: a pane holding wide glyphs, then a vertical split so the panes
# can be squeezed narrow against each other ===
Cleanup $SESSION
& $PSMUX new-session -d -s $SESSION -x 80 -y 24 2>&1 | Out-Null
Start-Sleep -Seconds 3
if (-not (Test-Alive $SESSION)) {
    Write-Fail "Session creation failed"
    exit 1
}
Write-Pass "Session created"

& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
$panes = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "Split into 2 panes for the squeeze test" }
else { Write-Fail "Expected 2 panes, got '$panes'" }

# Fill both panes with wide glyphs: CJK, plus the #533 VS16 emoji, which is a
# promoted wide cell and must survive the same truncation.
$fill = @'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$cjk = [string][char]0x4F60 + [string][char]0x4E16 + [string][char]0x754C
$vs16 = [string][char]0x2733 + [string][char]0xFE0F
for ($i = 0; $i -lt 6; $i++) { [Console]::Out.WriteLine("$cjk$vs16 line$i") }
[Console]::Out.Flush()
'@
$fillFile = "$env:TEMP\psmux_i534_fill.ps1"
Set-Content -Path $fillFile -Value $fill -Encoding UTF8

& $PSMUX send-keys -t "${SESSION}.0" "pwsh -NoProfile -File `"$fillFile`"" Enter 2>&1 | Out-Null
& $PSMUX send-keys -t "${SESSION}.1" "pwsh -NoProfile -File `"$fillFile`"" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 5

$cap = & $PSMUX capture-pane -t "${SESSION}.0" -p 2>&1 | Out-String
if ($cap -match "line0") { Write-Pass "Wide glyph content is in the pane" }
else { Write-Fail "Pane never received the fill content" }

# === TEST 1: squeeze the pane down through the glyph width, one column at a time
Write-Host "`n[Test 1] Squeeze a pane holding wide glyphs down to minimum width" -ForegroundColor Yellow
$died = $false
$widths = @()
for ($i = 0; $i -lt 34; $i++) {
    & $PSMUX resize-pane -t "${SESSION}.0" -x 1 2>&1 | Out-Null
    Start-Sleep -Milliseconds 120
    if (-not (Test-Alive $SESSION)) { $died = $true; Write-Info "server died at iteration $i"; break }
    $w = (& $PSMUX display-message -t "${SESSION}.0" -p '#{pane_width}' 2>&1).Trim()
    $widths += $w
}
if (-not $died) {
    Write-Pass "Server survived $($widths.Count) narrowing resizes (final width $($widths[-1]))"
} else {
    Write-Fail "SERVER DIED while narrowing a pane holding wide glyphs"
}

# === TEST 2: erase-in-line against the squeezed pane ===
# This is the exact trigger: erase over a row whose wide glyph lost its
# continuation to the resize.
Write-Host "`n[Test 2] Erase-in-line over the squeezed pane" -ForegroundColor Yellow
if (Test-Alive $SESSION) {
    $eraser = @'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$e = [char]27
foreach ($seq in @("[K","[0K","[1K","[2K","[J","[2J")) {
    [Console]::Out.Write("$e$seq")
}
[Console]::Out.Write("ERASE_DONE")
[Console]::Out.Flush()
'@
    $eraserFile = "$env:TEMP\psmux_i534_erase.ps1"
    Set-Content -Path $eraserFile -Value $eraser -Encoding UTF8
    & $PSMUX send-keys -t "${SESSION}.0" "pwsh -NoProfile -File `"$eraserFile`"" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    if (Test-Alive $SESSION) {
        Write-Pass "Server survived every erase-in-line and erase-in-display variant"
    } else {
        Write-Fail "SERVER DIED on erase over the squeezed pane"
    }
} else {
    Write-Fail "Skipped: server already dead"
}

# === TEST 3: grow back and confirm the grid is still coherent ===
Write-Host "`n[Test 3] Grow the pane back and verify a usable grid" -ForegroundColor Yellow
if (Test-Alive $SESSION) {
    # Restore a genuinely usable geometry. A marker only proves the pane works
    # if the pane is wide enough to hold it on one row: at 3 columns any string
    # longer than 3 chars is wrapped and would never match contiguously.
    & $PSMUX resize-window -t $SESSION -x 80 -y 24 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    for ($i = 0; $i -lt 10; $i++) {
        & $PSMUX resize-pane -t "${SESSION}.0" -x 40 2>&1 | Out-Null
        Start-Sleep -Milliseconds 80
    }
    Start-Sleep -Milliseconds 600
    if (Test-Alive $SESSION) {
        $w = [int](& $PSMUX display-message -t "${SESSION}.0" -p '#{pane_width}' 2>&1).Trim()
        Write-Info "pane width after regrow: $w"
        if ($w -ge 20) {
            Write-Pass "Pane grew back to a usable width ($w columns)"
        } else {
            Write-Fail "Pane did not grow back, still $w columns"
        }
        & $PSMUX send-keys -t "${SESSION}.0" "echo REGROW_MARKER" Enter 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        # Strip line breaks before matching so a wrap cannot fake a failure.
        $cap = (& $PSMUX capture-pane -t "${SESSION}.0" -p 2>&1 | Out-String) -replace "`r|`n",""
        if ($cap -match "REGROW_MARKER") {
            Write-Pass "Pane still accepts input and echoes after the resize storm"
        } else {
            Write-Fail "Pane stopped echoing after the resize storm"
        }
    } else {
        Write-Fail "SERVER DIED while growing the pane back"
    }
} else {
    Write-Fail "Skipped: server already dead"
}

# === TEST 4: whole-window resize through the glyph width ===
Write-Host "`n[Test 4] Resize the whole window narrow with wide glyphs present" -ForegroundColor Yellow
if (Test-Alive $SESSION) {
    $survived = $true
    foreach ($w in @(20, 10, 5, 3, 2, 1, 2, 5, 40)) {
        & $PSMUX resize-window -t $SESSION -x $w -y 12 2>&1 | Out-Null
        Start-Sleep -Milliseconds 250
        if (-not (Test-Alive $SESSION)) {
            Write-Fail "SERVER DIED resizing the window to width $w"
            $survived = $false
            break
        }
    }
    if ($survived) { Write-Pass "Server survived window resizes down to 1 column and back" }
} else {
    Write-Fail "Skipped: server already dead"
}

# === TEST 5: TCP path still answers coherently ===
Write-Host "`n[Test 5] TCP server path answers after the resize storm" -ForegroundColor Yellow
if ((Test-Path "$psmuxDir\$SESSION.port") -and (Test-Alive $SESSION)) {
    try {
        $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
        $key  = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false))
        $writer.Write("AUTH $key`n"); $writer.Flush()
        if ($reader.ReadLine() -eq "OK") {
            $writer.Write("list-panes`n"); $writer.Flush()
            $stream.ReadTimeout = 5000
            try { $resp = $reader.ReadLine() } catch { $resp = $null }
            if ($resp) { Write-Pass "TCP list-panes answered: '$($resp.Substring(0, [Math]::Min(60, $resp.Length)))'" }
            else { Write-Fail "TCP list-panes returned nothing" }
        } else { Write-Fail "TCP AUTH failed" }
        $tcp.Close()
    } catch { Write-Fail "TCP path error: $_" }
} else {
    Write-Fail "Skipped: session or port file missing"
}

# ============================================================
# Win32 TUI VISUAL VERIFICATION (Layer 2, mandatory)
# ============================================================
Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

$SESSION_TUI = "issue534_tui_proof"
Cleanup $SESSION_TUI
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 5

if (Test-Alive $SESSION_TUI) {
    Write-Pass "TUI: real attached psmux window is alive"

    & $PSMUX split-window -h -t $SESSION_TUI 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $PSMUX send-keys -t "${SESSION_TUI}.0" "pwsh -NoProfile -File `"$fillFile`"" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 4

    # Squeeze the attached client's pane through the glyph width.
    for ($i = 0; $i -lt 25; $i++) {
        & $PSMUX resize-pane -t "${SESSION_TUI}.0" -x 1 2>&1 | Out-Null
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 500
    if (Test-Alive $SESSION_TUI) {
        Write-Pass "TUI: attached client survived the narrowing squeeze on wide glyphs"
    } else {
        Write-Fail "TUI: attached client died during the squeeze"
    }

    if (Test-Alive $SESSION_TUI) {
        & $PSMUX resize-pane -Z -t $SESSION_TUI 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
        $zoom = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_zoomed_flag}' 2>&1).Trim()
        if ($zoom -eq "1") { Write-Pass "TUI: resize-pane -Z still works afterwards" }
        else { Write-Fail "TUI: zoom expected 1, got '$zoom'" }

        $panesT = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1).Trim()
        if ($panesT -eq "2") { Write-Pass "TUI: both panes still present" }
        else { Write-Fail "TUI: expected 2 panes, got '$panesT'" }
    }
} else {
    Write-Fail "TUI: attached session never came up"
}

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Cleanup $SESSION
Cleanup $SESSION_TUI
Remove-Item "$env:TEMP\psmux_i534_*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
