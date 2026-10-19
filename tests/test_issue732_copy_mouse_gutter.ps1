# Issue #732: with copy-mode-line-numbers on, a mouse click or drag in copy
# mode lands on a cell to the RIGHT of the pointer, by the width of the line
# number gutter.
#
# The gutter pushes the pane content right, so a content column cx is painted
# at view column gutter + cx. A mouse report carries the view column, and copy
# mode counts content columns, so the pointer column has to be brought back
# through the gutter. tmux does that with window_copy_cursor_unoffset
# (window-copy.c) at every one of its mouse entry points.
#
# The pane holds the alphabet on one row, so content column N is the Nth
# letter and the yank reads back as the letters the pointer covered. Each case
# selects C to F. Both mouse routes are driven from the CLI with no attached
# client: `pane-mouse`, which carries pane relative coordinates the way an
# attached client sends them, and the raw `mouse-down` / `mouse-drag` /
# `mouse-up` verbs, which carry screen coordinates.
#
# Before the fix: 3 passed, 7 failed. After: 10 passed, 0 failed.

$ErrorActionPreference = "Continue"
$env:PSMUX_NO_WARM = "1"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = "i732"
$SESS = "g1"
$LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }
function P { & $PSMUX -L $NS @args 2>&1 }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan
Write-Host ("version: " + (& $PSMUX -V)) -ForegroundColor Cyan

P kill-server | Out-Null
Start-Sleep -Milliseconds 300
P new-session -d -s $SESS -x 80 -y 24 | Out-Null
$up = $false
for ($i = 0; $i -lt 40; $i++) {
    if ((P list-sessions | Out-String) -match $SESS) { $up = $true; break }
    Start-Sleep -Milliseconds 250
}
if (-not $up) { Write-Host "FATAL: no session" -ForegroundColor Red; exit 1 }
P set -g mouse on | Out-Null
# vi keys keep the cell under the pointer in the copy, so C to F yanks CDEF.
# Emacs keys leave that cell out, as tmux does; this suite is about the
# gutter, test_copy_selection_parity covers the emacs end cell.
P set -g mode-keys vi | Out-Null

# One row of known content. The gutter width is derived from the history the
# session actually has, below, rather than assumed.
Start-Sleep -Milliseconds 1200
P send-keys -t $SESS "echo $LETTERS" Enter | Out-Null

$row = -1
$cap = @()
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 300
    $cap = (P capture-pane -t $SESS -p | Out-String) -split "`r?`n"
    for ($j = 0; $j -lt $cap.Count; $j++) { if ($cap[$j].TrimEnd() -eq $LETTERS) { $row = $j } }
    if ($row -ge 0) { break }
}
if ($row -lt 0) {
    Write-Host "FATAL: the alphabet row is not on screen" -ForegroundColor Red
    $cap | ForEach-Object { Write-Host "    [$_]" }
    P kill-server | Out-Null
    exit 1
}
$paneId = ((P display-message -t $SESS -p "#{pane_id}" | Out-String).Trim()).TrimStart('%')
$hist = [int]((P display-message -t $SESS -p "#{history_size}" | Out-String).Trim())
$height = [int]((P display-message -t $SESS -p "#{pane_height}" | Out-String).Trim())

# window_copy_line_number_width: the digits of hsize + height + 1, at least 3,
# plus one column for the separating space.
$digits = ([string]($hist + $height + 1)).Length
if ($digits -lt 3) { $digits = 3 }
$GUTTER = $digits + 1
Write-Info "alphabet row $row, pane %$paneId, history $hist, height $height, gutter $GUTTER"

function Set-LineNumbers($mode) {
    P set -g copy-mode-line-numbers $mode | Out-Null
    Start-Sleep -Milliseconds 150
}

function Clear-Buffers {
    while ((P list-buffers | Out-String).Trim()) {
        P delete-buffer | Out-Null
        if ($script:guard++ -gt 20) { break }
    }
    $script:guard = 0
}

function Get-Buffer { (P show-buffer 2>&1 | Out-String).TrimEnd("`r", "`n") }

function Enter-CopyMode {
    P copy-mode -t $SESS | Out-Null
    Start-Sleep -Milliseconds 250
}

function Get-CopyCursorCol {
    $d = (P dump-state | Out-String)
    $m = [regex]::Match($d, '"copy_cursor_row":(\d+),"copy_cursor_col":(\d+)')
    if (-not $m.Success) { return -1 }
    return [int]$m.Groups[2].Value
}

# ---- the pane-mouse route: a press lands under the pointer ----
foreach ($case in @(@("off", 0), @("absolute", $GUTTER), @("relative", $GUTTER), @("default", $GUTTER))) {
    $mode = $case[0]; $shift = $case[1]
    Set-LineNumbers $mode
    Enter-CopyMode
    P pane-mouse $paneId 0 (7 + $shift) $row M | Out-Null
    Start-Sleep -Milliseconds 250
    $got = Get-CopyCursorCol
    if ($got -eq 7) {
        Write-Pass "$mode : a press on the H selects content column 7"
    } else {
        Write-Fail "$mode : a press on the H selected content column $got, wanted 7"
    }
    P send-keys -t $SESS -X cancel | Out-Null
    Start-Sleep -Milliseconds 200
}

# ---- the pane-mouse route: a drag yanks the letters under the pointer ----
foreach ($mode in @("off", "absolute")) {
    $shift = if ($mode -eq "off") { 0 } else { $GUTTER }
    Set-LineNumbers $mode
    Clear-Buffers
    Enter-CopyMode
    P pane-mouse $paneId 0 (2 + $shift) $row M | Out-Null
    Start-Sleep -Milliseconds 200
    P pane-mouse $paneId 32 (5 + $shift) $row M | Out-Null
    Start-Sleep -Milliseconds 200
    P pane-mouse $paneId 0 (5 + $shift) $row m | Out-Null
    Start-Sleep -Milliseconds 400
    $buf = Get-Buffer
    if ($buf -eq "CDEF") {
        Write-Pass "$mode : a drag over C to F yanks CDEF"
    } else {
        Write-Fail "$mode : a drag over C to F yanked [$buf], wanted CDEF"
    }
}

# ---- the raw screen-coordinate verbs ----
foreach ($mode in @("off", "absolute")) {
    $shift = if ($mode -eq "off") { 0 } else { $GUTTER }
    Set-LineNumbers $mode
    Clear-Buffers
    Enter-CopyMode
    # The window starts at column 0 and the status bar is at the bottom, so a
    # screen cell and the pane's view cell are the same thing here.
    P mouse-down (2 + $shift) $row | Out-Null
    Start-Sleep -Milliseconds 200
    P mouse-drag (5 + $shift) $row | Out-Null
    Start-Sleep -Milliseconds 200
    P mouse-up (5 + $shift) $row | Out-Null
    Start-Sleep -Milliseconds 400
    $buf = Get-Buffer
    if ($buf -eq "CDEF") {
        Write-Pass "$mode : the raw verbs yank CDEF"
    } else {
        Write-Fail "$mode : the raw verbs yanked [$buf], wanted CDEF"
    }
}

# ---- a press on the gutter itself is the first content column ----
Set-LineNumbers "absolute"
Enter-CopyMode
P pane-mouse $paneId 0 1 $row M | Out-Null
Start-Sleep -Milliseconds 250
$got = Get-CopyCursorCol
if ($got -eq 0) {
    Write-Pass "absolute : a press on the gutter selects content column 0"
} else {
    Write-Fail "absolute : a press on the gutter selected content column $got, wanted 0"
}
P send-keys -t $SESS -X cancel | Out-Null

# ---- the rightmost cell on screen is the last visible content column ----
Enter-CopyMode
P pane-mouse $paneId 0 79 $row M | Out-Null
Start-Sleep -Milliseconds 250
$got = Get-CopyCursorCol
$want = 80 - $GUTTER - 1
if ($got -eq $want) {
    Write-Pass "absolute : a press on the last column selects content column $want"
} else {
    Write-Fail "absolute : a press on the last column selected content column $got, wanted $want"
}

P kill-server | Out-Null
Start-Sleep -Milliseconds 300

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor Cyan
if ($script:Fail -gt 0) { exit 1 }
exit 0
