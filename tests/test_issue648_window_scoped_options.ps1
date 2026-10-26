# Issue #648 (split out of #647 WIN-01, reported by keith9681): window scoped
# options must live on the window.
#
# THE REPORT
#
#     tmux new-session -d -s s -n zero
#     tmux new-window -d -t "s:" -n one
#     tmux set-option -w -t "s:zero" remain-on-exit on
#
#     psmux 3.3.8: zero=on one=on          global=on
#     tmux 3.4:    zero=on one=<inherited> global=off
#
# psmux kept ONE ordinary option store per server, so `-w` and `-g` selected the
# same map and a window targeted write landed on every window and on the global.
# That is not cosmetic: reap_children read the one flag for every window, so the
# reporter's ordinary PowerShell panes - in a DIFFERENT window from the gateway
# - stopped closing after `exit`. On top of that, `-t "s:zero"` was parsed for
# its numeric half only, so the NAME was thrown away and the write silently
# acted on the active window.
#
# THE ORACLE
#
# Every expectation below was measured against tmux 3.4 under WSL on
# `tmux -L p648` before any psmux code was written:
#
#     set -w -t s:zero remain-on-exit on
#       show -w -v -t s:zero -> on      show -w -v -t s:one -> (empty)
#       show -g -v           -> off
#       show -wA -t s:zero   -> "remain-on-exit on"
#       show -wA -t s:one    -> "remain-on-exit* off"
#     set -w -u -t s:zero remain-on-exit  -> s:zero inherits again
#     set -wg remain-on-exit on           -> global on, s:zero still inherits
#     set -p on a pane beats set -w on its window
#       show -w -t s:one     -> the option is ABSENT, not resolved (#655)
#
# psmux reports the RESOLVED value where tmux prints a blank for an unset window
# option, which is what tmux's own `show -wA -v` prints; libtmux and tmuxp probe
# window scope and depend on getting an answer (#321). The `*` marker makes
# local and inherited distinguishable on both. Everything else matches exactly.
#
# Usage: pwsh -NoProfile -File tests\test_issue648_window_scoped_options.ps1
#        pwsh -NoProfile -File tests\test_issue648_window_scoped_options.ps1 -Binary <path>

param([string]$Binary = "")

$ErrorActionPreference = "Continue"

$PSMUX = ""
if ($Binary) { $PSMUX = (Resolve-Path $Binary -EA SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

# Unique namespaces so a parallel suite cannot collide with this run.
$NS        = "ns648"
$SESSION   = "test_issue648"
$TUISESS   = "test_issue648tui"
$CFGSESS   = "test_issue648cfg"
$PSMUX_DIR = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor Gray }

# Run psmux with an exact argv (no shell re-tokenizing) and capture rc/out/err.
function Invoke-Psmux([string[]]$ArgList) {
    $so = Join-Path $env:TEMP "t648_out.txt"
    $se = Join-Path $env:TEMP "t648_err.txt"
    $p = Start-Process -FilePath $PSMUX -ArgumentList $ArgList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $so -RedirectStandardError $se
    [pscustomobject]@{
        rc  = $p.ExitCode
        out = "$(Get-Content $so -Raw -ErrorAction SilentlyContinue)".Trim()
        err = "$(Get-Content $se -Raw -ErrorAction SilentlyContinue)".Trim()
    }
}

# Window-scoped read for one window: `show-options -w -v -t <window> <name>`.
function Read-WinOpt($target, $name) {
    (Invoke-Psmux @('show-options', '-w', '-v', '-t', $target, $name)).out
}
function Read-GlobalOpt($sess, $name) {
    (Invoke-Psmux @('show-options', '-g', '-v', '-t', $sess, $name)).out
}

# Raw TCP straight at the server, bypassing the CLI guard entirely, so the
# server-side parser is measured on its own.
function Send-TcpCommand {
    param([string]$Session, [string]$Command, [int]$TimeoutMs = 5000)
    try {
        $port = (Get-Content "$PSMUX_DIR\$Session.port" -Raw).Trim()
        $key  = (Get-Content "$PSMUX_DIR\$Session.key" -Raw).Trim()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.NoDelay = $true
        $tcp.Connect("127.0.0.1", [int]$port)
        $ns = $tcp.GetStream()
        $ns.ReadTimeout = $TimeoutMs
        $wr = New-Object System.IO.StreamWriter($ns); $wr.AutoFlush = $true
        $rd = New-Object System.IO.StreamReader($ns)
        $wr.WriteLine("AUTH $key")
        $auth = $rd.ReadLine()
        if ($auth -ne "OK") { $tcp.Close(); return @{ ok = $false; err = "AUTH_FAIL" } }
        $wr.WriteLine($Command)
        $lines = @()
        try {
            while ($true) {
                $line = $rd.ReadLine()
                if ($null -eq $line) { break }
                $lines += $line
                # Read to EOF: a one-shot reply ends when the server closes the
                # connection (ReadLine returns null), bounded by ReadTimeout. A quiet
                # socket is not the end of a reply.
            }
        } catch {}
        $tcp.Close()
        return @{ ok = $true; resp = ($lines -join "`n"); lines = $lines }
    } catch { return @{ ok = $false; err = $_.Exception.Message } }
}

function Wait-SessionReady([string]$Name, [int]$TimeoutMs = 20000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        & $PSMUX has-session -t $Name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

$env:PSMUX_NO_WARM = "1"
Remove-Item Env:PSMUX_SESSION_NAME -ErrorAction SilentlyContinue

Write-Host "`n=== Issue #648: window scoped options live on the window ===" -ForegroundColor Cyan
Write-Info "Binary: $PSMUX"

foreach ($s in @($SESSION, $TUISESS, $CFGSESS)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 800

& $PSMUX new-session -d -s $SESSION -n zero
if (-not (Wait-SessionReady $SESSION)) { Write-Fail "session creation failed"; exit 1 }
& $PSMUX new-window -d -t "${SESSION}:" -n one 2>&1 | Out-Null
Start-Sleep -Milliseconds 900

# ---------------------------------------------------------------------------
# Arm 1: the reporter's exact transcript, through the CLI.
# ---------------------------------------------------------------------------
Write-Host "[Arm 1] CLI: the reporter's exact transcript" -ForegroundColor Yellow

$before = @(
    (Read-WinOpt "${SESSION}:zero" 'remain-on-exit'),
    (Read-WinOpt "${SESSION}:one"  'remain-on-exit'),
    (Read-GlobalOpt $SESSION 'remain-on-exit')
)
Write-Info "SCOPE_BEFORE zero=$($before[0]) one=$($before[1]) global=$($before[2])"

$r = Invoke-Psmux @('set-option', '-w', '-t', "${SESSION}:zero", 'remain-on-exit', 'on')
if ($r.rc -eq 0) { Write-Pass "set-option -w -t ${SESSION}:zero remain-on-exit on at rc 0" }
else { Write-Fail "targeted set failed: rc=$($r.rc) err=[$($r.err)] out=[$($r.out)]" }

$zero   = Read-WinOpt "${SESSION}:zero" 'remain-on-exit'
$one    = Read-WinOpt "${SESSION}:one"  'remain-on-exit'
$global = Read-GlobalOpt $SESSION 'remain-on-exit'
Write-Info "SCOPE_AFTER_WINDOW_SET zero=$zero one=$one global=$global"

if ($zero -eq 'on') { Write-Pass "the targeted window reads the write back: zero=on" }
else { Write-Fail "zero=[$zero], expected on" }

if ($one -eq 'off') { Write-Pass "the SIBLING window still inherits: one=off (was: on)" }
else { Write-Fail "BUG #648: the sibling window shows [$one]; a window targeted write leaked" }

if ($global -eq 'off') { Write-Pass "the GLOBAL store is untouched: global=off (was: on)" }
else { Write-Fail "BUG #648: the global store shows [$global]; a window targeted write leaked" }

# ---------------------------------------------------------------------------
# Arm 2: the -t target resolves by NAME, not by whichever window is active.
# ---------------------------------------------------------------------------
Write-Host "[Arm 2] -t resolves by name, index and id" -ForegroundColor Yellow

& $PSMUX select-window -t "${SESSION}:zero" 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Invoke-Psmux @('set-option', '-w', '-t', "${SESSION}:one", 'monitor-activity', 'on') | Out-Null
$onName  = Read-WinOpt "${SESSION}:one"  'monitor-activity'
$offName = Read-WinOpt "${SESSION}:zero" 'monitor-activity'
if ($onName -eq 'on' -and $offName -eq 'off') {
    Write-Pass "-t ${SESSION}:one wrote the NAMED window while zero was active"
} else {
    Write-Fail "BUG #648: -t by name landed on the active window: one=[$onName] zero=[$offName]"
}

Invoke-Psmux @('set-option', '-w', '-t', "${SESSION}:1", 'monitor-silence', '11') | Out-Null
$byIdx  = Read-WinOpt "${SESSION}:1" 'monitor-silence'
$sib    = Read-WinOpt "${SESSION}:0" 'monitor-silence'
if ($byIdx -eq '11' -and $sib -eq '0') { Write-Pass "-t <session>:<index> targets that window only" }
else { Write-Fail "index target: one=[$byIdx] zero=[$sib]" }

$r = Invoke-Psmux @('set-option', '-w', '-t', "${SESSION}:nosuchwindow", 'remain-on-exit', 'on')
if ($r.out -match "can't find window" -or $r.err -match "can't find window") {
    Write-Pass "an unresolvable -t is reported, not silently applied somewhere else"
} else { Write-Fail "bad target was swallowed: rc=$($r.rc) out=[$($r.out)] err=[$($r.err)]" }

# ---------------------------------------------------------------------------
# Arm 3: -wg writes the global table; -u restores inheritance.
# ---------------------------------------------------------------------------
Write-Host "[Arm 3] -wg writes global, -u restores inheritance" -ForegroundColor Yellow

Invoke-Psmux @('set-option', '-w', '-u', '-t', "${SESSION}:zero", 'remain-on-exit') | Out-Null
$zero   = Read-WinOpt "${SESSION}:zero" 'remain-on-exit'
$global = Read-GlobalOpt $SESSION 'remain-on-exit'
if ($zero -eq 'off' -and $global -eq 'off') { Write-Pass "-u removed the window value; it inherits off again" }
else { Write-Fail "-u: zero=[$zero] global=[$global]" }

$r = Invoke-Psmux @('set-option', '-wg', '-t', $SESSION, 'remain-on-exit', 'on')
$global = Read-GlobalOpt $SESSION 'remain-on-exit'
$zero   = Read-WinOpt "${SESSION}:zero" 'remain-on-exit'
$one    = Read-WinOpt "${SESSION}:one"  'remain-on-exit'
if ($r.rc -eq 0 -and $global -eq 'on' -and $zero -eq 'on' -and $one -eq 'on') {
    Write-Pass "-wg writes the GLOBAL window table and every window inherits it"
} else { Write-Fail "-wg: rc=$($r.rc) global=[$global] zero=[$zero] one=[$one]" }

Invoke-Psmux @('set-option', '-w', '-t', "${SESSION}:one", 'remain-on-exit', 'off') | Out-Null
Invoke-Psmux @('set-option', '-wg', '-t', $SESSION, 'remain-on-exit', 'on') | Out-Null
$one = Read-WinOpt "${SESSION}:one" 'remain-on-exit'
if ($one -eq 'off') { Write-Pass "a window's own value outranks a later -wg write" }
else { Write-Fail "window-local value lost to a -wg write: one=[$one]" }

Invoke-Psmux @('set-option', '-wg', '-t', $SESSION, 'remain-on-exit', 'off') | Out-Null
Invoke-Psmux @('set-option', '-w', '-u', '-t', "${SESSION}:one", 'remain-on-exit') | Out-Null

# ---------------------------------------------------------------------------
# Arm 4: show-options -w and -wA read the window store back.
# ---------------------------------------------------------------------------
Write-Host "[Arm 4] show-options -w / -wA" -ForegroundColor Yellow

Invoke-Psmux @('set-option', '-w', '-t', "${SESSION}:zero", 'remain-on-exit', 'on') | Out-Null

$lz = (Invoke-Psmux @('show-options', '-w', '-t', "${SESSION}:zero")).out
$lo = (Invoke-Psmux @('show-options', '-w', '-t', "${SESSION}:one")).out
if ($lz -match '(?m)^remain-on-exit on$') { Write-Pass "show -w -t zero lists remain-on-exit on" }
else { Write-Fail "show -w -t zero: [$lz]" }
# #655 supersedes the original #648 line here: tmux prints NOTHING for an
# option the window does not own, so the sibling's listing must not carry
# remain-on-exit at all. The inherited value is what -A and -v report.
if ($lo -notmatch '(?m)^remain-on-exit') { Write-Pass "show -w -t one omits the option it does not own (tmux parity, #655)" }
else { Write-Fail "BUG #648: show -w -t one reported the other window's value: [$lo]" }

$az = (Invoke-Psmux @('show-options', '-w', '-A', '-t', "${SESSION}:zero")).out
$ao = (Invoke-Psmux @('show-options', '-w', '-A', '-t', "${SESSION}:one")).out
if ($az -match '(?m)^remain-on-exit on$') { Write-Pass "-A leaves a window-LOCAL value unmarked (tmux parity)" }
else { Write-Fail "-A marked a local value: [$az]" }
if ($ao -match '(?m)^remain-on-exit\* off$') { Write-Pass "-A marks an INHERITED value with * (tmux parity)" }
else { Write-Fail "-A missing the * inherited marker: [$ao]" }
if ($lz -notmatch '\*' -and $lo -notmatch '\*') { Write-Pass "plain show -w never emits the * marker" }
else { Write-Fail "the * marker leaked into a plain show -w listing" }

$wv = (Invoke-Psmux @('show-options', '-wv', '-t', "${SESSION}:zero", 'remain-on-exit')).out
if ($wv -eq 'on') { Write-Pass "the combined -wv token answers per window: $wv" }
else { Write-Fail "-wv -t zero remain-on-exit = [$wv]" }

$showw = (Invoke-Psmux @('showw', '-v', '-t', "${SESSION}:one", 'remain-on-exit')).out
if ($showw -eq 'off') { Write-Pass "the showw spelling answers per window too: $showw" }
else { Write-Fail "showw -v -t one remain-on-exit = [$showw]" }

# ---------------------------------------------------------------------------
# Arm 5: raw TCP, straight at the server parser (no CLI guard in the way).
# ---------------------------------------------------------------------------
Write-Host "[Arm 5] raw TCP to the server parser" -ForegroundColor Yellow

$t = Send-TcpCommand -Session $SESSION -Command "set-option -w -t ${SESSION}:one window-status-format `"TCP#I`""
if ($t.ok) {
    Start-Sleep -Milliseconds 300
    $vOne  = Read-WinOpt "${SESSION}:one"  'window-status-format'
    $vZero = Read-WinOpt "${SESSION}:zero" 'window-status-format'
    if ($vOne -eq 'TCP#I' -and $vZero -ne 'TCP#I') {
        Write-Pass "raw TCP set -w wrote one window only: one=[$vOne] zero=[$vZero]"
    } else { Write-Fail "raw TCP set -w: one=[$vOne] zero=[$vZero]" }
} else { Write-Fail "TCP connect failed: $($t.err)" }

$t = Send-TcpCommand -Session $SESSION -Command "show-options -w -A -t ${SESSION}:zero"
if ($t.ok -and $t.resp -match '(?m)^window-status-format\*') {
    Write-Pass "raw TCP show -wA marks the inherited window-status-format"
} else { Write-Fail "raw TCP show -wA: [$($t.resp)]" }

$t = Send-TcpCommand -Session $SESSION -Command "set-option -w -u -t ${SESSION}:one window-status-format"
Start-Sleep -Milliseconds 300
$vOne = Read-WinOpt "${SESSION}:one" 'window-status-format'
if ($vOne -ne 'TCP#I') { Write-Pass "raw TCP set -w -u restored inheritance: [$vOne]" }
else { Write-Fail "raw TCP -u left the window value in place: [$vOne]" }

# ---------------------------------------------------------------------------
# Arm 6: command chaining.
# ---------------------------------------------------------------------------
Write-Host "[Arm 6] command chaining" -ForegroundColor Yellow

$t = Send-TcpCommand -Session $SESSION `
    -Command "set-option -w -t ${SESSION}:zero monitor-silence 4 \; set-option -w -t ${SESSION}:one monitor-silence 6"
Start-Sleep -Milliseconds 400
$mz = Read-WinOpt "${SESSION}:zero" 'monitor-silence'
$mo = Read-WinOpt "${SESSION}:one"  'monitor-silence'
if ($mz -eq '4' -and $mo -eq '6') { Write-Pass "each chained -w write reached its own window: zero=$mz one=$mo" }
else { Write-Fail "chained window writes: zero=[$mz] one=[$mo]" }

Invoke-Psmux @('set-option', '-w', '-u', '-t', "${SESSION}:zero", 'monitor-silence') | Out-Null
Invoke-Psmux @('set-option', '-w', '-u', '-t', "${SESSION}:one",  'monitor-silence') | Out-Null

# ---------------------------------------------------------------------------
# Arm 7: THE REPORTER'S SCENARIO. A later pane in an untargeted window must
# still close after `exit`. This is the behaviour the option scope bug broke,
# and the only arm here that exercises reap_children rather than reporting.
# ---------------------------------------------------------------------------
Write-Host "[Arm 7] a later pane must NOT inherit remain-on-exit on" -ForegroundColor Yellow

Invoke-Psmux @('set-option', '-wg', '-t', $SESSION, 'remain-on-exit', 'off') | Out-Null
Invoke-Psmux @('set-option', '-w', '-t', "${SESSION}:zero", 'remain-on-exit', 'on') | Out-Null

# A pane in the UNTARGETED window, created AFTER the targeted write, exactly
# like the reporter's "ordinary PowerShell panes created later".
Invoke-Psmux @('split-window', '-d', '-t', "${SESSION}:one") | Out-Null
Start-Sleep -Seconds 2
$panesOneBefore = @((Invoke-Psmux @('list-panes', '-t', "${SESSION}:one", '-F', '#{pane_id}')).out -split "`r?`n" | Where-Object { $_ -ne '' }).Count
Write-Info "window one has $panesOneBefore panes before the exit"

Invoke-Psmux @('send-keys', '-t', "${SESSION}:one", 'exit', 'Enter') | Out-Null
Start-Sleep -Seconds 4
$panesOneAfter = @((Invoke-Psmux @('list-panes', '-t', "${SESSION}:one", '-F', '#{pane_id}')).out -split "`r?`n" | Where-Object { $_ -ne '' }).Count
Write-Info "window one has $panesOneAfter panes after the exit"

if ($panesOneAfter -lt $panesOneBefore) {
    Write-Pass "the ordinary pane in the UNTARGETED window closed on exit ($panesOneBefore -> $panesOneAfter)"
} else {
    Write-Fail "BUG #648: a later pane inherited remain-on-exit on and stayed dead ($panesOneBefore -> $panesOneAfter)"
}

$deadZero = (Invoke-Psmux @('display-message', '-t', "${SESSION}:zero", '-p', '#{?pane_dead,dead,alive}')).out
Write-Info "window zero active pane: $deadZero (it is still running; the flag only matters on exit)"
if ((Read-WinOpt "${SESSION}:zero" 'remain-on-exit') -eq 'on') {
    Write-Pass "the targeted window kept remain-on-exit on throughout"
} else { Write-Fail "the targeted window lost its own value" }

# The documented #647 workaround must keep working: -w off on the window, -p on
# on the one pane that should survive.
$pane0 = ((Invoke-Psmux @('list-panes', '-t', "${SESSION}:zero", '-F', '#{pane_id}')).out -split "`r?`n")[0]
Invoke-Psmux @('set-option', '-w', '-t', "${SESSION}:zero", 'remain-on-exit', 'off') | Out-Null
$r = Invoke-Psmux @('set-option', '-p', '-t', $pane0, 'remain-on-exit', 'on')
$pv = (Invoke-Psmux @('show-options', '-p', '-v', '-t', $pane0, 'remain-on-exit')).out
$wvz = Read-WinOpt "${SESSION}:zero" 'remain-on-exit'
if ($r.rc -eq 0 -and $pv -eq 'on' -and $wvz -eq 'off') {
    Write-Pass "-p still outranks -w on the pane that has it: pane=$pv window=$wvz"
} else { Write-Fail "-p over -w: rc=$($r.rc) pane=[$pv] window=[$wvz]" }

# ---------------------------------------------------------------------------
# Arm 8: config file route. A STARTUP config runs before any window exists, so
# an untargeted `-w` line has no window to aim at and lands in the global window
# table, which is where psmux has always put it. A config SOURCED at runtime has
# real windows, so `-w -t <window>` there reaches exactly one of them.
# ---------------------------------------------------------------------------
Write-Host "[Arm 8] config file route" -ForegroundColor Yellow

$conf = Join-Path $env:TEMP "psmux_648.conf"
@"
set -g remain-on-exit off
set -w monitor-activity on
setw monitor-silence 7
setw status-left "[#S] cfg"
"@ | Set-Content -Path $conf -Encoding ASCII

$env:PSMUX_CONFIG_FILE = $conf
& $PSMUX new-session -d -s $CFGSESS -n cfgzero
$ready = Wait-SessionReady $CFGSESS
Remove-Item env:PSMUX_CONFIG_FILE -ErrorAction SilentlyContinue

if (-not $ready) {
    Write-Fail "config-file session did not start"
} else {
    Start-Sleep -Milliseconds 900
    & $PSMUX new-window -d -t "${CFGSESS}:" -n cfgone 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900

    # No window existed when the startup config ran, so the value went to the
    # global window table and every window inherits it. tmux 3.4 drops such a
    # line entirely; psmux keeps landing it, because every .psmux.conf with a
    # bare `setw` line depends on that.
    $v  = Read-WinOpt "${CFGSESS}:cfgzero" 'monitor-activity'
    $v2 = Read-WinOpt "${CFGSESS}:cfgone"  'monitor-activity'
    $vg = Read-GlobalOpt $CFGSESS 'monitor-activity'
    if ($v -eq 'on' -and $v2 -eq 'on' -and $vg -eq 'on') {
        Write-Pass "an untargeted startup-config set -w lands in the global window table: zero=$v one=$v2 global=$vg"
    } else { Write-Fail "startup config set -w: zero=[$v] one=[$v2] global=[$vg]" }

    $v = Read-GlobalOpt $CFGSESS 'monitor-silence'
    if ($v -eq '7') { Write-Pass "an untargeted startup-config setw lands there too: monitor-silence=$v" }
    else { Write-Fail "startup config setw monitor-silence = [$v]" }

    # tmux derives scope from the option NAME, so a SESSION option under
    # -w/setw still lands in the session store. Every config that spells
    # `setw status-left ...` must keep working.
    $v = (Invoke-Psmux @('show-options', '-gv', '-t', $CFGSESS, 'status-left')).out
    if ($v -eq '[#S] cfg') { Write-Pass "a session option under setw still lands in the session store: $v" }
    else { Write-Fail "setw status-left = [$v], expected '[#S] cfg'" }

    # Sourced at RUNTIME, with real windows, a targeted -w line reaches one.
    $conf2 = Join-Path $env:TEMP "psmux_648_runtime.conf"
    @"
set -w -t "${CFGSESS}:cfgone" window-status-format "CFG#I"
setw -t "${CFGSESS}:cfgone" remain-on-exit on
"@ | Set-Content -Path $conf2 -Encoding ASCII
    Invoke-Psmux @('source-file', '-t', $CFGSESS, $conf2) | Out-Null
    Start-Sleep -Milliseconds 700

    $f1 = Read-WinOpt "${CFGSESS}:cfgone"  'window-status-format'
    $f0 = Read-WinOpt "${CFGSESS}:cfgzero" 'window-status-format'
    if ($f1 -eq 'CFG#I' -and $f0 -ne 'CFG#I') {
        Write-Pass "a sourced config `set -w -t <window>` wrote one window: cfgone=[$f1] cfgzero=[$f0]"
    } else { Write-Fail "sourced config set -w -t: cfgone=[$f1] cfgzero=[$f0]" }

    $r1 = Read-WinOpt "${CFGSESS}:cfgone"  'remain-on-exit'
    $r0 = Read-WinOpt "${CFGSESS}:cfgzero" 'remain-on-exit'
    if ($r1 -eq 'on' -and $r0 -eq 'off') {
        Write-Pass "a sourced config `setw -t <window>` wrote one window: cfgone=[$r1] cfgzero=[$r0]"
    } else { Write-Fail "sourced config setw -t: cfgone=[$r1] cfgzero=[$r0]" }
}
& $PSMUX kill-session -t $CFGSESS 2>&1 | Out-Null

# ---------------------------------------------------------------------------
# Arm 9 (Layer 2, TUI): the same commands against a real attached Win32 client,
# read back through display-message so the value is proven live in the server
# the client is talking to, not just in a one-shot CLI round trip.
# ---------------------------------------------------------------------------
Write-Host "[Arm 9] attached Win32 client (TUI)" -ForegroundColor Yellow

# A .cmd wrapper, because the agent shell exports PSMUX_SESSION_NAME and the
# launched client would otherwise route into the wrong session.
$launcher = Join-Path $env:TEMP "psmux_648_launch.cmd"
@"
@echo off
set PSMUX_SESSION_NAME=
set PSMUX_NO_WARM=1
"$PSMUX" new-session -s %1 -n tuizero -x 120 -y 30
"@ | Set-Content -Path $launcher -Encoding ASCII

$tuiProc = Start-Process -FilePath $launcher -ArgumentList @($TUISESS) -PassThru
if (-not (Wait-SessionReady $TUISESS 25000)) {
    Write-Fail "attached client never came up"
} else {
    Start-Sleep -Seconds 3
    & $PSMUX new-window -d -t "${TUISESS}:" -n tuione 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    $r = Invoke-Psmux @('set-option', '-w', '-t', "${TUISESS}:tuione", 'monitor-activity', 'on')
    Start-Sleep -Milliseconds 900
    $liveOne  = Read-WinOpt "${TUISESS}:tuione"  'monitor-activity'
    $liveZero = Read-WinOpt "${TUISESS}:tuizero" 'monitor-activity'
    if ($r.rc -eq 0 -and $liveOne -eq 'on' -and $liveZero -eq 'off') {
        Write-Pass "a window write against a live attached client stays on that window: tuione=$liveOne tuizero=$liveZero"
    } else { Write-Fail "TUI window write: rc=$($r.rc) tuione=[$liveOne] tuizero=[$liveZero]" }

    # display-message proves the LIVE server (the one rendering the client) has
    # the value, not just a one-shot CLI reply.
    $dm = Invoke-Psmux @('display-message', '-t', "${TUISESS}:tuione", '-p', '#{window_name}')
    if ($dm.out -eq 'tuione') { Write-Pass "display-message reaches the attached server's second window: $($dm.out)" }
    else { Write-Fail "display-message -t tuione = [$($dm.out)]" }

    # A per-window window-status-format must reach the STATUS BAR the client
    # draws, which is the render path the per-window wire fields were added for.
    Invoke-Psmux @('set-option', '-w', '-t', "${TUISESS}:tuione", 'window-status-format', 'TUIONE') | Out-Null
    Start-Sleep -Milliseconds 900
    $fOne  = Read-WinOpt "${TUISESS}:tuione"  'window-status-format'
    $fZero = Read-WinOpt "${TUISESS}:tuizero" 'window-status-format'
    if ($fOne -eq 'TUIONE' -and $fZero -ne 'TUIONE') {
        Write-Pass "per-window window-status-format is live in the attached server: tuione=[$fOne] tuizero=[$fZero]"
    } else { Write-Fail "TUI window-status-format: tuione=[$fOne] tuizero=[$fZero]" }

    $aw = (Invoke-Psmux @('show-options', '-w', '-A', '-t', "${TUISESS}:tuizero")).out
    if ($aw -match '(?m)^window-status-format\* ') {
        Write-Pass "the attached route marks the inherited window-status-format with *"
    } else { Write-Fail "attached show -wA: [$aw]" }
}

# Close the window this test opened, by PID, and only this one.
& $PSMUX kill-session -t $TUISESS 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
if ($tuiProc -and -not $tuiProc.HasExited) {
    Stop-Process -Id $tuiProc.Id -Force -ErrorAction SilentlyContinue
}

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
