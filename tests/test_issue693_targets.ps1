# Issue #693: five tmux parity gaps in target handling, found by the #691
# survey.  Each reproduced three times on master c467dab before a line of
# product code was read.
#
#   1. link-window -s <sess>:0 -t <sess>:5   rc=0, window list unchanged.
#      The -s parser was w[1].trim_start_matches(':').parse::<usize>(), which
#      cannot read a session qualified source, and the -t was stripped by
#      without_outer_target and then refused by the generic temp focus, which
#      will not focus an index no window holds yet.  tmux: that -t is
#      CMD_FIND_WINDOW_INDEX (cmd-move-window.c:83, the branch link-window
#      shares with move-window) and need NOT exist, exactly like break-pane's.
#
#   2. unlink-window -t <sess>:1 ignored its -t and removed the ACTIVE window.
#      The temp focus hid that for a target that exists; the shape it could
#      not hide is unlink-window -t <sess>:9, which exited 0 having done
#      nothing where tmux says "can't find window: 9" at exit 1.  tmux acts on
#      target->wl (cmd-kill-window.c:75-83).
#
#   3. select-pane -t s:1.0 switched the current WINDOW:
#          parked on window 0, select-pane -t s:1.1
#          before  current=0   panes 0.0* 1.0* 1.1
#          after   current=1   panes 0.0* 1.0  1.1*
#      tmux calls window_set_active_pane(w, wp, 1) on the TARGET window
#      (cmd-select-pane.c:274) and never session_select, so the session's
#      current window does not move.
#
#   4. select-window -t +1 / -t ! / -t {end} / -t - / -t + died on the CLI
#      with "no server running on session '<ns>__+1'", and -t +1 reached the
#      server only because Rust's usize parser accepts a leading '+', so it
#      was read as the literal index 1:
#          parked 0 : -t +1 -> 1   (want 1)
#          parked 1 : -t +1 -> 1   (want 2)
#          parked 2 : -t +1 -> 1   (want 3)
#      tmux maps the braced spellings through cmd_find_window_table
#      (cmd-find.c:51-58) and resolves the rest in
#      cmd_find_get_window_with_session (cmd-find.c:364-457).
#
#   5. select-pane -l with no last pane exited 0 in silence.  tmux errors
#      "no last pane" at exit 1 (cmd-select-pane.c:176) and, before that,
#      falls back to the sibling when the window has exactly two panes and
#      neither was ever visited (:167-172).
#
# Four routes throughout: the CLI, a raw control socket, a bind-key binding
# pressed into a real attached client with tests\injector.cs, and the prefix
# ':' prompt.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i693tgt" }
$SESSION = "i693_s"

$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

$repoTests = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($v in 'PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') {
    Remove-Item "env:$v" -EA SilentlyContinue
}
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_i693_targets"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

Write-Host ""
Write-Host "=== Issue #693: target handling parity ===" -ForegroundColor Magenta
Write-Info "Binary: $PSMUX"
Write-Info "Namespace: $NS   data: $($env:PSMUX_DATA_DIR)"

function Invoke-Psmux([string[]]$a) { & $PSMUX -L $NS @a 2>&1 }
function Stop-Srv { Invoke-Psmux @('kill-server') | Out-Null; Start-Sleep -Milliseconds 400 }

function Send-OverSocket([string]$Command) {
    $pf = Get-ChildItem (Join-Path $env:PSMUX_DATA_DIR "*.port") -EA SilentlyContinue | Select-Object -First 1
    if (-not $pf) { return "NO_PORT_FILE" }
    $kf = [IO.Path]::ChangeExtension($pf.FullName, ".key")
    if (-not (Test-Path $kf)) { return "NO_KEY_FILE" }
    try {
        $port = (Get-Content $pf.FullName -Raw).Trim()
        $key  = (Get-Content $kf -Raw).Trim()
        $c = [System.Net.Sockets.TcpClient]::new()
        $c.Connect('127.0.0.1', [int]$port)
        $s = $c.GetStream(); $s.ReadTimeout = 5000
        $w = [System.IO.StreamWriter]::new($s); $w.AutoFlush = $true
        $r = [System.IO.StreamReader]::new($s)
        $w.WriteLine("AUTH $key")
        if ($r.ReadLine() -ne "OK") { $c.Close(); return "AUTH_FAILED" }
        $w.WriteLine($Command)
        $lines = @()
        try {
            while ($true) {
                $line = $r.ReadLine()
                if ($null -eq $line) { break }
                $lines += $line
                # Read to EOF: a one-shot reply ends when the server closes the
                # connection (ReadLine returns null), bounded by ReadTimeout. A quiet
                # socket is not the end of a reply.
            }
        } catch {}
        $c.Close()
        return ($lines -join "`n")
    } catch { return "ERROR: $_" }
}

# --- fixtures --------------------------------------------------------------

# Three single pane windows 0, 1, 2, parked on 0.
function New-Windows3 {
    Stop-Srv
    Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
    Start-Sleep -Milliseconds 600
    Invoke-Psmux @('new-window','-d','-t',$SESSION) | Out-Null
    Invoke-Psmux @('new-window','-d','-t',$SESSION) | Out-Null
    Start-Sleep -Milliseconds 500
    Invoke-Psmux @('select-window','-t',"${SESSION}:0") | Out-Null
    Start-Sleep -Milliseconds 250
}

# Window 0 with one pane, window 1 with two, parked on 0.
function New-PaneFixture {
    Stop-Srv
    Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
    Start-Sleep -Milliseconds 600
    Invoke-Psmux @('new-window','-d','-t',$SESSION) | Out-Null
    Start-Sleep -Milliseconds 400
    Invoke-Psmux @('split-window','-d','-t',"${SESSION}:1") | Out-Null
    Start-Sleep -Milliseconds 600
    Invoke-Psmux @('select-window','-t',"${SESSION}:0") | Out-Null
    Start-Sleep -Milliseconds 250
}

function Get-Windows { (@(Invoke-Psmux @('list-windows','-t',$SESSION,'-F','#{window_index}'))) -join ',' }
function Get-Cur { (Invoke-Psmux @('display-message','-p','-t',$SESSION,'#{window_index}')) -join '' }
function Get-Panes { (@(Invoke-Psmux @('list-panes','-a','-t',$SESSION,'-F','#{window_index}.#{pane_index}#{?pane_active,*,}'))) -join ' ' }

# --------------------------------------------------- item 1: link-window -s/-t

Write-Host ""
Write-Host "--- item 1: link-window -s <sess>:0 -t <sess>:5 ---" -ForegroundColor Yellow

$landed = @()
for ($r = 1; $r -le 3; $r++) {
    New-Windows3
    Invoke-Psmux @('link-window','-s',"${SESSION}:0",'-t',"${SESSION}:5") | Out-Null
    Start-Sleep -Milliseconds 700
    $landed += (Get-Windows)
}
Write-Info "CLI link-window -s S:0 -t S:5 left: $($landed -join ' | ')"
if (($landed | Where-Object { $_ -ne '0,1,2,5' }).Count -eq 0) {
    Write-Pass "CLI link-window links the named source at the named index, three runs of three"
} else {
    Write-Fail "CLI link-window -s S:0 -t S:5 left $($landed -join '/'), want 0,1,2,5 each (#693 left 0,1,2)"
}

# The link really is a link of the SOURCE window, not of whatever was active.
New-Windows3
Invoke-Psmux @('rename-window','-t',"${SESSION}:0",'srcwin') | Out-Null
Start-Sleep -Milliseconds 300
Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
Start-Sleep -Milliseconds 300
Invoke-Psmux @('link-window','-d','-s',"${SESSION}:0",'-t',"${SESSION}:5") | Out-Null
Start-Sleep -Milliseconds 700
$named = (@(Invoke-Psmux @('list-windows','-t',$SESSION,'-F','#{window_index}:#{window_name}'))) -join ' '
if ($named -match '5:srcwin') {
    Write-Pass "link-window -s names the SOURCE window, not the active one ($named)"
} else {
    Write-Fail "link-window -s S:0 produced $named, want index 5 named srcwin"
}

# -d keeps the current window (cmd-move-window.c:103 passes !dflag).
if ((Get-Cur) -eq '2') {
    Write-Pass "link-window -d left the current window at 2"
} else {
    Write-Fail "link-window -d moved the current window to $(Get-Cur), want 2"
}

# Without -d the linked window is selected.
New-Windows3
Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
Start-Sleep -Milliseconds 300
Invoke-Psmux @('link-window','-s',"${SESSION}:0",'-t',"${SESSION}:5") | Out-Null
Start-Sleep -Milliseconds 700
if ((Get-Cur) -eq '5') {
    Write-Pass "link-window without -d selects the linked window (index 5)"
} else {
    Write-Fail "link-window without -d left the current window at $(Get-Cur), want 5"
}

# An unresolvable -s is tmux's message at exit 1, not a silent rc 0.
New-Windows3
$out = Invoke-Psmux @('link-window','-s',"${SESSION}:9",'-t',"${SESSION}:5")
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds 400
if ($rc -ne 0 -and ($out -join '') -match "can't find window: 9" -and (Get-Windows) -eq '0,1,2') {
    Write-Pass "link-window -s S:9 exits $rc with `"can't find window: 9`" and links nothing"
} else {
    Write-Fail "link-window -s S:9 gave rc=$rc '$($out -join '|')' and left $(Get-Windows)"
}

# An occupied destination without -k is "index in use: N" at exit 1.
New-Windows3
$out = Invoke-Psmux @('link-window','-s',"${SESSION}:0",'-t',"${SESSION}:1")
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds 400
if ($rc -ne 0 -and ($out -join '') -match "index in use: 1" -and (Get-Windows) -eq '0,1,2') {
    Write-Pass "link-window onto an occupied index exits $rc with `"index in use: 1`""
} else {
    Write-Fail "link-window -t S:1 gave rc=$rc '$($out -join '|')' and left $(Get-Windows)"
}

# -k kills the occupant first.
New-Windows3
Invoke-Psmux @('link-window','-d','-k','-s',"${SESSION}:0",'-t',"${SESSION}:1") | Out-Null
Start-Sleep -Milliseconds 800
if ((Get-Windows) -eq '0,1,2') {
    Write-Pass "link-window -k replaces the occupant of the destination index"
} else {
    Write-Fail "link-window -k left $(Get-Windows), want 0,1,2 with index 1 replaced"
}

# The socket route.
$sock = @()
$socketOk = $true
for ($r = 1; $r -le 3; $r++) {
    New-Windows3
    $resp = Send-OverSocket "link-window -s ${SESSION}:0 -t ${SESSION}:5"
    if ($resp -in @('NO_PORT_FILE','NO_KEY_FILE','AUTH_FAILED')) { $socketOk = $false; break }
    Start-Sleep -Milliseconds 700
    $sock += (Get-Windows)
}
if (-not $socketOk) {
    Write-Skip "control socket did not accept a connection on this host"
} elseif (($sock | Where-Object { $_ -ne '0,1,2,5' }).Count -eq 0) {
    Write-Pass "socket link-window -s S:0 -t S:5 links at index 5, three runs of three"
} else {
    Write-Fail "socket link-window left $($sock -join '/'), want 0,1,2,5 each"
}

# --------------------------------------------------- item 2: unlink-window -t

Write-Host ""
Write-Host "--- item 2: unlink-window -t names the window to unlink ---" -ForegroundColor Yellow

$landed = @()
for ($r = 1; $r -le 3; $r++) {
    New-Windows3
    Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
    Start-Sleep -Milliseconds 250
    Invoke-Psmux @('unlink-window','-t',"${SESSION}:1") | Out-Null
    Start-Sleep -Milliseconds 700
    $landed += "$(Get-Windows)/$(Get-Cur)"
}
Write-Info "CLI unlink-window -t S:1 parked on 2 left: $($landed -join ' | ')"
if (($landed | Where-Object { $_ -ne '0,2/2' }).Count -eq 0) {
    Write-Pass "unlink-window -t S:1 removes window 1 and leaves the current window at 2"
} else {
    Write-Fail "unlink-window -t S:1 left $($landed -join '/'), want 0,2/2 each"
}

# The shape the temp focus could not hide: a -t that names no window.
$misses = @()
for ($r = 1; $r -le 3; $r++) {
    New-Windows3
    Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
    Start-Sleep -Milliseconds 250
    $out = Invoke-Psmux @('unlink-window','-t',"${SESSION}:9")
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 500
    $misses += "rc=$rc/$(Get-Windows)/$(($out -join '') -match "can't find window: 9")"
}
Write-Info "unlink-window -t S:9: $($misses -join ' | ')"
if (($misses | Where-Object { $_ -ne 'rc=1/0,1,2/True' }).Count -eq 0) {
    Write-Pass "unlink-window -t S:9 exits 1 with `"can't find window: 9`" and unlinks nothing"
} else {
    Write-Fail "unlink-window -t S:9 gave $($misses -join '/'), want rc=1/0,1,2/True each (#693 gave rc=0 in silence)"
}

# A bare unlink-window still means the current window.
New-Windows3
Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
Start-Sleep -Milliseconds 250
Invoke-Psmux @('unlink-window') | Out-Null
Start-Sleep -Milliseconds 700
if ((Get-Windows) -eq '0,1') {
    Write-Pass "a bare unlink-window still unlinks the current window"
} else {
    Write-Fail "bare unlink-window left $(Get-Windows), want 0,1"
}

# By window id, and by window name.
New-Windows3
Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
Start-Sleep -Milliseconds 250
Invoke-Psmux @('unlink-window','-t','@2') | Out-Null
Start-Sleep -Milliseconds 700
if ((Get-Windows) -eq '0,2') {
    Write-Pass "unlink-window -t @2 unlinks the window with that id"
} else {
    Write-Fail "unlink-window -t @2 left $(Get-Windows), want 0,2"
}

# The socket route.
$sock = @()
if ($socketOk) {
    for ($r = 1; $r -le 3; $r++) {
        New-Windows3
        Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
        Start-Sleep -Milliseconds 250
        Send-OverSocket "unlink-window -t ${SESSION}:1" | Out-Null
        Start-Sleep -Milliseconds 700
        $sock += "$(Get-Windows)/$(Get-Cur)"
    }
    if (($sock | Where-Object { $_ -ne '0,2/2' }).Count -eq 0) {
        Write-Pass "socket unlink-window -t S:1 removes window 1, three runs of three"
    } else {
        Write-Fail "socket unlink-window left $($sock -join '/'), want 0,2/2 each"
    }
    New-Windows3
    Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
    Start-Sleep -Milliseconds 250
    $resp = Send-OverSocket "unlink-window -t ${SESSION}:9"
    Start-Sleep -Milliseconds 500
    if ($resp -match "can't find window: 9" -and (Get-Windows) -eq '0,1,2') {
        Write-Pass "socket unlink-window -t S:9 answers `"can't find window: 9`" and unlinks nothing"
    } else {
        Write-Fail "socket unlink-window -t S:9 answered '$resp' and left $(Get-Windows)"
    }
} else {
    Write-Skip "socket unlink-window: no control socket on this host"
}

# ------------------------------------- item 3: select-pane keeps the window

Write-Host ""
Write-Host "--- item 3: select-pane -t s:1.1 must not move the current window ---" -ForegroundColor Yellow

$landed = @()
for ($r = 1; $r -le 3; $r++) {
    New-PaneFixture
    Invoke-Psmux @('select-pane','-t',"${SESSION}:1.1") | Out-Null
    Start-Sleep -Milliseconds 600
    $landed += "$(Get-Cur)/$(Get-Panes)"
}
Write-Info "CLI select-pane -t S:1.1 parked on 0: $($landed -join ' | ')"
if (($landed | Where-Object { $_ -ne '0/0.0* 1.0 1.1*' }).Count -eq 0) {
    Write-Pass "select-pane -t S:1.1 sets window 1's active pane and stays on window 0"
} else {
    Write-Fail "select-pane -t S:1.1 landed on $($landed -join ' /// '), want '0/0.0* 1.0 1.1*' each (#693 moved to window 1)"
}

# A pane id in another window obeys the same rule (CMD_FIND_PANE).
New-PaneFixture
$pid11 = (Invoke-Psmux @('list-panes','-t',"${SESSION}:1",'-F','#{pane_index} #{pane_id}') | Where-Object { $_ -match '^1 ' }) -replace '^1 ',''
if ($pid11) {
    Invoke-Psmux @('select-pane','-t',$pid11.Trim()) | Out-Null
    Start-Sleep -Milliseconds 600
    if ((Get-Cur) -eq '0' -and (Get-Panes) -eq '0.0* 1.0 1.1*') {
        Write-Pass "select-pane -t $($pid11.Trim()) reaches another window without switching to it"
    } else {
        Write-Fail "select-pane -t $($pid11.Trim()) left current=$(Get-Cur) panes '$(Get-Panes)'"
    }
} else {
    Write-Skip "could not read window 1's pane id on this host"
}

# Inside the CURRENT window select-pane still moves the pane, as always.
New-PaneFixture
Invoke-Psmux @('select-window','-t',"${SESSION}:1") | Out-Null
Start-Sleep -Milliseconds 300
Invoke-Psmux @('select-pane','-t',"${SESSION}:1.1") | Out-Null
Start-Sleep -Milliseconds 500
if ((Get-Cur) -eq '1' -and (Get-Panes) -eq '0.0* 1.0 1.1*') {
    Write-Pass "select-pane inside the current window still moves the active pane"
} else {
    Write-Fail "select-pane -t S:1.1 from window 1 left current=$(Get-Cur) panes '$(Get-Panes)'"
}

# select-window is still the command that changes windows.
New-PaneFixture
Invoke-Psmux @('select-window','-t',"${SESSION}:1") | Out-Null
Start-Sleep -Milliseconds 400
if ((Get-Cur) -eq '1') {
    Write-Pass "select-window -t S:1 still switches the current window"
} else {
    Write-Fail "select-window -t S:1 left the current window at $(Get-Cur)"
}

# The socket route.
if ($socketOk) {
    $sock = @()
    for ($r = 1; $r -le 3; $r++) {
        New-PaneFixture
        Send-OverSocket "select-pane -t ${SESSION}:1.1" | Out-Null
        Start-Sleep -Milliseconds 600
        $sock += "$(Get-Cur)/$(Get-Panes)"
    }
    if (($sock | Where-Object { $_ -ne '0/0.0* 1.0 1.1*' }).Count -eq 0) {
        Write-Pass "socket select-pane -t S:1.1 stays on window 0, three runs of three"
    } else {
        Write-Fail "socket select-pane landed on $($sock -join ' /// '), want '0/0.0* 1.0 1.1*' each"
    }
} else {
    Write-Skip "socket select-pane: no control socket on this host"
}

# ------------------------------------------ item 4: select-window -t symbols

Write-Host ""
Write-Host "--- item 4: select-window resolves every window spec ---" -ForegroundColor Yellow

# Offsets step from the CURRENT window.  This is the sharp reproduction:
# -t +1 used to land on window 1 from every starting window.
New-Windows3
Invoke-Psmux @('new-window','-d','-t',$SESSION) | Out-Null   # 0,1,2,3
Start-Sleep -Milliseconds 400
$offsets = @()
foreach ($park in 0,1,2) {
    Invoke-Psmux @('select-window','-t',"${SESSION}:$park") | Out-Null
    Start-Sleep -Milliseconds 250
    Invoke-Psmux @('select-window','-t','+1') | Out-Null
    Start-Sleep -Milliseconds 250
    $offsets += "$park->$(Get-Cur)"
}
Write-Info "select-window -t +1: $($offsets -join ' ')"
if (($offsets -join ' ') -eq '0->1 1->2 2->3') {
    Write-Pass "select-window -t +1 steps from the current window (#693 always landed on 1)"
} else {
    Write-Fail "select-window -t +1 gave $($offsets -join ' '), want 0->1 1->2 2->3"
}

# Every symbol, from a known parking spot.  Windows 0..3, last window = 1.
function Reset-Symbols {
    Invoke-Psmux @('select-window','-t',"${SESSION}:1") | Out-Null
    Start-Sleep -Milliseconds 200
    Invoke-Psmux @('select-window','-t',"${SESSION}:0") | Out-Null
    Start-Sleep -Milliseconds 200
}
$symbolFailures = @()
foreach ($case in @(
    @{ t = '!';           want = '1' },
    @{ t = '{last}';      want = '1' },
    @{ t = '^';           want = '0' },
    @{ t = '{start}';     want = '0' },
    @{ t = '$';           want = '3' },
    @{ t = '{end}';       want = '3' },
    @{ t = '+';           want = '1' },
    @{ t = '{next}';      want = '1' },
    @{ t = '-';           want = '3' },
    @{ t = '{previous}';  want = '3' },
    @{ t = '+2';          want = '2' },
    @{ t = '-1';          want = '3' }
)) {
    Reset-Symbols
    $out = Invoke-Psmux @('select-window','-t',$case.t)
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 250
    $got = Get-Cur
    if ($rc -ne 0 -or $got -ne $case.want) {
        $symbolFailures += "$($case.t): rc=$rc landed $got want $($case.want) '$($out -join '|')'"
    }
}
if ($symbolFailures.Count -eq 0) {
    Write-Pass "every symbolic and offset form selects its window on the CLI (12 cases)"
} else {
    Write-Fail "select-window symbols missed: $($symbolFailures -join '; ')"
}

# #692 and #497 must still hold.
Reset-Symbols
Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
Start-Sleep -Milliseconds 250
Invoke-Psmux @('select-window','-t','0') | Out-Null
Start-Sleep -Milliseconds 250
if ((Get-Cur) -eq '0') {
    Write-Pass "select-window -t 0 still selects window 0 (#692)"
} else {
    Write-Fail "select-window -t 0 landed on $(Get-Cur), want 0"
}
Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
Start-Sleep -Milliseconds 250
Invoke-Psmux @('select-window','-t','@2') | Out-Null
Start-Sleep -Milliseconds 250
if ((Get-Cur) -eq '1') {
    Write-Pass "select-window -t @2 still selects the window with that id (#497)"
} else {
    Write-Fail "select-window -t @2 landed on $(Get-Cur), want 1"
}
$out = Invoke-Psmux @('select-window','-t','9')
$rc = $LASTEXITCODE
if ($rc -ne 0 -and ($out -join '') -match "can't find window: 9") {
    Write-Pass "select-window -t 9 still exits 1 with `"can't find window: 9`" (#692)"
} else {
    Write-Fail "select-window -t 9 gave rc=$rc '$($out -join '|')'"
}
$sessRc = 0
Invoke-Psmux @('has-session','-t','0') | Out-Null
$sessRc = $LASTEXITCODE
if ($sessRc -ne 0) {
    Write-Pass "has-session -t 0 still reads 0 as a SESSION name (rc=$sessRc)"
} else {
    Write-Fail "has-session -t 0 succeeded, so a bare number leaked into session targets"
}

# move-window's #602 forms are untouched.
Invoke-Psmux @('select-window','-t',"${SESSION}:0") | Out-Null
Start-Sleep -Milliseconds 250
Invoke-Psmux @('move-window','-t','7') | Out-Null
Start-Sleep -Milliseconds 400
if ((Get-Windows) -match '7') {
    Write-Pass "move-window -t 7 still moves the window to index 7 (#602)"
} else {
    Write-Fail "move-window -t 7 left $(Get-Windows)"
}

# The socket route.
if ($socketOk) {
    $symbolFailures = @()
    New-Windows3
    Invoke-Psmux @('new-window','-d','-t',$SESSION) | Out-Null
    Start-Sleep -Milliseconds 400
    foreach ($case in @(
        @{ t = '+1';     want = '1' },
        @{ t = '!';      want = '1' },
        @{ t = '{end}';  want = '3' },
        @{ t = '-';      want = '3' }
    )) {
        Reset-Symbols
        Send-OverSocket "select-window -t $($case.t)" | Out-Null
        Start-Sleep -Milliseconds 300
        $got = Get-Cur
        if ($got -ne $case.want) { $symbolFailures += "$($case.t): landed $got want $($case.want)" }
    }
    if ($symbolFailures.Count -eq 0) {
        Write-Pass "socket select-window resolves +1, !, {end} and - (4 cases)"
    } else {
        Write-Fail "socket select-window symbols missed: $($symbolFailures -join '; ')"
    }
    $resp = Send-OverSocket "select-window -t 9"
    if ($resp -match "can't find window: 9") {
        Write-Pass "socket select-window -t 9 answers `"can't find window: 9`""
    } else {
        Write-Fail "socket select-window -t 9 answered '$resp'"
    }
} else {
    Write-Skip "socket select-window: no control socket on this host"
}

# ------------------------------------------- item 5: select-pane -l diagnostic

Write-Host ""
Write-Host "--- item 5: select-pane -l with no last pane ---" -ForegroundColor Yellow

$results = @()
for ($r = 1; $r -le 3; $r++) {
    Stop-Srv
    Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
    Start-Sleep -Milliseconds 700
    $out = Invoke-Psmux @('select-pane','-l')
    $rc = $LASTEXITCODE
    $results += "rc=$rc/$(($out -join '') -match 'no last pane')"
}
Write-Info "select-pane -l on a single pane window: $($results -join ' | ')"
if (($results | Where-Object { $_ -ne 'rc=1/True' }).Count -eq 0) {
    Write-Pass "select-pane -l with no last pane exits 1 with `"no last pane`" (#693 exited 0 in silence)"
} else {
    Write-Fail "select-pane -l gave $($results -join '/'), want rc=1/True each"
}

# last-pane is the same command entry in tmux and owes the same error.
Stop-Srv
Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
Start-Sleep -Milliseconds 700
$out = Invoke-Psmux @('last-pane')
$rc = $LASTEXITCODE
if ($rc -ne 0 -and ($out -join '') -match 'no last pane') {
    Write-Pass "last-pane with no last pane exits $rc with `"no last pane`""
} else {
    Write-Fail "last-pane gave rc=$rc '$($out -join '|')'"
}

# A two pane window that was never switched inside falls back to the sibling.
Stop-Srv
Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
Start-Sleep -Milliseconds 700
Invoke-Psmux @('split-window','-d','-t',"${SESSION}:0") | Out-Null
Start-Sleep -Milliseconds 700
$out = Invoke-Psmux @('select-pane','-l')
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds 400
$panes = (@(Invoke-Psmux @('list-panes','-t',"${SESSION}:0",'-F','#{pane_index}#{?pane_active,*,}'))) -join ' '
if ($rc -eq 0 -and $panes -eq '0 1*') {
    Write-Pass "select-pane -l on a never visited two pane window takes the sibling (cmd-select-pane.c:167)"
} else {
    Write-Fail "select-pane -l gave rc=$rc panes '$panes', want rc=0 and '0 1*'"
}

# Three panes and no history is still an error, not a guess.
Stop-Srv
Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
Start-Sleep -Milliseconds 700
Invoke-Psmux @('split-window','-d','-t',"${SESSION}:0") | Out-Null
Start-Sleep -Milliseconds 500
Invoke-Psmux @('split-window','-d','-t',"${SESSION}:0") | Out-Null
Start-Sleep -Milliseconds 700
$out = Invoke-Psmux @('select-pane','-l')
$rc = $LASTEXITCODE
if ($rc -ne 0 -and ($out -join '') -match 'no last pane') {
    Write-Pass "select-pane -l with three panes and no history exits $rc with `"no last pane`""
} else {
    Write-Fail "select-pane -l with three panes gave rc=$rc '$($out -join '|')'"
}

# A real last pane still works, and -l after it goes back.
Stop-Srv
Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
Start-Sleep -Milliseconds 700
Invoke-Psmux @('split-window','-d','-t',"${SESSION}:0") | Out-Null
Start-Sleep -Milliseconds 500
Invoke-Psmux @('split-window','-d','-t',"${SESSION}:0") | Out-Null
Start-Sleep -Milliseconds 700
Invoke-Psmux @('select-pane','-t',"${SESSION}:0.2") | Out-Null
Start-Sleep -Milliseconds 400
Invoke-Psmux @('select-pane','-t',"${SESSION}:0.0") | Out-Null
Start-Sleep -Milliseconds 400
$out = Invoke-Psmux @('select-pane','-l')
$rc = $LASTEXITCODE
Start-Sleep -Milliseconds 400
$panes = (@(Invoke-Psmux @('list-panes','-t',"${SESSION}:0",'-F','#{pane_index}#{?pane_active,*,}'))) -join ' '
if ($rc -eq 0 -and $panes -eq '0 1 2*') {
    Write-Pass "select-pane -l returns to the remembered pane (rc=0, $panes)"
} else {
    Write-Fail "select-pane -l after a real visit gave rc=$rc panes '$panes', want '0 1 2*'"
}

# The socket route.
if ($socketOk) {
    Stop-Srv
    Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
    Start-Sleep -Milliseconds 700
    $resp = Send-OverSocket "select-pane -l"
    if ($resp -match 'no last pane') {
        Write-Pass "socket select-pane -l answers `"no last pane`""
    } else {
        Write-Fail "socket select-pane -l answered '$resp'"
    }
    $resp = Send-OverSocket "last-pane"
    if ($resp -match 'no last pane') {
        Write-Pass "socket last-pane answers `"no last pane`""
    } else {
        Write-Fail "socket last-pane answered '$resp'"
    }
} else {
    Write-Skip "socket select-pane -l: no control socket on this host"
}

# ------------------------- routes 3 and 4: a binding and the command prompt

Write-Host ""
Write-Host "--- routes 3 and 4: a binding and the prefix ':' prompt ---" -ForegroundColor Yellow

$injectorExe = Join-Path $root "injector693.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
& $csc /nologo /optimize /out:$injectorExe (Join-Path $repoTests "injector.cs") 2>&1 | Out-Null

$script:OpenedPids = @()
function Close-Client($proc) {
    try { if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } } catch {}
    Start-Sleep -Milliseconds 300
}

if (-not (Test-Path $injectorExe)) {
    Write-Skip "injector.cs did not compile; the binding and prompt routes need it"
} else {
    # item 1 + item 2 through a binding and the prompt.
    foreach ($route in @('binding','prompt')) {
        # link-window
        New-Windows3
        if ($route -eq 'binding') {
            Invoke-Psmux @('bind-key','j','link-window','-d','-s',"${SESSION}:0",'-t',"${SESSION}:5") | Out-Null
            Start-Sleep -Milliseconds 250
        }
        $proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"attach","-t",$SESSION -PassThru
        $script:OpenedPids += $proc.Id
        Start-Sleep -Milliseconds 2500
        $before = Get-Windows
        if ($route -eq 'binding') {
            & $injectorExe $proc.Id '^b{SLEEP:500}j{SLEEP:1200}' | Out-Null
        } else {
            & $injectorExe $proc.Id ('^b{SLEEP:500}:{SLEEP:600}link-window -d -s ' + $SESSION + ':0 -t ' + $SESSION + ':5{SLEEP:300}{ENTER}{SLEEP:1200}') | Out-Null
        }
        Start-Sleep -Milliseconds 1200
        $after = Get-Windows
        Close-Client $proc
        if ($before -ne '0,1,2') {
            Write-Skip "$route link-window: the fixture was $before, not 0,1,2, on this host"
        } elseif ($after -eq '0,1,2,5') {
            Write-Pass "$route link-window -s S:0 -t S:5 links at index 5 ($before -> $after)"
        } else {
            Write-Fail "$route link-window left $after, want 0,1,2,5 (#693 left $before)"
        }

        # unlink-window
        New-Windows3
        Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
        Start-Sleep -Milliseconds 250
        if ($route -eq 'binding') {
            Invoke-Psmux @('bind-key','j','unlink-window','-t',"${SESSION}:1") | Out-Null
            Start-Sleep -Milliseconds 250
        }
        $proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"attach","-t",$SESSION -PassThru
        $script:OpenedPids += $proc.Id
        Start-Sleep -Milliseconds 2500
        $before = Get-Windows
        if ($route -eq 'binding') {
            & $injectorExe $proc.Id '^b{SLEEP:500}j{SLEEP:1200}' | Out-Null
        } else {
            & $injectorExe $proc.Id ('^b{SLEEP:500}:{SLEEP:600}unlink-window -t ' + $SESSION + ':1{SLEEP:300}{ENTER}{SLEEP:1200}') | Out-Null
        }
        Start-Sleep -Milliseconds 1200
        $after = Get-Windows
        Close-Client $proc
        if ($before -ne '0,1,2') {
            Write-Skip "$route unlink-window: the fixture was $before on this host"
        } elseif ($after -eq '0,2') {
            Write-Pass "$route unlink-window -t S:1 removes window 1 ($before -> $after)"
        } else {
            Write-Fail "$route unlink-window left $after, want 0,2"
        }

        # select-pane must not move the attached client's window
        New-PaneFixture
        if ($route -eq 'binding') {
            Invoke-Psmux @('bind-key','j','select-pane','-t',"${SESSION}:1.1") | Out-Null
            Start-Sleep -Milliseconds 250
        }
        $proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"attach","-t",$SESSION -PassThru
        $script:OpenedPids += $proc.Id
        Start-Sleep -Milliseconds 2500
        $before = Get-Cur
        if ($route -eq 'binding') {
            & $injectorExe $proc.Id '^b{SLEEP:500}j{SLEEP:1200}' | Out-Null
        } else {
            & $injectorExe $proc.Id ('^b{SLEEP:500}:{SLEEP:600}select-pane -t ' + $SESSION + ':1.1{SLEEP:300}{ENTER}{SLEEP:1200}') | Out-Null
        }
        Start-Sleep -Milliseconds 1200
        $afterCur = Get-Cur
        $afterPanes = Get-Panes
        $alive = -not $proc.HasExited
        Close-Client $proc
        if ($before -ne '0') {
            Write-Skip "$route select-pane: the client started on window $before on this host"
        } elseif ($afterCur -eq '0' -and $afterPanes -eq '0.0* 1.0 1.1*') {
            Write-Pass "$route select-pane -t S:1.1 left the attached client on window 0 (panes $afterPanes)"
        } else {
            Write-Fail "$route select-pane -t S:1.1 moved the client to window $afterCur (panes $afterPanes)"
        }
        if ($alive) {
            Write-Pass "${route}: the attached client survived the select-pane"
        } else {
            Write-Fail "${route}: the attached client exited during the select-pane"
        }

        # select-window -t +1 and -t {end}
        New-Windows3
        Invoke-Psmux @('new-window','-d','-t',$SESSION) | Out-Null
        Start-Sleep -Milliseconds 400
        Invoke-Psmux @('select-window','-t',"${SESSION}:1") | Out-Null
        Start-Sleep -Milliseconds 300
        if ($route -eq 'binding') {
            Invoke-Psmux @('bind-key','j','select-window','-t','+1') | Out-Null
            Start-Sleep -Milliseconds 250
        }
        $proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"attach","-t",$SESSION -PassThru
        $script:OpenedPids += $proc.Id
        Start-Sleep -Milliseconds 2500
        $before = Get-Cur
        if ($route -eq 'binding') {
            & $injectorExe $proc.Id '^b{SLEEP:500}j{SLEEP:1200}' | Out-Null
        } else {
            & $injectorExe $proc.Id '^b{SLEEP:500}:{SLEEP:600}select-window -t +1{SLEEP:300}{ENTER}{SLEEP:1200}' | Out-Null
        }
        Start-Sleep -Milliseconds 1200
        $after = Get-Cur
        Close-Client $proc
        if ($before -ne '1') {
            Write-Skip "$route select-window -t +1: the client started on window $before on this host"
        } elseif ($after -eq '2') {
            Write-Pass "$route select-window -t +1 stepped from window 1 to window 2"
        } else {
            Write-Fail "$route select-window -t +1 landed on $after, want 2 (#693 landed on 1)"
        }

        New-Windows3
        Invoke-Psmux @('new-window','-d','-t',$SESSION) | Out-Null
        Start-Sleep -Milliseconds 400
        Invoke-Psmux @('select-window','-t',"${SESSION}:0") | Out-Null
        Start-Sleep -Milliseconds 300
        if ($route -eq 'binding') {
            Invoke-Psmux @('bind-key','j','select-window','-t','{end}') | Out-Null
            Start-Sleep -Milliseconds 250
        }
        $proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"attach","-t",$SESSION -PassThru
        $script:OpenedPids += $proc.Id
        Start-Sleep -Milliseconds 2500
        $before = Get-Cur
        if ($route -eq 'binding') {
            & $injectorExe $proc.Id '^b{SLEEP:500}j{SLEEP:1200}' | Out-Null
        } else {
            & $injectorExe $proc.Id '^b{SLEEP:500}:{SLEEP:600}select-window -t {LBRACE}end{RBRACE}{SLEEP:300}{ENTER}{SLEEP:1200}' | Out-Null
        }
        Start-Sleep -Milliseconds 1200
        $after = Get-Cur
        Close-Client $proc
        if ($before -ne '0') {
            Write-Skip "$route select-window -t {end}: the client started on window $before on this host"
        } elseif ($after -eq '3') {
            Write-Pass "$route select-window -t {end} selected the last window"
        } else {
            Write-Fail "$route select-window -t {end} landed on $after, want 3"
        }
    }
}

# --------------------------------------------------------------- teardown

Stop-Srv
foreach ($p in $script:OpenedPids) {
    try {
        $proc = Get-Process -Id $p -EA SilentlyContinue
        if ($proc) { Stop-Process -Id $p -Force -EA SilentlyContinue }
    } catch {}
}
Remove-Item -Recurse -Force $root -EA SilentlyContinue
if ($null -ne $savedDataDir) { $env:PSMUX_DATA_DIR = $savedDataDir } else { Remove-Item env:PSMUX_DATA_DIR -EA SilentlyContinue }
if ($null -ne $savedNoWarm)  { $env:PSMUX_NO_WARM  = $savedNoWarm }  else { Remove-Item env:PSMUX_NO_WARM  -EA SilentlyContinue }

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Magenta
Write-Host "  Passed:  $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed:  $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped: $script:TestsSkipped" -ForegroundColor Yellow
exit $(if ($script:TestsFailed -gt 0) { 1 } else { 0 })
