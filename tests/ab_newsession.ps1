# ab_newsession.ps1 — interleaved A/B of end to end `psmux new-session` wall
# time. This machine drifts a lot, so the two builds are sampled ALTERNATELY
# inside one loop: any drift lands on both arms equally, and the paired
# differences are what get reported.
#
#   pwsh -NoProfile -File tests\ab_newsession.ps1 -A target\ab_before\pmux.exe -B target\release\pmux.exe -N 20
#
# Both binaries must be named psmux/pmux/tmux: session.rs gates the server image
# name, and a differently named copy silently loses the warm claim fast path,
# which makes the A/B measure the rename instead of the change.
param(
    [string]$A = "",
    [string]$B = "",
    [int]$N = 20,
    [switch]$NoWarm,
    [switch]$Attachless
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
if (-not $A) { $A = Join-Path $root "target\ab_before\pmux.exe" }
if (-not $B) { $B = Join-Path $root "target\release\pmux.exe" }
$A = (Resolve-Path $A).Path; $B = (Resolve-Path $B).Path
foreach ($p in @($A, $B)) {
    # NOTE: $n would be the SAME variable as $N here — PowerShell variable names
    # are case insensitive — and would silently overwrite the sample count.
    $imgName = [IO.Path]::GetFileNameWithoutExtension($p).ToLower()
    if ($imgName -notin @("psmux", "pmux", "tmux")) { Write-Host "REFUSING: '$imgName' is not a recognised server image name; the warm claim would be skipped" -ForegroundColor Red; exit 1 }
}
$DataDir = Join-Path $env:USERPROFILE ".psmux"

function Cleanup { param($exe, $ns)
    try { & $exe -L $ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 220
    Get-ChildItem "$DataDir\$($ns)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Med { param([double[]]$v) $s = $v | Sort-Object; $c = $s.Count; if ($c % 2 -eq 1) { $s[[int](($c-1)/2)] } else { ($s[$c/2-1]+$s[$c/2])/2 } }
function P90 { param([double[]]$v) $s = $v | Sort-Object; $s[[Math]::Min($s.Count-1, [int][Math]::Ceiling(0.9*$s.Count)-1)] }

# One sample: prime the namespace's warm spare the way a real machine has it,
# then time the launch that a user actually waits on.
function Sample { param($exe, $ns, $i)
    Cleanup $exe $ns
    if (-not $NoWarm) {
        & $exe -L $ns new-session -d -s primer 2>&1 | Out-Null
        & $exe -L $ns kill-session -t primer 2>&1 | Out-Null
        $w = [Diagnostics.Stopwatch]::StartNew()
        while ($w.ElapsedMilliseconds -lt 10000 -and -not (Test-Path "$DataDir\$($ns)____warm__.port")) { Start-Sleep -Milliseconds 15 }
        Start-Sleep -Milliseconds 1200   # let the spare's shell finish booting
    }
    $env:PSMUX_NO_WARM = $(if ($NoWarm) { "1" } else { $null })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $exe -L $ns new-session -d -s s$i 2>&1 | Out-Null
    $sw.Stop()
    $rc = $LASTEXITCODE
    $env:PSMUX_NO_WARM = $null
    if ($rc -ne 0) { return -1 }
    return $sw.Elapsed.TotalMilliseconds
}

$ta = @(); $tb = @(); $pairs = @()
for ($i = 0; $i -lt $N; $i++) {
    # alternate which arm goes first so ordering cannot favour one build
    # NOT $a/$b: those are the SAME variables as $A/$B (PowerShell names are
    # case insensitive) and assigning a timing to them would overwrite the
    # binary paths mid-run.
    if ($i % 2 -eq 0) {
        $sampA = Sample $A "abx$i" $i; $sampB = Sample $B "aby$i" $i
    } else {
        $sampB = Sample $B "aby$i" $i; $sampA = Sample $A "abx$i" $i
    }
    if ($sampA -ge 0 -and $sampB -ge 0) { $ta += $sampA; $tb += $sampB; $pairs += ($sampB - $sampA) }
    Write-Host ("  {0,2}: A={1,7:N1}  B={2,7:N1}  diff={3,7:N1}" -f $i, $sampA, $sampB, ($sampB - $sampA)) -ForegroundColor DarkGray
}
Cleanup $A "abx0"; Cleanup $B "aby0"
for ($i = 0; $i -lt $N; $i++) { Cleanup $A "abx$i"; Cleanup $B "aby$i" }

Write-Host ""
Write-Host ("A (before) : n={0}  med={1,7:N1}  min={2,7:N1}  p90={3,7:N1}   {4}" -f $ta.Count, (Med $ta), ($ta | Measure-Object -Minimum).Minimum, (P90 $ta), $A) -ForegroundColor Cyan
Write-Host ("B (after)  : n={0}  med={1,7:N1}  min={2,7:N1}  p90={3,7:N1}   {4}" -f $tb.Count, (Med $tb), ($tb | Measure-Object -Minimum).Minimum, (P90 $tb), $B) -ForegroundColor Cyan
$mp = Med $pairs
$wins = ($pairs | Where-Object { $_ -lt 0 }).Count
Write-Host ("paired diff (B - A): median={0,7:N1}ms   B faster in {1}/{2} pairs" -f $mp, $wins, $pairs.Count) -ForegroundColor Magenta

# A flat poll interval does not make the median slower so much as QUANTISED: a
# launch lands either just after a probe (fast) or a whole interval after the
# session became ready. Machine load moves the median by far more than one
# interval and hides that entirely, so measure the quantisation itself: how many
# samples sit within a few ms of that arm's OWN floor. A ramped poll clusters on
# its floor; a flat one smears upward in steps of the interval.
function NearFloor { param([double[]]$v, [double]$slack)
    $f = ($v | Measure-Object -Minimum).Minimum
    return ($v | Where-Object { $_ -le $f + $slack }).Count
}
foreach ($slack in @(5, 10, 20)) {
    Write-Host ("  within {0,2}ms of own floor:  A={1,2}/{2}   B={3,2}/{4}" -f `
        $slack, (NearFloor $ta $slack), $ta.Count, (NearFloor $tb $slack), $tb.Count) -ForegroundColor Yellow
}
Write-Host "done."
