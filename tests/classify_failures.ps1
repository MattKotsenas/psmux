# Classify every failing suite in a run against the archived history of previous
# runs, WITHOUT touching the machine. Pure log reads: it spawns no psmux, kills
# nothing, and is therefore safe to use while a suite is still running.
#
# Why this exists: the expensive way to tell "my regression" from "pre-existing"
# is to rebuild a baseline binary and re-run the suite. But ~/.psmux-test-logs
# keeps a per-suite log for every historical run, so for any suite that has run
# before, the answer is already on disk for free.
#
# Verdicts:
#   PRE-EXISTING   today's exit code matches every historical run -> not new
#   ** CHANGED **  historically passed (exit 0), fails today      -> needs A/B
#   no history     never run before (e.g. suites unlocked by -IncludeInteractive)
#   mixed          inconsistent history -> flaky, needs repeat runs
#
# A ** CHANGED ** verdict is NOT proof of a regression. It only means the
# question cannot be answered from history. Settle it with a real A/B in which
# BOTH sides run under IDENTICAL conditions: comparing a standalone baseline
# against an in-suite HEAD measures the conditions, not the code, and will
# manufacture false regressions.
param(
    [string]$Run,                       # run id, default = newest
    [int]$HistoryCount = 4              # how many prior runs to compare against
)

$logRoot = Join-Path $env:TEMP "psmux-test-logs"
$runs = Get-ChildItem $logRoot -Directory -EA SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_' } |
        Sort-Object Name
if (-not $runs) { Write-Host "no runs found in $logRoot"; exit 1 }

$current = if ($Run) { $runs | Where-Object Name -eq $Run } else { $runs[-1] }
if (-not $current) { Write-Host "run '$Run' not found"; exit 1 }
$history = @($runs | Where-Object { $_.Name -ne $current.Name } | Select-Object -Last $HistoryCount)

Write-Host ""
Write-Host "Current run : $($current.Name)" -ForegroundColor Cyan
Write-Host "Compared to : $($history.Name -join ', ')" -ForegroundColor Cyan
Write-Host ""

function ExitCodeOf($runDir, $suite) {
    $f = Join-Path $runDir "suites\$suite.log"
    if (-not (Test-Path $f)) { return $null }
    $line = Select-String -Path $f -Pattern '^Exit:' -EA SilentlyContinue | Select-Object -First 1
    if ($line -and $line.Line -match 'Exit:\s*(-?\d+)') { return $Matches[1] }
    return $null
}

$prog = Join-Path $current.FullName "progress.log"
if (-not (Test-Path $prog)) { Write-Host "no progress.log in current run"; exit 1 }

$failing = Select-String -Path $prog -Pattern '^\[[^\]]*\]\s+(FAIL|TIMEOUT)\s+(\S+)' |
           ForEach-Object { $_.Matches[0].Groups[2].Value } | Sort-Object -Unique

if (-not $failing) { Write-Host "No failures in this run." -ForegroundColor Green; exit 0 }

$counts = @{ 'PRE-EXISTING'=0; '** CHANGED **'=0; 'no history'=0; 'mixed'=0 }
'{0,-46} {1,-7} {2,-8} {3}' -f 'SUITE','TODAY','HISTORY','VERDICT' | Write-Host
'{0,-46} {1,-7} {2,-8} {3}' -f ('-'*46),'-----','-------','-------' | Write-Host

foreach ($s in $failing) {
    $today = ExitCodeOf $current.FullName $s
    $hist  = foreach ($h in $history) { $c = ExitCodeOf $h.FullName $s; if ($null -eq $c) { '-' } else { $c } }
    $hs = ($hist -join '')

    # A '-' means that run has no log for this suite (an aborted run, or a suite
    # added later). That is absence of evidence, not conflicting evidence, so gaps
    # are DROPPED rather than treated as inconsistency. Counting them as "mixed"
    # made every single suite read 'mixed' the moment one empty run dir existed,
    # which hid two genuine regressions in a wall of noise.
    $known = @($hist | Where-Object { $_ -ne '-' })
    $uniq  = @($known | Select-Object -Unique)

    if ($known.Count -eq 0)                                         { $verdict = 'no history' }
    elseif ($uniq.Count -eq 1 -and $uniq[0] -eq $today)             { $verdict = 'PRE-EXISTING' }
    elseif ($uniq.Count -eq 1 -and $uniq[0] -eq '0')                { $verdict = '** CHANGED **' }
    elseif ($uniq -notcontains $today -and $uniq -contains '0')     { $verdict = '** CHANGED **' }
    else                                                            { $verdict = 'mixed' }

    $counts[$verdict]++
    $colour = switch ($verdict) {
        'PRE-EXISTING'  { 'DarkGray' }
        '** CHANGED **' { 'Red' }
        'no history'    { 'Yellow' }
        default         { 'Magenta' }
    }
    Write-Host ('{0,-46} {1,-7} {2,-8} {3}' -f $s, $today, $hs, $verdict) -ForegroundColor $colour
}

Write-Host ""
foreach ($k in 'PRE-EXISTING','** CHANGED **','no history','mixed') {
    Write-Host ("  {0,-15} {1}" -f $k, $counts[$k])
}
Write-Host ""
Write-Host "Only '** CHANGED **' and 'mixed' need an A/B. Run BOTH sides identically." -ForegroundColor Yellow
