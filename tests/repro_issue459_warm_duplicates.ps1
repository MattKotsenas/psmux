# Issue #459: unbounded psmux.exe growth from duplicate warm servers.
#
# Warm (`__warm__`) servers were exempt from the single-server-per-name mutex,
# so any number of them could coexist in one namespace. Since the handoff is a
# single `__warm__.port` file, everything past the first was unreachable and
# immortal. This script starts two warm servers in a private namespace and
# asserts that only one survives.
#
# SAFETY: every process this script touches is matched on BOTH
#   (a) an image path under this repo's target\ directory, and
#   (b) a command line containing this run's unique namespace,
# so it can never affect an installed psmux, another agent's server, or the
# session this script is running inside. Teardown is in a finally block.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $repoRoot 'target\debug\psmux.exe'
if (-not (Test-Path $exe)) { throw "build first: cargo build --bin psmux  (missing $exe)" }

# Unique per-run namespace. Nothing else on this machine can match it.
$ns = "psmux459e2e-$PID-$(Get-Random -Maximum 99999)"
$psmuxDir = Join-Path $env:USERPROFILE '.psmux'
$warmBase = "$($ns)____warm__"

function Get-NsProcesses {
    # Both conditions required: our build AND our namespace.
    Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue |
        Where-Object { $_.ExecutablePath -like "$repoRoot\target\*" -and $_.CommandLine -like "*$ns*" }
}

function Start-Warm {
    Start-Process -FilePath $exe `
        -ArgumentList @('server', '-s', '__warm__', '-L', $ns, '-x', '80', '-y', '24') `
        -WindowStyle Hidden -PassThru
}

$failures = @()
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host "  PASS  $name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $name -- $detail" -ForegroundColor Red; $script:failures += $name }
}

try {
    Write-Host "namespace: $ns"
    Write-Host ''

    # --- scenario 1: a second warm server must exit as a duplicate ----------
    Write-Host 'scenario 1: two warm servers, one namespace'
    $first = Start-Warm
    $portFile = Join-Path $psmuxDir "$warmBase.port"
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $portFile)) { Start-Sleep -Milliseconds 200 }
    Check 'first warm registers its .port' (Test-Path $portFile) "no $portFile after 15s"

    $second = Start-Warm
    Start-Sleep -Seconds 3

    $alive = @(Get-NsProcesses)
    Check 'exactly one warm server survives' ($alive.Count -eq 1) `
        "found $($alive.Count): $(($alive | ForEach-Object { $_.ProcessId }) -join ', ')"
    Check 'the survivor is the first warm' `
        ($alive.Count -eq 1 -and $alive[0].ProcessId -eq $first.Id) `
        "expected pid $($first.Id), got $(($alive | ForEach-Object { $_.ProcessId }) -join ', ')"
    Check 'the duplicate exited on its own' `
        (-not (Get-Process -Id $second.Id -EA SilentlyContinue)) `
        "pid $($second.Id) is still running"

    # The duplicate must not have clobbered the winner's readiness beacon.
    Check 'winner .port still present after duplicate exit' (Test-Path $portFile) 'port file was removed'

    Write-Host ''

    # --- scenario 2: a claim must free the warm name for a replacement ------
    # Regression guard for the fix itself: if the claim did not release the warm
    # name, the namespace would be left with no warm server and every later open
    # would be a cold start.
    Write-Host 'scenario 2: claim hands the warm name over'
    & $exe -L $ns new-session -d -s work 2>&1 | Out-Null
    Start-Sleep -Seconds 4

    $sessions = (& $exe -L $ns list-sessions 2>&1 | Out-String)
    Check 'claimed session exists' ($sessions -match 'work') "list-sessions: $($sessions.Trim())"

    $after = @(Get-NsProcesses)
    # One claimed session server + one replacement warm.
    Check 'namespace settles at 2 servers (session + replacement warm)' `
        ($after.Count -le 2) `
        "found $($after.Count): $(($after | ForEach-Object { $_.ProcessId }) -join ', ')"

    Write-Host ''
    if ($failures.Count -eq 0) { Write-Host 'RESULT: PASS' -ForegroundColor Green }
    else { Write-Host "RESULT: FAIL ($($failures -join '; '))" -ForegroundColor Red }
}
finally {
    Write-Host ''
    Write-Host 'teardown...'
    # Namespace-scoped kill-server first (never a bare kill-server).
    & $exe -L $ns kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    # Force-kill anything left, still matched on repo path AND namespace.
    foreach ($p in @(Get-NsProcesses)) {
        Write-Host "  force-killing leftover pid $($p.ProcessId)"
        Stop-Process -Id $p.ProcessId -Force -EA SilentlyContinue
    }
    # Registry files for this namespace only (see issue #530 -- nothing prunes these).
    Get-ChildItem $psmuxDir -Filter "$ns*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    Write-Host 'teardown complete'
}

if ($failures.Count -gt 0) { exit 1 }
exit 0
