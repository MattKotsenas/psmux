# bench_startup_latency.ps1 — one command startup and creation latency harness.
#
# Answers, with n samples per scenario and median/min/p90/max (never a single
# number, because this machine is rarely quiet):
#
#   A. Cold start   (PSMUX_NO_WARM=1) to (a) server ready + TCP reachable,
#                    (b) shell prompt actually drawn in the pane.
#   B. Warm start   (warm pool available) to the same milestones.
#   C. Attach to an existing session, to first painted frame (real ConPTY).
#   D. new-window / split-window in TWO forms that must not be conflated:
#        D1 server side cost over a PERSISTENT TCP connection
#        D2 end to end `psmux new-window` CLI, which pays process start +
#           connect + AUTH per call (this is what test_perf_vs_wt.ps1 8.1 does)
#   E. The decomposition layers that explain D2:
#        L0  psmux.exe process start alone      (`psmux -V`, no connect)
#        L1  L0 + connect + AUTH + trivial cmd  (`psmux has-session`)
#        L2  L1 + real window creation          (`psmux new-window`)
#        connect+AUTH measured alone from an already running pwsh (no spawn)
#   F. Baselines on the same machine in the same window: raw tiny process
#      spawn, bare pwsh -NoProfile -Command exit, and tmux in WSL if present.
#
# Everything is scoped to a private -L namespace and to the psmux.exe under the
# repo the script lives in. It never kills by image name.
#
#   pwsh -NoProfile -File tests\bench_startup_latency.ps1
#   pwsh -NoProfile -File tests\bench_startup_latency.ps1 -N 25 -Only cold,warm
#   pwsh -NoProfile -File tests\bench_startup_latency.ps1 -Psmux <path> -Tag before

param(
    [int]$N = 15,
    [string]$Ns = "",
    [string]$Only = "",
    [string]$Psmux = "",
    [string]$Tag = "cur",
    [string]$Csv = "",
    [switch]$SkipWsl
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

if (-not $Psmux) { $Psmux = Join-Path (Split-Path -Parent $PSScriptRoot) "target\release\psmux.exe" }
$Psmux = (Resolve-Path $Psmux -ErrorAction SilentlyContinue).Path
if (-not $Psmux) { Write-Host "psmux release binary not found; run cargo build --release" -ForegroundColor Red; exit 1 }
if (-not $Ns) { $Ns = "bsl$PID" }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DataDir  = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { Join-Path $env:USERPROFILE ".psmux" }
$Want     = if ($Only) { $Only.Split(",") | ForEach-Object { $_.Trim().ToLower() } } else { @() }
function Want([string]$k) { return ($Want.Count -eq 0) -or ($Want -contains $k) }

$script:Rows = @()

function Stat {
    param([string]$Scenario, [double[]]$Samples, [string]$Note = "")
    if (-not $Samples -or $Samples.Count -eq 0) {
        Write-Host ("  {0,-42} NO SAMPLES {1}" -f $Scenario, $Note) -ForegroundColor Yellow
        return
    }
    $s = $Samples | Sort-Object
    $n = $s.Count
    $med = if ($n % 2 -eq 1) { $s[[int](($n - 1) / 2)] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
    $p90 = $s[[Math]::Min($n - 1, [int][Math]::Ceiling(0.9 * $n) - 1)]
    $row = [pscustomobject]@{
        tag = $Tag; scenario = $Scenario; n = $n
        median = [math]::Round($med, 1); min = [math]::Round($s[0], 1)
        p90 = [math]::Round($p90, 1); max = [math]::Round($s[$n - 1], 1)
        note = $Note
    }
    $script:Rows += $row
    Write-Host ("  {0,-42} n={1,-3} med={2,8:N1}  min={3,8:N1}  p90={4,8:N1}  max={5,8:N1}  {6}" -f `
        $Scenario, $n, $row.median, $row.min, $row.p90, $row.max, $Note) -ForegroundColor Cyan
}

function Head([string]$t) {
    Write-Host ""
    Write-Host ("=" * 96) -ForegroundColor Yellow
    Write-Host "  $t" -ForegroundColor Yellow
    Write-Host ("=" * 96) -ForegroundColor Yellow
}

# ---------------------------------------------------------------- process mgmt
# Only ever touch processes whose image path is the psmux.exe under test.
function Get-OwnPsmux {
    Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $Psmux) }
}
function Stop-OwnPsmux {
    foreach ($p in Get-OwnPsmux) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 300
}
function Kill-Ns {
    try { & $Psmux -L $Ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 200
}
function Reset-All {
    Kill-Ns
    Stop-OwnPsmux
    Get-ChildItem "$DataDir\$($Ns)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Wait-Session {
    param([string]$Sess, [int]$TimeoutMs = 20000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        & $Psmux -L $Ns has-session -t $Sess 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 20
    }
    return $false
}

function Get-PortKey {
    param([string]$Sess)
    $pf = "$DataDir\$($Ns)__$Sess.port"
    $kf = "$DataDir\$($Ns)__$Sess.key"
    if (-not (Test-Path $pf)) { return $null }
    $port = [int]((Get-Content $pf -Raw).Trim())
    $key = if (Test-Path $kf) { (Get-Content $kf -Raw).Trim() } else { "" }
    return @{ port = $port; key = $key }
}

function New-Conn {
    param([int]$Port, [string]$Key, [switch]$Persistent)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.NoDelay = $true
    $tcp.Connect("127.0.0.1", $Port)
    $ns2 = $tcp.GetStream(); $ns2.ReadTimeout = 20000
    $wr = New-Object System.IO.StreamWriter($ns2); $wr.AutoFlush = $false
    $rd = New-Object System.IO.StreamReader($ns2)
    $wr.WriteLine("AUTH $Key"); $wr.Flush()
    $auth = $rd.ReadLine()
    if ($auth -ne "OK") { throw "auth failed: $auth" }
    if ($Persistent) { $wr.WriteLine("PERSISTENT"); $wr.Flush(); Start-Sleep -Milliseconds 60 }
    return @{ tcp = $tcp; writer = $wr; reader = $rd }
}
function Close-Conn { param($c) try { $c.tcp.Close() } catch {} }

# A plain authed connection is ONE SHOT: reply lines, blank line, EOF. That is
# exactly what the CLI does, minus the process start, so it isolates
# connect+AUTH+server work from psmux.exe startup.
function Invoke-OneShot {
    param([int]$Port, [string]$Key, [string]$Cmd)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.NoDelay = $true
    $tcp.Connect("127.0.0.1", $Port)
    $ns2 = $tcp.GetStream(); $ns2.ReadTimeout = 20000
    $wr = New-Object System.IO.StreamWriter($ns2); $wr.AutoFlush = $false
    $rd = New-Object System.IO.StreamReader($ns2)
    $wr.WriteLine("AUTH $Key"); $wr.Flush()
    if ($rd.ReadLine() -ne "OK") { $tcp.Close(); throw "auth failed" }
    $wr.WriteLine($Cmd); $wr.Flush()
    while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break } }
    $tcp.Close()
}

# A PERSISTENT connection is the attached client channel: it streams state. Drain
# it, issue the verb, then read one line back. The line only arrives once the
# server has done the work, so this is the server side cost with no process
# start and no fresh connect+AUTH in it.
function Drain-Conn {
    param($c)
    $c.tcp.ReceiveTimeout = 30
    try { while ($c.tcp.Available -gt 0) { $null = $c.reader.ReadLine() } } catch {}
    $c.tcp.ReceiveTimeout = 20000
}
function Invoke-Barrier {
    param($c, [string]$Cmd)
    $c.writer.WriteLine($Cmd)
    $c.writer.WriteLine("dump-state")
    $c.writer.Flush()
    return $c.reader.ReadLine()
}

# A pane is "usable" when the shell has drawn its prompt. dump-state carries the
# pane text, so poll that on the persistent channel: each poll costs ~1ms rather
# than a whole psmux.exe process start.
function Wait-Prompt {
    param($c, [int]$TimeoutMs = 25000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $line = Invoke-Barrier $c "display-message -p ''"
        if ($line -and $line -match 'PS [A-Za-z]:\\') { return $sw.ElapsedMilliseconds }
        Start-Sleep -Milliseconds 2
    }
    return -1
}

Write-Host ""
Write-Host ("#" * 96)
Write-Host "  PSMUX STARTUP AND CREATION LATENCY   tag=$Tag  n=$N  ns=$Ns"
Write-Host "  binary: $Psmux"
Write-Host ("  built:  " + (Get-Item $Psmux).LastWriteTime + "   size: " + [math]::Round((Get-Item $Psmux).Length / 1MB, 2) + " MB")
Write-Host ("#" * 96)

Reset-All

# =============================================================== F. BASELINES
if (Want "baseline") {
    Head "F. MACHINE BASELINES (same window, same load)"

    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & cmd.exe /c "exit" | Out-Null
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "baseline: cmd.exe /c exit" $t "raw tiny process spawn from pwsh"

    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & pwsh -NoProfile -Command exit | Out-Null
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "baseline: pwsh -NoProfile -Command exit" $t "the shell psmux spawns in a pane"

    if (-not $SkipWsl) {
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if ($wsl) {
            $has = & wsl.exe -e sh -lc "command -v tmux >/dev/null && echo YES" 2>$null
            if ("$has".Trim() -eq "YES") {
                & wsl.exe -e sh -lc "tmux kill-server >/dev/null 2>&1" 2>$null | Out-Null
                # BOUNDED wait: a shell whose prompt never appears must not hang
                # the whole harness, so cap the poll and count only real hits.
                $script = 'tmux new-session -d -s bb 2>/dev/null || exit 9; i=0; ' +
                          'while [ $i -lt 600 ]; do ' +
                          'tmux capture-pane -p -t bb 2>/dev/null | tr -d " \n" | grep -q . && break; ' +
                          'i=$((i+1)); done; tmux kill-session -t bb 2>/dev/null; ' +
                          '[ $i -lt 600 ] || exit 8'
                $t = @()
                for ($i = 0; $i -lt $N; $i++) {
                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    & wsl.exe -e sh -c $script 2>$null | Out-Null
                    $rc = $LASTEXITCODE
                    $sw.Stop()
                    if ($rc -eq 0) { $t += $sw.Elapsed.TotalMilliseconds }
                }
                & wsl.exe -e sh -lc "tmux kill-server >/dev/null 2>&1" 2>$null | Out-Null
                Stat "baseline: WSL tmux new-session to pane text" $t "includes wsl.exe hop"
            } else { Write-Host "  (wsl present but no tmux inside; skipping)" -ForegroundColor DarkGray }
        } else { Write-Host "  (no wsl.exe; skipping tmux baseline)" -ForegroundColor DarkGray }
    }
}

# ============================================ E. CLI LAYER DECOMPOSITION (L0)
# L0 has to be measured before any server exists so nothing else is in play.
if (Want "layers") {
    Head "E1. psmux.exe PROCESS START ALONE (no server contact)"
    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $Psmux -V | Out-Null
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "L0: psmux -V (start + init + exit)" $t "pure process cost, no TCP"
}

# ================================================================ A/B. STARTS
function Measure-Start {
    param([string]$Label, [bool]$NoWarm, [int]$Count, [int]$SettleMs = 0)
    $ready = @(); $prompt = @(); $warmHit = 0
    for ($i = 0; $i -lt $Count; $i++) {
        Reset-All
        $sess = "s$i"
        if ($NoWarm) { $env:PSMUX_NO_WARM = "1" } else { $env:PSMUX_NO_WARM = $null }

        $warmFile = "$DataDir\$($Ns)____warm__.port"
        if (-not $NoWarm) {
            # The warm server is PER NAMESPACE (<ns>____warm__.port). Reset-All
            # wiped it, so prime it the way a real machine has it primed: create
            # and tear down a throwaway session, then wait for the spare to exist.
            & $Psmux -L $Ns new-session -d -s primer 2>&1 | Out-Null
            & $Psmux -L $Ns kill-session -t primer 2>&1 | Out-Null
            $swp = [Diagnostics.Stopwatch]::StartNew()
            while ($swp.ElapsedMilliseconds -lt 10000 -and -not (Test-Path $warmFile)) { Start-Sleep -Milliseconds 20 }
            if (-not (Test-Path $warmFile)) { Write-Host "    (iter ${i}: warm spare never appeared)" -ForegroundColor DarkYellow }
            else { $warmHit++ }
            # A real machine's spare has been sitting ready for minutes, so its
            # shell has long since drawn its prompt. Timing from the instant the
            # .port file appears measures a spare that is still booting.
            if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        Start-Process -FilePath $Psmux -ArgumentList @("-L", $Ns, "new-session", "-d", "-s", $sess) -WindowStyle Hidden | Out-Null
        # milestone (a): server ready AND TCP reachable
        $pk = $null
        while ($sw.ElapsedMilliseconds -lt 30000) {
            $pk = Get-PortKey $sess
            if ($pk) {
                try { $probe = New-Conn -Port $pk.port -Key $pk.key; Close-Conn $probe; break } catch { $pk = $null }
            }
            Start-Sleep -Milliseconds 2
        }
        if (-not $pk) { $env:PSMUX_NO_WARM = $null; continue }
        $ready += $sw.Elapsed.TotalMilliseconds

        # milestone (b): shell prompt actually drawn
        try {
            $c = New-Conn -Port $pk.port -Key $pk.key -Persistent
            $p = Wait-Prompt $c
            Close-Conn $c
            if ($p -ge 0) { $prompt += $sw.Elapsed.TotalMilliseconds }
        } catch {}
        $env:PSMUX_NO_WARM = $null
    }
    Stat "$Label -> (a) server ready + TCP reachable" $ready
    Stat "$Label -> (b) shell prompt drawn in pane"   $prompt
    if (-not $NoWarm) { Write-Host ("    warm spare present before timing: {0}/{1} iterations" -f $warmHit, $Count) -ForegroundColor DarkCyan }
}

if (Want "cold") { Head "A. COLD START (PSMUX_NO_WARM=1)"; Measure-Start "cold" $true $N }
if (Want "warm") {
    Head "B. WARM START (warm pool just created)"
    Measure-Start "warm" $false $N
}
if (Want "warmsettled") {
    Head "B2. WARM START (spare settled 1.5s, what a real machine has)"
    Measure-Start "warm settled" $false $N 1500
}

# ================================================ D + E: OPERATIONS ON A LIVE SESSION
if ((Want "ops") -or (Want "layers") -or (Want "attach")) {
    Reset-All
    $env:PSMUX_NO_WARM = $null
    $sess = "ops"
    Start-Process -FilePath $Psmux -ArgumentList @("-L", $Ns, "new-session", "-d", "-s", $sess) -WindowStyle Hidden | Out-Null
    if (-not (Wait-Session $sess)) { Write-Host "FATAL: ops session never came up" -ForegroundColor Red; Reset-All; exit 1 }
    $pk = Get-PortKey $sess
    Start-Sleep -Milliseconds 400
}

if (Want "layers") {
    Head "E2. NO PROCESS SPAWN: what one CLI invocation costs minus psmux.exe start"
    $t = @()
    for ($i = 0; $i -lt ($N * 2); $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $c = New-Conn -Port $pk.port -Key $pk.key
        $sw.Stop(); Close-Conn $c
        $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "S0: connect + AUTH only" $t "TCP loopback + one AUTH exchange"

    $t = @()
    for ($i = 0; $i -lt ($N * 2); $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-OneShot $pk.port $pk.key "list-sessions"
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "S1: connect + AUTH + trivial cmd + reply" $t "the whole CLI wire cost"

    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-OneShot $pk.port $pk.key "new-window -t $sess"
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "S2: connect + AUTH + new-window + reply" $t "S2 - S1 = real window creation"

    Head "E3. CLI LAYERS (each pays a whole psmux.exe process start)"
    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $Psmux -L $Ns has-session -t $sess 2>&1 | Out-Null
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "L1: psmux has-session (start+connect+auth+cmd)" $t "L1 - S1 = psmux.exe start + resolve"

    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $Psmux -L $Ns display-message -p "x" 2>&1 | Out-Null
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "L1b: psmux display-message -p (trivial server cmd)" $t
}

if (Want "ops") {
    Head "D1. SERVER SIDE COST OVER A PERSISTENT TCP CONNECTION"
    $c = New-Conn -Port $pk.port -Key $pk.key -Persistent
    for ($i = 0; $i -lt 3; $i++) { $null = Invoke-Barrier $c "new-window -t $sess" }

    $t = @()
    for ($i = 0; $i -lt ($N * 2); $i++) {
        Drain-Conn $c
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-Barrier $c "list-sessions"
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "TCP persistent: list-sessions (round trip floor)" $t

    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        Drain-Conn $c
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-Barrier $c "new-window -t $sess"
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "TCP persistent: new-window (server side only)" $t

    # A window only has room for a handful of splits; past that the server
    # REFUSES instantly and a refusal times at ~0.2ms, which reads as blazing
    # speed and is nothing of the kind. Close the pane again between samples so
    # every timed split is real work.
    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        Drain-Conn $c
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-Barrier $c "split-window -t $sess"
        $sw.Stop()
        if ($sw.Elapsed.TotalMilliseconds -ge 2) { $t += $sw.Elapsed.TotalMilliseconds }
        $null = Invoke-Barrier $c "kill-pane -t $sess"
        Start-Sleep -Milliseconds 120
    }
    Stat "TCP persistent: split-window (server side only)" $t "refusals (<2ms) discarded"
    Close-Conn $c

    Head "D2. END TO END CLI (what test_perf_vs_wt.ps1 bench 8.1 measures)"
    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $Psmux -L $Ns new-window -t $sess 2>&1 | Out-Null
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
    }
    Stat "L2: psmux new-window CLI (end to end)" $t

    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $Psmux -L $Ns split-window -t $sess 2>&1 | Out-Null
        $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
        & $Psmux -L $Ns kill-pane -t $sess 2>&1 | Out-Null
    }
    Stat "L2b: psmux split-window CLI (end to end)" $t "pane closed again between samples"

    # exact replica of bench 8.1 so the canary and this harness agree
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt 10; $i++) { & $Psmux -L $Ns new-window -t $sess 2>$null | Out-Null }
    $sw.Stop()
    Write-Host ("  bench 8.1 replica: 10 windows in {0}ms = {1}ms/window" -f $sw.ElapsedMilliseconds, [math]::Round($sw.ElapsedMilliseconds / 10, 1)) -ForegroundColor Magenta
}

# ================================================================== C. ATTACH
if (Want "attach") {
    Head "C. ATTACH TO AN EXISTING SESSION, TIME TO FIRST PAINTED FRAME"
    # An attached psmux client needs a real console. Hosted under a bare ConPTY
    # that never answers the terminal queries it emits, the client writes its
    # setup sequences and then waits forever, so a ConPTY harness measures the
    # harness. Launch it in a real console instead and take the milestone from
    # the SERVER, the one vantage point that cannot be faked: poll list-clients
    # on the wire until the session reports an attached client. The client
    # paints its first frame immediately after that registration.
    $savedSess = $env:PSMUX_SESSION_NAME; $env:PSMUX_SESSION_NAME = $null
    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process -FilePath $Psmux -ArgumentList @("-L", $Ns, "attach", "-t", $sess) -PassThru -WindowStyle Minimized
        $seen = -1
        while ($sw.ElapsedMilliseconds -lt 15000) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $tcp.NoDelay = $true
                $tcp.Connect("127.0.0.1", $pk.port)
                $st = $tcp.GetStream(); $st.ReadTimeout = 5000
                $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $false
                $rd = New-Object System.IO.StreamReader($st)
                $wr.WriteLine("AUTH $($pk.key)"); $wr.Flush()
                if ($rd.ReadLine() -eq "OK") {
                    $wr.WriteLine("list-clients -t $sess"); $wr.Flush()
                    $body = ""
                    while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break }; $body += $l }
                    if ($body.Trim()) { $seen = $sw.Elapsed.TotalMilliseconds }
                }
            } catch {} finally { try { $tcp.Close() } catch {} }
            if ($seen -ge 0) { break }
        }
        if ($seen -ge 0) { $t += $seen }
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Milliseconds 400
    }
    $env:PSMUX_SESSION_NAME = $savedSess
    Stat "attach -> server registers the client" $t "first paint follows immediately"
}

# ============================================== G. WARM POOL HIT RATE VS BURST
# The warm pane pool holds ONE spare and is replenished off the command path,
# during an idle gap. So a back to back burst of new-window (which is exactly
# what test_perf_vs_wt.ps1 bench 8.1 loops) never lets it refill, while a user
# creating windows even a tenth of a second apart hits it every time. This
# sweep is the evidence for the hit rate, and the answer to whether the product
# is slow or the benchmark is starving the pool.
if (Want "warmgap") {
    Head "G. WARM PANE POOL: new-window cost vs the idle gap before each call"
    foreach ($gap in @(0, 50, 100, 250, 800)) {
        Reset-All
        $env:PSMUX_NO_WARM = $null
        Start-Process -FilePath $Psmux -ArgumentList @("-L", $Ns, "new-session", "-d", "-s", "gp") -WindowStyle Hidden | Out-Null
        if (-not (Wait-Session "gp")) { Write-Host "  (gap=${gap}: session never came up)" -ForegroundColor Yellow; continue }
        Start-Sleep -Milliseconds 1200
        $gk = Get-PortKey "gp"
        $t = @()
        for ($i = 0; $i -lt $N; $i++) {
            if ($gap -gt 0) { Start-Sleep -Milliseconds $gap }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Invoke-OneShot $gk.port $gk.key "new-window -t gp"
            $sw.Stop(); $t += $sw.Elapsed.TotalMilliseconds
        }
        # A sample under 5ms could only have come from a ready made pane: a cold
        # CreatePseudoConsole plus a shell CreateProcess cannot finish that fast.
        $hits = ($t | Where-Object { $_ -lt 5 }).Count
        Stat ("new-window, {0}ms idle gap" -f $gap) $t ("warm hits {0}/{1}" -f $hits, $t.Count)
    }
}

# ==================================================================== SUMMARY
Head "SUMMARY (all times ms)"
$script:Rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
if ($Csv) {
    $script:Rows | Export-Csv -NoTypeInformation -Path $Csv
    Write-Host "wrote $Csv"
}

Reset-All
Write-Host "done."
