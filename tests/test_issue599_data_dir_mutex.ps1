# Issue #599: the single-server name mutex ignored PSMUX_DATA_DIR, so two
# isolated registries could not both hold a session of the same name.
#
# PSMUX_DATA_DIR namespaces the registry (paths.rs roots every .port/.key/.sid/
# .pid under it, and ls/has-session honour it), but the guard that enforces one
# server per name is a MACHINE-WIDE kernel mutex named from the session base
# alone. Measured on 3.3.8, with a live 'X' in root ONE:
#
#   TWO_CREATE_SAME  rc=1 psmux: failed to create session 'dup-4576f600'
#
# and, because '__warm__' is a fixed name psmux chooses for itself, only the
# FIRST data root on the box ever published a warm server:
#
#   ONE warm published -> True
#   TWO warm published -> False
#
# The fix folds a tag derived from the RESOLVED data root into the mutex name,
# the way -L already reaches it through port_file_base(). tmux 3.4 is the
# parity reference: two -L namespaces hold the same session name concurrently.
#
# Everything here is headless: no attached client, no interactive terminal.
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

# Inherited session routing would aim these calls at an existing server.
$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null

$rigBase = Join-Path $env:TEMP ("psmux599-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$rootOne = Join-Path $rigBase 'one'
$rootTwo = Join-Path $rigBase 'two'
New-Item -ItemType Directory -Force -Path $rootOne, $rootTwo | Out-Null

function Run($root, $argv) {
    $env:PSMUX_DATA_DIR = $root
    $out = & $PSMUX @argv 2>&1
    $rc = $LASTEXITCODE
    $env:PSMUX_DATA_DIR = $null
    return @{ rc = $rc; out = (($out | Out-String) -replace '\s+', ' ').Trim() }
}

try {
    # === 1. Same session name, two data roots ===
    Write-Host "`n--- same name in two registries ---" -ForegroundColor Yellow
    $sname = 'dup-' + [guid]::NewGuid().ToString('N').Substring(0,8)

    $r = Run $rootOne @('new-session','-d','-s',$sname)
    if ($r.rc -eq 0) { Write-Pass "root ONE created '$sname'" }
    else { Write-Fail "root ONE could not create '$sname' (rc=$($r.rc) $($r.out))" }

    # Isolation must already hold: root TWO cannot SEE root ONE's session.
    $r = Run $rootTwo @('has-session','-t',$sname)
    if ($r.rc -ne 0) { Write-Pass "root TWO cannot see root ONE's session (registries are isolated)" }
    else { Write-Fail "root TWO saw root ONE's session, so the roots are not isolated at all" }

    # THE BUG: refused as a duplicate of a server it cannot see.
    $r = Run $rootTwo @('new-session','-d','-s',$sname)
    if ($r.rc -eq 0) { Write-Pass "root TWO created its own '$sname' alongside root ONE's" }
    else { Write-Fail "root TWO refused '$sname' (rc=$($r.rc)) '$($r.out)'" }

    # Both must be live and independent, not one server answering twice.
    $r = Run $rootOne @('has-session','-t',$sname)
    if ($r.rc -eq 0) { Write-Pass "root ONE's session survived root TWO's create" }
    else { Write-Fail "root ONE's session went away (rc=$($r.rc))" }
    $r = Run $rootTwo @('has-session','-t',$sname)
    if ($r.rc -eq 0) { Write-Pass "root TWO's session is live" }
    else { Write-Fail "root TWO reports no '$sname' after a successful create" }

    $portOne = Get-Content -LiteralPath (Join-Path $rootOne "$sname.port") -EA SilentlyContinue
    $portTwo = Get-Content -LiteralPath (Join-Path $rootTwo "$sname.port") -EA SilentlyContinue
    Write-Info "ports: ONE=$portOne TWO=$portTwo"
    if ($portOne -and $portTwo -and $portOne -ne $portTwo) {
        Write-Pass "two distinct servers (separate .port registrations)"
    } else {
        Write-Fail "expected two distinct .port values, got ONE=$portOne TWO=$portTwo"
    }

    # Isolating by root must not weaken the guard INSIDE a root: a second
    # cold-spawn of the same name in the SAME root is still refused.
    $r = Run $rootOne @('new-session','-d','-s',$sname)
    if ($r.rc -ne 0) { Write-Pass "a duplicate of '$sname' within root ONE is still refused" }
    else { Write-Fail "root ONE accepted a duplicate '$sname': the guard was weakened" }

    foreach ($root in @($rootOne, $rootTwo)) {
        $env:PSMUX_DATA_DIR = $root
        & $PSMUX kill-session -t $sname 2>&1 | Out-Null
        & $PSMUX kill-server 2>&1 | Out-Null
        $env:PSMUX_DATA_DIR = $null
    }
    Start-Sleep -Seconds 1

    # === 2. The warm server, with no name chosen by the caller ===
    Write-Host "`n--- __warm__ in two registries ---" -ForegroundColor Yellow
    $wRig = Join-Path $env:TEMP ("psmux599w-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $wOne = Join-Path $wRig 'one'; $wTwo = Join-Path $wRig 'two'
    New-Item -ItemType Directory -Force -Path $wOne, $wTwo | Out-Null

    Run $wOne @('new-session','-d','-s','w1') | Out-Null
    Start-Sleep -Seconds 3
    $warmOne = Test-Path -LiteralPath (Join-Path $wOne '__warm__.port')
    Run $wTwo @('new-session','-d','-s','w2') | Out-Null
    Start-Sleep -Seconds 3
    $warmTwo = Test-Path -LiteralPath (Join-Path $wTwo '__warm__.port')
    Write-Info "warm published: ONE=$warmOne TWO=$warmTwo"

    if ($warmOne) { Write-Pass "root ONE published __warm__" }
    else { Write-Fail "root ONE published no __warm__ at all (warm start regressed)" }
    if ($warmTwo) { Write-Pass "root TWO published its own __warm__" }
    else { Write-Fail "root TWO never published __warm__: the fixed name is still machine-wide" }

    if ($warmOne -and $warmTwo) {
        $wp1 = Get-Content -LiteralPath (Join-Path $wOne '__warm__.port') -EA SilentlyContinue
        $wp2 = Get-Content -LiteralPath (Join-Path $wTwo '__warm__.port') -EA SilentlyContinue
        if ($wp1 -and $wp2 -and $wp1 -ne $wp2) { Write-Pass "the two warm servers are distinct processes (ports $wp1 / $wp2)" }
        else { Write-Fail "warm ports collided: ONE=$wp1 TWO=$wp2" }
    }

    foreach ($root in @($wOne, $wTwo)) {
        $env:PSMUX_DATA_DIR = $root
        & $PSMUX kill-server 2>&1 | Out-Null
        $env:PSMUX_DATA_DIR = $null
    }
    Start-Sleep -Seconds 1
    Remove-Item -LiteralPath $wRig -Recurse -Force -EA SilentlyContinue

    # === 3. One registry, however it is spelled, is still one guard ===
    # Keying on the raw variable instead of the resolved root would split the
    # DEFAULT registry across two guard names and let two servers own one
    # name, which is exactly what the guard exists to prevent.
    Write-Host "`n--- one registry keeps one guard ---" -ForegroundColor Yellow
    $defaultRoot = "$env:USERPROFILE\.psmux"
    $sname2 = 'same-' + [guid]::NewGuid().ToString('N').Substring(0,8)

    $env:PSMUX_DATA_DIR = $null
    & $PSMUX new-session -d -s $sname2 2>&1 | Out-Null
    $rcPlain = $LASTEXITCODE
    if ($rcPlain -eq 0) {
        # Same directory, spelled explicitly and with a different case: the
        # duplicate must still be refused.
        $r = Run $defaultRoot.ToLower() @('new-session','-d','-s',$sname2)
        if ($r.rc -ne 0) { Write-Pass "explicit lower-case spelling of the default root still guards '$sname2'" }
        else { Write-Fail "a second server took '$sname2' in the same registry (rc=0): guard split by spelling" }
        & $PSMUX kill-session -t $sname2 2>&1 | Out-Null
    } else {
        Write-Fail "could not create '$sname2' in the default root (rc=$rcPlain)"
    }
}
finally {
    $env:PSMUX_DATA_DIR = $null
    Remove-Item -LiteralPath $rigBase -Recurse -Force -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
exit $script:Fail
