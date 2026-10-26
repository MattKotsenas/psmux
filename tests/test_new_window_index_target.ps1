# new-window -t sess:N, -a, -b, -k, -S, -P against tmux 3.4.
#
# On 23a65aa5 (PSMUX_NO_WARM=1, -L, isolated PSMUX_DATA_DIR), after
# `new-session -d -s sa -n w0`:
#   new-window -d -t sa:1 / -t sa:7 / -t :3   rc 0 and NO window
#   new-window -d -t sa:0                     rc 0 and a window appended
#   new-window -d -k -t sa:0, -a, -b          a window appended, nothing replaced or shuffled
#   new-window -d -P -t sa:20                 "ERROR: can't find window: 20" on stdout, rc 0
# tmux 3.4 (`tmux -L nwref`, same script):
#   -t sa:1 -> 0 1, -t sa:7 -> 0 1 7, -t :3 -> 0 1 3 7
#   -t sa:0 -> "create window failed: index 0 in use", rc 1
#   -k -t sa:0 replaces window 0
#   0=w0 1=w1 2=w2 5=w5: -a -t sa:1 -> 2=A 3=w2 5=w5; -b -t sa:1 -> 1=B 2=w1 3=A 4=w2 5=w5
#   -S -n w5 -t sa selects w5; -S -n w5 -t sa:5 with 5 taken -> index 5 in use
#   -P -t sa:20 prints sa:20.0 (psmux's default -P line is sa:20)
#   -t sa:abc -> "can't find window: abc", rc 1
# tmux resolves the -t with CMD_FIND_WINDOW_INDEX (cmd-new-window.c) and
# spawn_window refuses an index in use unless -k (spawn.c).
#
# Routes: the CLI with -L, the CLI without -L (default namespace inside the
# isolated PSMUX_DATA_DIR), raw one-shot TCP (what the command prompt and key
# bindings send through send_control_to_port), and source-file (the config
# route). Judged by list-windows and rc only.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_new_window_index_target.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "nwidx$PID" }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_nwidx_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"
Write-Info ("psmux: {0}  ({1})" -f $PSMUX, ((& $PSMUX -V) -join ' '))

# $script:L is the namespace prefix: @('-L', $NS) or @() for the default one.
$script:L = @('-L', $NS)
function Invoke-Bin([string[]]$ArgList) {
    $se = Join-Path $root "err.txt"
    $out = & $PSMUX @($script:L + $ArgList) 2>$se
    $rc = $LASTEXITCODE
    [pscustomobject]@{
        rc  = $rc
        out = (@($out) -join "`n").TrimEnd("`r", "`n")
        err = "$(Get-Content $se -Raw -EA SilentlyContinue)".Trim()
    }
}
function Windows([string]$Sess) {
    ((Invoke-Bin @('list-windows', '-t', $Sess, '-F', '#{window_index}=#{window_name}')).out -split "`r?`n" | Where-Object { $_ }) -join ' '
}
function Active([string]$Sess) { (Invoke-Bin @('display-message', '-p', '-t', $Sess, '#{window_index}')).out.Trim() }
function Check($name, $cond, $detail) { if ($cond) { Write-Pass $name } else { Write-Fail "$name :: $detail" } }
function Expect-Windows([string]$name, [string]$Sess, [string]$want) {
    $got = Windows $Sess
    Check $name ($got -eq $want) "want '$want' got '$got'"
}
function Start-Sess([string]$Sess) {
    Invoke-Bin @('new-session', '-d', '-s', $Sess, '-n', 'w0', '-x', '120', '-y', '30') | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 10000) {
        if ((Invoke-Bin @('has-session', '-t', $Sess)).rc -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
}
function Send-Tcp([string]$Base, [string]$Command) {
    try {
        $port = (Get-Content (Join-Path $env:PSMUX_DATA_DIR "$Base.port") -Raw).Trim()
        $key  = (Get-Content (Join-Path $env:PSMUX_DATA_DIR "$Base.key") -Raw).Trim()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.NoDelay = $true
        $tcp.Connect("127.0.0.1", [int]$port)
        $st = $tcp.GetStream(); $st.ReadTimeout = 8000
        $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $true
        $rd = New-Object System.IO.StreamReader($st)
        $wr.WriteLine("AUTH $key")
        if ($rd.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAIL" }
        $wr.WriteLine($Command)
        $lines = @()
        try {
            while ($true) {
                $line = $rd.ReadLine()
                if ($null -eq $line) { break }
                $lines += $line
            }
        } catch {}
        $tcp.Close()
        return ($lines -join "`n")
    } catch { return "TCP_ERROR: $($_.Exception.Message)" }
}

# The CLI cases, run once with -L and once in the default namespace.
function Run-CliCases([string]$S, [string]$label) {
    Start-Sess $S
    $r = Invoke-Bin @('new-window', '-d', '-n', 'w1', '-t', "${S}:1")
    Check "[$label] -t ${S}:1 rc 0" ($r.rc -eq 0) "rc=$($r.rc) err=$($r.err)"
    Expect-Windows "[$label] -t ${S}:1 creates index 1" $S "0=w0 1=w1"
    Invoke-Bin @('new-window', '-d', '-n', 'w7', '-t', "${S}:7") | Out-Null
    Expect-Windows "[$label] -t ${S}:7 creates index 7" $S "0=w0 1=w1 7=w7"
    Invoke-Bin @('new-window', '-d', '-n', 'w3', '-t', "${S}:3") | Out-Null
    Expect-Windows "[$label] -t ${S}:3 fills the gap at 3" $S "0=w0 1=w1 3=w3 7=w7"
    $r = Invoke-Bin @('new-window', '-d', '-t', "${S}:0")
    Check "[$label] -t ${S}:0 in use is rc 1" ($r.rc -eq 1) "rc=$($r.rc)"
    Check "[$label] -t ${S}:0 says tmux's message" ($r.err -match 'create window failed: index 0 in use') "err='$($r.err)'"
    Expect-Windows "[$label] -t ${S}:0 in use changes nothing" $S "0=w0 1=w1 3=w3 7=w7"
    $r = Invoke-Bin @('new-window', '-d', '-k', '-n', 'K', '-t', "${S}:0")
    Check "[$label] -k rc 0" ($r.rc -eq 0) "rc=$($r.rc) err=$($r.err)"
    Expect-Windows "[$label] -k replaces window 0" $S "0=K 1=w1 3=w3 7=w7"
    Invoke-Bin @('new-window', '-d', '-a', '-n', 'A', '-t', "${S}:1") | Out-Null
    Expect-Windows "[$label] -a -t :1 takes the free index 2, nothing moves" $S "0=K 1=w1 2=A 3=w3 7=w7"
    Invoke-Bin @('new-window', '-d', '-b', '-n', 'B', '-t', "${S}:1") | Out-Null
    Expect-Windows "[$label] -b -t :1 shuffles the run 1 2 up, stops at the gap" $S "0=K 1=B 2=w1 3=A 4=w3 7=w7"
}

try {
    Write-Host "`n=== CLI with -L $NS ===" -ForegroundColor Yellow
    $script:L = @('-L', $NS)
    Run-CliCases 'sa' '-L'

    $S = 'sa'
    $r = Invoke-Bin @('new-window', '-dP', '-t', "${S}:20")
    Check "-P -t ${S}:20 prints the new window" ($r.rc -eq 0 -and $r.out -eq "${S}:20") "rc=$($r.rc) out='$($r.out)' err='$($r.err)'"
    $r = Invoke-Bin @('new-window', '-d', '-P', '-F', '#{window_index}:#{window_name}', '-n', 'pf', '-t', "${S}:21")
    Check "-P -F describes index 21" ($r.out -eq '21:pf') "out='$($r.out)'"
    $r = Invoke-Bin @('new-window', '-d', '-t', "${S}:abc")
    Check "-t ${S}:abc is can't find window at rc 1" ($r.rc -eq 1 -and $r.err -match "can't find window: abc") "rc=$($r.rc) err='$($r.err)'"
    $r = Invoke-Bin @('neww', '-d', '-n', 'nw', '-t', "${S}:30")
    Expect-Windows "neww alias honours the index" $S "0=K 1=B 2=w1 3=A 4=w3 7=w7 20=pwsh 21=pf 30=nw"

    # -S: selects the named window when -t has no index, refuses when the
    # index is taken, and creates when no window has that name.
    Invoke-Bin @('select-window', '-t', "${S}:0") | Out-Null
    $r = Invoke-Bin @('new-window', '-S', '-n', 'w7', '-t', $S)
    Check "-S -n w7 selects window 7" ($r.rc -eq 0 -and (Active $S) -eq '7') "rc=$($r.rc) active=$(Active $S)"
    Expect-Windows "-S -n w7 created nothing" $S "0=K 1=B 2=w1 3=A 4=w3 7=w7 20=pwsh 21=pf 30=nw"
    $r = Invoke-Bin @('new-window', '-d', '-S', '-n', 'w7', '-t', "${S}:7")
    Check "-S with a taken index is index in use" ($r.rc -eq 1 -and $r.err -match 'index 7 in use') "rc=$($r.rc) err='$($r.err)'"

    # Without -d the new window is current; -d keeps the current one.
    Invoke-Bin @('new-window', '-n', 'cur', '-t', "${S}:40") | Out-Null
    Check "new-window -t :40 without -d selects 40" ((Active $S) -eq '40') "active=$(Active $S)"
    Invoke-Bin @('new-window', '-d', '-n', 'bg', '-t', "${S}:41") | Out-Null
    Check "new-window -d -t :41 keeps 40 current" ((Active $S) -eq '40') "active=$(Active $S)"

    # A bare number is a window of the current session, not a session.
    $r = Invoke-Bin @('new-window', '-d', '-n', 'bare', '-t', '50')
    Check "-t 50 (bare) creates index 50 in the current session" ($r.rc -eq 0 -and (Windows $S) -match '50=bare') "rc=$($r.rc) err='$($r.err)' got '$(Windows $S)'"

    # Another session in the same namespace, named in the target.
    Start-Sess 'sb'
    $r = Invoke-Bin @('new-window', '-d', '-n', 'x5', '-t', 'sb:5')
    Expect-Windows "-t sb:5 lands in session sb" 'sb' "0=w0 5=x5"
    Check "-t sb:5 left session sa alone" ((Windows $S) -notmatch 'x5') "sa: $(Windows $S)"

    Write-Host "`n=== Raw one-shot TCP (command prompt / key binding route) ===" -ForegroundColor Yellow
    Start-Sess 'tc'
    $resp = Send-Tcp "${NS}__tc" "new-window -d -n t4 -t tc:4"
    Expect-Windows "TCP -t tc:4 creates index 4" 'tc' "0=w0 4=t4"
    $resp = Send-Tcp "${NS}__tc" "new-window -d -t :4"
    Check "TCP index in use answers ERROR" ($resp -match 'ERROR: create window failed: index 4 in use') "resp='$resp'"
    Send-Tcp "${NS}__tc" "new-window -d -k -n K4 -t :4" | Out-Null
    Expect-Windows "TCP -k replaces index 4" 'tc' "0=w0 4=K4"
    Send-Tcp "${NS}__tc" "new-window -d -b -n B0 -t :0" | Out-Null
    Expect-Windows "TCP -b -t :0 shuffles 0 up to 1" 'tc' "0=B0 1=w0 4=K4"
    $resp = Send-Tcp "${NS}__tc" "new-window -d -P -n p9 -t tc:9"
    Check "TCP -P prints tc:9" ($resp.Trim() -eq 'tc:9') "resp='$resp'"

    Write-Host "`n=== source-file (config route) ===" -ForegroundColor Yellow
    Start-Sess 'cf'
    $conf = Join-Path $root "nw.conf"
    Set-Content -Path $conf -Value @("new-window -d -n c6 -t cf:6", "new-window -d -n c9 -t :9") -Encoding ascii
    Invoke-Bin @('source-file', '-t', 'cf', $conf) | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 8000 -and (Windows 'cf') -ne "0=w0 6=c6 9=c9") { Start-Sleep -Milliseconds 200 }
    Expect-Windows "source-file places -t cf:6 and -t :9" 'cf' "0=w0 6=c6 9=c9"

    Write-Host "`n=== Control mode (-C) ===" -ForegroundColor Yellow
    Start-Sess 'cc'
    $psi = New-Object Diagnostics.ProcessStartInfo $PSMUX
    $psi.Arguments = "-L $NS -C attach -t cc"
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $cp = [Diagnostics.Process]::Start($psi)
    $cp.StandardInput.WriteLine("new-window -d -n c5 -t cc:5"); Start-Sleep -Milliseconds 1500
    $cp.StandardInput.WriteLine("new-window -d -t cc:5"); Start-Sleep -Milliseconds 1500
    $cp.StandardInput.WriteLine("new-window -d -P -n c6 -t cc:6"); Start-Sleep -Milliseconds 1500
    $cp.StandardInput.Close()
    if (-not $cp.WaitForExit(5000)) { $cp.Kill() }
    $ccOut = $cp.StandardOutput.ReadToEnd()
    Expect-Windows "-C new-window -t cc:5 and -P -t cc:6" 'cc' "0=w0 5=c5 6=c6"
    Check "-C index in use is a %error with tmux's message" ($ccOut -match "create window failed: index 5 in use\r?\n%error") "out='$ccOut'"
    Check "-C -P prints cc:6" ($ccOut -match "(?m)^cc:6\r?$") "out='$ccOut'"

    Write-Host "`n=== CLI in the default namespace (isolated PSMUX_DATA_DIR) ===" -ForegroundColor Yellow
    $script:L = @()
    $D = "nwdef$PID"
    Run-CliCases $D 'no -L'
    Invoke-Bin @('kill-session', '-t', $D) | Out-Null
    $script:L = @('-L', $NS)
} finally {
    $script:L = @('-L', $NS)
    Invoke-Bin @('kill-server') | Out-Null
    $env:PSMUX_DATA_DIR = $savedDataDir
    $env:PSMUX_NO_WARM = $savedNoWarm
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host ("`nResults: {0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip)
exit $script:Fail
