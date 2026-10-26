# Discussion #694: tanaeakihiko's audit of the 51 default copy-mode-vi keys.
#
# Every check here drives an ATTACHED client with real keystrokes
# (tests\injector.cs writes console input records into the client's console)
# and reads what the user sees: the client's console screen and its colour
# attributes (tests\conread.cs -a) and the host cursor (tests\cursorprobe.cs).
#
# Measured on dd695ea, before the fixes:
#
#   1  Space lll then Escape         pane_in_mode 0 (tmux: 1, selection gone)
#   2  v                             selection_present 1 (tmux: rectangle on,
#                                    nothing selected)
#   3  r, then G                     drawn tick 12 while the pane was at 28
#   4a typing "row 7 alpha" into /   (search down) row7alpha
#   4b ?beta                         no row coloured, only the cursor cell
#   5  X                             marked row 7x120 like its neighbours
#   7  Space llll, then o            host cursor parked at x 93 both times
#                                    (copy cursor 92, then 88)
#   8  /abc C-a Z, Left              abcZ, then the prompt vanished
#
# tmux side: key-bindings.c:654 (Escape clear-selection), :705 (v
# rectangle-toggle), :656 (Space begin-selection), window-copy.c
# window_copy_cmd_refresh_from_pane (3.7) and window_copy_update_style,
# prompt.c prompt_key, options-table.c copy-mode-*-style.
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0; $script:TestsFailed = 0
$script:Opened = @()

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }
function Check($ok, $pass, $fail) { if ($ok) { Write-Pass $pass } else { Write-Fail $fail } }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null
# NO_COLOR makes the client draw without colour, and then no highlight can be
# seen in the console attributes at all.
Remove-Item Env:NO_COLOR -EA SilentlyContinue

$NS   = "d694-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "cmvi"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_d694_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null

function P { & $PSMUX -L $NS @args 2>&1 }
function D($f) { ((P display-message -t $SESS -p $f) -join '').Trim() }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
foreach ($tool in "conread", "injector", "cursorprobe") {
    $exe = Join-Path $TMP "$tool.exe"
    if ($csc -and (Test-Path $csc)) {
        & $csc /nologo /optimize /out:$exe (Join-Path $PSScriptRoot "$tool.cs") 2>&1 | Out-Null
    }
    if (-not (Test-Path $exe)) {
        Write-Fail "could not build tests\$tool.cs (csc.exe unavailable)"
        Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
        exit 1
    }
}
$RD  = Join-Path $TMP "conread.exe"
$INJ = Join-Path $TMP "injector.exe"
$CUR = Join-Path $TMP "cursorprobe.exe"

function Stop-Opened {
    foreach ($id in $script:Opened) { try { Stop-Process -Id $id -Force -EA SilentlyContinue } catch {} }
    $script:Opened = @()
}

function Kill-Rig {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Stop-Opened
    Get-ChildItem "$psmuxDir\${NS}__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

$CONF = Join-Path $TMP "d694.conf"
$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
@(
    "set -g default-shell $POWERSHELL",
    "set -g mode-keys vi",
    "set -g history-limit 2000",
    "set -g status-left ''"
) | Set-Content -Path $CONF -Encoding ASCII

function Start-Attached {
    $p = Start-Process -FilePath $PSMUX `
        -ArgumentList "-f",$CONF,"-L",$NS,"new-session","-s",$SESS,"-x","100","-y","30" -PassThru
    $script:Opened += $p.Id
    $portFile = Join-Path $psmuxDir "${NS}__${SESS}.port"
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path $portFile) {
            $port = (Get-Content $portFile -Raw).Trim()
            try {
                $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $t.Close()
                Start-Sleep -Milliseconds 2500
                return $p
            } catch {}
        }
    }
    return $null
}

# Real keystrokes into the attached client's console.
function Inj($keys) { & $INJ $script:cpid $keys | Out-Null; Start-Sleep -Milliseconds 450 }

function Screen([switch]$Attr) {
    $o = Join-Path $TMP "screen.txt"
    $a = @("$script:cpid"); if ($Attr) { $a += "-a" }
    Start-Process -FilePath $RD -ArgumentList $a -Wait -WindowStyle Hidden -RedirectStandardOutput $o | Out-Null
    if (Test-Path $o) { return @(Get-Content $o) }
    return @()
}

# The attribute runs of the first screen row whose text matches $pattern.
function Row-Attr($pattern) {
    foreach ($l in Screen -Attr) {
        if ($l -match '^\[attr ([^\]]+)\] (.*)$') {
            $runs = $Matches[1]; $text = $Matches[2]
            if ($text -match $pattern) { return $runs }
        }
    }
    return ""
}

function Status-Line { (Screen | Select-Object -Last 1) -join '' }

function Host-Cursor {
    $o = Join-Path $TMP "cursor.json"
    Remove-Item $o -EA SilentlyContinue
    Start-Process -FilePath $CUR -ArgumentList "$script:cpid",$o,"5","40" -Wait -WindowStyle Hidden | Out-Null
    if (Test-Path $o) { return (Get-Content $o -Raw | ConvertFrom-Json) }
    return $null
}

function Enter-Copy { P copy-mode -t $SESS | Out-Null; Start-Sleep -Milliseconds 700 }
function Leave-Copy { P send-keys -t $SESS -X cancel | Out-Null; Start-Sleep -Milliseconds 400 }

# ── Rig ──

Kill-Rig
$proc = Start-Attached
if (-not $proc) {
    Write-Fail "the attached client never came up"
    Kill-Rig
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}
$script:cpid = $proc.Id
for ($try = 0; $try -lt 4; $try++) {
    P send-keys -t $SESS 'cls; 1..80 | % { "row $_ alpha beta gamma" }' Enter | Out-Null
    Start-Sleep -Seconds 2
    if ([int]("0" + (D '#{history_size}')) -ge 40) { break }
    Write-Info "the pane is still empty after attempt $($try + 1); sending the range again"
}
Write-Info "history_size = $(D '#{history_size}')"

# ── 1. Escape is clear-selection ──

Write-Head "1. Escape clears the selection and stays in copy mode"
Enter-Copy
Inj "kk lll"
Check ((D '#{selection_present}') -eq "1") "Space starts a selection" "Space did not start a selection"
Inj "{ESC}"
Check ((D '#{pane_in_mode}') -eq "1") "Escape stays in copy mode" "Escape left copy mode (pane_in_mode $(D '#{pane_in_mode}'))"
Check ((D '#{selection_present}') -eq "0") "Escape cleared the selection" "the selection survived Escape"
Inj "{ESC}"
Check ((D '#{pane_in_mode}') -eq "1") "Escape with nothing selected does nothing" "Escape with no selection left copy mode"
Inj "q"
Check ((D '#{pane_in_mode}') -eq "0") "q leaves copy mode" "q did not leave copy mode"

# ── 4a. a space in the search prompt ──

Write-Head "4a. a space can be searched for"
Enter-Copy
Inj "/row 7 alpha"
$st = Status-Line
Check ($st -match '\(search down\) row 7 alpha') "the prompt shows [$($st.Trim())]" "the prompt reads [$($st.Trim())]"
Inj "{ENTER}"
$line = D '#{copy_cursor_line}'
Check ($line -match '^row 7 alpha') "the search found [$line]" "the search landed on [$line]"

# ── 4b. match highlighting ──

Write-Head "4b. every match is coloured, the current one differently"
Inj "?beta{ENTER}"
$cy = [int](D '#{copy_cursor_y}')
$rows = Screen -Attr
$cyan = 0; $magenta = 0
foreach ($l in $rows) {
    if ($l -match '^\[attr ([^\]]+)\]') {
        if ($Matches[1] -match '(^|,)48x4(,|$)') { $cyan++ }
        # The cursor cell of the current match is also reversed (0x4000).
        if ($Matches[1] -match '(^|,)(80x4|16464x1,80x3)(,|$)') { $magenta++ }
    }
}
Write-Info "rows with a cyan match: $cyan, with a magenta match: $magenta (cursor row $cy)"
Check ($cyan -ge 10) "the other matches are bg=cyan ($cyan rows)" "matches are not highlighted ($cyan cyan rows)"
Check ($magenta -eq 1) "the match under the cursor is bg=magenta" "no current match highlight ($magenta rows)"
Inj "n"
$curRow = (D '#{copy_cursor_line}')
$a = Row-Attr ([regex]::Escape($curRow))
Check ($a -match '(^|,)(80x4|16464x1,80x3)(,|$)') "n moves the current match [$a]" "after n the cursor row reads [$a]"

# ── 5. the marked line ──

Write-Head "5. the marked line is coloured"
Inj "{ESC}"
Inj "kkk"
$markLine = D '#{copy_cursor_line}'
Inj "X"
Inj "kkk"
$a = Row-Attr ("^" + [regex]::Escape($markLine))
Check ($a -match '(^|,)64x') "the marked row is bg=red [$a]" "the marked row reads [$a]"
$b = Row-Attr ("^" + [regex]::Escape((D '#{copy_cursor_line}')))
Check ($b -notmatch '64x') "other rows are not marked" "the cursor row is marked too [$b]"
Leave-Copy

# ── 2. v is rectangle-toggle ──

Write-Head "2. v toggles the rectangle, Space begins the selection"
Enter-Copy
Inj "?row 70 alpha{ENTER}"
Inj "v"
Check ((D '#{selection_present}') -eq "0") "v alone selects nothing" "v started a selection"
Inj " lllljj{ENTER}"
$buf = @((P show-buffer) | ForEach-Object { "$_" })
Write-Info ("buffer: " + (($buf | ForEach-Object { "[$_]" }) -join ' '))
$block = ($buf.Count -eq 3) -and (@($buf | Where-Object { $_.TrimEnd().Length -le 5 }).Count -eq 3)
Check $block "v then Space copies a block" "the copy is not a block"

# ── 7. the cursor inside a selection ──

Write-Head "7. the cursor is shown inside a selection"
Enter-Copy
Inj "kk0 llll"
$cx = [int](D '#{copy_cursor_x}'); $cyy = [int](D '#{copy_cursor_y}')
$c = Host-Cursor
Write-Info "copy cursor $cx,$cyy; host cursor $($c.cursorX),$($c.cursorY - $c.winTop) visible $($c.visible)/$($c.samples)"
Check ($c -and $c.visible -gt 0 -and $c.cursorX -eq $cx -and ($c.cursorY - $c.winTop) -eq $cyy) "the host cursor is on the moving end" "the host cursor is not on the copy cursor"
Inj "o"
$cx2 = [int](D '#{copy_cursor_x}')
$c = Host-Cursor
Write-Info "after o: copy cursor $cx2; host cursor $($c.cursorX) visible $($c.visible)/$($c.samples)"
Check ($cx2 -ne $cx -and $c.cursorX -eq $cx2 -and $c.visible -gt 0) "o moves the visible cursor to the other end" "o did not move the visible cursor"
Leave-Copy

# ── 8. line editing in the search prompt ──

Write-Head "8. the search prompt edits like tmux's"
Enter-Copy
Inj "/abc"
Inj "^a"
Inj "Z"
$st = Status-Line
Check ($st -match '\(search down\) Zabc') "C-a goes to the start [$($st.Trim())]" "C-a then Z gave [$($st.Trim())]"
Inj "{END}!"
$st = Status-Line
Check ($st -match '\(search down\) Zabc!') "End goes to the end" "End then ! gave [$($st.Trim())]"
Inj "{LEFT}{LEFT}"
$st = Status-Line
Check ($st -match '\(search down\) Zabc!') "the prompt stays drawn after Left" "Left made the prompt vanish [$($st.Trim())]"
Inj "{UP}"
$st = Status-Line
Check ($st -match '\(search down\) row 70 alpha') "Up recalls the last search" "Up gave [$($st.Trim())]"
Inj "{ESC}"
Check ((D '#{pane_in_mode}') -eq "1") "Escape closes the prompt and stays in copy mode" "Escape left copy mode"
Leave-Copy

# ── 3. refresh-from-pane ──

Write-Head "3. r copies new output in once and keeps the place"
P send-keys -t $SESS 'cls; 1..200 | % { "old$_" }; 0..60 | % { "tick $_"; Start-Sleep -Milliseconds 250 }' Enter | Out-Null
Start-Sleep -Seconds 3
function Last-Tick($lines) {
    $t = $lines | Where-Object { $_ -match 'tick (\d+)' } | Select-Object -Last 1
    if ($t -match 'tick (\d+)') { return [int]$Matches[1] }
    return -1
}
function Pane-Tick { Last-Tick @(P capture-pane -t $SESS -p) }
Enter-Copy
$entered = Last-Tick (Screen)
Start-Sleep -Seconds 2
$paneBefore = Pane-Tick
Inj "r"
Inj "G"
$drawn = Last-Tick (Screen)
Write-Info "copy mode entered at tick $entered, pane at $paneBefore before r, drawn after r G $drawn"
Check ($drawn -ge $paneBefore) "the new output is reachable after r (tick $drawn)" "r left the old screen (drawn $drawn, pane $paneBefore)"
Check ((D '#{pane_in_mode}') -eq "1") "r stays in copy mode" "r left copy mode"
# Scroll up 5 lines, let the pane print, and refresh: the top line stays.
Inj "^y^y^y^y^y"
$pos = [int](D '#{scroll_position}')
$top = (Screen | Select-Object -First 1)
Start-Sleep -Seconds 1
Inj "r"
$pos2 = [int](D '#{scroll_position}')
$top2 = (Screen | Select-Object -First 1)
Write-Info "before r: scroll_position $pos top [$($top.Trim())]; after r: $pos2 [$($top2.Trim())]"
Check ($pos2 -gt $pos) "the offset grows by the new lines ($pos -> $pos2)" "the offset did not follow ($pos -> $pos2)"
Check ($top2.Trim() -eq $top.Trim()) "the line on top stays where it was" "the top line moved"
Inj "^y^y^y^y^y^y^y^y^y^y"
$pos3 = [int](D '#{scroll_position}')
Check ($pos3 -eq $pos2 + 10) "scrolling still works after r ($pos2 -> $pos3)" "10 scroll-ups moved $pos2 -> $pos3"
Leave-Copy

# ── 3b. refresh-on, tmux's newer automatic refresh ──

Write-Head "3b. refresh-on follows output at the bottom and keeps the place above it"
Start-Sleep -Seconds 6   # let the first printer finish
P send-keys -t $SESS 'cls; 1..100 | % { "fill$_" }; 0..60 | % { "tock $_"; Start-Sleep -Milliseconds 250 }' Enter | Out-Null
Start-Sleep -Seconds 3
function Last-Tock($lines) {
    $t = $lines | Where-Object { $_ -match 'tock (\d+)' } | Select-Object -Last 1
    if ($t -match 'tock (\d+)') { return [int]$Matches[1] }
    return -1
}
Enter-Copy
P send-keys -t $SESS -X bottom-line | Out-Null
P send-keys -t $SESS -X refresh-on | Out-Null
$a = Last-Tock (Screen)
Start-Sleep -Seconds 3
$b = Last-Tock (Screen)
$pane = Last-Tock @(P capture-pane -t $SESS -p)
Write-Info "drawn $a, 3 s later $b, pane $pane"
Check ($b -gt $a -and $b -ge $pane - 2) "the view follows new output at the bottom" "the view did not follow ($a -> $b, pane $pane)"
P send-keys -t $SESS -X scroll-up | Out-Null
P send-keys -t $SESS -X scroll-up | Out-Null
Start-Sleep -Milliseconds 400
$p1 = [int](D '#{scroll_position}'); $t1 = (Screen | Select-Object -First 1)
Start-Sleep -Seconds 2
$p2 = [int](D '#{scroll_position}'); $t2 = (Screen | Select-Object -First 1)
Write-Info "scrolled up: $p1 -> $p2"
Check ($p2 -gt $p1 -and $t1.Trim() -eq $t2.Trim()) "above the bottom it keeps the place ($p1 -> $p2)" "the view moved or did not refresh ($p1 -> $p2)"
P send-keys -t $SESS -X refresh-off | Out-Null
Start-Sleep -Milliseconds 400
$p3 = [int](D '#{scroll_position}')
Start-Sleep -Seconds 1
Check ([int](D '#{scroll_position}') -eq $p3) "refresh-off stops it" "the view still refreshes after refresh-off"
Leave-Copy

# ── Teardown ──

Kill-Rig
Remove-Item $TMP -Recurse -Force -EA SilentlyContinue

Write-Host ""
Write-Host "Passed: $script:TestsPassed  Failed: $script:TestsFailed" `
    -ForegroundColor $(if ($script:TestsFailed -eq 0) { 'Green' } else { 'Red' })
exit $(if ($script:TestsFailed -eq 0) { 0 } else { 1 })
