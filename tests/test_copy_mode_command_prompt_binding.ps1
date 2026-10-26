# A copy mode key table binding to `command-prompt` left copy mode and showed
# no prompt.
#
# tmux writes most of its own copy mode keys as prompts (key-bindings.c:582 to
# :704); `list-keys -T copy-mode-vi` prints psmux's built in `:` as
#
#   bind-key -T copy-mode-vi : command-prompt -p'(goto line)' { send -X goto-line -- '%%' }
#
# and binding that very line replaced the working built in with a dead key.
# Measured on master 822bac1 with real keystrokes into an attached client:
#
#   after ':'          pane_in_mode = 0, no prompt on the status line
#   after '50' Enter   `50` typed at the shell prompt, scroll_position = 0
#
# tmux keeps the pane in copy mode while the prompt is open on the status line
# and runs the command built from the template against it
# (cmd-command-prompt.c:186 and :238).
#
# Keys go through tests\injector.cs (WriteConsoleInput into the client's
# console); the status line is read back with tests\conread.cs. The client
# window is opened minimized and closed by PID.
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0; $script:TestsFailed = 0; $script:Skipped = 0
$script:Opened = @()

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow; $script:Skipped++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan
Write-Host ((& $PSMUX -V) -join ' ') -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null

$NS   = "cpbind-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "cp"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_cpbind_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null

function P { & $PSMUX -L $NS @args 2>&1 }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
$RD  = Join-Path $TMP "conread.exe"
$INJ = Join-Path $TMP "psmux_injector_cpbind.exe"
if ($csc -and (Test-Path $csc)) {
    & $csc /nologo /optimize /out:$RD  (Join-Path $PSScriptRoot "conread.cs")  2>&1 | Out-Null
    & $csc /nologo /optimize /out:$INJ (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $RD) -or -not (Test-Path $INJ)) {
    Write-Fail "could not build tests\conread.cs or tests\injector.cs (csc.exe unavailable)"
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}
. (Join-Path $PSScriptRoot "injector_guard.ps1")

# The default namespace must not change while this runs.
$defaultBefore = ((& $PSMUX ls 2>&1) -join "`n")

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

$LISTED = "bind-key -T copy-mode-vi : command-prompt -p'(goto line)' { send -X goto-line -- '%%' }"
$CONF = Join-Path $TMP "cpbind.conf"
$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
@(
    "set -g default-shell $POWERSHELL",
    "set -g mode-keys vi",
    "set -g copy-mode-line-numbers absolute",
    "set -g history-limit 2000",
    $LISTED,
    "bind -T copy-mode-vi / command-prompt -T search -p'(search down)' { send -X search-forward -- '%%' }",
    "bind -T copy-mode-vi f command-prompt -1p'(jump forward)' { send -X jump-forward -- '%%' }"
) | Set-Content -Path $CONF -Encoding ASCII

function Start-Attached {
    $p = Start-Process -FilePath $PSMUX -WindowStyle Minimized `
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

function Get-ClientScreen {
    $o = Join-Path $TMP "screen.txt"; $e = Join-Path $TMP "screen_err.txt"
    Start-Process -FilePath $RD -ArgumentList "$($script:proc.Id)" -Wait -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
    if (Test-Path $o) { return @(Get-Content $o) }
    return @()
}

# The first screen row matching $pattern, trimmed, or "".
function Find-Row($pattern) {
    foreach ($r in Get-ClientScreen) { if ($r -match $pattern) { return $r.Trim() } }
    return ""
}

function Wait-Row($pattern, $want) {
    $last = ""
    for ($i = 0; $i -lt 16; $i++) {
        $last = Find-Row $pattern
        if ($last -match $want) { return $last }
        Start-Sleep -Milliseconds 250
    }
    return $last
}

# Real keystrokes into the client's console. A run the harness could not
# deliver is recorded as a skip, never judged as a psmux result.
function Keys($k) {
    if (-not (Invoke-GuardedInjector -Injector $INJ -ClientPid $script:proc.Id -Keys $k -RequireDelivery)) {
        return $false
    }
    Start-Sleep -Milliseconds 700
    return $true
}

function Fmt($f) { ((P display-message -t $SESS -p $f) -join '').Trim() }
function Pos { [int](Fmt '#{scroll_position}') }
function Hist { [int](Fmt '#{history_size}') }
function InMode { Fmt '#{pane_in_mode}' }

function Fill-History {
    for ($try = 0; $try -lt 4; $try++) {
        P send-keys -t $SESS '1..200' Enter | Out-Null
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Milliseconds 250
            if ((Hist) -ge 150) { Start-Sleep -Milliseconds 500; return }
        }
    }
}

function Enter-Copy {
    if ((InMode) -ne "1") { P copy-mode -t $SESS | Out-Null; Start-Sleep -Milliseconds 800 }
    P send-keys -t $SESS -X history-bottom | Out-Null
    Start-Sleep -Milliseconds 400
}

# ── Rig ──

Kill-Rig
$script:proc = Start-Attached
if (-not $script:proc) {
    Write-Fail "the attached client never came up"
    Kill-Rig; Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}
Fill-History
$hist = Hist
Write-Info "history_size = $hist"
if ($hist -lt 150) {
    Write-Fail "the pane did not collect a scrollback (history_size = $hist)"
    Kill-Rig; Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
    exit 1
}
$listed = ((P list-keys -T copy-mode-vi ':') -join '').Trim()
Write-Info "list-keys -T copy-mode-vi : -> $listed"

function Run-Section([scriptblock]$body) {
    & $body
    if ($script:InjectorBlocked) {
        Write-Skip "keystrokes could not be delivered: $script:InjectorBlocked"
        return $false
    }
    return $true
}

# ── 1. The list-keys line, bound from a config file ──

Write-Head "the printed : binding, from the config file"
$ok = Run-Section {
    Enter-Copy
    $h = Hist
    if (-not (Keys ':')) { return }
    $mode = InMode
    if ($mode -eq "1") { Write-Pass "':' keeps the pane in copy mode (pane_in_mode = 1)" }
    else { Write-Fail "':' left copy mode (pane_in_mode = $mode)" }
    $row = Wait-Row '\(goto line\)' '\(goto line\)'
    if ($row -match '\(goto line\)') { Write-Pass "the prompt is on the status line: [$row]" }
    else { Write-Fail "no (goto line) prompt on screen" }
    if (-not (Keys '50')) { return }
    $row = Wait-Row '\(goto line\)' '\(goto line\) 50'
    if ($row -match '\(goto line\) 50') { Write-Pass "typed digits reach the prompt: [$row]" }
    else { Write-Fail "the digits did not reach the prompt; row was [$row]" }
    if (-not (Keys '{ENTER}')) { return }
    $pos = Pos; $mode = InMode; $want = $h - 49
    if ($mode -eq "1") { Write-Pass "Enter runs the command and stays in copy mode" }
    else { Write-Fail "Enter left copy mode (pane_in_mode = $mode)" }
    if ($pos -eq $want) { Write-Pass "line 50 reached (scroll_position = $pos)" }
    else { Write-Fail "line 50 gave scroll_position = $pos, expected $want" }
    if ((Find-Row '\(goto line\)') -eq "") { Write-Pass "the prompt clears once accepted" }
    else { Write-Fail "the prompt stayed on the status line" }
}

# ── 2. A runtime `bind` with a quoted string template ──

Write-Head "runtime bind with a quoted template"
$ok = Run-Section {
    P bind -T copy-mode-vi X command-prompt -p 'line?' "send -X goto-line -- '%%'" | Out-Null
    Enter-Copy
    $h = Hist
    if (-not (Keys 'X')) { return }
    $row = Wait-Row 'line\?' 'line\?'
    if ($row -match 'line\?') { Write-Pass "the runtime binding opens its prompt: [$row]" }
    else { Write-Fail "no line? prompt on screen" }
    if (-not (Keys '1{ENTER}')) { return }
    $pos = Pos
    if ((InMode) -eq "1" -and $pos -eq $h) { Write-Pass "line 1 reached from the runtime binding (scroll_position = $pos)" }
    else { Write-Fail "runtime binding gave pane_in_mode = $(InMode), scroll_position = $pos, expected 1 and $h" }
}

# ── 3. Escape cancels without moving ──

Write-Head "Escape"
$ok = Run-Section {
    Enter-Copy
    $before = Pos
    if (-not (Keys ':7')) { return }
    if (-not (Keys '{ESC}')) { return }
    $pos = Pos
    if ((InMode) -eq "1" -and $pos -eq $before) { Write-Pass "Escape closes the prompt and stays put in copy mode" }
    else { Write-Fail "Escape gave pane_in_mode = $(InMode), scroll_position $before -> $pos" }
    if ((Find-Row '\(goto line\)') -eq "") { Write-Pass "Escape clears the prompt" }
    else { Write-Fail "the prompt stayed after Escape" }
}

# ── 4. A search template ──

Write-Head "search-forward through a prompt"
$ok = Run-Section {
    Enter-Copy
    P send-keys -t $SESS -X history-top | Out-Null
    Start-Sleep -Milliseconds 400
    $top = Pos
    if (-not (Keys '/')) { return }
    $row = Wait-Row '\(search down\)' '\(search down\)'
    if ($row -match '\(search down\)') { Write-Pass "'/' bound to command-prompt opens (search down): [$row]" }
    else { Write-Fail "no (search down) prompt on screen" }
    if (-not (Keys '150{ENTER}')) { return }
    $pos = Pos; $str = Fmt '#{pane_search_string}'
    if ((InMode) -eq "1" -and $pos -lt $top) { Write-Pass "the search ran in copy mode and moved the view ($top -> $pos), search string [$str]" }
    else { Write-Fail "search gave pane_in_mode = $(InMode), scroll_position $top -> $pos" }
}

# ── 5. A one key prompt ──

Write-Head "jump-forward through command-prompt -1"
$ok = Run-Section {
    Enter-Copy
    # Park the cursor at the start of the line reading `150`, so a jump to
    # its `0` has a known column to land on.
    P send-keys -t $SESS -X search-backward 150 | Out-Null
    Start-Sleep -Milliseconds 400
    P send-keys -t $SESS -X start-of-line | Out-Null
    Start-Sleep -Milliseconds 400
    $x0 = Fmt '#{copy_cursor_x}'
    if (-not (Keys 'f')) { return }
    $row = Wait-Row '\(jump forward\)' '\(jump forward\)'
    if ($row -match '\(jump forward\)') { Write-Pass "'f' opens (jump forward): [$row]" }
    else { Write-Fail "no (jump forward) prompt on screen" }
    if (-not (Keys '0')) { return }
    if ((InMode) -eq "1" -and (Find-Row '\(jump forward\)') -eq "") { Write-Pass "one key answers a -1 prompt and copy mode stays" }
    else { Write-Fail "-1 prompt: pane_in_mode = $(InMode), prompt row [$(Find-Row '\(jump forward\)')]" }
    $x1 = Fmt '#{copy_cursor_x}'
    if ($x0 -eq "0" -and $x1 -eq "2") { Write-Pass "f then 0 jumped onto the 0 of 150 (copy_cursor_x $x0 -> $x1)" }
    else { Write-Fail "f then 0 gave copy_cursor_x $x0 -> $x1, expected 0 -> 2" }
}

# ── 6. unbind leaves the key dead ──

Write-Head "unbind -T copy-mode-vi :"
$ok = Run-Section {
    P unbind -T copy-mode-vi ':' | Out-Null
    Enter-Copy
    $before = Pos
    if (-not (Keys ':')) { return }
    if ((InMode) -eq "1" -and (Find-Row '\(goto line\)') -eq "" -and (Pos) -eq $before) { Write-Pass "an unbound ':' does nothing, as in tmux" }
    else { Write-Fail "unbound ':' gave pane_in_mode = $(InMode), prompt [$(Find-Row '\(goto line\)')]" }
    P bind -T copy-mode-vi ':' command-prompt "-p(goto line)" "send -X goto-line -- '%%'" | Out-Null
}

# ── 7. Changing pane while the prompt is open ──

Write-Head "select-pane with a prompt open"
$ok = Run-Section {
    Enter-Copy
    $p0 = Fmt '#{pane_id}'
    if (-not (Keys ':')) { return }
    P split-window -t $SESS -d | Out-Null
    Start-Sleep -Milliseconds 1500
    P select-pane -t "${SESS}:.1" | Out-Null
    Start-Sleep -Milliseconds 700
    $row = Find-Row '\(goto line\)'
    if ($row -eq "") { Write-Pass "the prompt does not follow focus to the other pane" }
    else { Write-Fail "the prompt stayed on screen after select-pane: [$row]" }
    $m0 = ((P display-message -t $p0 -p '#{pane_in_mode}') -join '').Trim()
    if ($m0 -eq "1") { Write-Pass "the first pane is still in copy mode ($p0)" }
    else { Write-Fail "the first pane left copy mode ($p0 pane_in_mode = $m0)" }
    P select-pane -t $p0 | Out-Null
    Start-Sleep -Milliseconds 500
    P kill-pane -t "${SESS}:.1" | Out-Null
    Start-Sleep -Milliseconds 500
}

# ── 8. The prefix table prompt is unchanged ──

Write-Head "prefix table command-prompt"
$ok = Run-Section {
    P send-keys -t $SESS -X cancel | Out-Null
    Start-Sleep -Milliseconds 400
    P bind-key y command-prompt -p 'pfx' "set -g @cpbind '%%'" | Out-Null
    if (-not (Keys '^b')) { return }
    if (-not (Keys 'y')) { return }
    $row = Wait-Row 'pfx' 'pfx'
    if ($row -match 'pfx') { Write-Pass "prefix y draws its prompt: [$row]" }
    else { Write-Fail "prefix y drew no prompt" }
    if (-not (Keys 'ok{ENTER}')) { return }
    Start-Sleep -Milliseconds 400
    $v = ((P show-options -gv '@cpbind') -join '').Trim()
    if ($v -eq "ok") { Write-Pass "the prefix prompt ran its command (@cpbind = ok)" }
    else { Write-Fail "the prefix prompt did not run its command (@cpbind = [$v])" }
}

# ── Teardown ──

Kill-Rig
Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
$defaultAfter = ((& $PSMUX ls 2>&1) -join "`n")
if ($defaultAfter -ne $defaultBefore) { Write-Fail "the DEFAULT namespace changed while this ran" }
$left = @($script:Opened | Where-Object { Get-Process -Id $_ -EA SilentlyContinue })
if ($left.Count -gt 0) { Write-Fail "client processes left behind: $($left -join ',')" }

Write-Host ""
Write-Host "Passed: $script:TestsPassed  Failed: $script:TestsFailed  Skipped: $script:Skipped" `
    -ForegroundColor $(if ($script:TestsFailed -eq 0) { 'Green' } else { 'Red' })
exit $(if ($script:TestsFailed -eq 0) { 0 } else { 1 })
