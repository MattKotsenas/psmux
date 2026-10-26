# Issue #692: `select-window -t 0` did nothing while `-t :0` worked, and the
# report also said `-t @1` did not switch while `@2` and `@3` did.
#
# Half of that reproduced and half did not, and this file pins both halves.
#
# THE BARE NUMBER. Three windows, parked on window 2, `select-window -t 0`:
#
#     CLI     rc=1  "psmux: no server running on session 'h691__0'"  2 -> 2
#     socket  2/@3 -> 2/@3
#     binding 2/@3 -> 2/@3     (binding stored, key delivered, nothing moved)
#     prompt  2/@3 -> 2/@3
#
# three runs on each route, while `-t :0` moved to window 0 every time. The
# cause is one sentence in cli.rs parse_target: "A bare string without ':' or
# '.' is always a session name, even if numeric", so the window number was
# looked up as a SESSION.
#
# tmux resolves a window command's -t through cmd_find_get_window
# (cmd-find.c:328): the CURRENT session, then cmd_find_get_window_with_session,
# which tries "a valid window index in this session" at cmd-find.c:443, and
# only then tries the token as a session (cmd-find.c:348).
#
# THE WINDOW ID. Not reproduced. A 16 case matrix (a 2 window and a 4 window
# fixture, parking on each window in turn and selecting every id) was OK on all
# 16, three runs, on the CLI, the socket, a binding and the prompt. Ids start at
# @1, so in a fixture parked on window 0 the id @1 IS the active window and
# "does not switch" is what selecting it looks like. `@0` never exists. The
# walk from @0 to @3 below keeps a real regression from hiding.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i692tgt" }
$SESSION = "i692_s"

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
$root = Join-Path $env:TEMP "psmux_i692_target"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

Write-Host ""
Write-Host "=== Issue #692: select-window target resolution ===" -ForegroundColor Magenta
Write-Info "Binary: $PSMUX"
Write-Info "Namespace: $NS   data: $($env:PSMUX_DATA_DIR)"

function Invoke-Psmux([string[]]$a) { & $PSMUX -L $NS @a 2>&1 }
function Stop-Srv { Invoke-Psmux @('kill-server') | Out-Null; Start-Sleep -Milliseconds 350 }

# Three windows (0, 1, 2 with ids @1, @2, @3), parked on window 2.
function New-Fixture {
    Stop-Srv
    Invoke-Psmux @('new-session','-d','-s',$SESSION,'-x','80','-y','24') | Out-Null
    Start-Sleep -Milliseconds 250
    Invoke-Psmux @('new-window','-t',$SESSION) | Out-Null
    Invoke-Psmux @('new-window','-t',$SESSION) | Out-Null
    Start-Sleep -Milliseconds 300
    Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
    Start-Sleep -Milliseconds 200
}
function Get-Where { (Invoke-Psmux @('display-message','-p','-t',$SESSION,'#{window_index}/#{window_id}')) -join '' }

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

# --- Route 1: the CLI ------------------------------------------------------
Write-Host ""
Write-Host "--- Route 1: the CLI ---" -ForegroundColor Yellow
$cli = @()
for ($r = 1; $r -le 3; $r++) {
    New-Fixture
    Invoke-Psmux @('select-window','-t','0') | Out-Null
    Start-Sleep -Milliseconds 250
    $cli += (Get-Where)
}
Write-Info "select-window -t 0 landed on: $($cli -join ', ')"
if (($cli | Where-Object { $_ -ne '0/@1' }).Count -eq 0) {
    Write-Pass "CLI select-window -t 0 selects window 0, three runs of three"
} else {
    Write-Fail "CLI select-window -t 0 landed on $($cli -join '/'), want 0/@1 each (#692 stayed on 2/@3)"
}

# The colon form, which always worked, must keep working.
New-Fixture
Invoke-Psmux @('select-window','-t',':1') | Out-Null
Start-Sleep -Milliseconds 250
$colon = Get-Where
if ($colon -eq '1/@2') { Write-Pass "select-window -t :1 still selects window 1" }
else { Write-Fail "select-window -t :1 landed on $colon, want 1/@2" }

# A bare number that names no window is tmux's error, not a silent no-op.
New-Fixture
$miss = Invoke-Psmux @('select-window','-t','9')
$missRc = $LASTEXITCODE
Start-Sleep -Milliseconds 250
$after = Get-Where
if ($missRc -eq 1 -and ($miss -join '') -match "can't find window: 9" -and $after -eq '2/@3') {
    Write-Pass "select-window -t 9 exits 1 with `"can't find window: 9`" and selects nothing"
} else {
    Write-Fail "select-window -t 9 gave rc=$missRc '$($miss -join '|')' and landed on $after"
}

# A bare number must not have stolen the SESSION meaning from commands whose
# -t really is a session.
New-Fixture
$sess = Invoke-Psmux @('has-session','-t','0')
$sessRc = $LASTEXITCODE
if ($sessRc -ne 0) {
    Write-Pass "has-session -t 0 still reads 0 as a SESSION name (rc=$sessRc)"
} else {
    Write-Fail "has-session -t 0 succeeded, so a bare number leaked into session targets"
}

# --- Route 2: the raw control socket ---------------------------------------
Write-Host ""
Write-Host "--- Route 2: the raw control socket ---" -ForegroundColor Yellow
$tcp = @()
$socketOk = $true
for ($r = 1; $r -le 3; $r++) {
    New-Fixture
    $resp = Send-OverSocket "select-window -t 0"
    if ($resp -in @('NO_PORT_FILE','NO_KEY_FILE','AUTH_FAILED')) { $socketOk = $false; break }
    Start-Sleep -Milliseconds 300
    $tcp += (Get-Where)
}
if (-not $socketOk) {
    Write-Skip "control socket did not accept a connection on this host"
} else {
    Write-Info "select-window -t 0 landed on: $($tcp -join ', ')"
    if (($tcp | Where-Object { $_ -ne '0/@1' }).Count -eq 0) {
        Write-Pass "socket select-window -t 0 selects window 0, three runs of three"
    } else {
        Write-Fail "socket select-window -t 0 landed on $($tcp -join '/'), want 0/@1 each (#692 stayed on 2/@3)"
    }
}

# --- every window id, @0 through @3 ----------------------------------------
Write-Host ""
Write-Host "--- @0 through @3, every id, from every window ---" -ForegroundColor Yellow
New-Fixture
Invoke-Psmux @('new-window','-t',$SESSION) | Out-Null   # 4 windows, @1..@4
Start-Sleep -Milliseconds 300
$ids  = @(Invoke-Psmux @('list-windows','-t',$SESSION,'-F','#{window_id}'))
$idxs = @(Invoke-Psmux @('list-windows','-t',$SESSION,'-F','#{window_index}'))
Write-Info "windows: $($idxs -join ',')   ids: $($ids -join ',')"
$idFailures = @()
foreach ($park in $idxs) {
    foreach ($id in $ids) {
        Invoke-Psmux @('select-window','-t',"${SESSION}:$park") | Out-Null
        Start-Sleep -Milliseconds 120
        Invoke-Psmux @('select-window','-t',$id) | Out-Null
        Start-Sleep -Milliseconds 150
        $landed = (Invoke-Psmux @('display-message','-p','-t',$SESSION,'#{window_id}')) -join ''
        if ($landed -ne $id) { $idFailures += "parked on $park, -t $id landed on $landed" }
    }
}
if ($idFailures.Count -eq 0) {
    Write-Pass "every @id selects its window from every starting window ($($idxs.Count)x$($ids.Count) cases)"
} else {
    Write-Fail "@id selection missed: $($idFailures -join '; ')"
}

# @0 never exists: ids start at @1. tmux's wording, exit 1, nothing selected.
Invoke-Psmux @('select-window','-t',"${SESSION}:2") | Out-Null
Start-Sleep -Milliseconds 150
$zero = Invoke-Psmux @('select-window','-t','@0')
$zeroRc = $LASTEXITCODE
Start-Sleep -Milliseconds 200
$zeroAfter = (Invoke-Psmux @('display-message','-p','-t',$SESSION,'#{window_index}')) -join ''
if ($zeroRc -eq 1 -and ($zero -join '') -match "can't find window: @0" -and $zeroAfter -eq '2') {
    Write-Pass "select-window -t @0 exits 1 with `"can't find window: @0`" and selects nothing"
} else {
    Write-Fail "select-window -t @0 gave rc=$zeroRc '$($zero -join '|')' and landed on window $zeroAfter"
}

# --- Routes 3 and 4: a binding and the command prompt ----------------------
Write-Host ""
Write-Host "--- Routes 3 and 4: a binding and the command prompt ---" -ForegroundColor Yellow
$injectorExe = Join-Path $root "injector692.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
& $csc /nologo /optimize /out:$injectorExe (Join-Path $repoTests "injector.cs") 2>&1 | Out-Null

if (-not (Test-Path $injectorExe)) {
    Write-Skip "injector.cs did not compile; the binding and prompt routes need it"
} else {
    # The reporter's exact binding: a BARE 0, not the colon form the built in
    # digit bindings use, pressed through a real attached client.
    foreach ($route in @('binding','prompt')) {
        foreach ($target in @('0','@1')) {
            $landed = @()
            $delivered = $true
            for ($r = 1; $r -le 3; $r++) {
                New-Fixture
                if ($route -eq 'binding') {
                    Invoke-Psmux @('bind-key','j','select-window','-t',$target) | Out-Null
                    Start-Sleep -Milliseconds 250
                }
                $proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"attach","-t",$SESSION -PassThru
                Start-Sleep -Milliseconds 2500
                $before = Get-Where
                if ($route -eq 'binding') {
                    & $injectorExe $proc.Id '^b{SLEEP:500}j{SLEEP:900}' | Out-Null
                } else {
                    & $injectorExe $proc.Id ('^b{SLEEP:500}:{SLEEP:600}select-window -t ' + $target + '{SLEEP:300}{ENTER}{SLEEP:900}') | Out-Null
                }
                Start-Sleep -Milliseconds 1200
                $landed += (Get-Where)
                if ($before -ne '2/@3') { $delivered = $false }
                try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } } catch {}
                Start-Sleep -Milliseconds 350
            }
            Write-Info "$route select-window -t $target landed on: $($landed -join ', ')"
            if (-not $delivered) {
                Write-Skip "$route route -t ${target}: the client never reached the fixture window on this host"
            } elseif (($landed | Where-Object { $_ -ne '0/@1' }).Count -eq 0) {
                Write-Pass "$route select-window -t $target selects window 0, three runs of three"
            } else {
                Write-Fail "$route select-window -t $target landed on $($landed -join '/'), want 0/@1 each (#692 stayed on 2/@3)"
            }
        }
    }
}

# --- move-window and swap-window keep their #602 forms ---------------------
Write-Host ""
Write-Host "--- the #602 symbolic forms are untouched ---" -ForegroundColor Yellow
New-Fixture
Invoke-Psmux @('select-window','-t',"${SESSION}:0") | Out-Null
Start-Sleep -Milliseconds 200
Invoke-Psmux @('move-window','-t','7') | Out-Null
Start-Sleep -Milliseconds 300
$moved = @(Invoke-Psmux @('list-windows','-t',$SESSION,'-F','#{window_index}'))
if ($moved -contains '7') {
    Write-Pass "move-window -t 7 still moves the window to index 7 (#602)"
} else {
    Write-Fail "move-window -t 7 left the window list at $($moved -join ',')"
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
