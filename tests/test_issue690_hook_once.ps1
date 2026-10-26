# Issue #690: one `select-window` fired `after-select-window` TWICE.
#
# The reporter's four commands, and what they printed on master 519d2de:
#
#     psmux -L h new-session -d -s s -x 80 -y 24
#     psmux -L h new-window -t s
#     psmux -L h set-hook -g after-select-window "set-buffer HOOKFIRED"
#     psmux -L h select-window -t s:0
#     psmux -L h list-buffers
#         buffer0: 9 bytes: "HOOKFIRED"
#         buffer1: 9 bytes: "HOOKFIRED"
#
# `set-buffer` with no -b makes a NEW buffer every time, so the buffer count
# IS the firing count.  Two buffers, one command.  A hook that pastes landed
# its text twice, which is why the targeted paste in
# tests\test_issue684_paste_route.ps1 arrived as 46 bytes, two copies of 23.
#
# It counted 2 three runs out of three on every route, because the doubling
# was on the server side of all of them: `select-window -t <index>` sent TWO
# control requests for the same window, a permanent `FocusWindow` from the
# generic -t focus block and a `SelectWindow` from the command's own arm, and
# every request carries its own hook slot in the server loop.  With
# PSMUX_HOOK_DEBUG pointed at a file the two carriers are named:
#
#     === FIRE after-select-window req=FocusWindow pid=3600 ===
#     === FIRE after-select-window req=SelectWindow pid=3600 ===
#
# tmux fires a command's after hook once, from the command queue: cmd-queue.c
# `cmdq_fire_command` calls `cmdq_insert_hook(s, item, &fs, "after-%s", name)`
# once, after the command's exec returns.
#
# This file drives all four routes a command can arrive on and asserts ONE
# firing on each:
#
#   1. the CLI                  psmux -L ns select-window -t s:0
#   2. the raw control socket   AUTH <key> then the command line
#   3. a key binding            bind-key j, injected into a real attached
#                               client with tests\injector.cs
#   4. the command prompt       prefix : select-window -t :0 Enter, same client
#
# and then sweeps the other hooks that fire on a targeted command, so a future
# change that doubles one of THEM is caught here too.  Counts on a pre fix
# build: after-select-window 2 on all four routes, everything else 1.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i690hook" }
$SESSION = "i690_s"

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

$root = Join-Path $env:TEMP "psmux_i690_hook"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

Write-Host ""
Write-Host "=== Issue #690: one command, one hook firing ===" -ForegroundColor Magenta
Write-Info "Binary: $PSMUX"
Write-Info "Namespace: $NS   data: $($env:PSMUX_DATA_DIR)"

function Invoke-Psmux([string[]]$a) { & $PSMUX -L $NS @a 2>&1 }

function Stop-Srv {
    Invoke-Psmux @('kill-server') | Out-Null
    Start-Sleep -Milliseconds 350
}

# A fresh server with two windows, window 1 active, and no hook set yet.
function New-Fixture([string[]]$Setup) {
    Stop-Srv
    Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
    Start-Sleep -Milliseconds 250
    foreach ($s in $Setup) { Invoke-Psmux ($s -split ' ') | Out-Null }
    Start-Sleep -Milliseconds 250
}

# `set-buffer` with no -b appends a new buffer per run, so this is the count.
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

# --- routes 1 and 2: the CLI and the raw control socket --------------------
Write-Host ""
Write-Host "--- Route 1: the CLI ---" -ForegroundColor Yellow
$cliCounts = @()
for ($r = 1; $r -le 3; $r++) {
    New-Fixture @("new-window -t $SESSION")
    Invoke-Psmux @('set-hook','-g','after-select-window','set-buffer HOOKFIRED') | Out-Null
    Invoke-Psmux @('select-window','-t',"${SESSION}:0") | Out-Null
    $cliCounts += (Get-FiringCount)
}
Write-Info "counts: $($cliCounts -join ', ')"
if (($cliCounts | Where-Object { $_ -ne 1 }).Count -eq 0) {
    Write-Pass "CLI select-window fires after-select-window once, three runs of three"
} else {
    Write-Fail "CLI select-window fired after-select-window $($cliCounts -join '/') times, want 1 each (#690 counted 2)"
}

Write-Host ""
Write-Host "--- Route 2: the raw control socket ---" -ForegroundColor Yellow
$tcpCounts = @()
for ($r = 1; $r -le 3; $r++) {
    New-Fixture @("new-window -t $SESSION")
    Invoke-Psmux @('set-hook','-g','after-select-window','set-buffer HOOKFIRED') | Out-Null
    $resp = Send-OverSocket "select-window -t ${SESSION}:0"
    if ($resp -in @('NO_PORT_FILE','NO_KEY_FILE','AUTH_FAILED')) {
        Write-Info "socket unavailable: $resp"
        $tcpCounts += -1
    } else {
        $tcpCounts += (Get-FiringCount)
    }
}
Write-Info "counts: $($tcpCounts -join ', ')"
if ($tcpCounts -contains -1) {
    Write-Skip "control socket did not accept a connection on this host"
} elseif (($tcpCounts | Where-Object { $_ -ne 1 }).Count -eq 0) {
    Write-Pass "socket select-window fires after-select-window once, three runs of three"
} else {
    Write-Fail "socket select-window fired after-select-window $($tcpCounts -join '/') times, want 1 each (#690 counted 2)"
}

# --- the other hooks a targeted command fires ------------------------------
# Only the hooks that DO fire on this route are listed.  `after-select-pane`,
# `window-linked`, `session-created`, `after-swap-pane`, `after-select-layout`
# and `after-swap-window` fire zero times on master and on the fix alike; they
# are a separate defect and are deliberately not asserted here.
Write-Host ""
Write-Host "--- The other hooks, one firing each ---" -ForegroundColor Yellow
$sweep = [ordered]@{
  'after-new-window'     = @{ setup=@(); trigger="new-window -t $SESSION" }
  'after-split-window'   = @{ setup=@(); trigger="split-window -t ${SESSION}:0" }
  'after-kill-pane'      = @{ setup=@("split-window -d -t ${SESSION}:0"); trigger="kill-pane -t ${SESSION}:0.1" }
  'after-rename-window'  = @{ setup=@(); trigger="rename-window -t ${SESSION}:0 renamed690" }
  'after-resize-pane'    = @{ setup=@("split-window -d -t ${SESSION}:0"); trigger="resize-pane -t ${SESSION}:0.0 -D 2" }
  'after-rename-session' = @{ setup=@(); trigger="rename-session -t $SESSION i690_r" }
  'after-rotate-window'  = @{ setup=@("split-window -d -t ${SESSION}:0"); trigger="rotate-window -t ${SESSION}:0" }
  'after-break-pane'     = @{ setup=@("split-window -d -t ${SESSION}:0"); trigger="break-pane -d -s ${SESSION}:0.1" }
  'after-join-pane'      = @{ setup=@("new-window -t $SESSION"); trigger="join-pane -d -s ${SESSION}:1 -t ${SESSION}:0" }
  'after-respawn-pane'   = @{ setup=@(); trigger="respawn-pane -k -t ${SESSION}:0.0" }
  'window-closed'        = @{ setup=@("new-window -t $SESSION"); trigger="kill-window -t ${SESSION}:1" }
  'before-select-window' = @{ setup=@("new-window -t $SESSION"); trigger="select-window -t ${SESSION}:0" }
}
foreach ($name in $sweep.Keys) {
    New-Fixture $sweep[$name].setup
    Invoke-Psmux @('set-hook','-g',$name,'set-buffer HOOKFIRED') | Out-Null
    Invoke-Psmux ($sweep[$name].trigger -split ' ') | Out-Null
    $n = Get-FiringCount
    if ($n -eq 1) { Write-Pass "$name fired once" }
    else { Write-Fail "$name fired $n times, want 1" }
}

# --- routes 3 and 4: a key binding and the command prompt ------------------
Write-Host ""
Write-Host "--- Routes 3 and 4: a binding and the command prompt ---" -ForegroundColor Yellow
$injectorExe = Join-Path $root "injector690.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
& $csc /nologo /optimize /out:$injectorExe (Join-Path $repoTests "injector.cs") 2>&1 | Out-Null

if (-not (Test-Path $injectorExe)) {
    Write-Skip "injector.cs did not compile; the binding and prompt routes need it"
} else {
    foreach ($route in @('binding','prompt')) {
        $counts = @()
        $delivered = $true
        for ($r = 1; $r -le 3; $r++) {
            New-Fixture @("new-window -t $SESSION")
            # A binding whose target carries the colon: a bare `-t 0` from a
            # binding resolves to nothing, which is its own defect.
            Invoke-Psmux @('bind-key','j','select-window','-t',':0') | Out-Null
            Start-Sleep -Milliseconds 250

            $proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"attach","-t",$SESSION -PassThru
            Start-Sleep -Milliseconds 2500

            # The hook goes on only once the client is attached and settled, so
            # the attach itself cannot contribute a firing.
            Invoke-Psmux @('set-hook','-g','after-select-window','set-buffer HOOKFIRED') | Out-Null
            Start-Sleep -Milliseconds 400

            $before = (Invoke-Psmux @('display-message','-p','-t',$SESSION,'#{window_index}')) -join ''
            if ($route -eq 'binding') {
                & $injectorExe $proc.Id '^b{SLEEP:500}j{SLEEP:900}' | Out-Null
            } else {
                & $injectorExe $proc.Id '^b{SLEEP:500}:{SLEEP:600}select-window -t :0{SLEEP:300}{ENTER}{SLEEP:900}' | Out-Null
            }
            Start-Sleep -Milliseconds 1200
            $after = (Invoke-Psmux @('display-message','-p','-t',$SESSION,'#{window_index}')) -join ''
            $counts += (Get-FiringCount)

            # A run where the keys never reached the client proves nothing.
            if ($before -ne '1' -or $after -ne '0') { $delivered = $false }

            try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } } catch {}
            Start-Sleep -Milliseconds 350
        }
        Write-Info "$route counts: $($counts -join ', ')"
        if (-not $delivered) {
            Write-Skip "$route route: the injected keys did not reach the attached client on this host"
        } elseif (($counts | Where-Object { $_ -ne 1 }).Count -eq 0) {
            Write-Pass "$route select-window fires after-select-window once, three runs of three"
        } else {
            Write-Fail "$route select-window fired after-select-window $($counts -join '/') times, want 1 each (#690 counted 2)"
        }
    }
}

# --- the selection itself is unchanged -------------------------------------
# Every select-window form must land where it landed before #690 moved the
# decision into one place.
Write-Host ""
Write-Host "--- select-window still selects ---" -ForegroundColor Yellow
Stop-Srv
Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
Invoke-Psmux @('new-window','-t',$SESSION) | Out-Null
Invoke-Psmux @('new-window','-t',$SESSION) | Out-Null
Start-Sleep -Milliseconds 400
function Get-Idx { (Invoke-Psmux @('display-message','-p','-t',$SESSION,'#{window_index}')) -join '' }
$forms = @(
    @{ desc = "-t ${SESSION}:0"; args = @('select-window','-t',"${SESSION}:0"); want = '0' },
    @{ desc = "-t ${SESSION}:2"; args = @('select-window','-t',"${SESSION}:2"); want = '2' },
    @{ desc = "-t $SESSION -l";  args = @('select-window','-t',$SESSION,'-l');  want = '0' },
    @{ desc = "-t $SESSION -n";  args = @('select-window','-t',$SESSION,'-n');  want = '1' },
    @{ desc = "-t $SESSION -p";  args = @('select-window','-t',$SESSION,'-p');  want = '0' }
)
foreach ($f in $forms) {
    Invoke-Psmux $f.args | Out-Null
    Start-Sleep -Milliseconds 300
    $got = Get-Idx
    if ($got -eq $f.want) { Write-Pass "select-window $($f.desc) -> window $got" }
    else { Write-Fail "select-window $($f.desc) -> window $got, want $($f.want)" }
}

# A bad target is still rejected with tmux's wording and exit 1, and fires no
# hook at all.
Invoke-Psmux @('set-hook','-g','after-select-window','set-buffer HOOKFIRED') | Out-Null
Invoke-Psmux @('delete-buffer') | Out-Null
$bad = (Invoke-Psmux @('select-window','-t',"${SESSION}:99")) -join ''
$badRc = $LASTEXITCODE
Start-Sleep -Milliseconds 400
$badCount = @((Invoke-Psmux @('list-buffers')) | Where-Object { $_ -match 'HOOKFIRED' }).Count
if ($badRc -eq 1 -and $bad -match "can't find window") {
    Write-Pass "select-window -t ${SESSION}:99 exits 1 with `"$bad`""
} else {
    Write-Fail "select-window -t ${SESSION}:99 exited $badRc with `"$bad`", want 1 and tmux's wording"
}
if ($badCount -eq 0) { Write-Pass "an unresolvable target fires no hook" }
else { Write-Fail "an unresolvable target fired after-select-window $badCount times" }

# The alert clearing FocusWindow used to do has to survive the move: a bell in
# a window must be gone once that window is selected.
Write-Host ""
Write-Host "--- selecting a window still clears its alert ---" -ForegroundColor Yellow
Stop-Srv
Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
Invoke-Psmux @('new-window','-t',$SESSION) | Out-Null
Invoke-Psmux @('set-option','-g','monitor-bell','on') | Out-Null
Start-Sleep -Milliseconds 400
# Ring the bell in window 0 while window 1 is active.
Invoke-Psmux @('send-keys','-t',"${SESSION}:0",'echo "`a"','Enter') | Out-Null
Start-Sleep -Milliseconds 1500
$flagBefore = (Invoke-Psmux @('list-windows','-t',$SESSION,'-F','#{window_index}:#{window_bell_flag}')) -join ' '
Invoke-Psmux @('select-window','-t',"${SESSION}:0") | Out-Null
Start-Sleep -Milliseconds 600
$flagAfter = (Invoke-Psmux @('list-windows','-t',$SESSION,'-F','#{window_index}:#{window_bell_flag}')) -join ' '
Write-Info "bell flags before: $flagBefore   after: $flagAfter"
if ($flagBefore -match '0:1') {
    if ($flagAfter -match '0:0') { Write-Pass "selecting window 0 cleared its bell flag" }
    else { Write-Fail "window 0 kept its bell flag after being selected: $flagAfter" }
} else {
    Write-Skip "the bell did not set window 0's flag on this host, nothing to clear"
}

Stop-Srv

if ($savedDataDir) { $env:PSMUX_DATA_DIR = $savedDataDir } else { Remove-Item env:PSMUX_DATA_DIR -EA SilentlyContinue }
if ($savedNoWarm)  { $env:PSMUX_NO_WARM  = $savedNoWarm }  else { Remove-Item env:PSMUX_NO_WARM  -EA SilentlyContinue }

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Magenta
Write-Host "  Passed:  $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed:  $($script:TestsFailed)" -ForegroundColor Red
Write-Host "  Skipped: $($script:TestsSkipped)" -ForegroundColor Yellow
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
