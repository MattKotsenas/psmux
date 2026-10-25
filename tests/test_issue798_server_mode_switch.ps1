# Issue #798 step 1: the server mode switch.
#
# PSMUX_SERVER_MODE (or `set -s server-mode` in the config) picks the kind of
# server a namespace start creates. `per-session`, unset and empty run exactly
# the code psmux always ran; `shared` enters src/server/shared, which since
# step 2 runs the shared server (tests\test_issue798_shared_server.ps1) and
# never a per session server or the warm standby; anything else is an error at
# exit 1.
#
# Part 1 proves the default path is untouched: the same scenario (new-session,
# new-window, ls, list-windows, kill-session, registry files, server processes
# per session, the warm standby) gives one identical signature with the switch
# unset, `per-session` and empty. With PSMUX_BASELINE_EXE pointing at a master
# build, the signature must also equal master's.
#
# Every step runs under its own -L namespace in a PSMUX_DATA_DIR of its own,
# with an isolated config, and cleans up only with `-L <ns> kill-server`.
# PSMUX_TEST_EXE picks the binary (default: psmux on PATH).

$ErrorActionPreference = "Continue"
$script:Passed = 0; $script:Failed = 0
function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }
function Check($ok, $m, $detail = "") { if ($ok) { Pass $m } else { Fail "$m $detail" } }
function Head($m) { Write-Host "`n--- $m ---" -ForegroundColor Yellow }

$PSMUX = $env:PSMUX_TEST_EXE
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }
$PSMUX = (Resolve-Path $PSMUX).Path
$BASE = $env:PSMUX_BASELINE_EXE
if ($BASE) { $BASE = (Resolve-Path $BASE).Path }

foreach ($v in 'PSMUX_SESSION_NAME', 'PSMUX_SESSION', 'PSMUX_PANE', 'PSMUX_TARGET_SESSION',
    'PSMUX_TARGET_FULL', 'TMUX', 'TMUX_PANE', 'PSMUX_SERVER_MODE', 'PSMUX_NO_WARM', 'PSMUX_REMOTE_ATTACH') {
    Remove-Item "Env:$v" -EA SilentlyContinue
}
$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
. "$PSScriptRoot\isolated_config.ps1" -Lines @("set -g default-shell $POWERSHELL")
$CFG_DEFAULT = $env:PSMUX_CONFIG_FILE

$ROOT = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_798_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $ROOT | Out-Null
$script:Namespaces = @()

Write-Host "`n=== Issue #798 step 1: PSMUX_SERVER_MODE / server-mode switch ===" -ForegroundColor Cyan
Write-Host "  Binary:   $PSMUX"
if ($BASE) { Write-Host "  Baseline: $BASE" }
Write-Host "  Root:     $ROOT"

# A fresh namespace and data dir for one step.
function New-Ns($tag) {
    $ns = "s798" + $tag + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $dir = Join-Path $ROOT $ns
    New-Item -ItemType Directory -Force $dir | Out-Null
    $script:Namespaces += , @($ns, $dir)
    return @{ Ns = $ns; Dir = $dir }
}

# Run the binary with a switch value. '<unset>' removes the variable.
function Run($exe, $ctx, $mode, [string[]]$a) {
    $env:PSMUX_DATA_DIR = $ctx.Dir
    if ($mode -eq '<unset>') { Remove-Item Env:PSMUX_SERVER_MODE -EA SilentlyContinue } else { $env:PSMUX_SERVER_MODE = $mode }
    $out = & $exe -L $ctx.Ns @a 2>&1
    $code = $LASTEXITCODE
    Remove-Item Env:PSMUX_SERVER_MODE -EA SilentlyContinue
    return @{ Code = $code; Out = (($out | ForEach-Object { "$_" }) -join "`n").Trim() }
}

function Server-Procs($exe, $ns) {
    Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $exe -and $_.CommandLine -match " server " -and $_.CommandLine -match "-L $ns(\s|$)" }
}

function Proc-Summary($exe, $ns) {
    $names = @(Server-Procs $exe $ns | ForEach-Object {
            if ($_.CommandLine -match ' -s (\S+)') { $Matches[1] } else { '?' } })
    ($names | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ','
}

function Registry($ctx) {
    (Get-ChildItem $ctx.Dir -File -Name -EA SilentlyContinue | Sort-Object |
        ForEach-Object { $_.Replace($ctx.Ns, '<ns>') }) -join ','
}

function Wait-Warm($exe, $ctx) {
    for ($i = 0; $i -lt 50; $i++) {
        if ((Proc-Summary $exe $ctx.Ns) -match '__warm__=1') { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Stop-Ns($exe, $ctx) {
    $env:PSMUX_DATA_DIR = $ctx.Dir
    & $exe -L $ctx.Ns kill-server 2>&1 | Out-Null
    for ($i = 0; $i -lt 30 -and @(Server-Procs $exe $ctx.Ns).Count -gt 0; $i++) { Start-Sleep -Milliseconds 100 }
}

# The default path scenario. Returns a signature string that must not depend on
# the switch value when that value means per session.
function Scenario($exe, $mode) {
    $ctx = New-Ns "d"
    $sig = @()
    $r = Run $exe $ctx $mode @('new-session', '-d', '-s', 'A', '-x', '100', '-y', '30'); $sig += "newA=$($r.Code):$($r.Out)"
    $sig += "warm=$(Wait-Warm $exe $ctx)"
    $sig += "procs1=$(Proc-Summary $exe $ctx.Ns)"
    $r = Run $exe $ctx $mode @('new-session', '-d', '-s', 'B', '-x', '100', '-y', '30'); $sig += "newB=$($r.Code):$($r.Out)"
    $sig += "warm2=$(Wait-Warm $exe $ctx)"
    $r = Run $exe $ctx $mode @('new-window', '-t', 'A'); $sig += "neww=$($r.Code):$($r.Out)"
    $r = Run $exe $ctx $mode @('ls', '-F', '#{session_name}:#{session_windows}'); $sig += "ls=$($r.Code):$($r.Out -replace "`n", ' ')"
    $r = Run $exe $ctx $mode @('list-windows', '-t', 'A', '-F', '#{window_index}:#{window_panes}'); $sig += "lsw=$($r.Code):$($r.Out -replace "`n", ' ')"
    $r = Run $exe $ctx $mode @('display-message', '-p', '-t', 'A', '#{session_name}'); $sig += "disp=$($r.Code):$($r.Out)"
    $sig += "procs2=$(Proc-Summary $exe $ctx.Ns)"
    $sig += "reg2=$(Registry $ctx)"
    $r = Run $exe $ctx $mode @('kill-session', '-t', 'B'); $sig += "kill=$($r.Code):$($r.Out)"
    Start-Sleep -Milliseconds 700
    $r = Run $exe $ctx $mode @('ls', '-F', '#{session_name}'); $sig += "ls2=$($r.Code):$($r.Out -replace "`n", ' ')"
    $sig += "procs3=$(Proc-Summary $exe $ctx.Ns)"
    $sig += "reg3=$(Registry $ctx)"
    Stop-Ns $exe $ctx
    $sig += "procs4=$(Proc-Summary $exe $ctx.Ns)"
    return ($sig -join "`n")
}

function Run-Raw($exe, $ctx, $mode, [string[]]$a, $extraEnv = @{}) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $quoted = @('-L', $ctx.Ns) + $a | ForEach-Object {
        if ($_ -eq '' -or $_ -match '[\s"]') { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' } else { $_ }
    }
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.EnvironmentVariables['PSMUX_DATA_DIR'] = $ctx.Dir
    $psi.EnvironmentVariables.Remove('PSMUX_SERVER_MODE')
    $psi.EnvironmentVariables.Remove('T895_V')
    if ($mode -ne '<unset>') { $psi.EnvironmentVariables['PSMUX_SERVER_MODE'] = $mode }
    foreach ($k in $extraEnv.Keys) { $psi.EnvironmentVariables[$k] = $extraEnv[$k] }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outMs = New-Object IO.MemoryStream; $errMs = New-Object IO.MemoryStream
    $outTask = $p.StandardOutput.BaseStream.CopyToAsync($outMs)
    $errTask = $p.StandardError.BaseStream.CopyToAsync($errMs)
    if (-not $p.WaitForExit(20000)) {
        try { $p.Kill() } catch {}
        return @{ Error = "timed out after 20 s: $($a -join ' ')" }
    }
    if (-not [Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 5000)) {
        return @{ Error = "output not drained 5 s after exit: $($a -join ' ')" }
    }
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = $outMs.ToArray(); Err = $errMs.ToArray() }
}

function Hex([byte[]]$bytes, $max = 0) {
    if ($null -eq $bytes) { $bytes = [byte[]]@() }
    if ($max -gt 0 -and $bytes.Length -gt $max) { $bytes = $bytes[0..($max - 1)] }
    ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
}

function Sha([byte[]]$bytes) {
    if ($null -eq $bytes) { $bytes = [byte[]]@() }
    $h = [Security.Cryptography.SHA256]::Create()
    try { Hex $h.ComputeHash($bytes) } finally { $h.Dispose() }
}

function JobSample($exe, $mode) {
    $res = @{ Items = [ordered]@{}; Error = '' }
    foreach ($f in 'payload.txt', 'identity.txt', 'done.txt') { Remove-Item (Join-Path $JOB $f) -Force -EA SilentlyContinue }
    Get-ChildItem $JOB -Filter *.tmp -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    $left = @(Get-ChildItem $JOB -Name -EA SilentlyContinue | Where-Object { $_ -ne 'ctx.cmd' })
    if ($left.Count) { $res.Error = "outputs of an earlier sample left: $($left -join ',')"; return $res }
    $ctx = New-Ns "j"
    $res.Ns = $ctx.Ns
    $steps = @(
        @('new', @('new-session', '-d', '-s', 'J', '-x', '100', '-y', '30', '-c', $JOBDIR), @{ T895_V = 'fixed895' }),
        @('interval', @('set-option', '-t', 'J', 'status-interval', '1'), @{}),
        @('right', @('set-option', '-t', 'J', 'status-right', "#($JOB\ctx.cmd)"), @{}),
        @('show', @('show-options', '-v', '-t', 'J', 'status-right'), @{}))
    foreach ($s in $steps) {
        $r = Run-Raw $exe $ctx $mode $s[1] $s[2]
        if ($r.Error) { $res.Error = $r.Error; Stop-Ns $exe $ctx; return $res }
        $res.Items["$($s[0]).out"] = $r.Out
        $res.Items["$($s[0]).err"] = $r.Err
        $res.Items["$($s[0]).code"] = [Text.Encoding]::ASCII.GetBytes("$($r.Code)")
    }
    $base = "$($ctx.Ns)__J"
    try {
        $res.Port = (Get-Content (Join-Path $ctx.Dir "$base.port") -Raw -EA Stop).Trim()
        $res.Pid = ((Get-Content (Join-Path $ctx.Dir "$base.pid") -Raw -EA Stop).Trim() -split ':')[0]
        $key = (Get-Content (Join-Path $ctx.Dir "$base.key") -Raw -EA Stop).Trim()
    } catch { $res.Error = "registry of J not readable: $_"; Stop-Ns $exe $ctx; return $res }
    $done = Join-Path $JOB 'done.txt'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $done) -and $sw.ElapsedMilliseconds -lt 10000) {
        try {
            $t = New-Object Net.Sockets.TcpClient; $t.Connect('127.0.0.1', [int]$res.Port)
            $st = $t.GetStream(); $st.ReadTimeout = 4000
            $b = [Text.Encoding]::UTF8.GetBytes("AUTH $key`ndump-state`n"); $st.Write($b, 0, $b.Length); $st.Flush()
            $buf = New-Object byte[] 65536
            try { while ($st.Read($buf, 0, $buf.Length) -gt 0) {} } catch {}
            $t.Close()
        } catch {}
        $next = $sw.ElapsedMilliseconds + 1200
        while (-not (Test-Path $done) -and $sw.ElapsedMilliseconds -lt [Math]::Min($next, 10000)) { Start-Sleep -Milliseconds 100 }
    }
    $ran = Test-Path $done
    Stop-Ns $exe $ctx
    $gone = $false
    for ($i = 0; $i -lt 50 -and -not $gone; $i++) { $gone = (@(Server-Procs $exe $ctx.Ns).Count -eq 0); if (-not $gone) { Start-Sleep -Milliseconds 100 } }
    if (-not $ran) { $res.Error = 'the job wrote no done.txt within 10 s of the first dump-state'; return $res }
    if (-not $gone) { $res.Error = 'server processes of the sample left 5 s after kill-server'; return $res }
    $res.Items['payload'] = [IO.File]::ReadAllBytes((Join-Path $JOB 'payload.txt'))
    $res.Identity = [IO.File]::ReadAllBytes((Join-Path $JOB 'identity.txt'))
    return $res
}

function Identity-Problem($s) {
    $text = [Text.Encoding]::ASCII.GetString($s.Identity)
    if ($text -cnotmatch '^T=([^;\r\n]*);X=([^\r\n]*)\r\n$') { return "unexpected identity bytes $(Hex $s.Identity 64)" }
    $target = $Matches[1]; $fields = $Matches[2] -split ','
    if ($target -cne "$($s.Ns)__J") { return "T=$target, registry $($s.Ns)__J" }
    if ($fields.Count -ne 3) { return "X has $($fields.Count) fields: $($Matches[2])" }
    if ($fields[0] -cne "/tmp/psmux-$($s.Pid)/$($s.Ns)" -or $fields[1] -cne $s.Port -or $fields[2] -cne '0') {
        return "X=$($Matches[2]), registry pid $($s.Pid) port $($s.Port)"
    }
    return ''
}

try {
    Head "Part 1: the default path is the same with the switch unset, per-session and empty"
    $sigs = @{}
    foreach ($m in '<unset>', 'per-session', '') {
        $sigs[$m] = Scenario $PSMUX $m
    }
    Write-Host ($sigs['<unset>'] -split "`n" | ForEach-Object { "      $_" } | Out-String)
    Check ($sigs['<unset>'] -match 'newA=0:' -and $sigs['<unset>'] -match 'ls=0:A:2 B:1') "unset: sessions A and B made, A has 2 windows" $sigs['<unset>']
    Check ($sigs['<unset>'] -match 'procs2=(__warm__=1,)?A=1,B=1') "unset: one server process per session" ($sigs['<unset>'] -split "`n" | Select-String procs2)
    Check ($sigs['<unset>'] -match 'reg2=[^\n]*<ns>__A\.key,<ns>__A\.pid,<ns>__A\.port,<ns>__A\.sid,<ns>__B\.key,<ns>__B\.pid,<ns>__B\.port,<ns>__B\.sid') "unset: four registry files per session" ($sigs['<unset>'] -split "`n" | Select-String reg2)
    Check ($sigs['per-session'] -eq $sigs['<unset>']) "PSMUX_SERVER_MODE=per-session gives the identical signature" ("`n" + $sigs['per-session'])
    Check ($sigs[''] -eq $sigs['<unset>']) "PSMUX_SERVER_MODE= (empty) gives the identical signature" ("`n" + $sigs[''])
    if ($BASE) {
        $b = Scenario $BASE '<unset>'
        Check ($b -eq $sigs['<unset>']) "the signature equals the baseline binary's" ("`nbaseline:`n$b")
    }

    $JOB = Join-Path $ROOT 'job'; $JOBDIR = Join-Path $ROOT 'job-dir'
    if ($ROOT -match '\s') {
        Fail "job samples need a temp folder without spaces (cmd /C runs the job path): $ROOT"
    } else {
        New-Item -ItemType Directory -Force $JOB, $JOBDIR | Out-Null
        Set-Content -Encoding ASCII (Join-Path $JOB 'ctx.cmd') @(
            '@echo off',
            "if exist `"$JOB\done.txt`" exit /b 0",
            ">`"$JOB\payload.tmp`" echo V=%T895_V%;D=%CD%",
            ">`"$JOB\identity.tmp`" echo T=%PSMUX_TARGET_SESSION%;X=%TMUX%",
            "move /y `"$JOB\payload.tmp`" `"$JOB\payload.txt`" >nul",
            "move /y `"$JOB\identity.tmp`" `"$JOB\identity.txt`" >nul",
            ">`"$JOB\done.tmp`" echo done",
            "move /y `"$JOB\done.tmp`" `"$JOB\done.txt`" >nul",
            'echo ok')
        $samples = [ordered]@{}
        foreach ($m in '<unset>', 'per-session', '') { $samples["mode '$m'"] = JobSample $PSMUX $m }
        if ($BASE) { $samples['baseline'] = JobSample $BASE '<unset>' }
        $ref = $samples["mode '<unset>'"]
        foreach ($name in $samples.Keys) {
            $s = $samples[$name]
            Check (-not $s.Error) "job sample ${name}: the job ran and its server ended" $s.Error
        }
        if (-not $ref.Error) {
            Write-Host "      payload bytes: $(Hex $ref.Items['payload'])"
            $want = [Text.Encoding]::ASCII.GetBytes("V=fixed895;D=$JOBDIR`r`n")
            Check ((Sha $ref.Items['payload']) -ceq (Sha $want)) "job sample: the job kept the CLI's environment and ran in the session directory" (Hex $ref.Items['payload'])
        }
        foreach ($name in @($samples.Keys | Select-Object -Skip 1)) {
            $s = $samples[$name]
            if ($s.Error -or $ref.Error) { continue }
            $diff = @()
            foreach ($item in $ref.Items.Keys) {
                $a = Sha $ref.Items[$item]; $b2 = Sha $s.Items[$item]
                if ($a -cne $b2) { $diff += "$item unset=$a $(Hex $ref.Items[$item] 64) ${name}=$b2 $(Hex $s.Items[$item] 64)" }
            }
            Check ($diff.Count -eq 0 -and $s.Items.Count -eq $ref.Items.Count) "job sample ${name}: every raw byte item equals mode '<unset>'s ($($ref.Items.Count) items)" ($diff -join ' | ')
        }
        $norm = @{}
        foreach ($name in $samples.Keys) {
            $s = $samples[$name]
            if ($s.Error) { continue }
            $problem = Identity-Problem $s
            Check (-not $problem) "job sample ${name}: the job saw its own session's target and TMUX" $problem
            if (-not $problem) {
                $norm[$name] = [Text.Encoding]::ASCII.GetString($s.Identity).Replace("/tmp/psmux-$($s.Pid)/", '/tmp/psmux-<pid>/').Replace($s.Ns, '<ns>').Replace(",$($s.Port),", ',<port>,')
            }
        }
        if ($norm.Count -eq $samples.Count) {
            $first = $norm["mode '<unset>'"]
            Check (@($norm.Values | Where-Object { $_ -cne $first }).Count -eq 0) "job samples: the normalised identity lines are the same" (($norm.Values | ForEach-Object { $_.Trim() }) -join ' | ')
        }
    }

    Head "Part 2: shared never runs the per session server (step 2: it runs the shared one)"
    $ctx = New-Ns "sh"
    $r = Run $PSMUX $ctx 'shared' @('new-session', '-d', '-s', 'A')
    Check ($r.Code -eq 0) "new-session under shared exits 0 (step 2)" "($($r.Code)) $($r.Out)"
    $r = Run $PSMUX $ctx ' SHARED ' @('new-session', '-d', '-s', 'A2')
    Check ($r.Code -eq 0) "case and spaces are ignored (' SHARED ')" $r.Out
    $r = Run $PSMUX $ctx 'shared' @('new', '-d')
    Check ($r.Code -eq 0) "the new alias is gated too"
    $r = Run $PSMUX $ctx 'shared' @('start-server')
    Check ($r.Code -eq 0) "start-server under shared finds the shared server" $r.Out
    $env:PSMUX_DATA_DIR = $ctx.Dir; $env:PSMUX_SERVER_MODE = 'shared'
    $cc = ('' | & $PSMUX -L $ctx.Ns -CC 2>&1 | Out-String).Trim(); $ccCode = $LASTEXITCODE
    Remove-Item Env:PSMUX_SERVER_MODE
    Check ($ccCode -eq 1 -and $cc -match 'not supported by the shared server yet') "bare -CC (control mode start) under shared exits 1" "($ccCode) $cc"
    $env:PSMUX_SERVER_MODE = 'shared'
    $srv = Start-Process -FilePath $PSMUX -ArgumentList @('server', '-s', 'X', '-L', $ctx.Ns) -WindowStyle Hidden -PassThru
    Remove-Item Env:PSMUX_SERVER_MODE
    # A binary without the gate runs that server for ever: bound the wait and
    # stop only the process this step started.
    $exited = $srv.WaitForExit(10000)
    if (-not $exited) { Stop-Process -Id $srv.Id -Force -EA SilentlyContinue; $srv.WaitForExit(3000) | Out-Null }
    Check ($exited -and $srv.ExitCode -eq 1) "the internal per session server process refuses shared" "(exited=$exited code=$($srv.ExitCode))"
    Start-Sleep -Milliseconds 300
    $procs = @(Server-Procs $PSMUX $ctx.Ns)
    Check ($procs.Count -eq 1 -and $procs[0].CommandLine -match '--shared-server') "the namespace has exactly one server, the shared one, and no standby" (($procs | ForEach-Object { $_.CommandLine }) -join ' | ')
    $reg = Registry $ctx
    Check ($reg -notmatch '<ns>__X\.' -and $reg -notmatch '__warm__') "no registry file for the refused X or a standby" $reg
    $r = Run $PSMUX $ctx '<unset>' @('ls', '-F', '#{session_name}')
    Check ($r.Code -eq 0 -and (($r.Out -split "`n" | Sort-Object) -join ',') -eq '0,A,A2') "ls lists the shared server's sessions" $r.Out
    Stop-Ns $PSMUX $ctx

    Head "Part 3: an unknown value is an error, never a fallback"
    $ctx = New-Ns "bg"
    foreach ($bad in 'bogus', 'per_session', 'on') {
        $r = Run $PSMUX $ctx $bad @('new-session', '-d', '-s', 'A')
        Check ($r.Code -eq 1 -and $r.Out -eq "psmux: PSMUX_SERVER_MODE: unknown value '$bad' (expected per-session or shared)") "PSMUX_SERVER_MODE=${bad}: exact error at exit 1" "($($r.Code)) $($r.Out)"
    }
    $r = Run $PSMUX $ctx 'bogus' @('start-server')
    Check ($r.Code -eq 1 -and $r.Out -match 'unknown value') "start-server with a bad value exits 1" $r.Out
    Start-Sleep -Milliseconds 300
    Check ((Proc-Summary $PSMUX $ctx.Ns) -eq '') "no server process after the bad values" (Proc-Summary $PSMUX $ctx.Ns)

    Head "Part 4: the config switch (set -s server-mode)"
    $cfgShared = Join-Path $ROOT "shared.conf"; Set-Content $cfgShared "set -g default-shell $POWERSHELL`nset -s server-mode shared" -Encoding ASCII
    $cfgBad = Join-Path $ROOT "bad.conf"; Set-Content $cfgBad "set -s server-mode sharde" -Encoding ASCII
    $cfgPer = Join-Path $ROOT "per.conf"; Set-Content $cfgPer "set -g default-shell $POWERSHELL`nset -s server-mode per-session" -Encoding ASCII
    $ctx = New-Ns "cf"
    $env:PSMUX_CONFIG_FILE = $cfgShared
    $r = Run $PSMUX $ctx '<unset>' @('new-session', '-d', '-s', 'S')
    $sharedProcs = @(Server-Procs $PSMUX $ctx.Ns | Where-Object { $_.CommandLine -match '--shared-server' })
    Check ($r.Code -eq 0 -and $sharedProcs.Count -eq 1) "config server-mode shared: new-session starts the shared server" "($($r.Code)) $($r.Out)"
    $r = Run $PSMUX $ctx 'per-session' @('new-session', '-d', '-s', 'A')
    Check ($r.Code -eq 0) "PSMUX_SERVER_MODE=per-session outranks the config" "($($r.Code)) $($r.Out)"
    Stop-Ns $PSMUX $ctx
    $env:PSMUX_CONFIG_FILE = $cfgBad
    $r = Run $PSMUX $ctx '<unset>' @('new-session', '-d', '-s', 'A')
    Check ($r.Code -eq 1 -and $r.Out -match "server-mode: unknown value 'sharde' in .*bad\.conf") "a bad config value names itself and the file" $r.Out
    $env:PSMUX_CONFIG_FILE = $cfgPer
    $r = Run $PSMUX $ctx '<unset>' @('new-session', '-d', '-s', 'P')
    Check ($r.Code -eq 0 -and $r.Out -eq '') "config server-mode per-session starts quietly" "($($r.Code)) $($r.Out)"
    $r = Run $PSMUX $ctx '<unset>' @('show-messages')
    Check ($r.Out -notmatch 'server-mode') "no config warning about server-mode" $r.Out
    $r = Run $PSMUX $ctx '<unset>' @('source-file', $cfgPer)
    Check ($r.Code -eq 0 -and $r.Out -eq '') "re-sourcing that config is silent" "($($r.Code)) $($r.Out)"
    Stop-Ns $PSMUX $ctx
    $env:PSMUX_CONFIG_FILE = $CFG_DEFAULT

    Head "Part 5: show and set on a running per session server (CLI, TCP)"
    $ctx = New-Ns "sw"
    $r = Run $PSMUX $ctx '<unset>' @('new-session', '-d', '-s', 'A'); Check ($r.Code -eq 0) "per session server up"
    $r = Run $PSMUX $ctx '<unset>' @('show', '-s', 'server-mode'); Check ($r.Code -eq 0 -and $r.Out -eq 'server-mode per-session') "show -s server-mode" $r.Out
    $r = Run $PSMUX $ctx '<unset>' @('show', '-sv', 'server-mode'); Check ($r.Out -eq 'per-session') "show -sv server-mode" $r.Out
    $r = Run $PSMUX $ctx '<unset>' @('display-message', '-p', '#{server-mode}'); Check ($r.Out -eq 'per-session') "#{server-mode} format" $r.Out
    $r = Run $PSMUX $ctx 'shared' @('show', '-sv', 'server-mode'); Check ($r.Out -eq 'per-session') "a shell with shared still sees this server's real mode" $r.Out
    $r = Run $PSMUX $ctx '<unset>' @('show', '-s'); $listing = $r.Out
    Check ($listing -notmatch 'server-mode') "bare show -s listing does not gain a line"
    $r = Run $PSMUX $ctx '<unset>' @('show', '-g'); Check ($r.Out -notmatch 'server-mode') "show -g listing does not gain a line"
    $r = Run $PSMUX $ctx '<unset>' @('set', '-s', 'server-mode', 'per-session'); Check ($r.Code -eq 0 -and $r.Out -eq '') "set -s server-mode per-session is a silent no-op" "($($r.Code)) $($r.Out)"
    $r = Run $PSMUX $ctx '<unset>' @('set', '-s', 'server-mode', 'shared')
    Check ($r.Code -eq 1 -and $r.Out -match 'cannot change on a running server') "set -s server-mode shared on a running server is refused" "($($r.Code)) $($r.Out)"
    $r = Run $PSMUX $ctx '<unset>' @('set', '-s', 'server-mode', 'bogus')
    Check ($r.Code -eq 1 -and $r.Out -match 'unknown value') "set -s server-mode bogus is refused" "($($r.Code)) $($r.Out)"
    $r = Run $PSMUX $ctx '<unset>' @('show', '-sv', 'server-mode'); Check ($r.Out -eq 'per-session') "mode unchanged after the refused sets" $r.Out
    # Raw TCP, the path a plugin or control client takes.
    $port = [int](Get-Content (Join-Path $ctx.Dir "$($ctx.Ns)__A.port")).Trim()
    $key = (Get-Content (Join-Path $ctx.Dir "$($ctx.Ns)__A.key")).Trim()
    $tcp = New-Object Net.Sockets.TcpClient; $tcp.Connect('127.0.0.1', $port)
    $st = $tcp.GetStream(); $w = New-Object IO.StreamWriter($st); $w.NewLine = "`n"
    $w.WriteLine("AUTH $key"); $w.WriteLine("show-options -sv server-mode"); $w.Flush()
    $rd = New-Object IO.StreamReader($st); $st.ReadTimeout = 2000
    $tcpOut = @(); try { while ($true) { $l = $rd.ReadLine(); if ($null -eq $l) { break }; $tcpOut += $l } } catch {}
    $tcp.Close()
    Check (($tcpOut -join '|') -match 'per-session') "TCP show-options -sv server-mode answers per-session" ($tcpOut -join '|')
    # A warm standby exists here (Part 1). A shared request must not claim it.
    $warmBefore = Wait-Warm $PSMUX $ctx
    $perSession = { @(Server-Procs $PSMUX $ctx.Ns | Where-Object { $_.CommandLine -notmatch '--shared-server' } | ForEach-Object { "$($_.ProcessId):$($_.CommandLine)" } | Sort-Object) -join ' | ' }
    $before = & $perSession
    $r = Run $PSMUX $ctx 'shared' @('new-session', '-d', '-s', 'C')
    Start-Sleep -Milliseconds 300
    $after = & $perSession
    Check ($r.Code -eq 0 -and $before -eq $after) "shared new-session leaves the warm standby and the per session servers alone (warm=$warmBefore)" "before=$before after=$after"
    $r = Run $PSMUX $ctx '<unset>' @('ls', '-F', '#{session_name}'); Check ((($r.Out -split "`n" | Sort-Object) -join ',') -eq 'A,C') "A is still per session; C was made by the shared server" $r.Out
    $r = Run $PSMUX $ctx 'shared' @('kill-session', '-t', 'A'); Check ($r.Code -eq 0) "commands that start no server still work under shared (kill-session)"

    Head "Part 6: starts a running server makes for the user honour the switch"
    # The config is flipped to shared while a per session server runs. A start
    # the server makes itself (hook, binding, command prompt: commands.rs; a
    # TCP new-session: connection.rs) must not quietly make a per session one.
    $cfgLive = Join-Path $ROOT "live.conf"; Set-Content $cfgLive "set -g default-shell $POWERSHELL" -Encoding ASCII
    $env:PSMUX_CONFIG_FILE = $cfgLive
    $ctx = New-Ns "rt"
    $r = Run $PSMUX $ctx '<unset>' @('new-session', '-d', '-s', 'A'); Check ($r.Code -eq 0) "per session server up"
    Run $PSMUX $ctx '<unset>' @('set-hook', '-g', 'after-new-window', 'new-session -d -s K') | Out-Null
    $warm = Wait-Warm $PSMUX $ctx
    Set-Content $cfgLive "set -g default-shell $POWERSHELL`nset -s server-mode shared" -Encoding ASCII
    Run $PSMUX $ctx '<unset>' @('new-window', '-t', 'A') | Out-Null
    Start-Sleep -Milliseconds 1500
    $r = Run $PSMUX $ctx '<unset>' @('ls', '-F', '#{session_name}')
    Check ($r.Out -eq 'A') "hook new-session (execute_command_string) starts nothing under shared (warm=$warm)" $r.Out
    function Tcp-Cmd($ctx, $line) {
        $port = [int](Get-Content (Join-Path $ctx.Dir "$($ctx.Ns)__A.port")).Trim()
        $key = (Get-Content (Join-Path $ctx.Dir "$($ctx.Ns)__A.key")).Trim()
        $t = New-Object Net.Sockets.TcpClient; $t.Connect('127.0.0.1', $port)
        $s = $t.GetStream(); $w = New-Object IO.StreamWriter($s); $w.NewLine = "`n"
        $w.WriteLine("AUTH $key"); $w.WriteLine($line); $w.Flush()
        $rd = New-Object IO.StreamReader($s); $s.ReadTimeout = 8000
        $o = @(); try { while ($true) { $l = $rd.ReadLine(); if ($null -eq $l) { break }; $o += $l } } catch {}
        $t.Close(); return ($o -join '|')
    }
    $o = Tcp-Cmd $ctx "new-session -s T1"
    Check ($o -match 'ERROR: shared server mode cannot start a session from inside a per-session server') "TCP new-session (server spawn route) answers the error" $o
    # The -d route hands the request to a `psmux new-session -d` CLI, which
    # reads the switch itself: since step 2 it makes T2 in the namespace's
    # SHARED server, never in a per session server or the standby.
    $o = Tcp-Cmd $ctx "new-session -d -s T2"
    Start-Sleep -Milliseconds 500
    $t2pid = [int](((Get-Content (Join-Path $ctx.Dir "$($ctx.Ns)__T2.pid") -Raw -EA SilentlyContinue) -split ':')[0])
    $t2proc = Server-Procs $PSMUX $ctx.Ns | Where-Object { $_.ProcessId -eq $t2pid }
    Check ($t2proc -and $t2proc.CommandLine -match '--shared-server') "TCP new-session -d (CLI route) makes T2 in the shared server" "($o) pid=$t2pid"
    $r = Run $PSMUX $ctx '<unset>' @('ls', '-F', '#{session_name}')
    Check ((($r.Out -split "`n" | Sort-Object) -join ',') -eq 'A,T2') "no per session server was made by the TCP routes (A, and T2 in the shared server)" $r.Out
    Run $PSMUX $ctx '<unset>' @('kill-session', '-t', 'T2') | Out-Null
    Set-Content $cfgLive "set -g default-shell $POWERSHELL" -Encoding ASCII
    Run $PSMUX $ctx '<unset>' @('new-window', '-t', 'A') | Out-Null
    $ok = $false; for ($i = 0; $i -lt 50 -and -not $ok; $i++) { Start-Sleep -Milliseconds 100; $ok = ((Run $PSMUX $ctx '<unset>' @('ls', '-F', '#{session_name}')).Out -match 'K') }
    Check $ok "with the config back to per session the same hook makes K"
    $env:PSMUX_CONFIG_FILE = $CFG_DEFAULT
} finally {
    Remove-Item Env:PSMUX_SERVER_MODE -EA SilentlyContinue
    foreach ($pair in $script:Namespaces) {
        $env:PSMUX_DATA_DIR = $pair[1]
        & $PSMUX -L $pair[0] kill-server 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $ROOT -EA SilentlyContinue
    if (Get-Command Remove-PsmuxIsolatedConfig -EA SilentlyContinue) { Remove-PsmuxIsolatedConfig }
}

Write-Host "`n=== Results: $script:Passed passed, $script:Failed failed ===" -ForegroundColor Cyan
if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
