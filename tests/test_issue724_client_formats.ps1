# Issue #724: a script must be able to tell attached clients apart.
#
# quazardous (psmux 3.3.8) reported that `list-clients -F <format>` ignored
# the format (every line was the fixed default) and `display-message -c
# <client> -p` ignored -c (it answered the SERVER's pid and `client0`), so no
# tool could map an attached client to its process or tell a read only client
# (`attach -r`) from a writable one.
#
# tmux reference:
#   cmd-list-clients.c   LIST_CLIENTS_TEMPLATE, -F, -f, -t <session>
#   format.c             client_name, client_tty, client_pid, client_readonly,
#                        client_flags, client_control_mode, ...
#   server-client.c      server_client_get_flags (attached,...,read-only,UTF-8)
#   cmd-display-message  -c picks the client the client_* formats describe
#   cmd-find.c           cmd_find_client: name, tty, tty without /dev/, ":"
#   server-client.c      a read only client's keys never reach the pane
#
# Every client here is a REAL attached psmux process started hidden with
# Start-Process, and every pid asserted is the pid Start-Process returned.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue724_client_formats.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i724cli$PID" }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }
function Assert-Eq($name, $want, $got) {
    if ("$got" -ceq "$want") { Write-Pass "$name ($got)" } else { Write-Fail "$name`n         want: '$want'`n          got: '$got'" }
}

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX_TARGET_SESSION','PSMUX_CLIENT_READONLY') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_i724_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$injector = Join-Path $root "injector724.exe"
& $csc /nologo /optimize /out:$injector (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
Write-Info ("psmux: {0}  ({1})" -f $PSMUX, ((& $PSMUX -V) -join ' '))

function Px { & $PSMUX -L $NS @args 2>&1 | ForEach-Object { "$_" } }
$script:Opened = @()
function Start-Client([string[]]$ArgList) {
    $p = Start-Process -FilePath $PSMUX -ArgumentList (@('-L', $NS) + $ArgList) -WindowStyle Hidden -PassThru
    $script:Opened += $p
    return $p
}
function Wait-Clients([int]$n, [string]$sess) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        $rows = @(Px list-clients -t $sess -F '#{client_name}' | Where-Object { $_ -match '^/dev/pts/' })
        if ($rows.Count -ge $n) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
function Pane-Text([string]$sess) { (Px capture-pane -p -t $sess) -join "`n" }

try {
    Write-Host "`n=== Setup: two sessions, a writable and a read only client on 'work' ===" -ForegroundColor Yellow
    Px new-session -d -s work -x 120 -y 30 -- cmd.exe | Out-Null
    Px new-session -d -s other -x 100 -y 25 -- cmd.exe | Out-Null
    $rw = Start-Client @('attach', '-t', 'work')
    if (-not (Wait-Clients 1 'work')) { Write-Fail "the writable client never attached" }
    $ro = Start-Client @('attach', '-r', '-t', 'work')
    if (-not (Wait-Clients 2 'work')) { Write-Fail "the read only client never attached" }
    Start-Sleep -Milliseconds 800
    Write-Info "writable client pid $($rw.Id), read only client pid $($ro.Id)"

    Write-Host "`n=== list-clients -F applies the format, one row per client ===" -ForegroundColor Yellow
    $rows = @(Px list-clients -t work -F '#{client_name} #{client_pid} #{client_readonly}')
    Write-Info ("rows: " + ($rows -join ' | '))
    $byPid = @{}
    foreach ($r in $rows) { $f = $r -split ' '; if ($f.Count -eq 3) { $byPid[$f[1]] = $f } }
    if ($byPid.ContainsKey("$($rw.Id)")) { Write-Pass "the writable client's row carries its Start-Process pid $($rw.Id)" } else { Write-Fail "no row with pid $($rw.Id): $($rows -join ' | ')" }
    if ($byPid.ContainsKey("$($ro.Id)")) { Write-Pass "the read only client's row carries its Start-Process pid $($ro.Id)" } else { Write-Fail "no row with pid $($ro.Id): $($rows -join ' | ')" }
    Assert-Eq "client_readonly of the writable client" "0" ($byPid["$($rw.Id)"] | Select-Object -Last 1)
    Assert-Eq "client_readonly of the read only client" "1" ($byPid["$($ro.Id)"] | Select-Object -Last 1)
    $rwName = ($byPid["$($rw.Id)"] | Select-Object -First 1)
    $roName = ($byPid["$($ro.Id)"] | Select-Object -First 1)
    if ($rwName -match '^/dev/pts/\d+$' -and $roName -match '^/dev/pts/\d+$' -and $rwName -ne $roName) {
        Write-Pass "client names are distinct ttys ($rwName, $roName)"
    } else { Write-Fail "client names: '$rwName' '$roName'" }

    $tty = @(Px list-clients -t work -F '#{client_tty}')
    Assert-Eq "client_tty equals client_name" (@($rwName, $roName) -join ',') ($tty -join ',')
    $flags = @(Px list-clients -t work -F '#{client_pid}=#{client_flags}')
    Write-Info ("flags: " + ($flags -join ' | '))
    $roFlags = ($flags | Where-Object { $_ -like "$($ro.Id)=*" }) -replace '^\d+=', ''
    $rwFlags = ($flags | Where-Object { $_ -like "$($rw.Id)=*" }) -replace '^\d+=', ''
    if ($roFlags -match '(^|,)read-only(,|$)' -and $roFlags -match '^attached') { Write-Pass "read only client flags '$roFlags'" } else { Write-Fail "read only client flags '$roFlags'" }
    if ($rwFlags -notmatch 'read-only' -and $rwFlags -match '^attached') { Write-Pass "writable client flags '$rwFlags'" } else { Write-Fail "writable client flags '$rwFlags'" }
    $misc = @(Px list-clients -t work -F '#{client_session}|#{client_control_mode}|#{client_utf8}|#{client_termname}|#{client_width}x#{client_height}')
    if (@($misc | Where-Object { $_ -match '^work\|0\|1\|\S+\|\d+x\d+$' }).Count -eq 2) { Write-Pass "session, control mode, utf8, termname, size all expand ($($misc[0]))" } else { Write-Fail "misc row: $($misc -join ' | ')" }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $times = @(Px list-clients -t work -F '#{client_created} #{client_activity}')
    $okTimes = @($times | Where-Object { $p = $_ -split ' '; [long]$p[0] -gt ($now - 120) -and [long]$p[0] -le ($now + 2) -and [long]$p[1] -ge [long]$p[0] - 1 })
    if ($okTimes.Count -eq 2) { Write-Pass "client_created / client_activity are this run's epoch seconds ($($times[0]))" } else { Write-Fail "times: $($times -join ' | ') (now $now)" }

    Write-Host "`n=== The default line is tmux's LIST_CLIENTS_TEMPLATE ===" -ForegroundColor Yellow
    $def = @(Px list-clients -t work)
    Write-Info ("default: " + ($def -join ' | '))
    $want = "^$([regex]::Escape($roName)): work \[\d+x\d+ \S+\] \(attached,(focused,)?read-only,UTF-8\)$"
    if (@($def | Where-Object { $_ -match $want }).Count -eq 1) { Write-Pass "read only row matches the tmux template" } else { Write-Fail "no default row matches $want" }
    if (@($def | Where-Object { $_ -eq '' }).Count -eq 0) { Write-Pass "no empty line after the list" } else { Write-Fail "an empty line was printed" }
    $filtered = @(Px list-clients -t work -f '#{client_readonly}' -F '#{client_pid}')
    Assert-Eq "list-clients -f '#{client_readonly}' keeps only the read only client" "$($ro.Id)" ($filtered -join ',')

    Write-Host "`n=== -t scopes to one session; no -t lists every session ===" -ForegroundColor Yellow
    $oc = Start-Client @('attach', '-t', 'other')
    $null = Wait-Clients 1 'other'
    Start-Sleep -Milliseconds 500
    $otherRows = @(Px list-clients -t other -F '#{client_pid} #{session_name}')
    Assert-Eq "list-clients -t other lists only that session's client" "$($oc.Id) other" ($otherRows -join ',')
    $allRows = @(Px list-clients -F '#{client_pid}')
    $allSet = ($allRows | Sort-Object) -join ','
    $wantSet = (@("$($rw.Id)", "$($ro.Id)", "$($oc.Id)") | Sort-Object) -join ','
    Assert-Eq "bare list-clients lists the clients of every session" $wantSet $allSet

    Write-Host "`n=== display-message -c answers for the named client ===" -ForegroundColor Yellow
    Assert-Eq "display-message -c <rw> -p" "$($rw.Id) 0 $rwName work" ((Px display-message -c $rwName -p '#{client_pid} #{client_readonly} #{client_name} #{session_name}') -join '')
    Assert-Eq "display-message -c <ro> -p" "$($ro.Id) 1 $roName work" ((Px display-message -c $roName -p '#{client_pid} #{client_readonly} #{client_name} #{session_name}') -join '')
    $short = $roName -replace '^/dev/', ''
    Assert-Eq "display-message -c $short (tty without /dev/)" "$($ro.Id)" ((Px display-message -c $short -p '#{client_pid}') -join '')
    Assert-Eq "display-message -c ${roName}: (trailing colon)" "$($ro.Id)" ((Px display-message -c "${roName}:" -p '#{client_pid}') -join '')
    $ocName = (Px list-clients -t other -F '#{client_name}') -join ''
    Assert-Eq "display-message -c <other's client> with no -t lands on that client's session" "$($oc.Id) other" ((Px display-message -c $ocName -p '#{client_pid} #{session_name}') -join '')
    $txt = (Px display-message -c $rwName -p 'X') -join ''
    Assert-Eq "-c and its value never leak into the message text" "X" $txt

    Write-Host "`n=== detach-client -t uses the same names, in any session ===" -ForegroundColor Yellow
    $out = (Px detach-client -t $ocName) -join ' '
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 6000 -and -not $oc.HasExited) { Start-Sleep -Milliseconds 200 }
    if ($oc.HasExited) { Write-Pass "detach-client -t $ocName detached pid $($oc.Id) of session other ($out)" } else { Write-Fail "detach-client -t $ocName left pid $($oc.Id) attached ($out)" }
    $bad = (Px detach-client -t /dev/pts/1) -join ' '
    if ($LASTEXITCODE -ne 0 -and $bad -match "can't find client") { Write-Pass "an unknown client is refused ($bad)" } else { Write-Fail "unknown client: rc $LASTEXITCODE '$bad'" }

    Write-Host "`n=== A read only client cannot type into the pane ===" -ForegroundColor Yellow
    if (-not (Test-Path $injector)) {
        Write-Skip "tests\injector.cs did not compile"
    } else {
        & $injector $ro.Id "echo RO724MARK{ENTER}" 2>&1 | Out-Null
        & $injector $rw.Id "echo RW724MARK{ENTER}" 2>&1 | Out-Null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 6000 -and (Pane-Text 'work') -notmatch 'RW724MARK') { Start-Sleep -Milliseconds 200 }
        Start-Sleep -Milliseconds 600
        $pane = Pane-Text 'work'
        if ($pane -match 'RW724MARK') { Write-Pass "keys typed in the writable client reached the pane" } else { Write-Skip "keys typed in the writable client never arrived (injector refused?), read only check not meaningful" }
        if ($pane -match 'RW724MARK') {
            if ($pane -notmatch 'RO724MARK') { Write-Pass "keys typed in the read only client were dropped" } else { Write-Fail "the read only client typed into the pane" }
        }
        # A read only client may still detach itself (detach-client is CMD_READONLY).
        & $injector $ro.Id "^b{SLEEP:300}d" 2>&1 | Out-Null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 6000 -and -not $ro.HasExited) { Start-Sleep -Milliseconds 200 }
        if ($ro.HasExited) { Write-Pass "the read only client detached itself with prefix d" } else { Write-Fail "prefix d did not detach the read only client" }
        $left = @(Px list-clients -t work -F '#{client_pid}')
        Assert-Eq "only the writable client is left" "$($rw.Id)" ($left -join ',')
    }

    Write-Host "`n=== A control mode (-CC) client reports its own pid and mode ===" -ForegroundColor Yellow
    $psi = New-Object Diagnostics.ProcessStartInfo $PSMUX, "-L $NS -CC attach -t other"
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $cc = [Diagnostics.Process]::Start($psi)
    $script:Opened += $cc
    $sw = [Diagnostics.Stopwatch]::StartNew(); $ccRow = $null
    while ($sw.ElapsedMilliseconds -lt 10000 -and -not $ccRow) {
        $ccRow = Px list-clients -t other -F '#{client_pid} #{client_control_mode} #{client_flags}' | Where-Object { $_ -like "$($cc.Id) *" }
        Start-Sleep -Milliseconds 200
    }
    if ($ccRow -and $ccRow -match "^$($cc.Id) 1 attached,control-mode,") { Write-Pass "-CC client row: $ccRow" } else { Write-Fail "-CC client row for pid $($cc.Id): '$ccRow'" }
    try { $cc.StandardInput.Close() } catch {}
} finally {
    foreach ($p in $script:Opened) { try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } } catch {} }
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    if ($null -ne $savedDataDir) { $env:PSMUX_DATA_DIR = $savedDataDir } else { Remove-Item Env:\PSMUX_DATA_DIR -EA SilentlyContinue }
    if ($null -ne $savedNoWarm) { $env:PSMUX_NO_WARM = $savedNoWarm } else { Remove-Item Env:\PSMUX_NO_WARM -EA SilentlyContinue }
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host "`nResults: $($script:Pass) passed, $($script:Fail) failed, $($script:Skip) skipped"
exit $(if ($script:Fail -gt 0) { 1 } else { 0 })
