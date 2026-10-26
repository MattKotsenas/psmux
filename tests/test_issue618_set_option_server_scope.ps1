# Issue #618: `set-option -s <option> <value>` (and the set / setw /
# set-window-option spellings) was rejected with
# "psmux: set-option: unknown flag -s" at exit 1.
#
# tmux 3.2 moved default-terminal, extended-keys and extended-keys-format onto
# the server option table, so `set-option -s default-terminal xterm-256color`
# is the documented, current syntax. thurbox issues exactly that on every
# session bootstrap, so the refusal broke a real tool with a correct command.
#
# The read side had the mirror-image gap: `show-options -s` was accepted but
# its -s was parsed into a variable nothing read, so it printed the whole
# option store, session options included, where tmux prints server options
# only.
#
# psmux runs one server per session and keeps a single option store, so -s
# resolves to the same store as -g on the write side. It is not genuine
# cross-session server-option storage; it puts the write where a caller using
# tmux 3.2+ syntax expects to find it, and narrows the -s listing the way tmux
# does.
#
# Usage: pwsh -NoProfile -File tests\test_issue618_set_option_server_scope.ps1

$ErrorActionPreference = "Continue"

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$SESSION   = "test_issue618"
$TUISESS   = "test_issue618tui"
$CFGSESS   = "test_issue618cfg"
$PSMUX_DIR = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor Gray }

# Run psmux with an exact argv (no shell re-tokenizing) and capture rc/out/err.
function Invoke-Psmux([string[]]$ArgList) {
    $so = Join-Path $env:TEMP "t618_out.txt"
    $se = Join-Path $env:TEMP "t618_err.txt"
    $p = Start-Process -FilePath $PSMUX -ArgumentList $ArgList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $so -RedirectStandardError $se
    [pscustomobject]@{
        rc  = $p.ExitCode
        out = "$(Get-Content $so -Raw -ErrorAction SilentlyContinue)".Trim()
        err = "$(Get-Content $se -Raw -ErrorAction SilentlyContinue)".Trim()
    }
}
function Read-Opt($sess, $name) { (Invoke-Psmux @('show-options','-qv','-t',$sess,$name)).out }

# Raw TCP straight to the server, bypassing the CLI guard entirely, so the
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
        if ($auth -ne "OK") { $tcp.Close(); return @{ ok=$false; err="AUTH_FAIL" } }
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
        return @{ ok=$true; resp=($lines -join "`n"); lines=$lines }
    } catch { return @{ ok=$false; err=$_.Exception.Message } }
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
$env:PSMUX_SESSION_NAME = $null

Write-Host "`n=== Issue #618: set-option -s (server scope) ===" -ForegroundColor Cyan
Write-Info "Binary: $PSMUX"

foreach ($s in @($SESSION, $TUISESS, $CFGSESS)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 800

& $PSMUX new-session -d -s $SESSION
if (-not (Wait-SessionReady $SESSION)) { Write-Fail "session creation failed"; exit 1 }

# ---------------------------------------------------------------------------
# Arm 1: the reporter's exact commands, through the CLI.
# ---------------------------------------------------------------------------
Write-Host "[Arm 1] CLI: the reporter's commands" -ForegroundColor Yellow

$r = Invoke-Psmux @('set-option','-s','-t',$SESSION,'default-terminal','xterm-256color')
if ($r.rc -eq 0 -and $r.err -notmatch 'unknown flag') {
    Write-Pass "set-option -s default-terminal xterm-256color at rc 0 (was: rc 1 unknown flag -s)"
} else { Write-Fail "set-option -s: rc=$($r.rc) err=[$($r.err)]" }

$v = Read-Opt $SESSION 'default-terminal'
if ($v -eq 'xterm-256color') { Write-Pass "the value actually landed: default-terminal = $v" }
else { Write-Fail "default-terminal after set -s = [$v], expected xterm-256color" }

$r = Invoke-Psmux @('set','-s','-t',$SESSION,'default-terminal','screen-256color')
$v = Read-Opt $SESSION 'default-terminal'
if ($r.rc -eq 0 -and $v -eq 'screen-256color') { Write-Pass "the set alias takes -s too" }
else { Write-Fail "set -s alias: rc=$($r.rc) value=[$v] err=[$($r.err)]" }

$r = Invoke-Psmux @('set-option','-s','-t',$SESSION,'extended-keys','on')
if ($r.rc -eq 0) { Write-Pass "set-option -s extended-keys on at rc 0 (thurbox's second call)" }
else { Write-Fail "set-option -s extended-keys: rc=$($r.rc) err=[$($r.err)]" }

$r = Invoke-Psmux @('set-option','-s','-t',$SESSION,'extended-keys-format','csi-u')
if ($r.rc -eq 0) { Write-Pass "set-option -s extended-keys-format csi-u at rc 0 (thurbox's third call)" }
else { Write-Fail "set-option -s extended-keys-format: rc=$($r.rc) err=[$($r.err)]" }

# ---------------------------------------------------------------------------
# Arm 2: the other spellings and the combined flag tokens.
# ---------------------------------------------------------------------------
Write-Host "[Arm 2] setw -s, set-window-option -s, combined tokens" -ForegroundColor Yellow

$r = Invoke-Psmux @('setw','-s','-t',$SESSION,'@i618setw','wv')
$v = Read-Opt $SESSION '@i618setw'
if ($r.rc -eq 0 -and $v -eq 'wv') { Write-Pass "setw -s stores the value at rc 0" }
else { Write-Fail "setw -s: rc=$($r.rc) value=[$v] err=[$($r.err)]" }

$r = Invoke-Psmux @('set-window-option','-s','-t',$SESSION,'@i618swo','sv')
$v = Read-Opt $SESSION '@i618swo'
if ($r.rc -eq 0 -and $v -eq 'sv') { Write-Pass "set-window-option -s stores the value at rc 0" }
else { Write-Fail "set-window-option -s: rc=$($r.rc) value=[$v] err=[$($r.err)]" }

$r = Invoke-Psmux @('set-option','-sq','-t',$SESSION,'@i618q','qv')
$v = Read-Opt $SESSION '@i618q'
if ($r.rc -eq 0 -and $v -eq 'qv') { Write-Pass "combined -sq parses as two flags, not one unknown one" }
else { Write-Fail "set -sq: rc=$($r.rc) value=[$v] err=[$($r.err)]" }

$r = Invoke-Psmux @('set-option','-sg','-t',$SESSION,'escape-time','25')
$v = Read-Opt $SESSION 'escape-time'
if ($r.rc -eq 0 -and $v -eq '25') { Write-Pass "the widely copied set -sg escape-time 25 line works" }
else { Write-Fail "set -sg escape-time: rc=$($r.rc) value=[$v] err=[$($r.err)]" }

$r = Invoke-Psmux @('set-option','-su','-t',$SESSION,'@i618q')
$v = Read-Opt $SESSION '@i618q'
if ($r.rc -eq 0 -and $v -eq '') { Write-Pass "-s composes with the unset flag" }
else { Write-Fail "set -su: rc=$($r.rc) value=[$v] err=[$($r.err)]" }

# ---------------------------------------------------------------------------
# Arm 3: the guard still refuses genuinely unknown flags (#553 must hold).
# ---------------------------------------------------------------------------
Write-Host "[Arm 3] the unknown-flag guard is still armed" -ForegroundColor Yellow

$r = Invoke-Psmux @('set-option','-Z','-t',$SESSION,'@i618z','zz')
if ($r.rc -eq 1 -and $r.err -match 'unknown flag -Z') { Write-Pass "-Z is still refused at rc 1 (#553 intact)" }
else { Write-Fail "unknown-flag guard regressed: rc=$($r.rc) err=[$($r.err)]" }

# ---------------------------------------------------------------------------
# Arm 4: raw TCP, straight at the server parser.
# ---------------------------------------------------------------------------
Write-Host "[Arm 4] raw TCP to the server" -ForegroundColor Yellow

$r = Send-TcpCommand $SESSION 'set-option -s @i618tcp tcpval'
if ($r.ok) {
    Start-Sleep -Milliseconds 400
    $v = (Send-TcpCommand $SESSION 'show-options -qv @i618tcp').resp
    if ("$v".Trim() -eq 'tcpval') { Write-Pass "set-option -s over TCP stored the value" }
    else { Write-Fail "TCP set -s: read back [$v]" }
} else { Write-Fail "TCP connect failed: $($r.err)" }

$r = Send-TcpCommand $SESSION 'set-option -s default-terminal tmux-256color'
Start-Sleep -Milliseconds 400
$v = (Send-TcpCommand $SESSION 'show-options -qv default-terminal').resp
if ("$v".Trim() -eq 'tmux-256color') { Write-Pass "set-option -s default-terminal over TCP stored the value" }
else { Write-Fail "TCP set -s default-terminal: read back [$v]" }

# ---------------------------------------------------------------------------
# Arm 5: show-options -s lists SERVER options only.
# ---------------------------------------------------------------------------
Write-Host "[Arm 5] show-options -s narrows the listing" -ForegroundColor Yellow

$r = Invoke-Psmux @('show-options','-s','-t',$SESSION)
$lines = @($r.out -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
Write-Info "show-options -s printed $($lines.Count) lines"
if ($r.rc -eq 0 -and $r.out -match '(?m)^default-terminal\s') { Write-Pass "show-options -s lists default-terminal" }
else { Write-Fail "show-options -s missing default-terminal: rc=$($r.rc) out=[$($r.out)]" }

if ($r.out -match '(?m)^escape-time\s') { Write-Pass "show-options -s lists escape-time" }
else { Write-Fail "show-options -s missing escape-time" }

if ($r.out -notmatch '(?m)^status\s') { Write-Pass "show-options -s omits the session option status (was: printed everything)" }
else { Write-Fail "show-options -s still lists the session option status" }

if ($r.out -notmatch '(?m)^prefix\s') { Write-Pass "show-options -s omits the session option prefix" }
else { Write-Fail "show-options -s still lists the session option prefix" }

$rg = Invoke-Psmux @('show-options','-g','-t',$SESSION)
if ($rg.out -match '(?m)^status\s') { Write-Pass "show-options -g still lists session options (no collateral narrowing)" }
else { Write-Fail "show-options -g stopped listing status" }

# -v prints one value row per option that HAS a value.  An array option with
# no items (terminal-overrides since #700, like tmux's terminal-overrides and
# user-keys) is listed by its bare name without -v and prints NOTHING with -v.
# tmux cmd_show_options_print (cmd-show-options.c):
#   if (a == NULL) { if (!args_has(args, 'v')) cmdq_print(item, "%s", name); return; }
# Measured on tmux 3.4 with -f /dev/null: `show -s` printed 25 rows, among them
# the bare `terminal-overrides` and `user-keys`, and `show -sv` printed 23.
# So the -v row count is the -s row count minus the bare name rows.  The rows
# are read raw (not through the trimmed Invoke-Psmux output) because an empty
# string value, such as copy-command, is a legitimate empty row and trimming
# would drop it when it lands first or last.
$slines = @(& $PSMUX show-options -s -t $SESSION 2>$null)
$bare = @($slines | Where-Object { $_ -match '^\S+$' })
$vlines = @(& $PSMUX show-options -sv -t $SESSION 2>$null)
$vrc = $LASTEXITCODE
$vjoined = $vlines -join "`n"
if ($vrc -eq 0 -and $vlines.Count -eq ($slines.Count - $bare.Count) -and $vjoined -notmatch 'default-terminal') {
    Write-Pass "show-options -sv prints one row per valued option, empty arrays omitted like tmux ($($vlines.Count) = $($slines.Count) minus bare [$($bare -join ',')])"
} else { Write-Fail "show-options -sv: rc=$vrc rows=$($vlines.Count), expected $($slines.Count) minus $($bare.Count) bare [$($bare -join ',')] out=[$vjoined]" }

$rn = Invoke-Psmux @('show-options','-s','-t',$SESSION,'default-terminal')
if ($rn.rc -eq 0 -and $rn.out -match 'default-terminal') {
    Write-Pass "show-options -s <name> still answers a named query (tmux ignores -s for a table option)"
} else { Write-Fail "show-options -s <name>: rc=$($rn.rc) out=[$($rn.out)]" }

# ---------------------------------------------------------------------------
# Arm 6: a config file carrying `set -s ...`.
# ---------------------------------------------------------------------------
Write-Host "[Arm 6] config file route" -ForegroundColor Yellow

$conf = Join-Path $env:TEMP "psmux_618.conf"
@"
set -s default-terminal xterm-256color
set -s @i618conf fromconfig
set -sg escape-time 33
"@ | Set-Content -Path $conf -Encoding ASCII

$env:PSMUX_CONFIG_FILE = $conf
& $PSMUX new-session -d -s $CFGSESS
$ready = Wait-SessionReady $CFGSESS
Remove-Item env:PSMUX_CONFIG_FILE -ErrorAction SilentlyContinue

if (-not $ready) {
    Write-Fail "config-file session did not start"
} else {
    Start-Sleep -Milliseconds 800
    $v = Read-Opt $CFGSESS 'default-terminal'
    if ($v -eq 'xterm-256color') { Write-Pass "config set -s default-terminal applied: $v" }
    else { Write-Fail "config set -s default-terminal = [$v]" }

    $v = Read-Opt $CFGSESS '@i618conf'
    if ($v -eq 'fromconfig') { Write-Pass "config set -s @i618conf applied" }
    else { Write-Fail "config set -s @i618conf = [$v]" }

    $v = Read-Opt $CFGSESS 'escape-time'
    if ($v -eq '33') { Write-Pass "config set -sg escape-time 33 applied" }
    else { Write-Fail "config set -sg escape-time = [$v]" }
}
& $PSMUX kill-session -t $CFGSESS 2>&1 | Out-Null

# ---------------------------------------------------------------------------
# Arm 7 (Layer 2, TUI): the same command against a real attached client, read
# back through display-message so the value is proven to be live in the
# server the client is talking to, not just in a one-shot CLI round trip.
# ---------------------------------------------------------------------------
Write-Host "[Arm 7] attached client (TUI)" -ForegroundColor Yellow

# A .cmd wrapper, because the agent shell exports PSMUX_SESSION_NAME and the
# launched client would otherwise route into the wrong session.
$launcher = Join-Path $env:TEMP "psmux_618_launch.cmd"
@"
@echo off
set PSMUX_SESSION_NAME=
set PSMUX_NO_WARM=1
"$PSMUX" new-session -s %1 -x 120 -y 30
"@ | Set-Content -Path $launcher -Encoding ASCII

Start-Process -FilePath $launcher -ArgumentList @($TUISESS) | Out-Null
if (-not (Wait-SessionReady $TUISESS 25000)) {
    Write-Fail "attached client never came up"
} else {
    Start-Sleep -Seconds 3
    $r = Invoke-Psmux @('set-option','-s','-t',$TUISESS,'@i618tui','livevalue')
    Start-Sleep -Milliseconds 700
    $dm = Invoke-Psmux @('display-message','-t',$TUISESS,'-p','#{@i618tui}')
    if ($r.rc -eq 0 -and $dm.out -eq 'livevalue') {
        Write-Pass "set-option -s against an attached client, read back via display-message: $($dm.out)"
    } else { Write-Fail "TUI set -s: rc=$($r.rc) display-message=[$($dm.out)] err=[$($r.err)]" }

    $r = Invoke-Psmux @('set-option','-s','-t',$TUISESS,'default-terminal','xterm-256color')
    $dm = Invoke-Psmux @('show-options','-s','-t',$TUISESS)
    if ($r.rc -eq 0 -and $dm.out -match '(?m)^default-terminal xterm-256color$') {
        Write-Pass "show-options -s against the attached client lists the new default-terminal"
    } else { Write-Fail "TUI show -s: rc=$($r.rc) out=[$($dm.out)]" }
}
& $PSMUX kill-session -t $TUISESS 2>&1 | Out-Null

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
