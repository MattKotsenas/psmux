# Issue #661: "split-window p99 is ten times its p90 on a session that only
# splits" - the spare pool is retired in the middle of a run of creations.
#
# WHAT WAS REPRODUCED (40 `split-window -v` on one live session with one
# attached client, ~265ms apart, worktree build of master 37e2990, trace on):
#
#   [12736.402] claim(split): pane=31 spare_age=2046.2ms pool_left=7 ready_left=6
#   [12839.661] pool: surge over, trimmed 6 surplus spare(s) back to target=2
#   [12840.356] pool: sample depth=2 ready=2 inflight=0 target=2 eff=2
#   [13002.912] claim(split): pane=32 spare_age=2056.4ms pool_left=1 ready_left=1
#   [13267.629] claim(split): pane=33 spare_age=2055.7ms pool_left=1 ready_left=0
#
#   Six settled spares were killed 103ms after one split and 160ms before the
#   next, while the user was still splitting. From there the pool alternated one
#   ready spare with none and the visible latency of a split went from ~20ms to
#   120-580ms: p50 125.6, p90 482.7, p99 581.6, max 581.6 over the 40.
#
#   The cause is the surge window: it was only ever written by a claim that
#   MISSED, so a run the surge was serving well renewed nothing and the window
#   counted down from a miss six seconds in the past.
#
# WHAT THIS SUITE PINS, from the pool's own trace rather than from timings alone
#   * no spare is retired BETWEEN the first and the last creation of a run
#   * the sampled depth never falls below the configured target mid run
#   * no claim older than the leading edge window (1500 ms from the first
#     claim, the time the surge's spares need to boot) finds NO READY SPARE
#   * and the user visible numbers that follow from all three: how many splits
#     are slow, and the max
#
# The depth samples come from `pool: sample depth=..` lines, written four times
# a second under PSMUX_WARM_TRACE (src/server/mod.rs, #661). Only the SESSION
# server's lines are read: the `__warm__` standby writes to the same file and is
# capped at one spare by design, so counting its samples would fail every run.
#
# Set PSMUX_TEST_BIN to test a non-installed binary.
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue661_warm_pool_depth_holds.ps1
param(
    [string]$Binary = "",
    # 24 splits at 250ms is 6 seconds of continuous creation, which is longer
    # than WARM_SURGE_HOLD (5s): the defect needs the run to outlive the window.
    [int]$Count = 24,
    [int]$GapMs = 250,
    [int]$SettleMs = 4000,
    [int]$PollMs = 5,
    # A creation the user notices, and how many of them a run may contain. Two:
    # a pool at its idle depth cannot serve three creations inside one shell
    # startup, so the leading edge of a burst is allowed to cost that, and no
    # more.
    [int]$SlowMs = 150,
    [int]$SlowBudget = 2,
    [int]$MaxLimitMs = 1500
)

$ErrorActionPreference = "Continue"
$script:Pass = 0
$script:Fail = 0
function Write-Pass { param($m) Write-Host "[PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info { param($m) Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Test { param($m) Write-Host "[TEST] $m" -ForegroundColor White }

if (-not $Binary -and $env:PSMUX_TEST_BIN) { $Binary = $env:PSMUX_TEST_BIN }
if (-not $Binary -and $env:PSMUX_TEST_BINARY) { $Binary = $env:PSMUX_TEST_BINARY }
if (-not $Binary) {
    foreach ($n in @("psmux.exe", "pmux.exe", "tmux.exe")) {
        $c = Join-Path $PSScriptRoot "..\target\release\$n"
        if (Test-Path $c) { $Binary = $c; break }
    }
}
if (-not $Binary) {
    $cmd = Get-Command psmux -ErrorAction SilentlyContinue
    if ($cmd) { $Binary = $cmd.Source }
}
if (-not $Binary -or -not (Test-Path $Binary)) {
    Write-Fail "no psmux binary found"
    exit 1
}
$Binary = (Resolve-Path $Binary).Path
# The server only claims a standby whose image name it recognises as its own, so
# a renamed copy would silently lose the warm path and every number here would
# be measuring the rename instead.
$imgName = [IO.Path]::GetFileNameWithoutExtension($Binary).ToLower()
if ($imgName -notin @("psmux", "pmux", "tmux")) {
    Write-Fail "'$imgName' is not a recognised server image name; the warm pool would be off"
    exit 1
}
Write-Info "Using: $Binary"

$Ns = "i661d$PID"
$Sess = "pool"
$PromptRe = 'PS [A-Z]:\\'
$DataDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR.TrimEnd('\', '/') } else { "$env:USERPROFILE\.psmux" }
$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION = $null
$TraceFile = Join-Path ([IO.Path]::GetTempPath()) "psmux_i661_$PID.log"
if (Test-Path $TraceFile) { Remove-Item $TraceFile -Force -EA SilentlyContinue }
$env:PSMUX_WARM_TRACE = "1"
$env:PSMUX_WARM_TRACE_FILE = $TraceFile
$script:ClientPid = 0

function Cleanup {
    # Only ever by pid, and only pids this suite started.
    if ($script:ClientPid -gt 0) {
        $p = Get-Process -Id $script:ClientPid -EA SilentlyContinue
        if ($p) { Stop-Process -Id $script:ClientPid -Force -EA SilentlyContinue }
        $script:ClientPid = 0
    }
    try { & $Binary -L $Ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 400
    Get-ChildItem "$DataDir\$($Ns)__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

function Invoke-Psmux {
    param([int]$Port, [string]$Key, [string]$Cmd)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.NoDelay = $true
    try {
        $tcp.Connect("127.0.0.1", $Port)
        $st = $tcp.GetStream(); $st.ReadTimeout = 20000
        $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $false
        $rd = New-Object System.IO.StreamReader($st)
        $wr.WriteLine("AUTH $Key"); $wr.Flush()
        if ($rd.ReadLine() -ne "OK") { return @{ ok = $false; lines = @() } }
        $wr.WriteLine("TARGET $Sess")
        $wr.WriteLine($Cmd)
        $wr.Flush()
        $acc = New-Object System.Collections.Generic.List[string]
        while ($true) {
            $l = $rd.ReadLine()
            if ($null -eq $l -or $l -eq "") { break }
            $acc.Add($l)
        }
        return @{ ok = $true; lines = $acc.ToArray() }
    } catch {
        return @{ ok = $false; lines = @() }
    } finally { $tcp.Close() }
}

function Get-Text { param($r) if ($null -eq $r -or -not $r.ok) { return "" } return ($r.lines -join "`n") }

function Wait-Registered {
    param([int]$TimeoutMs = 20000)
    $pf = "$DataDir\$($Ns)__$Sess.port"
    $kf = "$DataDir\$($Ns)__$Sess.key"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Test-Path $pf) -and (Test-Path $kf)) {
            try {
                $p = [int](Get-Content $pf -Raw).Trim()
                $k = (Get-Content $kf -Raw).Trim()
                if ($p -gt 0 -and $k.Length -gt 0) { return @{ Port = $p; Key = $k } }
            } catch {}
        }
        Start-Sleep -Milliseconds 10
    }
    return $null
}

function Get-ActivePaneId { param([int]$Port, [string]$Key)
    (Get-Text (Invoke-Psmux $Port $Key "display-message -p '#{pane_id}'")).Trim().Trim("'")
}

$samples = @()
try {
    Cleanup
    Start-Process -FilePath $Binary -ArgumentList "-L", $Ns, "new-session", "-d", "-s", $Sess -WindowStyle Hidden | Out-Null
    $inf = Wait-Registered
    if ($null -eq $inf) { Write-Fail "the test session never registered"; Cleanup; exit 1 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 25000) {
        if ((Get-Text (Invoke-Psmux $inf.Port $inf.Key "capture-pane -p")) -match $PromptRe) { break }
        Start-Sleep -Milliseconds 20
    }
    # One attached client, because that is the session the report is about, and
    # because the client's size is what the spares are spawned at.
    $c = Start-Process -FilePath $Binary -ArgumentList "-L", $Ns, "attach", "-t", $Sess -PassThru
    $script:ClientPid = $c.Id
    # A fresh -L namespace starts with a COLD pool: without this settle the
    # first samples would be measuring a shell boot, not the pool.
    Start-Sleep -Milliseconds $SettleMs

    Write-Test "$Count splits ${GapMs}ms apart on one live session"
    for ($i = 1; $i -le $Count; $i++) {
        $old = Get-ActivePaneId $inf.Port $inf.Key
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Psmux $inf.Port $inf.Key "split-window -v"
        $ms = -1
        if ($r.ok -and (($r.lines -join " ") -notmatch 'too small|no space|error|unknown command')) {
            while ($t0.ElapsedMilliseconds -lt 25000) {
                $id = Get-ActivePaneId $inf.Port $inf.Key
                if ($id -and $id -ne $old) {
                    if ((Get-Text (Invoke-Psmux $inf.Port $inf.Key "capture-pane -p -t $id")) -match $PromptRe) {
                        $ms = $t0.Elapsed.TotalMilliseconds
                        break
                    }
                }
                Start-Sleep -Milliseconds $PollMs
            }
        }
        if ($ms -ge 0) { $samples += [math]::Round($ms, 1) }
        # Keep room for the next vertical split, and never kill the last pane of
        # the window: that would end the session mid run.
        $panes = @((Get-Text (Invoke-Psmux $inf.Port $inf.Key "list-panes")) -split "`n" | Where-Object { $_ -match '\S' })
        if ($panes.Count -gt 1) { Invoke-Psmux $inf.Port $inf.Key "kill-pane" | Out-Null }
        $rest = $GapMs - $t0.ElapsedMilliseconds
        if ($rest -gt 0) { Start-Sleep -Milliseconds $rest }
    }
    Start-Sleep -Milliseconds 300
}
finally {
    Cleanup
}

if ($samples.Count -lt $Count) {
    Write-Fail "only $($samples.Count) of $Count splits produced a pane"
} else {
    Write-Pass "all $Count splits produced a pane"
}

if (-not (Test-Path $TraceFile)) {
    Write-Fail "the warm trace was never written ($TraceFile); PSMUX_WARM_TRACE is how this suite sees the pool"
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed:  $($script:Pass)"
    Write-Host "  Failed:  $($script:Fail)"
    exit $script:Fail
}
$trace = Get-Content $TraceFile

# The session server is the process that serves the splits; the `__warm__`
# standby writes to the same file and is capped at one spare by design.
$claimLines = @($trace | Where-Object { $_ -match 'claim\(split\)' })
if ($claimLines.Count -eq 0) {
    Write-Fail "no claim(split) lines in the trace: the splits did not go through the pool at all"
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed:  $($script:Pass)"
    Write-Host "  Failed:  $($script:Fail)"
    exit $script:Fail
}
$srvPid = ([regex]::Match($claimLines[0], 'pid=(\d+)')).Groups[1].Value
$srv = @($trace | Where-Object { $_ -match "pid=$srvPid\]" })
$firstClaim = [array]::IndexOf($srv, @($srv | Where-Object { $_ -match 'claim\(split\)' })[0])
$lastClaimLine = @($srv | Where-Object { $_ -match 'claim\(split\)' })[-1]
$lastClaim = [array]::LastIndexOf($srv, $lastClaimLine)
$during = $srv[$firstClaim..$lastClaim]

# 1. nothing is retired while the user is still creating panes
Write-Test "no spare is retired between the first and the last split"
$trims = @($during | Where-Object { $_ -match 'surge over, trimmed' })
if ($trims.Count -eq 0) {
    Write-Pass "no mid run trim"
} else {
    Write-Fail "the pool was trimmed $($trims.Count) time(s) mid run, which is #661 itself"
    $trims | ForEach-Object { Write-Info "  $_" }
}

# 2. the depth never falls below the configured target once the run is going.
#
# The SECOND HALF of the run, not all of it: the first creations happen while
# the pool is still at its idle depth, and a sample taken between a claim and
# its refill landing legitimately reads one short. What must never happen is the
# depth falling back once the run has been going for seconds, which is the
# trajectory in the report (depth 7 from split 4 to 28, depth 1 by split 31).
Write-Test "sampled depth holds within one of the configured target once the run is going"
$depths = @()
foreach ($l in $during) {
    $m = [regex]::Match($l, 'pool: sample depth=(\d+) ready=(\d+) inflight=(\d+) target=(\d+)')
    if ($m.Success) { $depths += [pscustomobject]@{ depth = [int]$m.Groups[1].Value; ready = [int]$m.Groups[2].Value; target = [int]$m.Groups[4].Value } }
}
if ($depths.Count -lt 8) {
    Write-Fail "only $($depths.Count) depth samples during the run; the trace should carry four a second"
} else {
    $target = $depths[0].target
    $half = @($depths[[int]($depths.Count / 2)..($depths.Count - 1)])
    $minDepth = ($half | Measure-Object -Property depth -Minimum).Minimum
    Write-Info ("depth samples={0} (second half {1}) min={2} max={3} target={4}" -f $depths.Count, $half.Count, $minDepth, ($half | Measure-Object -Property depth -Maximum).Maximum, $target)
    # One short is a claim whose refill is still booting (500 to 900 ms): when
    # every claim finds a ready spare no surge opens and the pool sits AT its
    # target, so a sample between a claim and its refill reads target - 1. The
    # defect fell further, to one ready spare and then none.
    if ($minDepth -ge ($target - 1)) {
        Write-Pass "minimum sampled depth $minDepth in the second half of the run is within one of target $target"
    } else {
        Write-Fail "the pool fell to depth $minDepth (target $target) while the user was still splitting"
    }
}

# 3. no claim past the leading edge finds nothing ready.
#
# The leading edge is a window of TIME, not a count of claims. A pool at its
# idle depth of two hands out its two settled spares, the surge opens on the
# next claim, and the spares it starts need a shell boot (500 to 900 ms on this
# machine) before they are ready. A claim that lands inside that window can
# still find seven spares that are all warming (`depth=7 got_warming=true`) and
# wait ~100 ms on one of them, which is the right call (the issue's own point:
# a warming spare beats a cold spawn). Counting claims made the fourth claim of
# a 250 ms run, arriving about one second in, fail on exactly that. The defect
# this suite guards is a miss LATE in the run, after the surge's spares have
# booted, which is what the mid run trim produced. So a miss is a failure only
# once the run is older than the leading edge window measured from the first
# claim of the run.
$LeadingEdgeMs = 1500
Write-Test "no claim older than ${LeadingEdgeMs}ms into the run finds NO READY SPARE"
$claims = @($srv | Where-Object { $_ -match 'claim\(split\)' })
$misses = @()
$firstClaimMs = $null
foreach ($c in $claims) {
    $m = [regex]::Match($c, '^\[\s*([0-9.]+)')
    if (-not $m.Success) { continue }
    $t = [double]$m.Groups[1].Value
    if ($null -eq $firstClaimMs) { $firstClaimMs = $t }
    if (($t - $firstClaimMs) -gt $LeadingEdgeMs -and $c -match 'NO READY SPARE') { $misses += $c }
}
if ($misses.Count -eq 0) {
    Write-Pass "$($claims.Count) claims, none past the leading edge missed"
} else {
    Write-Fail "$($misses.Count) claim(s) past the leading edge found no ready spare"
    $misses | ForEach-Object { Write-Info "  $_" }
}

# 4. and what that is worth to the user
Write-Test "user visible latency of the run"
$sorted = @($samples | Sort-Object)
if ($sorted.Count -gt 0) {
    function Pct { param($s, $p) $i = [Math]::Min($s.Count - 1, [int][Math]::Ceiling($p * $s.Count) - 1); if ($i -lt 0) { $i = 0 }; return $s[$i] }
    $p50 = Pct $sorted 0.5; $p90 = Pct $sorted 0.9; $p99 = Pct $sorted 0.99; $mx = $sorted[-1]
    $slow = @($samples | Where-Object { $_ -gt $SlowMs }).Count
    Write-Info ("p50={0:N1} p90={1:N1} p99={2:N1} max={3:N1} ms  [{4}]" -f $p50, $p90, $p99, $mx, (($samples | ForEach-Object { [int]$_ }) -join ', '))
    if ($slow -le $SlowBudget) {
        Write-Pass "$slow of $($samples.Count) splits over ${SlowMs}ms (budget $SlowBudget)"
    } else {
        Write-Fail "$slow of $($samples.Count) splits over ${SlowMs}ms, budget $SlowBudget"
    }
    if ($mx -le $MaxLimitMs) {
        Write-Pass ("max {0:N0}ms is within {1}ms" -f $mx, $MaxLimitMs)
    } else {
        Write-Fail ("max {0:N0}ms exceeds {1}ms" -f $mx, $MaxLimitMs)
    }
}

Remove-Item $TraceFile -Force -EA SilentlyContinue
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed:  $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
exit $script:Fail
