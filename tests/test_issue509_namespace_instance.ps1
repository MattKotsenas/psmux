# Issue #509: a `-L` namespace must present a stable server identity.
#
# psmux runs one server process per session, so `#{pid}` (and its alias
# `#{server_pid}`) resolve to whichever session's server answered the request.
# Creating a session therefore changes the value for the whole namespace, and a
# supervisor following the tmux idiom reads that as "the server restarted" —
# marking every already-running session as having lost its server.
#
# This is the issue's own reproduction, plus the two properties that make the new
# `#{server_instance}` token actually useful to a supervisor:
#   * it does NOT change when a session is created, and
#   * it DOES change when the namespace genuinely dies and comes back.
#
# The test uses a unique `-L` namespace in the real data directory and tears down
# only what it created. It never runs a bare `kill-server`.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\psmux_test_helpers.ps1"

$exe = Get-PsmuxExe
$psmuxDir = Join-Path $env:USERPROFILE '.psmux'
$ns = "i509t$(Get-Random -Maximum 999999)"
$failures = 0
$checks = 0

function Check($label, $condition, $detail) {
    $script:checks++
    if ($condition) {
        Write-Host "  PASS  $label"
    } else {
        $script:failures++
        Write-Host "  FAIL  $label" -ForegroundColor Red
        if ($detail) { Write-Host "        $detail" -ForegroundColor Red }
    }
}

function Query($namespace, $fmt) {
    # A namespace with no server answers on stderr ("no server running"), which
    # is a legitimate outcome here — an absent namespace has no identity. Keep
    # that from terminating the script under `$ErrorActionPreference = 'Stop'`.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $exe -f NUL -L $namespace display-message -p $fmt 2>&1 | Out-String).Trim()
    } catch {
        $out = ''
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($out -match 'no server running') { return '' }
    $out
}

function Remove-Namespace($namespace) {
    & $exe -L $namespace kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1500
    Remove-Item (Join-Path $psmuxDir "$namespace*") -Force -ErrorAction SilentlyContinue
}

Write-Host "issue #509: stable per-namespace server identity (namespace: $ns)"

try {
    # ---------------------------------------------------------------------
    # The issue's reproduction: three sessions, one namespace, no restart.
    # ---------------------------------------------------------------------
    $instances = @()
    $pids = @()
    foreach ($s in 'alpha', 'bravo', 'charlie') {
        & $exe -f NUL -L $ns new-session -d -s $s 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
        $pids += Query $ns '#{pid}'
        $instances += Query $ns '#{server_instance}'
    }

    Check "a namespace reports an identity at all" `
        ($instances[0] -match '^[0-9a-f]{16}$') `
        "got '$($instances[0])'"

    $distinct = @($instances | Sort-Object -Unique)
    Check "#{server_instance} is unchanged by creating sessions" `
        ($distinct.Count -eq 1) `
        "saw $($distinct.Count) different values across three sessions: $($instances -join ', ')"

    # Documents the behaviour that motivated the issue. This is deliberately NOT
    # changed by the fix: #{pid} is legitimately the answering server's pid, and
    # #{server_instance} is the value a supervisor should poll instead.
    $distinctPids = @($pids | Sort-Object -Unique)
    Check "#{pid} remains session-scoped (unchanged behaviour)" `
        ($distinctPids.Count -gt 1) `
        "expected per-session pids to differ, all were '$($pids[0])'"

    # All three sessions really are one namespace, so the identity above is
    # describing a live multi-session namespace rather than a collapsed one.
    $sessions = (& $exe -f NUL -L $ns list-sessions 2>&1 | Out-String)
    Check "all three sessions are live in one namespace" `
        (($sessions -match 'alpha') -and ($sessions -match 'bravo') -and ($sessions -match 'charlie')) `
        "list-sessions returned: $($sessions.Trim())"

    $beforeRestart = $instances[0]

    # ---------------------------------------------------------------------
    # A genuine restart MUST be visible: kill the namespace, start it again.
    # ---------------------------------------------------------------------
    Remove-Namespace $ns
    & $exe -f NUL -L $ns new-session -d -s alpha 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $afterRestart = Query $ns '#{server_instance}'

    Check "a genuinely restarted namespace reports a NEW identity" `
        ($afterRestart -ne $beforeRestart -and $afterRestart -match '^[0-9a-f]{16}$') `
        "before='$beforeRestart' after='$afterRestart'"

    # ---------------------------------------------------------------------
    # Namespaces must not share an identity.
    # ---------------------------------------------------------------------
    $ns2 = "${ns}b"
    try {
        & $exe -f NUL -L $ns2 new-session -d -s alpha 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
        $other = Query $ns2 '#{server_instance}'
        Check "separate namespaces have separate identities" `
            ($other -ne $afterRestart -and $other -match '^[0-9a-f]{16}$') `
            "ns='$afterRestart' ns2='$other'"
    } finally {
        Remove-Namespace $ns2
    }

    # ---------------------------------------------------------------------
    # An unknown namespace must report nothing rather than another's token.
    # ---------------------------------------------------------------------
    $unknown = Query "${ns}-never-existed" '#{server_instance}'
    Check "an unknown namespace reports no identity" `
        ([string]::IsNullOrWhiteSpace($unknown) -or $unknown -notmatch '^[0-9a-f]{16}$') `
        "got '$unknown'"

    # ---------------------------------------------------------------------
    # Steady state: the token must survive the server's periodic registry
    # re-ensure (every ~5s). A lone server with no warm helper sees no live
    # peers on every tick; a re-ensure that repeated the startup first-server
    # decision would re-mint the token every interval, signalling a restart
    # that never happened.
    # ---------------------------------------------------------------------
    $ns3 = "${ns}c"
    $prevNoWarm = $env:PSMUX_NO_WARM
    try {
        $env:PSMUX_NO_WARM = '1'
        & $exe -f NUL -L $ns3 new-session -d -s solo 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
        $observed = @()
        foreach ($i in 1..5) {
            $observed += Query $ns3 '#{server_instance}'
            Start-Sleep -Seconds 3
        }
        $distinctObserved = @($observed | Sort-Object -Unique)
        Check "a lone server's identity survives periodic re-ensure ticks" `
            ($distinctObserved.Count -eq 1 -and $observed[0] -match '^[0-9a-f]{16}$') `
            "polled over 12s, saw: $($observed -join ', ')"

        # Self-heal must not fake a restart: delete the token file while the
        # namespace is up; the next re-ensure restores the SAME identity.
        $steady = $observed[0]
        Remove-Item (Join-Path $psmuxDir "instances\$ns3*") -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 7
        $healed = Query $ns3 '#{server_instance}'
        Check "a lost token file is restored with the same identity" `
            ($healed -eq $steady) `
            "before='$steady' after='$healed'"
    } finally {
        $env:PSMUX_NO_WARM = $prevNoWarm
        Remove-Namespace $ns3
        Remove-Item (Join-Path $psmuxDir "instances\$ns3*") -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Namespace $ns
    Remove-Item (Join-Path $psmuxDir "instances\$ns*") -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures -gt 0) {
    Write-Host "issue #509: $failures of $checks checks FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "issue #509: all $checks checks passed" -ForegroundColor Green
exit 0
