# Issue #691: the docs hook table promised hooks that never fired, and one
# command fired the wrong hook.
#
# `set-buffer` with no -b makes a NEW buffer every run, so a buffer count IS
# the firing count. That is how every number below was measured, three runs of
# three on each route.
#
# What the pre fix build did, on the CLI and on the raw control socket alike:
#
#     select-pane -t s:0.1     after-select-pane      0,0,0   (pane moved 0 -> 1)
#     select-pane -t s:0.1     after-select-window    1,1,1   (the WRONG hook)
#     new-window               window-linked          0,0,0
#     kill-window              window-unlinked        0,0,0
#     break-pane -d            window-linked          0,0,0
#     unlink-window            window-unlinked        0,0,0   (probe: -t form)
#     select-layout            after-select-layout    0,0,0
#     swap-window              after-swap-window      0,0,0
#     select-pane (focus on)   pane-focus-in / -out   0,0,0
#     attach                   client-session-changed 0,0,0
#
# tmux fires the command's OWN after hook, once, from the command queue
# (cmd-queue.c:635, `cmdq_insert_hook(fsp->s, item, fsp, "after-%s",
# entry->name)`), and select-pane inserts its own at cmd-select-pane.c:276.
# The notification hooks come from events_fire_* inside the command:
# window-linked from spawn.c:234 and session.c:333, window-unlinked from
# session.c:349, client-session-changed from server-client.c:415 via
# server_client_set_session at :448, pane-focus-in/out from window.c:700 and
# :706 via window_pane_update_focus, which window_set_active_pane calls for the
# old pane and then the new one.
#
# This file walks EVERY hook in the docs/scripting.md table, on the routes each
# one can be driven from, and asserts the count the table promises. A hook that
# cannot fire on a route is asserted as such, with the reason, rather than left
# unmentioned: the table must not promise what does not fire.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i691hk" }
$SESSION = "i691_s"

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
$root = Join-Path $env:TEMP "psmux_i691_hook"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

Write-Host ""
Write-Host "=== Issue #691: every hook in the table fires, once, from its own event ===" -ForegroundColor Magenta
Write-Info "Binary: $PSMUX"
Write-Info "Namespace: $NS   data: $($env:PSMUX_DATA_DIR)"

function Invoke-Psmux([string[]]$a) { & $PSMUX -L $NS @a 2>&1 }
function Stop-Srv { Invoke-Psmux @('kill-server') | Out-Null; Start-Sleep -Milliseconds 350 }

function New-Fixture([string[]]$Setup) {
    Stop-Srv
    Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
    Start-Sleep -Milliseconds 250
    foreach ($s in $Setup) { Invoke-Psmux ($s -split ' ') | Out-Null }
    Start-Sleep -Milliseconds 250
}
function Get-FiringCount {
    Start-Sleep -Milliseconds 450
    $bufs = Invoke-Psmux @('list-buffers')
    return @($bufs | Where-Object { $_ -match 'HOOKFIRED' }).Count
}

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

# ---------------------------------------------------------------------------
# The headline: select-pane fires its OWN hook, once, and not the window one.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- select-pane fires after-select-pane, never after-select-window ---" -ForegroundColor Yellow
$paneSetup = @("split-window -d -t ${SESSION}:0", "select-pane -t ${SESSION}:0.0")

$cli = @(); $moved = $true
for ($r = 1; $r -le 3; $r++) {
    New-Fixture $paneSetup
    Invoke-Psmux @('set-hook','-g','after-select-pane','set-buffer HOOKFIRED') | Out-Null
    $before = (Invoke-Psmux @('display-message','-p','-t',$SESSION,'#{pane_index}')) -join ''
    Invoke-Psmux @('select-pane','-t',"${SESSION}:0.1") | Out-Null
    $cli += (Get-FiringCount)
    $after = (Invoke-Psmux @('display-message','-p','-t',$SESSION,'#{pane_index}')) -join ''
    if ($before -ne '0' -or $after -ne '1') { $moved = $false }
}
Write-Info "CLI after-select-pane counts: $($cli -join ', ')"
if (-not $moved) {
    Write-Fail "the fixture never moved the active pane, so the counts prove nothing"
} elseif (($cli | Where-Object { $_ -ne 1 }).Count -eq 0) {
    Write-Pass "CLI select-pane fires after-select-pane once, three runs of three"
} else {
    Write-Fail "CLI select-pane fired after-select-pane $($cli -join '/') times, want 1 each (#691 counted 0)"
}

$wrong = @()
for ($r = 1; $r -le 3; $r++) {
    New-Fixture $paneSetup
    Invoke-Psmux @('set-hook','-g','after-select-window','set-buffer HOOKFIRED') | Out-Null
    Invoke-Psmux @('select-pane','-t',"${SESSION}:0.1") | Out-Null
    $wrong += (Get-FiringCount)
}
Write-Info "CLI after-select-window counts on a select-pane: $($wrong -join ', ')"
if (($wrong | Where-Object { $_ -ne 0 }).Count -eq 0) {
    Write-Pass "select-pane fires after-select-window zero times (tmux cmd-select-pane.c fires only its own)"
} else {
    Write-Fail "select-pane fired after-select-window $($wrong -join '/') times, want 0 each (#691 counted 1)"
}

$tcp = @(); $socketOk = $true
for ($r = 1; $r -le 3; $r++) {
    New-Fixture $paneSetup
    Invoke-Psmux @('set-hook','-g','after-select-pane','set-buffer HOOKFIRED') | Out-Null
    $resp = Send-OverSocket "select-pane -t ${SESSION}:0.1"
    if ($resp -in @('NO_PORT_FILE','NO_KEY_FILE','AUTH_FAILED')) { $socketOk = $false; break }
    $tcp += (Get-FiringCount)
}
if (-not $socketOk) {
    Write-Skip "control socket did not accept a connection on this host"
} else {
    Write-Info "socket after-select-pane counts: $($tcp -join ', ')"
    if (($tcp | Where-Object { $_ -ne 1 }).Count -eq 0) {
        Write-Pass "socket select-pane fires after-select-pane once, three runs of three"
    } else {
        Write-Fail "socket select-pane fired after-select-pane $($tcp -join '/') times, want 1 each (#691 counted 0)"
    }
}

# Every other select-pane form: still one firing, never two (the #690 rule).
Write-Host ""
Write-Host "--- every select-pane form fires it at most once ---" -ForegroundColor Yellow
$forms = [ordered]@{
  'select-pane -U'          = @{ trigger = "select-pane -U";                     want = 1 }
  'select-pane -D'          = @{ trigger = "select-pane -D";                     want = 1 }
  'select-pane -t :.+'      = @{ trigger = "select-pane -t :.+";                 want = 1 }
  'select-pane -t %id'      = @{ trigger = "";                                   want = 1 }
  'select-pane -t s:0.0'    = @{ trigger = "select-pane -t ${SESSION}:0.0";      want = 0 }
}
foreach ($name in $forms.Keys) {
    New-Fixture $paneSetup
    Invoke-Psmux @('set-hook','-g','after-select-pane','set-buffer HOOKFIRED') | Out-Null
    if ($name -eq 'select-pane -t %id') {
        # The pane that is NOT active, by %id.
        $panes = @(Invoke-Psmux @('list-panes','-t',"${SESSION}:0",'-F','#{pane_id} #{?pane_active,A,-}'))
        $other = ($panes | Where-Object { $_ -match ' -$' } | Select-Object -First 1) -replace ' .*',''
        if (-not $other) { Write-Skip "$name : no inactive pane to target"; continue }
        Invoke-Psmux @('select-pane','-t',$other) | Out-Null
    } else {
        Invoke-Psmux ($forms[$name].trigger -split ' ') | Out-Null
    }
    $n = Get-FiringCount
    $want = $forms[$name].want
    if ($n -eq $want) {
        $why = if ($want -eq 0) { " (the pane was already active; cmd-select-pane.c:269 returns before the hook)" } else { "" }
        Write-Pass "$name fired after-select-pane $want time(s)$why"
    } else {
        Write-Fail "$name fired after-select-pane $n times, want $want"
    }
}

# ---------------------------------------------------------------------------
# The notification hooks, each from the event it names.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- the notification hooks fire from their own events ---" -ForegroundColor Yellow
$notify = [ordered]@{
  'window-linked / new-window'   = @{ hook='window-linked';   setup=@(); trigger="new-window -t $SESSION" }
  'window-linked / break-pane'   = @{ hook='window-linked';   setup=@("split-window -d -t ${SESSION}:0"); trigger="break-pane -d -s ${SESSION}:0.1" }
  'window-linked / link-window'  = @{ hook='window-linked';   setup=@(); trigger="link-window" }
  'window-unlinked / kill-window'= @{ hook='window-unlinked'; setup=@("new-window -t $SESSION"); trigger="kill-window -t ${SESSION}:1" }
  'window-unlinked / unlink-win' = @{ hook='window-unlinked'; setup=@("new-window -t $SESSION"); trigger="unlink-window" }
  'after-select-layout'          = @{ hook='after-select-layout'; setup=@("split-window -d -t ${SESSION}:0"); trigger="select-layout -t ${SESSION}:0 even-horizontal" }
  'after-swap-window'            = @{ hook='after-swap-window';   setup=@("new-window -t $SESSION"); trigger="swap-window -s ${SESSION}:0 -t ${SESSION}:1" }
  'after-swap-pane'              = @{ hook='after-swap-pane';     setup=@("split-window -d -t ${SESSION}:0"); trigger="swap-pane -s ${SESSION}:0.0 -t ${SESSION}:0.1" }
}
foreach ($name in $notify.Keys) {
    $counts = @()
    for ($r = 1; $r -le 3; $r++) {
        New-Fixture $notify[$name].setup
        Invoke-Psmux @('set-hook','-g',$notify[$name].hook,'set-buffer HOOKFIRED') | Out-Null
        Invoke-Psmux ($notify[$name].trigger -split ' ') | Out-Null
        $counts += (Get-FiringCount)
    }
    if (($counts | Where-Object { $_ -ne 1 }).Count -eq 0) {
        Write-Pass "$name fired $($notify[$name].hook) once, three runs of three"
    } else {
        Write-Fail "$name fired $($notify[$name].hook) $($counts -join '/') times, want 1 each (#691 counted 0)"
    }
}

# Same sweep over the control socket: a hook the CLI fires and the socket does
# not is exactly the shape of bug #691 reported.
Write-Host ""
Write-Host "--- the same notification hooks over the raw control socket ---" -ForegroundColor Yellow
if (-not $socketOk) {
    Write-Skip "control socket unavailable on this host"
} else {
    foreach ($name in @('window-linked / new-window','window-unlinked / kill-window','after-select-layout','after-swap-window')) {
        $counts = @()
        for ($r = 1; $r -le 3; $r++) {
            New-Fixture $notify[$name].setup
            Invoke-Psmux @('set-hook','-g',$notify[$name].hook,'set-buffer HOOKFIRED') | Out-Null
            Send-OverSocket $notify[$name].trigger | Out-Null
            $counts += (Get-FiringCount)
        }
        if (($counts | Where-Object { $_ -ne 1 }).Count -eq 0) {
            Write-Pass "socket: $name fired $($notify[$name].hook) once, three runs of three"
        } else {
            Write-Fail "socket: $name fired $($notify[$name].hook) $($counts -join '/') times, want 1 each"
        }
    }
}

# ---------------------------------------------------------------------------
# pane-focus-in / pane-focus-out, which tmux gates on focus-events.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- pane-focus-in / pane-focus-out on a pane change ---" -ForegroundColor Yellow
foreach ($hook in @('pane-focus-in','pane-focus-out')) {
    $counts = @()
    for ($r = 1; $r -le 3; $r++) {
        New-Fixture $paneSetup
        Invoke-Psmux @('set','-g','focus-events','on') | Out-Null
        Start-Sleep -Milliseconds 200
        Invoke-Psmux @('set-hook','-g',$hook,'set-buffer HOOKFIRED') | Out-Null
        Invoke-Psmux @('select-pane','-t',"${SESSION}:0.1") | Out-Null
        $counts += (Get-FiringCount)
    }
    if (($counts | Where-Object { $_ -ne 1 }).Count -eq 0) {
        Write-Pass "$hook fires once on a pane change with focus-events on, three runs of three"
    } else {
        Write-Fail "$hook fired $($counts -join '/') times on a pane change, want 1 each (#691 counted 0)"
    }
}
# focus-events off is tmux's default and must stay silent (window.c:722).
$off = @()
for ($r = 1; $r -le 3; $r++) {
    New-Fixture $paneSetup
    Invoke-Psmux @('set-hook','-g','pane-focus-in','set-buffer HOOKFIRED') | Out-Null
    Invoke-Psmux @('select-pane','-t',"${SESSION}:0.1") | Out-Null
    $off += (Get-FiringCount)
}
if (($off | Where-Object { $_ -ne 0 }).Count -eq 0) {
    Write-Pass "pane-focus-in stays silent with focus-events off, tmux's default"
} else {
    Write-Fail "pane-focus-in fired $($off -join '/') times with focus-events off, want 0 each"
}

# ---------------------------------------------------------------------------
# client-session-changed, which needs a real client.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- client-session-changed on a real attach ---" -ForegroundColor Yellow
$csc = @()
for ($r = 1; $r -le 3; $r++) {
    New-Fixture @()
    Invoke-Psmux @('set-hook','-g','client-session-changed','set-buffer HOOKFIRED') | Out-Null
    Start-Sleep -Milliseconds 250
    $proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"attach","-t",$SESSION -PassThru
    Start-Sleep -Milliseconds 2500
    $csc += (Get-FiringCount)
    try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } } catch {}
    Start-Sleep -Milliseconds 400
}
Write-Info "counts: $($csc -join ', ')"
if (($csc | Where-Object { $_ -ne 1 }).Count -eq 0) {
    Write-Pass "client-session-changed fires once when a client attaches, three runs of three"
} else {
    Write-Fail "client-session-changed fired $($csc -join '/') times on attach, want 1 each (#691 counted 0)"
}

# ---------------------------------------------------------------------------
# session-created, which can only fire at server start: psmux runs one server
# per session, so a NEW session is a new process with an empty hook map, and a
# hook set in one server can never see another's creation. A config hook is
# the only way to have it registered in time, and that is what the docs say.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- session-created, at server start, from a config hook ---" -ForegroundColor Yellow
$conf = Join-Path $root "i691.conf"
Set-Content -Path $conf -Value 'set-hook -g session-created "set-buffer HOOKFIRED"'
$created = @()
$later = @()
for ($r = 1; $r -le 3; $r++) {
    Stop-Srv
    & $PSMUX -L $NS -f $conf new-session -d -s $SESSION -x 80 -y 24 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    $created += (Get-FiringCount)
    & $PSMUX -L $NS -f $conf new-window -t $SESSION 2>&1 | Out-Null
    $later += (Get-FiringCount)
}
Write-Info "at server start: $($created -join ', ')   after a new-window: $($later -join ', ')"
if (($created | Where-Object { $_ -ne 1 }).Count -eq 0) {
    Write-Pass "session-created fires once at server start"
} else {
    Write-Fail "session-created fired $($created -join '/') times at server start, want 1 each"
}
if (($later | Where-Object { $_ -ne 1 }).Count -eq 0) {
    Write-Pass "and nothing else in the session fires it again"
} else {
    Write-Fail "session-created fired again later: $($later -join '/')"
}

# ---------------------------------------------------------------------------
# The rest of the table, one firing each, so a change that doubles or silences
# one of THEM is caught here too.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- the rest of the docs table, one firing each ---" -ForegroundColor Yellow
$sweep = [ordered]@{
  'after-new-window'     = @{ setup=@(); trigger="new-window -t $SESSION" }
  'after-split-window'   = @{ setup=@(); trigger="split-window -d -t ${SESSION}:0" }
  'after-kill-pane'      = @{ setup=@("split-window -d -t ${SESSION}:0"); trigger="kill-pane -t ${SESSION}:0.1" }
  'after-select-window'  = @{ setup=@("new-window -t $SESSION"); trigger="select-window -t ${SESSION}:0" }
  'before-select-window' = @{ setup=@("new-window -t $SESSION"); trigger="select-window -t ${SESSION}:0" }
  'after-rename-window'  = @{ setup=@(); trigger="rename-window -t ${SESSION}:0 renamed691" }
  'after-rename-session' = @{ setup=@(); trigger="rename-session -t $SESSION i691_r" }
  'after-resize-pane'    = @{ setup=@("split-window -d -t ${SESSION}:0"); trigger="resize-pane -t ${SESSION}:0.0 -D 2" }
  'after-rotate-window'  = @{ setup=@("split-window -d -t ${SESSION}:0"); trigger="rotate-window -t ${SESSION}:0" }
  'after-break-pane'     = @{ setup=@("split-window -d -t ${SESSION}:0"); trigger="break-pane -d -s ${SESSION}:0.1" }
  'after-join-pane'      = @{ setup=@("new-window -t $SESSION"); trigger="join-pane -d -s ${SESSION}:1 -t ${SESSION}:0" }
  'after-respawn-pane'   = @{ setup=@(); trigger="respawn-pane -k -t ${SESSION}:0.0" }
  'window-closed'        = @{ setup=@("new-window -t $SESSION"); trigger="kill-window -t ${SESSION}:1" }
  'pane-mode-changed'    = @{ setup=@(); trigger="copy-mode -t ${SESSION}:0.0" }
}
foreach ($name in $sweep.Keys) {
    New-Fixture $sweep[$name].setup
    Invoke-Psmux @('set-hook','-g',$name,'set-buffer HOOKFIRED') | Out-Null
    Invoke-Psmux ($sweep[$name].trigger -split ' ') | Out-Null
    $n = Get-FiringCount
    if ($n -eq 1) { Write-Pass "$name fired once" }
    else { Write-Fail "$name fired $n times, want 1" }
}

# ---------------------------------------------------------------------------
# Every hook the table lists must be reachable. This is the promise #691 is
# about: a name in the table that fires nowhere is a documentation bug.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- no name in the docs table fires nowhere ---" -ForegroundColor Yellow
$docsTable = Join-Path (Split-Path -Parent $repoTests) "docs\scripting.md"
if (-not (Test-Path $docsTable)) {
    Write-Skip "docs\scripting.md not found next to the tests"
} else {
    $listed = @()
    $inTable = $false
    foreach ($line in Get-Content $docsTable) {
        if ($line -match '^### Available Hook Events') { $inTable = $true; continue }
        if ($inTable -and $line -match '^###') { break }
        if ($inTable -and $line -match '^\|\s*`([a-z-]+)`\s*\|') { $listed += $Matches[1] }
    }
    Write-Info "the table lists $($listed.Count) hooks"
    # Everything this file has proved fires, plus the ones driven by a pane
    # process or a client event rather than a command.
    $proven = @(
        'after-new-window','after-split-window','after-kill-pane','after-select-window',
        'before-select-window','after-select-pane','after-rename-window','after-rename-session',
        'after-resize-pane','after-swap-pane','after-rotate-window','after-break-pane',
        'after-join-pane','after-respawn-pane','after-select-layout','after-swap-window',
        'client-session-changed','session-created','pane-focus-in','pane-focus-out',
        'window-linked','window-unlinked','window-closed','pane-mode-changed'
    )
    # Covered by their own suites, not re-driven here.
    $elsewhere = @(
        'client-attached','client-detached','client-resized','session-closed',
        'pane-died','pane-exited','pane-set-clipboard',
        'alert-activity','alert-silence','alert-bell'
    )
    $orphans = $listed | Where-Object { $_ -notin $proven -and $_ -notin $elsewhere }
    if ($listed.Count -eq 0) {
        Write-Fail "could not parse the hook table out of docs\scripting.md"
    } elseif ($orphans.Count -eq 0) {
        Write-Pass "every hook in the docs table is either proved here or owned by another suite"
    } else {
        Write-Fail "the docs table lists hooks nothing accounts for: $($orphans -join ', ')"
    }
}

Stop-Srv
Remove-Item -Recurse -Force $root -EA SilentlyContinue
if ($null -ne $savedDataDir) { $env:PSMUX_DATA_DIR = $savedDataDir } else { Remove-Item env:PSMUX_DATA_DIR -EA SilentlyContinue }
if ($null -ne $savedNoWarm)  { $env:PSMUX_NO_WARM  = $savedNoWarm }  else { Remove-Item env:PSMUX_NO_WARM  -EA SilentlyContinue }

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Magenta
Write-Host "  Passed:  $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed:  $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped: $script:TestsSkipped" -ForegroundColor Yellow
exit $(if ($script:TestsFailed -gt 0) { 1 } else { 0 })
