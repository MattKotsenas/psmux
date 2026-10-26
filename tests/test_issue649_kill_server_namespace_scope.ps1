# Issue #649: a bare `kill-server` ended every `-L` namespace, not just its own.
#
# psmux keeps every namespace in ONE registry directory: a `-L foo` session is
# `foo__name.port`, a default-namespace session is `name.port`. kill-server's
# target scan applied the namespace prefix only when `-L` was given ("Without
# -L: kill ALL sessions"), so one bare `psmux kill-server` -- or `tmux
# kill-server` through the compatibility alias -- walked every `.port` file in
# the data dir. Measured on the pre-fix build, three times running, with three
# namespaces in one isolated data dir:
#
#   BEFORE .port files: __warm__, nsA649____warm__, nsA649__sA,
#                       nsB649____warm__, nsB649__sB, sDef649
#   kill-server rc=0
#   AFTER  .port files: (none)
#   ls -L nsA649 -> rc 1 'no server running'
#
# tmux kills the server on its selected socket and nothing else, so the parity
# rule is: bare kill-server covers the default namespace, `-L X` covers X, and
# the psmux-only `-a`/`--all` keeps the machine-wide sweep.
#
# What this suite pins:
#   * bare kill-server ends the default namespace and leaves every other one
#     running (processes and registry files both)
#   * -L X ends X and nothing else
#   * -a still ends everything, in every namespace
#   * the `tmux` alias behaves exactly like `psmux`
#   * nothing to kill exits 1 with tmux's `no server running on <socket>`,
#     and an unknown option is refused
#   * with a REAL attached Win32 client on a default-namespace session, a bare
#     kill-server takes that client's window down and leaves the other
#     namespace answering `display-message`
#
# Every server started here lives in an isolated PSMUX_DATA_DIR and every
# namespace name contains 649, so nothing outside this rig is reachable.
#
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN }
         else { (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Get-Command psmux -EA SilentlyContinue).Source }
if (-not $PSMUX) { Write-Host "FATAL: psmux binary not found" -ForegroundColor Red; exit 1 }
$TMUX_ALIAS = Join-Path (Split-Path $PSMUX) 'tmux.exe'

$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

# Inherited session routing would aim these calls at somebody else's server.
$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_TARGET_SESSION = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null

$rig  = Join-Path $env:TEMP ("psmux649-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$root = Join-Path $rig 'data'
New-Item -ItemType Directory -Force -Path $rig, $root | Out-Null
$env:PSMUX_DATA_DIR = $root

$nsA = 'i649nsA'
$nsB = 'i649nsB'
$sDef = 'i649def'
$sA   = 'i649sa'
$sB   = 'i649sb'

$script:ClientProcs = @()

function Run($argv) {
    $out = & $PSMUX @argv 2>&1
    $rc = $LASTEXITCODE
    return @{ rc = $rc; out = ((($out | Out-String) -replace '\s+', ' ').Trim()) }
}
function RunAlias($argv) {
    $out = & $TMUX_ALIAS @argv 2>&1
    $rc = $LASTEXITCODE
    return @{ rc = $rc; out = ((($out | Out-String) -replace '\s+', ' ').Trim()) }
}
function PortNames() {
    (Get-ChildItem (Join-Path $root '*.port') -EA SilentlyContinue | ForEach-Object { $_.BaseName }) | Sort-Object
}
function ServerPid($base) {
    $p = Join-Path $root "$base.pid"
    try { $raw = (Get-Content -LiteralPath $p -Raw -EA Stop).Trim() } catch { return $null }
    $n = ($raw -split ':')[0]
    if ($n -match '^\d+$') { return [int]$n }
    return $null
}
function Is-Alive($procId) {
    if ($null -eq $procId) { return $false }
    return $null -ne (Get-Process -Id $procId -EA SilentlyContinue)
}
function Wait-Exit($procId, $ms) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if (-not (Is-Alive $procId)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return -not (Is-Alive $procId)
}
# Every server in the rig, killed by the pid the rig's OWN registry recorded.
function Clear-Rig {
    Get-ChildItem (Join-Path $root '*.pid') -EA SilentlyContinue | ForEach-Object {
        $raw = (Get-Content -LiteralPath $_.FullName -Raw -EA SilentlyContinue)
        if ($raw) {
            $n = ($raw.Trim() -split ':')[0]
            if ($n -match '^\d+$') { try { Stop-Process -Id ([int]$n) -Force -EA Stop } catch {} }
        }
    }
    Start-Sleep -Milliseconds 300
    Get-ChildItem $root -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue
}
# Three namespaces in one data dir: the exact shape #649 was reported on.
function Setup-Three {
    $r = Run @('-L',$nsA,'new-session','-d','-s',$sA)
    if ($r.rc -ne 0) { Write-Fail "could not create -L $nsA $sA (rc=$($r.rc)) '$($r.out)'"; return $false }
    $r = Run @('-L',$nsB,'new-session','-d','-s',$sB)
    if ($r.rc -ne 0) { Write-Fail "could not create -L $nsB $sB (rc=$($r.rc)) '$($r.out)'"; return $false }
    $r = Run @('new-session','-d','-s',$sDef)
    if ($r.rc -ne 0) { Write-Fail "could not create default $sDef (rc=$($r.rc)) '$($r.out)'"; return $false }
    Start-Sleep -Seconds 2
    return $true
}

try {
    # === 1. A bare kill-server is scoped to the default namespace ============
    Write-Host "`n--- bare kill-server: the default namespace only ---" -ForegroundColor Yellow
    if (Setup-Three) {
        $pidA = ServerPid "${nsA}__$sA"
        $pidB = ServerPid "${nsB}__$sB"
        $pidD = ServerPid $sDef
        Write-Info "pids: $nsA=$pidA $nsB=$pidB default=$pidD"

        $r = Run @('kill-server')
        Start-Sleep -Seconds 2
        if ($r.rc -eq 0) { Write-Pass "bare kill-server with a session to kill exits 0" }
        else { Write-Fail "expected exit 0, got $($r.rc) '$($r.out)'" }

        $r = Run @('ls')
        if ($r.rc -eq 1) { Write-Pass "the default namespace is gone" }
        else { Write-Fail "the default namespace survived its own kill-server (rc=$($r.rc)) '$($r.out)'" }

        $r = Run @('-L',$nsA,'ls')
        if ($r.rc -eq 0 -and $r.out -match [regex]::Escape($sA)) {
            Write-Pass "-L $nsA still lists $sA after a bare kill-server"
        } else { Write-Fail "-L $nsA lost its session to a bare kill-server (rc=$($r.rc)) '$($r.out)'" }

        $r = Run @('-L',$nsB,'ls')
        if ($r.rc -eq 0 -and $r.out -match [regex]::Escape($sB)) {
            Write-Pass "-L $nsB still lists $sB after a bare kill-server"
        } else { Write-Fail "-L $nsB lost its session to a bare kill-server (rc=$($r.rc)) '$($r.out)'" }

        if (Is-Alive $pidA) { Write-Pass "the $nsA server process is still running" }
        else { Write-Fail "the $nsA server process ($pidA) was terminated" }
        if (Is-Alive $pidB) { Write-Pass "the $nsB server process is still running" }
        else { Write-Fail "the $nsB server process ($pidB) was terminated" }
        if (-not (Is-Alive $pidD)) { Write-Pass "the default namespace's server process did exit" }
        else { Write-Fail "the default namespace's server ($pidD) survived" }

        $ports = PortNames
        if ($ports -contains "${nsA}__$sA" -and $ports -contains "${nsB}__$sB") {
            Write-Pass "both namespaces keep their .port registrations"
        } else { Write-Fail "registry files were swept across namespaces: $($ports -join ', ')" }
        if ($ports -notcontains $sDef) { Write-Pass "the default namespace's .port was removed" }
        else { Write-Fail "the default namespace's .port survived" }

        # === 2. With nothing but other namespaces left, it is `no server` ===
        Write-Host "`n--- nothing in scope: tmux's exit 1 ---" -ForegroundColor Yellow
        $r = Run @('kill-server')
        if ($r.rc -eq 1) { Write-Pass "a second bare kill-server exits 1 (nothing left in scope)" }
        else { Write-Fail "expected exit 1, got $($r.rc) '$($r.out)'" }
        if ($r.out -match 'no server running') { Write-Pass "it says 'no server running', as tmux does" }
        else { Write-Fail "expected a 'no server running' message, got '$($r.out)'" }
        $r = Run @('-L',$nsA,'ls')
        if ($r.rc -eq 0) { Write-Pass "the refused kill-server still touched nothing in $nsA" }
        else { Write-Fail "$nsA died to a kill-server that reported nothing to kill" }
    }
    Clear-Rig

    # === 3. -L kills exactly one namespace ==================================
    Write-Host "`n--- -L X kills only X ---" -ForegroundColor Yellow
    if (Setup-Three) {
        $r = Run @('-L',$nsA,'kill-server')
        Start-Sleep -Seconds 2
        if ($r.rc -eq 0) { Write-Pass "-L $nsA kill-server exits 0" }
        else { Write-Fail "expected exit 0, got $($r.rc) '$($r.out)'" }

        $r = Run @('-L',$nsA,'ls')
        if ($r.rc -eq 1) { Write-Pass "$nsA is gone" } else { Write-Fail "$nsA survived its own kill-server" }
        $r = Run @('-L',$nsB,'ls')
        if ($r.rc -eq 0 -and $r.out -match [regex]::Escape($sB)) { Write-Pass "$nsB is untouched" }
        else { Write-Fail "$nsB was killed by -L $nsA (rc=$($r.rc)) '$($r.out)'" }
        $r = Run @('ls')
        if ($r.rc -eq 0 -and $r.out -match [regex]::Escape($sDef)) { Write-Pass "the default namespace is untouched" }
        else { Write-Fail "the default namespace was killed by -L $nsA (rc=$($r.rc)) '$($r.out)'" }

        # === 4. -a is the everything sweep ==================================
        Write-Host "`n--- -a sweeps every namespace ---" -ForegroundColor Yellow
        $pidB = ServerPid "${nsB}__$sB"
        $pidD = ServerPid $sDef
        $r = Run @('kill-server','-a')
        Start-Sleep -Seconds 2
        if ($r.rc -eq 0) { Write-Pass "kill-server -a exits 0" }
        else { Write-Fail "expected exit 0, got $($r.rc) '$($r.out)'" }
        $r = Run @('-L',$nsB,'ls')
        if ($r.rc -eq 1) { Write-Pass "-a reached $nsB" } else { Write-Fail "-a left $nsB running" }
        $r = Run @('ls')
        if ($r.rc -eq 1) { Write-Pass "-a reached the default namespace" }
        else { Write-Fail "-a left the default namespace running" }
        if (-not (Is-Alive $pidB)) { Write-Pass "the $nsB server process is gone" }
        else { Write-Fail "the $nsB server process ($pidB) survived -a" }
        if (-not (Is-Alive $pidD)) { Write-Pass "the default server process is gone" }
        else { Write-Fail "the default server process ($pidD) survived -a" }
        $leftover = @(PortNames)
        if ($leftover.Count -eq 0) { Write-Pass "-a left no registry entries behind" }
        else { Write-Fail "-a left registry entries: $($leftover -join ', ')" }
    }
    Clear-Rig

    # === 5. --all is accepted as the long form ==============================
    Write-Host "`n--- --all is the long form of -a ---" -ForegroundColor Yellow
    if (Setup-Three) {
        $r = Run @('kill-server','--all')
        Start-Sleep -Seconds 2
        if ($r.rc -eq 0) { Write-Pass "kill-server --all exits 0" }
        else { Write-Fail "expected exit 0, got $($r.rc) '$($r.out)'" }
        $a = Run @('-L',$nsA,'ls'); $b = Run @('-L',$nsB,'ls'); $d = Run @('ls')
        if ($a.rc -eq 1 -and $b.rc -eq 1 -and $d.rc -eq 1) { Write-Pass "--all swept all three namespaces" }
        else { Write-Fail "--all missed one: nsA=$($a.rc) nsB=$($b.rc) default=$($d.rc)" }
    }
    Clear-Rig

    # === 6. The tmux alias behaves the same ================================
    Write-Host "`n--- the tmux alias is scoped identically ---" -ForegroundColor Yellow
    if (-not (Test-Path $TMUX_ALIAS)) {
        Write-Info "tmux alias not built next to psmux ($TMUX_ALIAS); skipping alias checks"
    } elseif (Setup-Three) {
        $r = RunAlias @('kill-server')
        Start-Sleep -Seconds 2
        if ($r.rc -eq 0) { Write-Pass "tmux kill-server exits 0 with a session in scope" }
        else { Write-Fail "expected exit 0, got $($r.rc) '$($r.out)'" }
        $r = RunAlias @('ls')
        if ($r.rc -eq 1) { Write-Pass "tmux kill-server ended the default namespace" }
        else { Write-Fail "the default namespace survived tmux kill-server" }
        $r = RunAlias @('-L',$nsA,'ls')
        if ($r.rc -eq 0 -and $r.out -match [regex]::Escape($sA)) {
            Write-Pass "tmux kill-server left $nsA alone (the drop-in has tmux's blast radius)"
        } else { Write-Fail "tmux kill-server killed $nsA (rc=$($r.rc)) '$($r.out)'" }
        $r = RunAlias @('-L',$nsB,'ls')
        if ($r.rc -eq 0) { Write-Pass "tmux kill-server left $nsB alone" }
        else { Write-Fail "tmux kill-server killed $nsB" }
        $r = RunAlias @('kill-server','-a')
        Start-Sleep -Seconds 2
        $a = Run @('-L',$nsA,'ls'); $b = Run @('-L',$nsB,'ls')
        if ($a.rc -eq 1 -and $b.rc -eq 1) { Write-Pass "tmux kill-server -a sweeps every namespace" }
        else { Write-Fail "tmux -a missed one: nsA=$($a.rc) nsB=$($b.rc)" }
    }
    Clear-Rig

    # === 7. Nothing running at all, and a bad option ========================
    Write-Host "`n--- an empty data dir, and an unknown option ---" -ForegroundColor Yellow
    $r = Run @('kill-server')
    if ($r.rc -eq 1) { Write-Pass "bare kill-server with no server exits 1" }
    else { Write-Fail "expected exit 1, got $($r.rc) '$($r.out)'" }
    if ($r.out -match 'no server running on') { Write-Pass "and prints tmux's 'no server running on <socket>'" }
    else { Write-Fail "expected 'no server running on ...', got '$($r.out)'" }

    $r = Run @('-L','i649ghost','kill-server')
    if ($r.rc -eq 1 -and $r.out -match 'i649ghost') {
        Write-Pass "-L on an empty namespace exits 1 and names the socket"
    } else { Write-Fail "expected exit 1 naming the namespace, got $($r.rc) '$($r.out)'" }

    $r = Run @('kill-server','-a')
    if ($r.rc -eq 0) { Write-Pass "kill-server -a on an empty data dir is a no-op at exit 0" }
    else { Write-Fail "expected exit 0 for -a with nothing to do, got $($r.rc) '$($r.out)'" }

    $r = Run @('kill-server','-Z')
    if ($r.rc -eq 1 -and $r.out -match 'unknown option') { Write-Pass "an unknown option is refused" }
    else { Write-Fail "expected exit 1 'unknown option', got $($r.rc) '$($r.out)'" }

    # === 8. A REAL attached Win32 client ====================================
    Write-Host "`n--- an attached client window, killed only in its own namespace ---" -ForegroundColor Yellow
    $tuiSess = 'i649tui'
    $r = Run @('new-session','-d','-s',$tuiSess)
    $r2 = Run @('-L',$nsA,'new-session','-d','-s',$sA)
    Start-Sleep -Seconds 2
    if ($r.rc -eq 0 -and $r2.rc -eq 0) {
        # A real client in its own console window, attached to the default
        # namespace's session.
        $client = Start-Process -FilePath $PSMUX -ArgumentList 'attach','-t',$tuiSess -PassThru
        $script:ClientProcs += $client.Id
        Start-Sleep -Seconds 3

        $r = Run @('display-message','-p','-t',$tuiSess,'#{session_name}|#{session_attached}')
        Write-Info "display-message before: '$($r.out)'"
        if ($r.rc -eq 0 -and $r.out -match "^$tuiSess\|[1-9]") {
            Write-Pass "the Win32 client really is attached (display-message reports session_attached >= 1)"
        } else { Write-Fail "no attached client to test with: rc=$($r.rc) '$($r.out)'" }

        $r = Run @('kill-server')
        Start-Sleep -Seconds 2
        if ($r.rc -eq 0) { Write-Pass "bare kill-server with an attached client exits 0" }
        else { Write-Fail "expected exit 0, got $($r.rc) '$($r.out)'" }
        if (Wait-Exit $client.Id 8000) { Write-Pass "the attached client window exited with its server" }
        else { Write-Fail "the client process $($client.Id) is still running" }

        $r = Run @('-L',$nsA,'display-message','-p','-t',$sA,'#{session_name}')
        Write-Info "display-message after (other namespace): rc=$($r.rc) '$($r.out)'"
        if ($r.rc -eq 0 -and $r.out -match [regex]::Escape($sA)) {
            Write-Pass "the other namespace's session still answers display-message"
        } else { Write-Fail "$nsA stopped answering after a bare kill-server (rc=$($r.rc)) '$($r.out)'" }
    } else {
        Write-Fail "could not set up the attached-client case (rc=$($r.rc)/$($r2.rc))"
    }
}
catch { Write-Info "aborted: $_" }
finally {
    foreach ($id in $script:ClientProcs) {
        if (Is-Alive $id) { try { Stop-Process -Id $id -Force -EA Stop } catch {} }
    }
    Clear-Rig
    $env:PSMUX_DATA_DIR = $null
    Remove-Item -LiteralPath $rig -Recurse -Force -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
exit $script:Fail
