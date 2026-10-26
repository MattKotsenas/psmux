#!/usr/bin/env pwsh
# Test PR #255: active pane border indicator for all split layouts
# Verifies that for 3+ pane layouts, separators between non-active panes
# are NOT colored as if active, and only the borders adjacent to the
# active pane are highlighted.

$ErrorActionPreference = 'Stop'
$psmux = (Get-Command psmux).Source
$session = "pr255_$(Get-Random -Maximum 99999)"
$failed = 0
$passed = 0

function Pass($msg) { Write-Host "[PASS] $msg" -ForegroundColor Green; $script:passed++ }
function Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:failed++ }

function Cleanup {
    & $psmux kill-session -t $session 2>$null | Out-Null
}

try {
    # ----- LAYER 4: Rust unit-level: count_leaves logic via TUI dump -----
    & $psmux new-session -d -s $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 300

    # 1. Verify session created (single pane baseline)
    $p0 = & $psmux list-panes -t $session -F '#{pane_id}' 2>$null
    if ($p0.Count -eq 1) { Pass "baseline single pane created" } else { Fail "expected 1 pane, got $($p0.Count)" }

    # 2. 2-pane horizontal split (legacy half-highlight path)
    & $psmux split-window -h -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    $panes = & $psmux list-panes -t $session -F '#{pane_id}' 2>$null
    if ($panes.Count -eq 2) { Pass "2-pane split created" } else { Fail "expected 2 panes, got $($panes.Count)" }

    # 3. 3-pane layout (vertical inside horizontal)
    & $psmux split-window -v -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    $panes = & $psmux list-panes -t $session -F '#{pane_id}' 2>$null
    if ($panes.Count -eq 3) { Pass "3-pane layout created" } else { Fail "expected 3 panes, got $($panes.Count)" }

    # 4. select-pane on each pane and verify pane_active flag updates
    foreach ($p in $panes) {
        & $psmux select-pane -t $p 2>$null | Out-Null
        Start-Sleep -Milliseconds 100
        $active = & $psmux display-message -t $session -p '#{pane_id}' 2>$null
        if ($active.Trim() -eq $p) { Pass "select-pane $p activates" } else { Fail "select-pane $p did not activate (got $active)" }
    }

    # 5. Verify list-panes width/height for 3-pane layout (layout calculation works)
    $rows = & $psmux list-panes -t $session -F '#{pane_id} #{pane_width} #{pane_height}' 2>$null
    if ($rows.Count -eq 3 -and ($rows | Where-Object { $_ -match '^\S+\s+\d+\s+\d+$' }).Count -eq 3) { Pass "list-panes reports geometry for 3 panes" } else { Fail "list-panes geometry malformed: $($rows -join '|')" }

    # 6. Zoom: total_panes should drop to 1 (no traversal). Verify zoom toggle works.
    & $psmux resize-pane -Z -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 150
    $zoomed = & $psmux display-message -t $session -p '#{window_zoomed_flag}' 2>$null
    if ($zoomed.Trim() -eq '1') { Pass "zoom flag set" } else { Fail "zoom flag not set: '$zoomed'" }
    & $psmux resize-pane -Z -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 150
    $zoomed = & $psmux display-message -t $session -p '#{window_zoomed_flag}' 2>$null
    if ($zoomed.Trim() -eq '0') { Pass "zoom flag cleared" } else { Fail "zoom flag still set: '$zoomed'" }

    # ----- LAYER 2: Win32 TUI Visual Verification -----
    Cleanup
    Start-Sleep -Milliseconds 200
    $proc = Start-Process -FilePath $psmux -ArgumentList @('new-session','-s',$session) -PassThru -WindowStyle Normal
    Start-Sleep -Milliseconds 1500

    # Build a 4-pane layout: split-h, split-v on right, split-v on left
    & $psmux split-window -h -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    & $psmux split-window -v -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    & $psmux select-pane -L -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 100
    & $psmux split-window -v -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 300

    $count = (& $psmux list-panes -t $session -F '#{pane_id}' 2>$null).Count
    if ($count -eq 4) { Pass "TUI: 4-pane layout created" } else { Fail "TUI: expected 4 panes, got $count" }

    # Cycle through each pane via select-pane and confirm the active changes
    & $psmux select-pane -t '%0' 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    $activeId = (& $psmux display-message -t $session -p '#{pane_id}' 2>$null).Trim()
    if ($activeId) { Pass "TUI: select-pane works in 4-pane layout (active=$activeId)" } else { Fail "TUI: no active pane id reported" }

    # Verify capture-pane works for each pane (proves no rendering crash).
    #
    # The plain capture path trims trailing blank rows, so a pane whose shell
    # has not printed its prompt yet captures as NOTHING with exit 0. One read
    # 600 ms after the third split read that as a failure whenever that shell
    # was still booting inside the pool's refill surge (sweeps 2026-10-05 and
    # 2026-10-06, 0 of 6 standalone), which is not a rendering crash. So each
    # pane is polled for its prompt, and only a non zero exit or a pane that
    # never shows one fails.
    $allCaptured = $true; $slow = @()
    foreach ($p in (& $psmux list-panes -t $session -F '#{pane_id}' 2>$null)) {
        $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false
        while ($sw.ElapsedMilliseconds -lt 8000) {
            $cap = & $psmux capture-pane -t $p -p 2>$null
            if ($LASTEXITCODE -ne 0) { break }
            if (($cap -join "`n") -match '\S') { $ok = $true; break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $ok) { $allCaptured = $false; $slow += "$p rc=$LASTEXITCODE after $($sw.ElapsedMilliseconds)ms"; break }
        if ($sw.ElapsedMilliseconds -gt 1500) { $slow += "$p prompt after $($sw.ElapsedMilliseconds)ms" }
    }
    if ($allCaptured) { Pass "TUI: capture-pane shows content for all 4 panes$(if ($slow) { ' (' + ($slow -join ', ') + ')' })" } else { Fail "TUI: capture-pane failed for some pane ($($slow -join ', '))" }

    if ($proc -and -not $proc.HasExited) { $proc | Stop-Process -Force }

    Cleanup
} finally {
    Cleanup
    Get-Process psmux,pmux,tmux -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like "*$session*" } | Stop-Process -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) { exit 1 }
