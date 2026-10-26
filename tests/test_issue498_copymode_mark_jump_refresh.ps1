# Issue #498 (part 2): the remaining copy-mode-vi keys.
#
#   X    set-mark            record the cursor position
#   M-x  jump-to-mark        swap cursor and mark (twice returns you)
#   ;    jump-again          repeat the last f/F/t/T
#   ,    jump-reverse        repeat the last f/F/t/T the other way
#   r    refresh-from-pane   copy the pane's current output in once (tmux 3.7,
#                            discussion #694; it used to toggle a live follow)
#
# Before the fix set-mark/jump-to-mark and refresh had no implementation at
# all, and jump-again/jump-reverse were empty stubs in the server -X match
# because no last-jump state was ever recorded.
#
# NOT covered: `P` toggle-position. tmux toggles a position indicator that
# psmux does not render, so there is no underlying state to toggle. Binding
# the key would be a no-op dressed up as parity.
#
# Layers: server -X path, real keystrokes via WriteConsoleInput, edge cases,
# and Win32 TUI verification.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "test_issue498b"
$INJ = "$env:TEMP\psmux_injector.exe"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Fmt([string]$f) { (& $PSMUX display-message -t $SESSION -p $f 2>&1 | Out-String).TrimEnd("`r","`n") }
function St {
    [pscustomobject]@{
        line   = (Fmt '#{copy_cursor_line}').Trim()
        x      = [int](Fmt '#{copy_cursor_x}').Trim()
        y      = [int](Fmt '#{copy_cursor_y}').Trim()
        scroll = [int](Fmt '#{scroll_position}').Trim()
        inmode = (Fmt '#{pane_in_mode}').Trim()
    }
}
function X([string]$cmd) { & $PSMUX send-keys -t $SESSION -X $cmd 2>&1 | Out-Null; Start-Sleep -Milliseconds 120 }
function Key([string]$k) { & $INJ $script:ProcId $k | Out-Null; Start-Sleep -Milliseconds 650 }
function Park([string]$target) {
    X "history-bottom"; X "bottom-line"
    for ($i = 0; $i -lt 250; $i++) { if ((St).line -eq $target) { return $true }; X "cursor-up" }
    return $false
}

# === SETUP ===
Cleanup
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /optimize /out:$INJ "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
if (-not (Test-Path $INJ)) { Write-Fail "Could not build the keystroke injector"; exit 1 }

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
$script:ProcId = $proc.Id
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

# Each line carries several 'x' so f/;/, have somewhere to go, and enough
# lines overall that the mark can live off-screen in the scrollback.
& $PSMUX send-keys -t $SESSION "clear; 1..20 | % { `"axbxcxdxe A`$_`" }; `"`"; 1..20 | % { `"axbxcxdxe B`$_`" }" Enter
Start-Sleep -Seconds 3

Write-Host "`n=== Issue #498 part 2: mark, jump repeat, refresh ===" -ForegroundColor Cyan
& $PSMUX copy-mode -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
if ((St).inmode -ne "1") { Write-Fail "Could not enter copy mode"; Cleanup; exit 1 }

# === PART A: server / TCP path ===
Write-Host "`n[Part A] send-keys -X set-mark / jump-to-mark / jump-again / jump-reverse" -ForegroundColor Yellow

if (Park "axbxcxdxe B2") {
    X "set-mark"
    $marked = St
    X "cursor-up"; X "cursor-up"; X "cursor-up"; X "cursor-up"
    $away = St
    X "jump-to-mark"
    $back = St
    if ($back.line -eq $marked.line -and $back.y -eq $marked.y) {
        Write-Pass "-X jump-to-mark returned to the mark ('$($away.line)' -> '$($back.line)')"
    } else {
        Write-Fail "-X jump-to-mark expected '$($marked.line)' (y=$($marked.y)), got '$($back.line)' (y=$($back.y))"
    }
    # tmux swaps rather than just moving, so a second jump goes back again
    X "jump-to-mark"
    $swapped = St
    if ($swapped.line -eq $away.line -and $swapped.y -eq $away.y) {
        Write-Pass "-X jump-to-mark swaps: a second press returns to '$($away.line)' (tmux semantics)"
    } else {
        Write-Fail "second -X jump-to-mark expected '$($away.line)' (y=$($away.y)), got '$($swapped.line)' (y=$($swapped.y))"
    }
} else { Write-Fail "Could not park on B2 for the mark test" }

if (Park "axbxcxdxe B2") {
    X "start-of-line"
    $p0 = St
    X "jump-forward"
    & $PSMUX send-keys -t $SESSION "x" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $p1 = St
    X "jump-again"
    $p2 = St
    X "jump-again"
    $p3 = St
    if ($p1.x -gt $p0.x) { Write-Pass "f x moved to the first 'x' (col $($p0.x) -> $($p1.x))" }
    else { Write-Fail "f x did not move (col $($p0.x) -> $($p1.x))" }
    if ($p2.x -gt $p1.x) { Write-Pass "-X jump-again advanced to the next 'x' (col $($p1.x) -> $($p2.x))" }
    else { Write-Fail "-X jump-again did not advance (col $($p1.x) -> $($p2.x))" }
    if ($p3.x -gt $p2.x) { Write-Pass "-X jump-again repeats again (col $($p2.x) -> $($p3.x))" }
    else { Write-Fail "second -X jump-again did not advance (col $($p2.x) -> $($p3.x))" }

    X "jump-reverse"
    $p4 = St
    if ($p4.x -lt $p3.x) { Write-Pass "-X jump-reverse went back the other way (col $($p3.x) -> $($p4.x))" }
    else { Write-Fail "-X jump-reverse did not go back (col $($p3.x) -> $($p4.x))" }

    # jump-reverse must not rewrite the stored direction: another jump-again
    # still has to move forwards.
    X "jump-again"
    $p5 = St
    if ($p5.x -gt $p4.x) { Write-Pass "jump-reverse leaves the stored direction alone (jump-again still forward: $($p4.x) -> $($p5.x))" }
    else { Write-Fail "jump-again after jump-reverse went the wrong way ($($p4.x) -> $($p5.x))" }
} else { Write-Fail "Could not park on B2 for the jump-again test" }

# t/T repeat: the classic case where a naive implementation stalls
if (Park "axbxcxdxe B3") {
    X "start-of-line"
    X "jump-to-forward"
    & $PSMUX send-keys -t $SESSION "x" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $t1 = St
    X "jump-again"
    $t2 = St
    if ($t2.x -gt $t1.x) { Write-Pass "jump-again after 't' advances instead of stalling (col $($t1.x) -> $($t2.x))" }
    else { Write-Fail "jump-again after 't' stalled (col $($t1.x) -> $($t2.x))" }
} else { Write-Fail "Could not park on B3 for the t-repeat test" }

# refresh-from-pane toggle
if (Park "axbxcxdxe A5") {
    $b = St
    X "refresh-from-pane"
    $a = St
    # tmux 3.7 keeps the line at the top of the view: with nothing new
    # printed the offset stays where it was (window_copy_cmd_refresh_from_pane).
    if ($a.scroll -ge $b.scroll -and $b.scroll -gt 0) {
        Write-Pass "-X refresh-from-pane kept the reader's place (scroll $($b.scroll) -> $($a.scroll))"
    } else {
        Write-Fail "-X refresh-from-pane: expected the scroll offset to stay at or above $($b.scroll), got $($a.scroll)"
    }
    if ((St).inmode -eq "1") { Write-Pass "refresh-from-pane stays in copy mode" }
    else { Write-Fail "refresh-from-pane dropped out of copy mode" }
    X "refresh-toggle"   # tmux's automatic refresh, on and straight off again
    X "refresh-toggle"
    if ((St).inmode -eq "1") { Write-Pass "refresh-toggle alias accepted and still in copy mode" }
    else { Write-Fail "refresh-toggle alias dropped out of copy mode" }
} else { Write-Fail "Could not park on A5 for the refresh test" }

# === PART B: real keystrokes ===
Write-Host "`n[Part B] real X / M-x / ; / , keystrokes via WriteConsoleInput" -ForegroundColor Yellow

if (Park "axbxcxdxe B4") {
    Key "X"
    $marked = St
    X "cursor-up"; X "cursor-up"; X "cursor-up"
    $away = St
    Key "{ALT:x}"
    $back = St
    if ($back.line -eq $marked.line -and $back.y -eq $marked.y) {
        Write-Pass "key 'X' then 'M-x' returned to the mark ('$($away.line)' -> '$($back.line)')"
    } else {
        Write-Fail "key M-x expected '$($marked.line)' (y=$($marked.y)), got '$($back.line)' (y=$($back.y))"
    }
} else { Write-Fail "Could not park on B4 for the keystroke mark test" }

if (Park "axbxcxdxe B5") {
    X "start-of-line"
    X "jump-forward"
    & $PSMUX send-keys -t $SESSION "x" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $k1 = St
    Key ";"
    $k2 = St
    if ($k2.x -gt $k1.x) { Write-Pass "key ';' repeated the jump (col $($k1.x) -> $($k2.x))" }
    else { Write-Fail "key ';' did nothing (col $($k1.x) -> $($k2.x))" }
    Key ","
    $k3 = St
    if ($k3.x -lt $k2.x) { Write-Pass "key ',' reversed the jump (col $($k2.x) -> $($k3.x))" }
    else { Write-Fail "key ',' did nothing (col $($k2.x) -> $($k3.x))" }
} else { Write-Fail "Could not park on B5 for the keystroke jump test" }

# === PART C: edge cases ===
Write-Host "`n[Part C] Edge cases" -ForegroundColor Yellow

# jump-again with no previous jump must be a harmless no-op
& $PSMUX send-keys -t $SESSION -X cancel 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX copy-mode -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
if (Park "axbxcxdxe B6") {
    $b = St
    X "jump-again"
    X "jump-reverse"
    $a = St
    if ($a.x -eq $b.x -and $a.y -eq $b.y -and (St).inmode -eq "1") {
        Write-Pass "jump-again/jump-reverse with no prior jump are harmless no-ops"
    } else {
        Write-Fail "jump-again with no prior jump moved the cursor ($($b.x),$($b.y)) -> ($($a.x),$($a.y))"
    }
} else { Write-Fail "Could not park on B6" }

# jump-to-mark with no mark set must be a no-op (copy mode was just re-entered)
$b = St
X "jump-to-mark"
$a = St
if ($a.x -eq $b.x -and $a.y -eq $b.y) { Write-Pass "jump-to-mark with no mark set is a no-op" }
else { Write-Fail "jump-to-mark with no mark moved the cursor ($($b.x),$($b.y)) -> ($($a.x),$($a.y))" }

# The mark survives a jump across the scrollback boundary
if (Park "axbxcxdxe B8") {
    X "set-mark"
    $marked = St
    X "history-top"
    $far = St
    X "jump-to-mark"
    $back = St
    if ($back.line -eq $marked.line) {
        Write-Pass "mark survives a jump from the top of the history back down ('$($far.line)' -> '$($back.line)')"
    } else {
        Write-Fail "mark lost across scrollback: expected '$($marked.line)', got '$($back.line)'"
    }
} else { Write-Fail "Could not park on B8" }

# Regression guard: previously fixed keys still work alongside the new arms.
# Park inside the A paragraph, which is the one followed by a blank separator
# (the B paragraph runs straight into the shell prompt, where stopping at the
# end of the buffer is the correct behaviour rather than a blank line).
if (Park "axbxcxdxe A7") {
    X "cursor-up"
    if ((St).line -eq "axbxcxdxe A6") { Write-Pass "regression guard: cursor-up unaffected" }
    else { Write-Fail "regression guard: cursor-up gave '$((St).line)'" }
    X "next-paragraph"
    if ((St).line -eq "") { Write-Pass "regression guard: next-paragraph (#498 part 1) still works" }
    else { Write-Fail "regression guard: next-paragraph gave '$((St).line)'" }
} else { Write-Fail "regression guard: could not park on A7" }

# === PART D: Win32 TUI verification ===
Write-Host "`n[Part D] Win32 TUI verification" -ForegroundColor Yellow
if ((Fmt '#{pane_in_mode}').Trim() -eq "1") { Write-Pass "TUI: still in copy mode after all mark/jump/refresh work" }
else { Write-Fail "TUI: fell out of copy mode" }

X "cancel"
Start-Sleep -Milliseconds 400
if ((Fmt '#{pane_in_mode}').Trim() -eq "0") { Write-Pass "TUI: cancel leaves copy mode cleanly" }
else { Write-Fail "TUI: still in copy mode after cancel" }

& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 900
if ((Fmt '#{window_panes}').Trim() -eq "2") { Write-Pass "TUI: split-window still works (2 panes)" }
else { Write-Fail "TUI: expected 2 panes, got $((Fmt '#{window_panes}').Trim())" }

& $PSMUX resize-pane -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
if ((Fmt '#{window_zoomed_flag}').Trim() -eq "1") { Write-Pass "TUI: resize-pane -Z still zooms" }
else { Write-Fail "TUI: zoom failed" }

# === TEARDOWN ===
Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
