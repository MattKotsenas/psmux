# Issue #498: copy-mode-vi keys `{` (previous-paragraph), `}` (next-paragraph)
# and `z` (scroll-middle).
#
# Before the fix these three keys were dead in copy mode: the client routes
# every plain printable key through handle_copy_mode_char(), whose match arm
# list had no entry for them, so the catch-all swallowed them. `{`/`}` existed
# only in the KeyCode table (which that path never reaches) and scroll-middle
# did not exist at all.
#
# Layers covered:
#   Part A  server/TCP path : send-keys -X previous-paragraph/next-paragraph/scroll-middle
#   Part B  real keystrokes : WriteConsoleInput injection of `{`, `}`, `z` into a live TUI
#   Part C  edge cases      : buffer ends, and z where centring is impossible
#   Part D  Win32 TUI proof : visible attached window driven + verified via CLI

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "test_issue498"
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
function X([string]$cmd) { & $PSMUX send-keys -t $SESSION -X $cmd 2>&1 | Out-Null; Start-Sleep -Milliseconds 110 }
function Key([string]$k) { & $INJ $script:ProcId $k | Out-Null; Start-Sleep -Milliseconds 700 }

# Park the copy cursor on a known line by stepping up from the bottom of the
# history until copy_cursor_line matches. Deterministic regardless of how tall
# the prompt or the pane happens to be.
function Park([string]$target) {
    X "history-bottom"
    X "bottom-line"
    for ($i = 0; $i -lt 250; $i++) {
        if ((St).line -eq $target) { return $true }
        X "cursor-up"
    }
    return $false
}

# === SETUP ===
Cleanup
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /optimize /out:$INJ "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
if (-not (Test-Path $INJ)) { Write-Fail "Could not build the keystroke injector"; exit 1 }

# Attached (visible) session: Part B needs a real console to inject keys into.
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
$script:ProcId = $proc.Id
Start-Sleep -Seconds 5

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

# Three paragraphs of 20 lines separated by single blank lines. Deliberately
# taller than the pane so there is plenty of real scrollback for `z` to work
# with in both directions.
& $PSMUX send-keys -t $SESSION "clear; 1..20 | % { `"A`$_`" }; `"`"; 1..20 | % { `"B`$_`" }; `"`"; 1..20 | % { `"C`$_`" }" Enter
Start-Sleep -Seconds 3

$rows = [int](Fmt '#{pane_height}')
$mid = [Math]::Floor(($rows - 1) / 2)
Write-Host "`n=== Issue #498 Tests (pane_height=$rows, middle row=$mid) ===" -ForegroundColor Cyan

& $PSMUX copy-mode -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
if ((St).inmode -ne "1") { Write-Fail "Could not enter copy mode"; Cleanup; exit 1 }

# === PART A: server / TCP path (send-keys -X) ===
Write-Host "`n[Part A] send-keys -X paragraph + scroll-middle" -ForegroundColor Yellow

if (Park "B5") {
    X "next-paragraph"
    $a = St
    if ($a.line -eq "") { Write-Pass "-X next-paragraph from B5 landed on the blank line after B20 (tmux semantics)" }
    else { Write-Fail "-X next-paragraph expected a blank line, got '$($a.line)'" }
} else { Write-Fail "Could not park cursor on B5" }

if (Park "B5") {
    X "previous-paragraph"
    $a = St
    if ($a.line -eq "") { Write-Pass "-X previous-paragraph from B5 landed on the blank line before B1" }
    else { Write-Fail "-X previous-paragraph expected a blank line, got '$($a.line)'" }
} else { Write-Fail "Could not park cursor on B5" }

# previous-paragraph must keep walking past the top of the viewport into the
# scrollback rather than stopping dead at screen row 0.
X "history-bottom"
X "top-line"
$b = St
X "previous-paragraph"
$a = St
if ($a.scroll -gt $b.scroll) { Write-Pass "-X previous-paragraph scrolls into history at the top of the viewport (scroll $($b.scroll) -> $($a.scroll))" }
else { Write-Fail "-X previous-paragraph stopped at the viewport edge (scroll $($b.scroll) -> $($a.scroll))" }

# scroll-middle with the cursor ABOVE the middle: older lines must be pulled in
# above it, so the offset grows by exactly (mid - y) and the cursor line holds.
X "history-bottom"
X "top-line"
$b = St
X "scroll-middle"
$a = St
if ($a.y -eq $mid -and $a.line -eq $b.line -and $a.scroll -eq ($b.scroll + ($mid - $b.y))) {
    Write-Pass "-X scroll-middle centred the cursor from above the middle (y $($b.y) -> $($a.y), line held at '$($a.line)', scroll $($b.scroll) -> $($a.scroll))"
} else {
    Write-Fail "-X scroll-middle from above: expected y=$mid line='$($b.line)' scroll=$($b.scroll + ($mid - $b.y)), got y=$($a.y) line='$($a.line)' scroll=$($a.scroll)"
}

# scroll-middle with the cursor BELOW the middle: the view scrolls down and the
# offset shrinks by exactly (y - mid).
X "history-top"
X "bottom-line"
$b = St
X "scroll-middle"
$a = St
if ($a.y -eq $mid -and $a.line -eq $b.line -and $a.scroll -eq ($b.scroll - ($b.y - $mid))) {
    Write-Pass "-X scroll-middle centred the cursor from below the middle (y $($b.y) -> $($a.y), line held at '$($a.line)', scroll $($b.scroll) -> $($a.scroll))"
} else {
    Write-Fail "-X scroll-middle from below: expected y=$mid line='$($b.line)' scroll=$($b.scroll - ($b.y - $mid)), got y=$($a.y) line='$($a.line)' scroll=$($a.scroll)"
}

# === PART B: real keystrokes through the client (the path that was broken) ===
Write-Host "`n[Part B] real { } z keystrokes via WriteConsoleInput" -ForegroundColor Yellow

if (Park "B5") {
    $b = St
    Key "{RBRACE}"
    $a = St
    if ($a.line -eq "" -and ($a.y -ne $b.y -or $a.scroll -ne $b.scroll)) {
        Write-Pass "key '}' jumped to the next paragraph boundary (y $($b.y) -> $($a.y))"
    } else {
        Write-Fail "key '}' did not jump: '$($b.line)'(y=$($b.y)) -> '$($a.line)'(y=$($a.y))"
    }
} else { Write-Fail "Could not park cursor on B5 for '}' test" }

if (Park "B5") {
    $b = St
    Key "{LBRACE}"
    $a = St
    if ($a.line -eq "" -and ($a.y -ne $b.y -or $a.scroll -ne $b.scroll)) {
        Write-Pass "key '{' jumped to the previous paragraph boundary (y $($b.y) -> $($a.y))"
    } else {
        Write-Fail "key '{' did not jump: '$($b.line)'(y=$($b.y)) -> '$($a.line)'(y=$($a.y))"
    }
} else { Write-Fail "Could not park cursor on B5 for '{' test" }

# Repeated `{` must keep walking backwards, not sit on the same boundary.
if (Park "C5") {
    Key "{LBRACE}"
    $first = St
    Key "{LBRACE}"
    $second = St
    $movedFurther = ($second.y -lt $first.y) -or ($second.scroll -gt $first.scroll)
    if ($movedFurther) { Write-Pass "repeated '{' keeps walking back one paragraph at a time (y $($first.y) -> $($second.y), scroll $($first.scroll) -> $($second.scroll))" }
    else { Write-Fail "second '{' did not move (y $($first.y) -> $($second.y), scroll $($first.scroll) -> $($second.scroll))" }
} else { Write-Fail "Could not park cursor on C5" }

# `z` via a real keystroke.
X "history-bottom"
X "top-line"
$b = St
Key "z"
$a = St
if ($a.y -eq $mid -and $a.line -eq $b.line -and $a.scroll -eq ($b.scroll + ($mid - $b.y))) {
    Write-Pass "key 'z' centred the cursor line (y $($b.y) -> $($a.y), line held at '$($a.line)', scroll $($b.scroll) -> $($a.scroll))"
} else {
    Write-Fail "key 'z': expected y=$mid line='$($b.line)' scroll=$($b.scroll + ($mid - $b.y)), got y=$($a.y) line='$($a.line)' scroll=$($a.scroll)"
}

# === PART C: edge cases ===
Write-Host "`n[Part C] Edge cases" -ForegroundColor Yellow

# z where centring is impossible: at the very top of the history with the
# cursor above the middle there is nothing left to pull in above it.
X "history-top"
X "top-line"
$b = St
X "scroll-middle"
$a = St
if ($a.scroll -eq $b.scroll -and $a.y -eq $b.y) { Write-Pass "scroll-middle is a no-op when there is nothing to scroll (tmux clamping)" }
else { Write-Fail "scroll-middle moved the view with no room: y $($b.y) -> $($a.y), scroll $($b.scroll) -> $($a.scroll)" }

# `{` at the very top of the history must stop, not spin or wrap
X "history-top"
X "top-line"
for ($i = 0; $i -lt 8; $i++) { X "previous-paragraph" }
$a1 = St
X "previous-paragraph"
$a2 = St
if ($a1.y -eq $a2.y -and $a1.scroll -eq $a2.scroll) { Write-Pass "previous-paragraph stops at the top of the history instead of wrapping" }
else { Write-Fail "previous-paragraph kept moving past the top: y $($a1.y) -> $($a2.y), scroll $($a1.scroll) -> $($a2.scroll)" }

# `}` at the very bottom must stop too
X "history-bottom"
X "bottom-line"
for ($i = 0; $i -lt 8; $i++) { X "next-paragraph" }
$a1 = St
X "next-paragraph"
$a2 = St
if ($a1.y -eq $a2.y -and $a1.scroll -eq $a2.scroll) { Write-Pass "next-paragraph stops at the bottom of the history instead of wrapping" }
else { Write-Fail "next-paragraph kept moving past the bottom: y $($a1.y) -> $($a2.y), scroll $($a1.scroll) -> $($a2.scroll)" }

# Unrelated copy-mode motions must be unaffected by the new match arms
if (Park "B5") {
    X "cursor-up"
    $l = (St).line
    if ($l -eq "B4") { Write-Pass "regression guard: cursor-up still works alongside the new bindings" }
    else { Write-Fail "regression guard: cursor-up from B5 gave '$l'" }
} else { Write-Fail "regression guard: could not park on B5" }

# === PART D: Win32 TUI verification ===
Write-Host "`n[Part D] Win32 TUI verification" -ForegroundColor Yellow
if ((Fmt '#{pane_in_mode}').Trim() -eq "1") { Write-Pass "TUI: still in copy mode after all paragraph/scroll navigation" }
else { Write-Fail "TUI: fell out of copy mode" }

X "cancel"
Start-Sleep -Milliseconds 400
if ((Fmt '#{pane_in_mode}').Trim() -eq "0") { Write-Pass "TUI: cancel leaves copy mode cleanly" }
else { Write-Fail "TUI: still in copy mode after cancel" }

& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 900
$panes = (Fmt '#{window_panes}').Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window still works (2 panes)" }
else { Write-Fail "TUI: expected 2 panes, got $panes" }

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
