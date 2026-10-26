# PR #740: a foreground run-shell bound to a prefix key must not park the
# attached client's reader on the server.
#
# The client sends a prefix binding as two lines in one flush: the command and
# then `prefix-end`. When the server ran a foreground `run-shell` synchronously
# on the client's reader thread, `prefix-end` sat unread until the shell exited,
# so #{client_prefix} stayed 1 (the PREFIX indicator stayed lit) and every key
# typed meanwhile was held and then delivered in a burst.
#
# tmux runs the command as a job (cmd-run-shell.c job_run, the callback fires
# from the event loop), and the client's input keeps flowing while it runs.
#
# Proof, with a real attached client in a hidden conhost and keys written into
# its console with tests\injector.cs:
#   1. prefix C-s runs `Start-Sleep 4; Write-Output RS740OUT`
#   2. #{client_prefix} drops to 0 within 500 ms of the key, while the command
#      is still running
#   3. text typed right after the binding reaches the pane within 1500 ms
#   4. the run-shell output popup still arrives, once, with RS740OUT, after the
#      command finishes
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_pr740_run_shell_reader.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "p740rs$PID" }
$SESS = "rs740"
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_p740_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

$sleepSec = 4
$conf = Join-Path $root "p740.conf"
@"
bind-key -T prefix C-s run-shell 'pwsh -NoProfile -Command "Start-Sleep -Seconds $sleepSec; Write-Output RS740OUT"'
bind-key -T prefix C-y run-shell 'pwsh -NoProfile -Command "Start-Sleep -Seconds 3"' \; set -g @chain740 done
"@ | Set-Content -Path $conf -Encoding ASCII

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$injector = Join-Path $root "injector740.exe"
& $csc /nologo /platform:x64 /out:$injector (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $injector)) { Write-Host "FATAL: could not compile tests\injector.cs" -ForegroundColor Red; exit 1 }

Write-Host "`n=== PR #740: foreground run-shell does not park the client reader ===" -ForegroundColor Cyan
Write-Info ("psmux: {0}  ({1})" -f $PSMUX, ((& $PSMUX -V) -join ' '))

function P { & $PSMUX -L $NS @args 2>&1 }
function Wait-Until([scriptblock]$cond, [int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 150 }
    return [bool](& $cond)
}
function Inject($clientPid, $keys) {
    & $injector $clientPid $keys 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}
# The server's state as the attached client sees it, from a PERSISTENT
# dump-state over TCP (read to the last full frame).
function Get-Dump {
    $portFile = Join-Path $env:PSMUX_DATA_DIR "${NS}__${SESS}.port"
    $keyFile  = Join-Path $env:PSMUX_DATA_DIR "${NS}__${SESS}.key"
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim(); $key = (Get-Content $keyFile -Raw).Trim()
    $tcp = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 4000
        $st = $tcp.GetStream(); $w = [System.IO.StreamWriter]::new($st); $r = [System.IO.StreamReader]::new($st)
        $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine(); $w.Write("PERSISTENT`n"); $w.Flush()
        $w.Write("dump-state`n"); $w.Flush()
        $best = $null; $tcp.ReceiveTimeout = 800
        for ($j = 0; $j -lt 80; $j++) {
            try { $line = $r.ReadLine() } catch { break }
            if ($null -eq $line) { break }
            if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
            if ($best) { $tcp.ReceiveTimeout = 60 }
        }
        return $best
    } catch { return $null } finally { if ($tcp) { $tcp.Close() } }
}
function Popup-Text {
    $d = Get-Dump
    if (-not $d) { return $null }
    try { $j = $d | ConvertFrom-Json } catch { return $null }
    if (-not $j.popup_active) { return "" }
    $txt = ""
    if ($j.popup_lines) { $txt += ($j.popup_lines -join "`n") }
    if ($j.popup_rows) { foreach ($row in $j.popup_rows) { $txt += "`n" + (-join ($row.runs | ForEach-Object { $_.text })) } }
    return ("[" + $j.popup_command + "] " + $txt)
}

$conhost = "$env:WINDIR\System32\conhost.exe"
$proc = $null
try {
    $proc = Start-Process -FilePath $conhost -ArgumentList "`"$PSMUX`"", '-L', $NS, '-f', "`"$conf`"", 'new-session', '-s', $SESS, '-x', '160', '-y', '40' -WindowStyle Hidden -PassThru
    Wait-Until { & $PSMUX -L $NS has-session -t $SESS 2>$null; $LASTEXITCODE -eq 0 } 15000 | Out-Null
    Wait-Until { ((P capture-pane -p -t $SESS) -join "`n") -match 'PS [A-Z]:\\' } 15000 | Out-Null
    $client = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" | Where-Object { $_.Name -like 'psmux*' } | Select-Object -First 1
    if (-not $client) { Write-Fail "no psmux client under conhost $($proc.Id)"; throw "no client" }
    $cpid = [int]$client.ProcessId
    Wait-Until { (P list-clients | Out-String).Trim().Length -gt 0 } 8000 | Out-Null
    $bound = (P list-keys -T prefix) -join "`n"
    if ($bound -match 'RS740OUT') { Write-Info "binding present: prefix C-s run-shell (sleep $sleepSec s)" }
    else { Write-Fail "prefix C-s binding not loaded from $conf"; throw "no binding" }

    # ---------------------------------------------------------------------
    Write-Host "`n[Test 1] prefix C-s with a $sleepSec s foreground run-shell, then typing" -ForegroundColor Yellow
    if (-not (Inject $cpid "^b{SLEEP:250}^s")) { Write-Skip "injection refused by the desktop (not a psmux result)"; throw "skip" }
    $t0 = Get-Date
    $firstZeroMs = $null; $typedMs = $null; $samples = @()
    # Sample before typing: starting the injector again costs a few hundred ms.
    Start-Sleep -Milliseconds 150
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    $cp = ((P display-message -t $SESS -p '#{client_prefix}') -join '').Trim()
    $samples += "${ms}ms=$cp"
    if ($cp -eq '0') { $firstZeroMs = $ms }
    if (-not (Inject $cpid "echo TYPED740")) { Write-Skip "injection refused by the desktop (not a psmux result)"; throw "skip" }

    $deadline = $t0.AddSeconds($sleepSec + 3)
    while ((Get-Date) -lt $deadline) {
        $ms = [int]((Get-Date) - $t0).TotalMilliseconds
        $cp = ((P display-message -t $SESS -p '#{client_prefix}') -join '').Trim()
        $samples += "${ms}ms=$cp"
        if ($null -eq $firstZeroMs -and $cp -eq '0') { $firstZeroMs = $ms }
        if ($null -eq $typedMs) {
            $scr = (P capture-pane -p -t $SESS) -join "`n"
            if ($scr -match 'TYPED740') { $typedMs = [int]((Get-Date) - $t0).TotalMilliseconds }
        }
        if ($null -ne $firstZeroMs -and $null -ne $typedMs -and $ms -gt 1500) { break }
        Start-Sleep -Milliseconds 200
    }
    Write-Info ("client_prefix samples: " + ($samples -join ' '))

    if ($null -ne $firstZeroMs -and $firstZeroMs -le 500) { Write-Pass "#{client_prefix} cleared $firstZeroMs ms after the binding, while the command still runs" }
    elseif ($null -ne $firstZeroMs) { Write-Fail "#{client_prefix} stayed 1 for $firstZeroMs ms (the reader was parked on the command)" }
    else { Write-Fail "#{client_prefix} never cleared within $($sleepSec + 3) s" }

    if ($null -ne $typedMs -and $typedMs -le 1500) { Write-Pass "typed text reached the pane $typedMs ms after the binding" }
    elseif ($null -ne $typedMs) { Write-Fail "typed text reached the pane only after $typedMs ms (held behind the command)" }
    else { Write-Fail "typed text never reached the pane within $($sleepSec + 3) s" }

    # ---------------------------------------------------------------------
    Write-Host "`n[Test 2] the run-shell output popup still arrives after the command" -ForegroundColor Yellow
    $popup = $null
    Wait-Until { $script:popup = Popup-Text; $script:popup -match 'RS740OUT' } (($sleepSec + 6) * 1000) | Out-Null
    $popup = $script:popup
    $popupMs = [int]((Get-Date) - $t0).TotalMilliseconds
    if ($popup -match 'RS740OUT') {
        if ($popupMs -ge (($sleepSec - 1) * 1000)) { Write-Pass "popup [$(($popup -split "`n")[0].Trim())] shows RS740OUT at $popupMs ms" }
        else { Write-Fail "popup appeared at $popupMs ms, before the $sleepSec s command could have finished" }
        $count = ([regex]::Matches($popup, 'RS740OUT')).Count
        if ($count -eq 1) { Write-Pass "output shown exactly once" } else { Write-Fail "output shown $count times" }
    } else {
        Write-Fail "no run-shell popup with RS740OUT (last: [$popup])"
    }

    # ---------------------------------------------------------------------
    # tmux runs the rest of a binding's command list only after a foreground
    # run-shell finishes (the item waits in the client's queue, cmd-queue.c
    # CMDQ_WAITING). Measured on tmux 3.4: `run-shell "sleep 3" \; set -g
    # @chain done` sets @chain at about 3100 ms, while client_prefix is 0
    # from the first sample.
    Write-Host "`n[Test 3] prefix C-y: run-shell (3 s) \; set -g @chain740 done keeps its order" -ForegroundColor Yellow
    [void](Inject $cpid "{ESC}")
    Wait-Until { (Popup-Text) -eq "" } 3000 | Out-Null
    P set -gu '@chain740' | Out-Null
    if (-not (Inject $cpid "^b{SLEEP:250}^y")) { Write-Skip "injection refused by the desktop (not a psmux result)"; throw "skip" }
    $t1 = Get-Date
    $chainMs = $null; $prefixMs = $null; $csamples = @()
    while (((Get-Date) - $t1).TotalMilliseconds -lt 7000) {
        $ms = [int]((Get-Date) - $t1).TotalMilliseconds
        $v = ((P display-message -t $SESS -p '#{client_prefix}|#{@chain740}') -join '').Trim()
        $csamples += "${ms}ms=$v"
        if ($null -eq $prefixMs -and $v -like '0|*') { $prefixMs = $ms }
        if ($null -eq $chainMs -and $v -like '*|done') { $chainMs = $ms }
        if ($null -ne $chainMs -and $null -ne $prefixMs) { break }
        Start-Sleep -Milliseconds 200
    }
    Write-Info ("client_prefix|@chain740 samples: " + ($csamples -join ' '))
    if ($null -ne $prefixMs -and $prefixMs -le 500) { Write-Pass "#{client_prefix} cleared $prefixMs ms after the chained binding" }
    else { Write-Fail "#{client_prefix} cleared only at [$prefixMs] ms after the chained binding" }
    if ($null -ne $chainMs -and $chainMs -ge 2000) { Write-Pass "the command after run-shell ran at $chainMs ms, after the 3 s shell finished" }
    elseif ($null -ne $chainMs) { Write-Fail "the command after run-shell ran at $chainMs ms, before the 3 s shell finished (tmux waits)" }
    else { Write-Fail "the command after run-shell never ran" }
} catch {
    if ("$_" -notin @('skip','no client','no binding')) { Write-Fail "exception: $_" }
} finally {
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 500
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue }
    $env:PSMUX_DATA_DIR = $savedDataDir
    $env:PSMUX_NO_WARM = $savedNoWarm
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host "`n=== Results: $($script:Pass) passed, $($script:Fail) failed, $($script:Skip) skipped ===" -ForegroundColor Cyan
if ($script:Fail -gt 0) { exit 1 }
exit 0
