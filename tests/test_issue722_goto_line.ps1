# Issue #722: copy-mode-vi has no `:` binding, and `send -X goto-line`
# never scrolls.
#
# tmux binds the goto line prompt to `:` in copy-mode-vi (key-bindings.c:608).
# psmux had no arm for it, and the verb behind it wrote the number into the copy
# cursor's screen row instead of moving the view, so no line of the scrollback
# could be reached.
#
# Measured on c802e3e with a 100x30 client and `1..200` in the pane, 3 runs:
#
#                                   #{scroll_position}   on screen
#   copy mode, then `:`             0                    (nothing)
#   then `1` and Enter              0                    (nothing)
#   send -X goto-line 1             0                    (nothing)
#
# With the fix, all three reach line 1, which is #{history_size} lines back.
#
# The prompt itself is drawn by the attached CLIENT on the status line, so
# capture-pane cannot see it. This suite launches a real attached client and
# reads its console screen with tests\conread.cs, the way the #702 suite does.
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

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null

$NS   = "i722-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "goto"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_i722_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null

function P { & $PSMUX -L $NS @args 2>&1 }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
$RD = Join-Path $TMP "conread.exe"
if ($csc -and (Test-Path $csc)) {
    & $csc /nologo /optimize /out:$RD (Join-Path $PSScriptRoot "conread.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $RD)) {
    Write-Fail "could not build tests\conread.cs (csc.exe unavailable); the prompt cannot be read"
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}

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

# The pane is filled with a PowerShell range, so the shell has to be PowerShell
# whatever the user's `default-shell` is. A config file passed with -f is read
# before the first window spawns, which is the only point where the option still
# has an effect.
$CONF = Join-Path $TMP "goto.conf"
$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
@(
    "set -g default-shell $POWERSHELL",
    "set -g mode-keys vi",
    "set -g copy-mode-line-numbers absolute",
    "set -g history-limit 2000"
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

function Get-ClientScreen($procId) {
    $o = Join-Path $TMP "screen.txt"; $e = Join-Path $TMP "screen_err.txt"
    Start-Process -FilePath $RD -ArgumentList "$procId" -Wait -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
    if (Test-Path $o) { return @(Get-Content $o) }
    return @()
}

# The prompt is a status message, so it lands on the status line rather than in
# the pane. Return the first row that carries it, trimmed.
function Get-Prompt($procId) {
    foreach ($r in Get-ClientScreen $procId) {
        if ($r -match '\(goto line\)') { return $r.Trim() }
    }
    return ""
}

function Wait-Prompt($procId, $want) {
    $last = ""
    for ($i = 0; $i -lt 20; $i++) {
        $last = Get-Prompt $procId
        if ($last -match [regex]::Escape($want)) { return $last }
        Start-Sleep -Milliseconds 250
    }
    return $last
}

function Pos { [int](((P display-message -t $SESS -p '#{scroll_position}') -join '').Trim()) }
function Hist { [int](((P display-message -t $SESS -p '#{history_size}') -join '').Trim()) }
function InMode { (((P display-message -t $SESS -p '#{pane_in_mode}') -join '').Trim()) }

# Fill the pane with more lines than it can hold, so there is a history to jump
# into. The shell may not have printed its first prompt yet when the client
# reports ready, and a range typed before that is lost, so the send is retried
# until the history is there.
function Fill-And-Enter {
    for ($try = 0; $try -lt 4; $try++) {
        P send-keys -t $SESS '1..200' Enter | Out-Null
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Milliseconds 250
            if ((Hist) -ge 150) {
                Start-Sleep -Milliseconds 500
                P copy-mode -t $SESS | Out-Null
                Start-Sleep -Milliseconds 800
                return
            }
        }
        Write-Info "the pane is still empty after attempt $($try + 1); sending the range again"
    }
    P copy-mode -t $SESS | Out-Null
    Start-Sleep -Milliseconds 800
}

function Leave-Mode {
    P send-keys -t $SESS -X cancel | Out-Null
    Start-Sleep -Milliseconds 400
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
Write-Info ("default-shell: " + ((P show-options -g default-shell) -join ''))
Fill-And-Enter
$hist = Hist
Write-Info "history_size = $hist, scroll_position = $(Pos)"
if ($hist -lt 150) {
    Write-Fail "the pane did not collect a scrollback to jump into (history_size = $hist)"
    Kill-Rig
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}

# ── The prompt appears and takes characters ──

Write-Head "the prompt"

P send-keys -t $SESS ':' | Out-Null
Start-Sleep -Milliseconds 400
$line = Wait-Prompt $proc.Id "(goto line)"
if ($line -match '\(goto line\)') { Write-Pass "`:` opens a prompt reading (goto line)" }
else { Write-Fail "`:` opened no prompt; status line was [$line]" }

P send-keys -t $SESS '1' | Out-Null
Start-Sleep -Milliseconds 400
$line = Wait-Prompt $proc.Id "(goto line) 1"
if ($line -match '\(goto line\) 1') { Write-Pass "a typed digit shows in the prompt" }
else { Write-Fail "the digit did not reach the prompt; status line was [$line]" }

# A copy mode key is inactive while the prompt is open: `q` would otherwise
# leave copy mode.
P send-keys -t $SESS 'q' | Out-Null
Start-Sleep -Milliseconds 400
if ((InMode) -eq "1") { Write-Pass "copy mode keys are inactive while the prompt is open" }
else { Write-Fail "`q` left copy mode from inside the prompt" }

P send-keys -t $SESS BSpace | Out-Null
Start-Sleep -Milliseconds 400
$line = Get-Prompt $proc.Id
if ($line -match '\(goto line\) 1$') { Write-Pass "backspace deletes the last character" }
else { Write-Fail "backspace did not redraw the prompt; status line was [$line]" }

# ── Accepting a number moves the view ──

Write-Head "absolute line numbers"

P send-keys -t $SESS Enter | Out-Null
Start-Sleep -Milliseconds 600
$pos = Pos
if ($pos -eq $hist) { Write-Pass "line 1 parks on the oldest retained line (scroll_position = $pos)" }
else { Write-Fail "line 1 gave scroll_position = $pos, expected $hist" }
if ((InMode) -eq "1") { Write-Pass "Enter stays in copy mode" }
else { Write-Fail "Enter left copy mode" }
if ((Get-Prompt $proc.Id) -eq "") { Write-Pass "the prompt clears once it is accepted" }
else { Write-Fail "the prompt stayed on the status line after Enter" }

# Back to the live bottom, then jump to a line that is deeper than the pane is
# tall. The old code wrote the number into the cursor's screen row, so anything
# past 30 was clamped away and the view never moved.
P send-keys -t $SESS -X history-bottom | Out-Null
Start-Sleep -Milliseconds 400
P send-keys -t $SESS ':' | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS '5' '0' | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS Enter | Out-Null
Start-Sleep -Milliseconds 600
$pos = Pos
$want = $hist - 49
if ($pos -eq $want) { Write-Pass "line 50 is reachable although the pane is 30 rows (scroll_position = $pos)" }
else { Write-Fail "line 50 gave scroll_position = $pos, expected $want" }

# ── Escape leaves the view alone ──

Write-Head "cancelling"

P send-keys -t $SESS -X history-bottom | Out-Null
Start-Sleep -Milliseconds 400
$before = Pos
P send-keys -t $SESS ':' | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS '1' | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS Escape | Out-Null
Start-Sleep -Milliseconds 600
$pos = Pos
if ($pos -eq $before) { Write-Pass "Escape leaves the view where it was (scroll_position = $pos)" }
else { Write-Fail "Escape moved the view from $before to $pos" }
if ((Get-Prompt $proc.Id) -eq "") { Write-Pass "Escape clears the prompt" }
else { Write-Fail "the prompt stayed on the status line after Escape" }

# Text that is not a number closes the prompt without moving.
P send-keys -t $SESS ':' | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS 'a' 'b' 'c' | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS Enter | Out-Null
Start-Sleep -Milliseconds 600
$pos = Pos
if ($pos -eq $before) { Write-Pass "a line number that is not a number leaves the view alone" }
else { Write-Fail "abc moved the view from $before to $pos" }

# ── copy-mode-line-numbers off changes what the number counts ──

Write-Head "default line numbers"

P set -g copy-mode-line-numbers off | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS -X history-bottom | Out-Null
Start-Sleep -Milliseconds 400
P send-keys -t $SESS ':' | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS '5' | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS Enter | Out-Null
Start-Sleep -Milliseconds 600
$pos = Pos
if ($pos -eq 5) { Write-Pass "without absolute numbering the number is the offset (scroll_position = 5)" }
else { Write-Fail "off mode gave scroll_position = $pos, expected 5" }

# ── The verb on its own ──

Write-Head "send-keys -X goto-line"

P set -g copy-mode-line-numbers absolute | Out-Null
Start-Sleep -Milliseconds 300
P send-keys -t $SESS -X history-bottom | Out-Null
Start-Sleep -Milliseconds 400
P send-keys -t $SESS -X goto-line -- 1 | Out-Null
Start-Sleep -Milliseconds 600
$pos = Pos
if ($pos -eq $hist) { Write-Pass "send -X goto-line -- 1 reaches line 1 (scroll_position = $pos)" }
else { Write-Fail "send -X goto-line -- 1 gave scroll_position = $pos, expected $hist" }

P send-keys -t $SESS -X history-bottom | Out-Null
Start-Sleep -Milliseconds 400
P send-keys -t $SESS -X goto-line 1 | Out-Null
Start-Sleep -Milliseconds 600
$pos = Pos
if ($pos -eq $hist) { Write-Pass "send -X goto-line 1 reaches line 1 without the -- marker" }
else { Write-Fail "send -X goto-line 1 gave scroll_position = $pos, expected $hist" }

# ── The key and the number in one argument ──

Write-Head "one send-keys argument"

# `send-keys ':50'` reaches the server as ONE send-text. The characters after
# `:` belong to the prompt it opens, the same as when they come one at a time;
# they used to be run as copy mode keys, so 50 became a count and the prompt
# was accepted empty.
if ((InMode) -ne "1") { P copy-mode -t $SESS | Out-Null; Start-Sleep -Milliseconds 800 }
P send-keys -t $SESS -X history-bottom | Out-Null
Start-Sleep -Milliseconds 400
$hNow = Hist
P send-keys -t $SESS ':50' Enter | Out-Null
Start-Sleep -Milliseconds 600
$pos = Pos
$want = $hNow - 49
if ($pos -eq $want) { Write-Pass "send-keys ':50' Enter reaches line 50 (scroll_position = $pos)" }
else { Write-Fail "send-keys ':50' Enter gave scroll_position = $pos, expected $want" }

# ── g keeps its meaning, since the new arm sits next to it ──

Write-Head "the g key"

# Re-enter copy mode first. Everything above leaves the pane in it on a build
# that has the fix, but on one that does not, the Enter further up exits copy
# mode, and then this would be typing a literal `g` at the shell and reading a
# scroll offset that means nothing.
if ((InMode) -ne "1") {
    Write-Info "the pane left copy mode earlier; re-entering so this section measures copy mode"
    P copy-mode -t $SESS | Out-Null
    Start-Sleep -Milliseconds 800
}
P send-keys -t $SESS -X history-bottom | Out-Null
Start-Sleep -Milliseconds 400
# Read the history size here rather than reusing the one from the start: a build
# without the fix has let the pane print a few more lines by now.
$hNow = Hist
P send-keys -t $SESS 'g' | Out-Null
Start-Sleep -Milliseconds 500
$pos = Pos
if ($pos -eq $hNow) { Write-Pass "g still reaches the top of the history (scroll_position = $pos)" }
else { Write-Fail "g gave scroll_position = $pos, expected $hNow" }
if ((Get-Prompt $proc.Id) -eq "") { Write-Pass "g opens no prompt" }
else { Write-Fail "g opened a prompt" }

# ── Teardown ──

Kill-Rig
Remove-Item $TMP -Recurse -Force -EA SilentlyContinue

Write-Host ""
Write-Host "Passed: $script:TestsPassed  Failed: $script:TestsFailed" `
    -ForegroundColor $(if ($script:TestsFailed -eq 0) { 'Green' } else { 'Red' })
exit $(if ($script:TestsFailed -eq 0) { 0 } else { 1 })
