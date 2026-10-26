# Issue #635 (reported by MattKotsenas): `kill-window -t` -- a `-t` with NO
# value after it -- silently killed the CURRENT window and exited 0.
#
# It was never specific to kill-window. Measured against the unfixed tree
# (e7013a3) with a live 5-window session, 71 of 71 sampled command lines
# carrying a dangling value-taking flag were accepted at rc 0 with empty
# output, and several mutated state:
#
#     COMMAND              RC   WINDOWS
#     kill-window -t       0    5 -> 4      window destroyed
#     unlink-window -t     0    5 -> 4      window destroyed
#     kill-session -t      0    5 -> 0      WHOLE SESSION destroyed
#     respawn-pane -c      0    9 -> 0      session lost
#     new-window -t        0    5 -> 6      window created
#
# kill-session is the worst: with no target it falls back to
# PSMUX_TARGET_SESSION, which the server sets and every pane child inherits,
# so `psmux kill-session -t $TARGET` with `$TARGET` unset -- an everyday
# scripting slip -- wipes the session it is running inside.
#
# tmux rejects this generically in arguments.c args_parse_flags:
#
#     xasprintf(cause, "-%c expects an argument", flag);
#     return (-1);
#
# The command never runs: message on stderr, exit 1, NO side effect. This
# suite asserts all three across every ingress psmux has -- CLI, raw TCP,
# config file, key binding at bind time, and a command typed inside a pane.
#
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue635_dangling_flag_value.ps1

$ErrorActionPreference = "Continue"

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

# ISOLATED data root. The destructive cases below deliberately run commands
# that used to kill sessions, so they must never be able to reach a real one.
$PSMUX_DIR = Join-Path $env:TEMP "psmux_i635_e2e"
Remove-Item $PSMUX_DIR -Recurse -Force -EA SilentlyContinue
New-Item -ItemType Directory -Path $PSMUX_DIR -Force | Out-Null
$env:PSMUX_DATA_DIR = $PSMUX_DIR
$env:PSMUX_NO_WARM = "1"
foreach ($v in 'TMUX','PSMUX_SESSION','PSMUX_SESSION_NAME','PSMUX_TARGET_SESSION','PSMUX_TARGET_FULL') {
    Remove-Item "Env:$v" -EA SilentlyContinue
}

$SESSION = "i635_main"
$CFGSESS = "i635_cfg"

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor Gray }

$script:OutFile = Join-Path $env:TEMP "i635_out.txt"
$script:ErrFile = Join-Path $env:TEMP "i635_err.txt"
function Invoke-Psmux([string[]]$ArgList) {
    $proc = Start-Process -FilePath $PSMUX -ArgumentList $ArgList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $script:OutFile -RedirectStandardError $script:ErrFile
    [pscustomobject]@{
        rc  = $proc.ExitCode
        out = "$(Get-Content $script:OutFile -Raw -EA SilentlyContinue)".Trim()
        err = "$(Get-Content $script:ErrFile -Raw -EA SilentlyContinue)".Trim()
    }
}
function New-PsmuxSession($name)    { & $PSMUX new-session -d -s $name 2>&1 | Out-Null }
function Remove-PsmuxSession($name) { & $PSMUX kill-session -t $name 2>&1 | Out-Null }
function Test-SessionAlive($name)   { return ((Invoke-Psmux @('has-session','-t',$name)).rc -eq 0) }

function Get-WindowCount($name) {
    if (-not (Test-SessionAlive $name)) { return -1 }
    $r = Invoke-Psmux @('list-windows','-t',$name)
    return (($r.out -split "`r?`n" | Where-Object { $_ -match '^\d+:' }) | Measure-Object).Count
}

function Wait-SessionReady([string]$Name, [int]$TimeoutMs = 25000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-SessionAlive $Name) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# Raw TCP straight to the server, bypassing the CLI guard entirely, so the
# server-side handler is measured on its own.
function Send-TcpCommand {
    param([string]$Session, [string]$Command, [int]$TimeoutMs = 5000)
    try {
        $port = (Get-Content "$PSMUX_DIR\$Session.port" -Raw).Trim()
        $key  = (Get-Content "$PSMUX_DIR\$Session.key" -Raw).Trim()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.NoDelay = $true
        $tcp.Connect("127.0.0.1", [int]$port)
        $ns = $tcp.GetStream(); $ns.ReadTimeout = $TimeoutMs
        $wr = New-Object System.IO.StreamWriter($ns); $wr.AutoFlush = $true
        $rd = New-Object System.IO.StreamReader($ns)
        $wr.WriteLine("AUTH $key")
        if ($rd.ReadLine() -ne "OK") { $tcp.Close(); return @{ ok=$false; err="AUTH_FAIL" } }
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
        return @{ ok=$true; resp=($lines -join "`n") }
    } catch { return @{ ok=$false; err=$_.Exception.Message } }
}

function Restore-Windows([string]$name, [int]$target) {
    if (-not (Test-SessionAlive $name)) {
        New-PsmuxSession $name
        [void](Wait-SessionReady $name)
    }
    $guard = 0
    while ((Get-WindowCount $name) -lt $target -and $guard -lt 10) {
        & $PSMUX new-window -t $name 2>&1 | Out-Null
        Start-Sleep -Milliseconds 400
        $guard++
    }
}

Write-Host "`n=== Issue #635: a value-taking flag with no value must be rejected ===" -ForegroundColor Cyan
Write-Info "Binary:    $PSMUX"
Write-Info "Data root: $PSMUX_DIR"

foreach ($s in @($SESSION, $CFGSESS)) { Remove-PsmuxSession $s }
Start-Sleep -Milliseconds 600
New-PsmuxSession $SESSION
if (-not (Wait-SessionReady $SESSION)) { Write-Fail "session creation failed"; exit 1 }
Restore-Windows $SESSION 5
Write-Info "session $SESSION has $(Get-WindowCount $SESSION) windows"

# ---------------------------------------------------------------- SECTION 1 --
Write-Host "`n--- 1. CLI route: message, exit code, and NO side effect ---" -ForegroundColor Cyan

# (command argv, flag) pairs. Every one of these exited 0 in silence before.
$cliCases = @(
    @{ a = @('kill-window','-t');       f = '-t' },
    @{ a = @('kill-session','-t');      f = '-t' },
    @{ a = @('unlink-window','-t');     f = '-t' },
    @{ a = @('kill-pane','-t');         f = '-t' },
    @{ a = @('new-window','-t');        f = '-t' },
    @{ a = @('new-window','-n');        f = '-n' },
    @{ a = @('rename-window','-t');     f = '-t' },
    @{ a = @('select-window','-t');     f = '-t' },
    @{ a = @('split-window','-t');      f = '-t' },
    @{ a = @('send-keys','-t');         f = '-t' },
    @{ a = @('display-message','-t');   f = '-t' },
    @{ a = @('list-panes','-t');        f = '-t' },
    @{ a = @('select-pane','-t');       f = '-t' },
    @{ a = @('swap-window','-t');       f = '-t' },
    @{ a = @('resize-pane','-t');       f = '-t' },
    @{ a = @('capture-pane','-t');      f = '-t' },
    @{ a = @('respawn-pane','-c');      f = '-c' },
    @{ a = @('list-windows','-F');      f = '-F' },
    @{ a = @('send-keys','-N');         f = '-N' },
    @{ a = @('capture-pane','-S');      f = '-S' },
    @{ a = @('resize-pane','-x');       f = '-x' },
    @{ a = @('select-pane','-T');       f = '-T' },
    @{ a = @('bind-key','-T');          f = '-T' },
    # alias forms
    @{ a = @('killw','-t');             f = '-t' },
    @{ a = @('neww','-t');              f = '-t' },
    @{ a = @('splitw','-t');            f = '-t' },
    @{ a = @('splitp','-t');            f = '-t' },
    @{ a = @('lsp','-t');               f = '-t' },
    @{ a = @('send','-t');              f = '-t' },
    # clustered: the value-taking letter is last in the cluster
    @{ a = @('kill-window','-at');      f = '-t' },
    @{ a = @('list-panes','-aF');       f = '-F' },
    # dangling flag not in final position of a boolean run
    @{ a = @('new-window','-d','-t');   f = '-t' }
)

foreach ($c in $cliCases) {
    $label = ($c.a -join ' ')
    $before = Get-WindowCount $SESSION
    $r = Invoke-Psmux $c.a
    $after = Get-WindowCount $SESSION
    $text = "$($r.err)`n$($r.out)"
    $wantMsg = "$($c.f) expects an argument"
    $okMsg  = $text -match [regex]::Escape($wantMsg)
    $okRc   = $r.rc -ne 0
    $okSide = $before -eq $after
    if ($okMsg -and $okRc -and $okSide) {
        Write-Pass "$label -> rc=$($r.rc), '$wantMsg', windows unchanged ($after)"
    } else {
        Write-Fail "$label -> rc=$($r.rc) msg_ok=$okMsg side_effect=$(-not $okSide) windows $before->$after out=[$($r.out)] err=[$($r.err)]"
        Restore-Windows $SESSION 5
    }
}

# ---------------------------------------------------------------- SECTION 2 --
Write-Host "`n--- 2. Destructive defaults survive: the session and its windows still exist ---" -ForegroundColor Cyan

Restore-Windows $SESSION 5
$before = Get-WindowCount $SESSION
$r = Invoke-Psmux @('kill-window','-t')
if ((Get-WindowCount $SESSION) -eq $before) {
    Write-Pass "kill-window -t destroyed nothing (still $before windows)"
} else {
    Write-Fail "kill-window -t still destroys a window ($before -> $(Get-WindowCount $SESSION))"
}

$r = Invoke-Psmux @('kill-session','-t')
if (Test-SessionAlive $SESSION) {
    Write-Pass "kill-session -t left the session alive"
} else {
    Write-Fail "kill-session -t DESTROYED the session"
    New-PsmuxSession $SESSION; [void](Wait-SessionReady $SESSION); Restore-Windows $SESSION 5
}

$before = Get-WindowCount $SESSION
$r = Invoke-Psmux @('unlink-window','-t')
if ((Get-WindowCount $SESSION) -eq $before) {
    Write-Pass "unlink-window -t destroyed nothing (still $before windows)"
} else {
    Write-Fail "unlink-window -t still removes a window ($before -> $(Get-WindowCount $SESSION))"
    Restore-Windows $SESSION 5
}

$before = Get-WindowCount $SESSION
$r = Invoke-Psmux @('new-window','-t')
if ((Get-WindowCount $SESSION) -eq $before) {
    Write-Pass "new-window -t created nothing (still $before windows)"
} else {
    Write-Fail "new-window -t still creates a window ($before -> $(Get-WindowCount $SESSION))"
    Restore-Windows $SESSION 5
}

# ---------------------------------------------------------------- SECTION 3 --
Write-Host "`n--- 3. Raw TCP route (server handler, CLI guard bypassed) ---" -ForegroundColor Cyan

Restore-Windows $SESSION 5
foreach ($cmd in @('kill-window -t', 'kill-session -t', 'unlink-window -t', 'new-window -t', 'capture-pane -t')) {
    $before = Get-WindowCount $SESSION
    $t = Send-TcpCommand -Session $SESSION -Command $cmd
    Start-Sleep -Milliseconds 400
    $alive = Test-SessionAlive $SESSION
    $after = if ($alive) { Get-WindowCount $SESSION } else { -1 }
    if (-not $t.ok) {
        Write-Fail "TCP '$cmd': connection failed ($($t.err))"
        continue
    }
    if ($t.resp -match 'expects an argument' -and $alive -and $after -eq $before) {
        Write-Pass "TCP '$cmd' -> [$($t.resp)], no side effect (windows $after)"
    } else {
        Write-Fail "TCP '$cmd' -> resp=[$($t.resp)] alive=$alive windows $before->$after"
        Restore-Windows $SESSION 5
    }
}

# ---------------------------------------------------------------- SECTION 4 --
Write-Host "`n--- 4. Config-file route ---" -ForegroundColor Cyan

$cfg = Join-Path $env:TEMP "i635_psmux.conf"
@(
    'set-option -g base-index 0',
    '# a top-level directive with a dangling value flag',
    'set-option -t',
    '# and a key binding whose BOUND command has one',
    'bind-key -T root F8 kill-window -t',
    '# a good binding on the same table must still land',
    'bind-key -T root F7 next-window'
) | Set-Content $cfg -Encoding UTF8

Remove-Item "$PSMUX_DIR\config-warnings.log" -Force -EA SilentlyContinue
Remove-PsmuxSession $CFGSESS
Start-Sleep -Milliseconds 400
& $PSMUX -f $cfg new-session -d -s $CFGSESS 2>&1 | Out-Null
if (-not (Wait-SessionReady $CFGSESS)) {
    Write-Fail "config-route session did not start"
} else {
    Start-Sleep -Milliseconds 800
    $log = "$(Get-Content "$PSMUX_DIR\config-warnings.log" -Raw -EA SilentlyContinue)"
    if ($log -match 'expects an argument') {
        Write-Pass "config file: dangling flag reported in config-warnings.log"
        Write-Info ("log: " + (($log -split "`r?`n" | Where-Object { $_ -match 'expects an argument' }) -join ' / '))
    } else {
        Write-Fail "config file: no 'expects an argument' warning (log=[$log])"
    }
    $keys = (Invoke-Psmux @('list-keys','-t',$CFGSESS)).out
    if ($keys -notmatch '\bF8\b') {
        Write-Pass "config file: the bad binding (F8) was refused, not armed"
    } else {
        Write-Fail "config file: F8 was bound to a command with a dangling -t"
    }
    if ($keys -match '\bF7\b') {
        Write-Pass "config file: the good binding (F7) still landed"
    } else {
        Write-Fail "config file: the good binding (F7) was lost"
    }
}

# ---------------------------------------------------------------- SECTION 5 --
Write-Host "`n--- 5. Key-binding route (bind-key at bind time, like cmd-bind-key.c) ---" -ForegroundColor Cyan

$r = Invoke-Psmux @('bind-key','-t',$SESSION,'-T','root','F9','kill-window','-t')
$text = "$($r.err)`n$($r.out)"
if ($text -match 'expects an argument') {
    Write-Pass "bind-key of a command with a dangling -t is refused: [$($text.Trim())]"
} else {
    Write-Fail "bind-key of a command with a dangling -t was accepted (rc=$($r.rc) out=[$($r.out)] err=[$($r.err)])"
}
$keys = (Invoke-Psmux @('list-keys','-t',$SESSION)).out
if ($keys -notmatch '\bF9\b') {
    Write-Pass "the refused binding was not armed"
} else {
    Write-Fail "F9 got bound to a command with a dangling -t"
}
$r = Invoke-Psmux @('bind-key','-t',$SESSION,'-T','root','F10','next-window')
$keys = (Invoke-Psmux @('list-keys','-t',$SESSION)).out
if ($keys -match '\bF10\b') {
    Write-Pass "a well-formed bind-key still lands"
} else {
    Write-Fail "a well-formed bind-key was lost (rc=$($r.rc) err=[$($r.err)])"
}

# ---------------------------------------------------------------- SECTION 6 --
Write-Host "`n--- 6. From INSIDE a pane, where PSMUX_TARGET_SESSION is inherited ---" -ForegroundColor Cyan

Restore-Windows $SESSION 5
& $PSMUX send-keys -t $SESSION "echo `"PTS=[`$env:PSMUX_TARGET_SESSION]`"" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap = (Invoke-Psmux @('capture-pane','-p','-t',$SESSION)).out
$pts = ($cap -split "`r?`n" | Where-Object { $_ -match '^PTS=' } | Select-Object -First 1)
if ($pts -match [regex]::Escape($SESSION)) {
    Write-Info "confirmed: pane inherits PSMUX_TARGET_SESSION as [$pts]"
} else {
    Write-Info "pane env reads [$pts] (inheritance not observed here)"
}

$before = Get-WindowCount $SESSION
& $PSMUX send-keys -t $SESSION "$PSMUX kill-window -t; echo I635W=`$LASTEXITCODE" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 4
$after = if (Test-SessionAlive $SESSION) { Get-WindowCount $SESSION } else { -1 }
$cap = (Invoke-Psmux @('capture-pane','-p','-t',$SESSION)).out
if ($after -eq $before -and $cap -match 'expects an argument') {
    Write-Pass "in-pane 'kill-window -t': rejected, windows unchanged ($after)"
} else {
    Write-Fail "in-pane 'kill-window -t': windows $before->$after, pane text had the message = $($cap -match 'expects an argument')"
    Restore-Windows $SESSION 5
}

& $PSMUX send-keys -t $SESSION "$PSMUX kill-session -t; echo I635S=`$LASTEXITCODE" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 5
if (Test-SessionAlive $SESSION) {
    $cap = (Invoke-Psmux @('capture-pane','-p','-t',$SESSION)).out
    $sawMsg = $cap -match 'expects an argument'
    $sawRc  = ($cap -match 'I635S=1')
    if ($sawMsg) {
        Write-Pass "in-pane 'kill-session -t': session SURVIVED and the pane shows the tmux message"
    } else {
        Write-Fail "in-pane 'kill-session -t': session survived but no message in the pane"
    }
    if ($sawRc) {
        Write-Pass "in-pane 'kill-session -t': exit status is 1"
    } else {
        Write-Info "in-pane exit status line not captured (pane text: $(($cap -split "`r?`n" | Where-Object {$_ -match 'I635S'}) -join ' '))"
    }
} else {
    Write-Fail "in-pane 'kill-session -t' DESTROYED the session"
    New-PsmuxSession $SESSION; [void](Wait-SessionReady $SESSION)
}

# ---------------------------------------------------------------- SECTION 7 --
Write-Host "`n--- 7. Legitimate usage must be untouched ---" -ForegroundColor Cyan

Restore-Windows $SESSION 5
$legit = @(
    @{ n = 'list-windows -t S';           a = @('list-windows','-t',$SESSION) },
    @{ n = 'list-panes -t S';             a = @('list-panes','-t',$SESSION) },
    @{ n = 'has-session -t S';            a = @('has-session','-t',$SESSION) },
    @{ n = 'display-message -p -t S #S';  a = @('display-message','-p','-t',$SESSION,'#S') },
    @{ n = 'new-window -t S -n w9';       a = @('new-window','-t',$SESSION,'-n','w9') },
    @{ n = 'select-window -t S:0';        a = @('select-window','-t',"${SESSION}:0") },
    @{ n = 'rename-window -t S:0 rn';     a = @('rename-window','-t',"${SESSION}:0",'rn') },
    @{ n = 'list-windows -t S -F #I';     a = @('list-windows','-t',$SESSION,'-F','#{window_index}') },
    @{ n = 'capture-pane -p -t S';        a = @('capture-pane','-p','-t',$SESSION) },
    @{ n = 'capture-pane -p -S -5 -t S';  a = @('capture-pane','-p','-S','-5','-t',$SESSION) },
    @{ n = 'send-keys -t S -- -foo';      a = @('send-keys','-t',$SESSION,'--','-foo') },
    @{ n = 'resize-pane -t S:0.0 -x 40';  a = @('resize-pane','-t',"${SESSION}:0.0",'-x','40') },
    @{ n = 'resize-pane -t S:0.0 -D 2';   a = @('resize-pane','-t',"${SESSION}:0.0",'-D','2') },
    @{ n = 'resize-pane -t S:0.0 -D';     a = @('resize-pane','-t',"${SESSION}:0.0",'-D') },
    @{ n = 'resize-pane -t S:0.0 -x -5';  a = @('resize-pane','-t',"${SESSION}:0.0",'-x','-5') },
    @{ n = 'set-option -t S base-index 0';a = @('set-option','-t',$SESSION,'base-index','0') },
    @{ n = 'show-options -t S -g';        a = @('show-options','-t',$SESSION,'-g') },
    @{ n = 'lsw -t S (alias)';            a = @('lsw','-t',$SESSION) },
    @{ n = 'neww -t S (alias)';           a = @('neww','-t',$SESSION) },
    @{ n = 'split-window -d -t S';        a = @('split-window','-d','-t',$SESSION) },
    @{ n = 'select-pane -t S:0.0 -T ti';  a = @('select-pane','-t',"${SESSION}:0.0",'-T','ti') },
    @{ n = 'list-sessions -F #S';         a = @('list-sessions','-F','#{session_name}') },
    @{ n = 'send-keys -t S -N 3 Up';      a = @('send-keys','-t',$SESSION,'-N','3','Up') },
    @{ n = 'list-windows -tS (attached)'; a = @('list-windows',"-t$SESSION") },
    @{ n = 'list-windows -t=S (equals)';  a = @('list-windows',"-t=$SESSION") },
    @{ n = 'list-panes -a';               a = @('list-panes','-a') }
)
foreach ($c in $legit) {
    $r = Invoke-Psmux $c.a
    $text = "$($r.err)`n$($r.out)"
    if ($text -match 'expects an argument') {
        Write-Fail "REGRESSION: '$($c.n)' now reports a dangling flag: [$($text.Trim())]"
    } else {
        Write-Pass "'$($c.n)' still accepted (rc=$($r.rc))"
    }
}

# ---------------------------------------------------------------- SECTION 8 --
Write-Host "`n--- 8. tmux parse-shape parity ---" -ForegroundColor Cyan

# `kill-window -t -a`: tmux takes "-a" AS the -t value (a REQUIRED value is
# never dash-tested), so this is a target lookup failure, not a parse error.
$before = Get-WindowCount $SESSION
$r = Invoke-Psmux @('kill-window','-t','-a')
$text = "$($r.err)`n$($r.out)"
$after = Get-WindowCount $SESSION
if ($text -notmatch 'expects an argument' -and $after -eq $before) {
    Write-Pass "'kill-window -t -a' treats -a as the target (not a parse error), no window lost"
} else {
    Write-Fail "'kill-window -t -a' -> [$($text.Trim())] windows $before->$after"
    Restore-Windows $SESSION 5
}

# `--` ends option parsing: the -t after it is payload.
$r = Invoke-Psmux @('send-keys','-t',$SESSION,'--','-t')
if ("$($r.err)$($r.out)" -notmatch 'expects an argument') {
    Write-Pass "'send-keys -t S -- -t' is payload after --, not a dangling flag"
} else {
    Write-Fail "'send-keys -t S -- -t' was rejected: [$($r.err)]"
}

# Flag parsing stops at the first positional.
$r = Invoke-Psmux @('send-keys','-t',$SESSION,'hello','-t')
if ("$($r.err)$($r.out)" -notmatch 'expects an argument') {
    Write-Pass "'send-keys -t S hello -t' stops flag parsing at the positional"
} else {
    Write-Fail "'send-keys -t S hello -t' was rejected: [$($r.err)]"
}

# The GLOBAL (pre-subcommand) region is checked too.
$r = Invoke-Psmux @('-t')
if ($r.rc -ne 0 -and "$($r.err)$($r.out)" -match 'expects an argument') {
    Write-Pass "global 'psmux -t' with no value is rejected (rc=$($r.rc))"
} else {
    Write-Fail "global 'psmux -t' -> rc=$($r.rc) out=[$($r.out)] err=[$($r.err)]"
}
$r = Invoke-Psmux @('-L')
if ($r.rc -ne 0 -and "$($r.err)$($r.out)" -match 'expects an argument') {
    Write-Pass "global 'psmux -L' with no value is rejected (rc=$($r.rc))"
} else {
    Write-Fail "global 'psmux -L' -> rc=$($r.rc) out=[$($r.out)] err=[$($r.err)]"
}

# ------------------------------------------------------------------- WRAP ----
foreach ($s in @($SESSION, $CFGSESS)) { Remove-PsmuxSession $s }
Start-Sleep -Milliseconds 600
& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
Remove-Item $cfg -Force -EA SilentlyContinue
Remove-Item $script:OutFile, $script:ErrFile -Force -EA SilentlyContinue
Remove-Item $PSMUX_DIR -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
