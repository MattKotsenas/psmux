# Issue #757: the rename overlay opens empty, draws no cursor, and edits with
# Backspace alone.
#
# tmux reaches both renames through `command-prompt`: `,` is
# `command-prompt -I'#W' { rename-window -- '%%' }` and `$` is
# `command-prompt -I'#S' { rename-session -- '%%' }` (key-bindings.c:368 and
# :361, tag 3.7c). `-I` puts the current name in, the status prompt draws a
# cursor, and prompt.c gives it the whole line editor. psmux draws its own
# overlay instead, which until this change started empty, showed no cursor and
# took only Backspace.
#
# GROUND TRUTH: the text of the attached client's console (tests\conread.cs)
# for what the overlay holds, and its console cursor
# (GetConsoleScreenBufferInfo through tests\cursorprobe.cs) for where typing
# will land. Keys go in through tests\injector.cs.
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0; $script:TestsFailed = 0; $script:Skipped = 0
$script:Opened = @()

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor DarkYellow; $script:Skipped++ }
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

$NS   = "rp-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "rp"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_cr_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

$CONF = Join-Path $TMP "cr.conf"
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

function Inj($keys) { & $INJ $script:cpid $keys | Out-Null; Start-Sleep -Milliseconds 450 }

function Screen([switch]$Attr) {
    $o = Join-Path $TMP "screen.txt"
    $a = @("$script:cpid"); if ($Attr) { $a += "-a" }
    Start-Process -FilePath $RD -ArgumentList $a -Wait -WindowStyle Hidden -RedirectStandardOutput $o | Out-Null
    if (Test-Path $o) { return @(Get-Content $o) }
    return @()
}

# The overlay row: the one that reads "name: ...". Returns the row, the column
# the typed text starts at, and the line.
function Find-Name($screen) {
    for ($i = 0; $i -lt $screen.Count; $i++) {
        $line = [string]$screen[$i]
        $at = $line.IndexOf("name: ")
        if ($at -ge 0) { return @{ Row = $i; After = $at + 6; Line = $line } }
    }
    return $null
}

# What the overlay HOLDS, exactly. The box border comes back from the screen
# reader as non ASCII, so it is dropped before the trim. Compared with -eq, not
# -match: `name: rp` matches `name: rp-4f2a1c__rp` too, and that is the bug
# issue #759 is about.
function Name-Value($nm) {
    if (-not $nm) { return $null }
    $tail = [string]$nm.Line
    if ($nm.After -ge $tail.Length) { return "" }
    return ($tail.Substring($nm.After) -replace '[^ -~]', ' ').Trim()
}

function Overlay-Title($screen) {
    foreach ($l in $screen) {
        $s = [string]$l
        if ($s -match 'rename (session|window)') { return $Matches[0] }
    }
    return ""
}

function Cursor {
    $o = Join-Path $TMP ("cur_" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".json")
    Start-Process -FilePath $CUR -ArgumentList "$($script:cpid)", "`"$o`"", "3", "60", "1" `
        -Wait -WindowStyle Hidden | Out-Null
    if (-not (Test-Path $o)) { return $null }
    $j = Get-Content $o -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item $o -Force -EA SilentlyContinue
    return $j
}

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
Start-Sleep -Milliseconds 800
& $PSMUX -L $NS rename-window -t $SESS "alpha" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Write-Info "the window is called [$((( & $PSMUX -L $NS list-windows -a -F '#{window_name}') -join '').Trim())]"

# ── 1. the overlay opens on the current name ──

Write-Head "1. prefix , opens on the current window name"
Inj "^b{SLEEP:300},"
$pr = Screen
$nm = Find-Name $pr
Check ($null -ne $nm) "the overlay is on screen" "no overlay row found"
if ($nm) {
    Write-Info "row: '$($nm.Line.TrimEnd())'"
    Check ((Name-Value $nm) -eq 'alpha') "it holds the current name [alpha]" "it reads [$(Name-Value $nm)]"
}
Check ((Overlay-Title $pr) -eq "rename window") "the title is rename window" "the title reads [$(Overlay-Title $pr)]"

# ── 2. the cursor is on the overlay's row and visible ──
#
# Measured as a MOVEMENT from here on. The screen reader writes a box drawing
# border as two characters, so a column counted from the text in its dump is
# one off from the console's own column. A movement is immune to that, and
# movement is what this change is about.

Write-Head "2. the cursor is visible on the overlay's row"
$c = Cursor
$script:c0 = $null
if ($null -eq $c -or $c.error) {
    Write-Skip "the cursor probe could not attach"
} elseif ($nm) {
    Write-Info "cursor ($($c.cursorX),$($c.cursorY)) visible $($c.visible)/$($c.samples), overlay row $($nm.Row)"
    Check ($c.visible -eq $c.samples) "the cursor is visible with the overlay open" "the cursor is hidden: $($c.visible)/$($c.samples)"
    Check ($c.cursorY -eq $nm.Row) "the cursor is on the overlay's row" "the cursor is on row $($c.cursorY), the overlay is on $($nm.Row)"
    $script:c0 = $c.cursorX
}

# ── 3. typing appends, as it would in tmux ──

Write-Head "3. typing goes in at the cursor"
Inj "X"
$pr = Screen; $nm = Find-Name $pr
Check ((Name-Value $nm) -eq 'alphaX') "the name reads alphaX" "it reads [$(Name-Value $nm)]"

# ── 4. C-a goes to the start and typing lands there ──

Write-Head "4. C-a moves to the start"
# The buffer reads alphaX by now, six characters, and the cursor was at its end
# one character ago: typing X moved it one right of where test 2 read it.
$c = Cursor
$end = if ($c -and -not $c.error) { $c.cursorX } else { $null }
Inj "^a"
$c = Cursor
if ($null -ne $end -and $c -and -not $c.error) {
    Write-Info "cursor $end then $($c.cursorX), six characters apart is what C-a owes"
    Check (($end - $c.cursorX) -eq 6) "C-a moved the cursor to the start of alphaX" `
        "C-a moved it $($end - $c.cursorX) columns, not 6"
}
Inj "Z"
$pr = Screen; $nm = Find-Name $pr
Check ((Name-Value $nm) -eq 'ZalphaX') "the name reads ZalphaX" "it reads [$(Name-Value $nm)]"

# ── 5. Right then Delete removes the character under the cursor ──

Write-Head "5. Right, then C-d deletes under the cursor"
# The buffer is ZalphaX with the cursor just after the Z. Right puts it after
# the a, and C-d, which is tmux's delete-char, takes the l.
# C-d rather than the Delete key because tests\injector.cs has no token for it.
$c = Cursor
$before = if ($c -and -not $c.error) { $c.cursorX } else { $null }
Inj "{RIGHT}"
$c = Cursor
if ($null -ne $before -and $c -and -not $c.error) {
    Check (($c.cursorX - $before) -eq 1) "Right moved the cursor one column" `
        "Right moved it $($c.cursorX - $before) columns"
}
Inj "^d"
$pr = Screen; $nm = Find-Name $pr
Check ((Name-Value $nm) -eq 'ZaphaX') "the name reads ZaphaX" "it reads [$(Name-Value $nm)]"

# ── 6. the rename lands on the window ──

Write-Head "6. Enter renames the window"
Inj "{ENTER}"
Start-Sleep -Milliseconds 500
$w = ((& $PSMUX -L $NS list-windows -a -F '#{window_name}') -join '').Trim()
$s = ((& $PSMUX -L $NS list-sessions -F '#{session_name}') -join '').Trim()
Check ($w -eq "ZaphaX") "the window is ZaphaX" "the window reads [$w]"
Check ($s -eq $SESS) "the session is untouched" "the session reads [$s]"

# ── 7. the session rename opens on the session name ──

Write-Head "7. prefix `$ opens on the current session name"
Inj "^b{SLEEP:300}`$"
$pr = Screen; $nm = Find-Name $pr
Check ((Name-Value $nm) -eq $SESS) "it holds the current session name [$SESS]" "it reads [$(Name-Value $nm)]"
Check ((Overlay-Title $pr) -eq "rename session") "the title is rename session" "the title reads [$(Overlay-Title $pr)]"
Inj "{ESC}"

# ── 8. the overlay follows a rename, and is not the port file base ──
#
# `prefix $` used to open on PSMUX_SESSION_NAME, read once at attach. That is
# the port file base, so under `-L ns` it reads `ns__name`, and a later
# `rename-session` never reached it. The session name travels in every frame
# (`session_name` in the dump-state JSON), which is what the overlay reads now.
# Test 7 closed its overlay, so this opens one of its own.

Write-Head "8. the overlay follows a rename-session"
Inj "^b{SLEEP:300}`$"
Inj "^u"
Inj "beta"
$pr = Screen; $nm = Find-Name $pr
Check ((Name-Value $nm) -eq 'beta') "the field takes the new name" "it reads [$(Name-Value $nm)]"
Inj "{ENTER}"
Start-Sleep -Milliseconds 1200
$now = ((P list-sessions -F '#{session_name}') -join ' ').Trim()
Check ($now -eq 'beta') "the session is beta" "list-sessions reads [$now]"

Inj "^b{SLEEP:300}`$"
$pr = Screen; $nm = Find-Name $pr
Write-Info "second open reads [$(Name-Value $nm)]"
Check ((Name-Value $nm) -eq 'beta') "a second open holds the name the session has now" `
    "it reads [$(Name-Value $nm)], the name it had at attach"
Inj "{ESC}"

# The window rename is unaffected by the session rename, so the two overlays
# are not sharing a buffer.
Inj "^b{SLEEP:300},"
$pr = Screen; $nm = Find-Name $pr
Check ((Name-Value $nm) -eq 'ZaphaX') "prefix , still holds the window name" "it reads [$(Name-Value $nm)]"
Inj "{ESC}"

# ── 9. the default status-left shows the name too ──
#
# `status-left ''` in the rig config leaves the client's own `[#S] ` default in
# place, which came from the same attach time value.

Write-Head "9. the default status-left follows the rename"
$pr = Screen
$status = if ($pr.Count -ge 30) { ([string]$pr[29]) } else { "" }
Write-Info "status row: [$($status.Trim())]"
Check ($status -match '\[beta\]') "the status line reads [beta]" "it reads [$($status.Trim())]"
Check ($status -notmatch [regex]::Escape($NS)) "the -L namespace is not in the status line" `
    "the status line carries the namespace [$NS]"

# ── 10. C-c and C-g close the prompt, as tmux's prompt.c does ──
#
# Before, C-c went to the shell behind the overlay as a real interrupt on
# master, and did nothing at all once the overlay had an editor. A closed
# overlay must also be repainted away on an idle pane.

Write-Head "10. C-c and C-g close the overlay, with no side effects"
foreach ($k in "c", "g") {
    Inj "^b{SLEEP:300},"
    Check ($null -ne (Find-Name (Screen))) "prefix , opened the overlay" "no overlay before C-$k"
    Inj "^$k"
    Check ($null -eq (Find-Name (Screen))) "C-$k closed it" "the overlay is still drawn after C-$k"
}
$w = ((& $PSMUX -L $NS list-windows -a -F '#{window_name}') -join '').Trim()
Check ($w -eq "ZaphaX") "the window kept its name" "the window reads [$w]"

# ── 11. keys the overlay has no use for stay in it ──
#
# Tab, Up and F5 used to fall through to the pane while the overlay was up:
# PSReadLine recalled a history line into the shell behind it.

Write-Head "11. Tab, Up and F5 do not reach the pane"
$before = ((P capture-pane -p) -join "`n").TrimEnd()
Inj "^b{SLEEP:300},"
Inj "{MOD:09:09:0000}"
Inj "{UP}"
Inj "{F5}"
Check ((Name-Value (Find-Name (Screen))) -eq 'ZaphaX') "the overlay still holds ZaphaX" "it reads [$(Name-Value (Find-Name (Screen)))]"
Inj "{ESC}"
Start-Sleep -Milliseconds 600
$after = ((P capture-pane -p) -join "`n").TrimEnd()
Check ($before -eq $after) "the pane is unchanged" "the pane changed behind the overlay"

# ── 12. AltGr characters are typed ──
#
# Windows reports AltGr as Ctrl+Alt, so `@` on a German layout (AltGr+Q) is
# Char('@') with CONTROL and ALT. It is text, not a Ctrl chord.

Write-Head "12. AltGr @ is typed into the overlay"
Inj "^b{SLEEP:300},"
Inj "^u"
Inj "ab{MOD:51:40:0009}cd"
Check ((Name-Value (Find-Name (Screen))) -eq 'ab@cd') "the field reads ab@cd" "it reads [$(Name-Value (Find-Name (Screen)))]"
Inj "{ESC}"

# A rename-session done OUTSIDE this client is not covered here. It has to
# arrive in a frame, and the server answers dump-state with "NC" after a
# rename-session: RenameWindow sets meta_dirty and RenameSession does not, and
# combined_data_version carries no term for the name. Whether the new name
# reaches an attached client is then a race, measured as such, so there is
# nothing stable to assert here. That is the server's side of it and its own
# piece of work.

# ── Cleanup ──

Kill-Rig
Remove-Item $TMP -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed, $($script:Skipped) skipped ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
