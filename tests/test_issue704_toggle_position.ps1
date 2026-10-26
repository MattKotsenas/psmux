# Issue #704: the copy mode position indicator could not be hidden. There was
# no `toggle-position` command, `P` was not bound to anything, and
# `copy-mode -H` was parsed and then dropped.
#
# Measured on master `f31103e` before the fix, a 100x30 attached client with
# `1..200` in the pane, reading the real console screen:
#
#     entered copy mode                [0/173]
#     send-keys -X toggle-position     [0/173]   exit 0, no output
#     P, bound by hand to that verb    [0/173]
#     P with no binding                [0/173]
#     copy-mode -H on a fresh entry    [0/173]
#
# and after it the indicator goes on the first press of either route.
#
# capture-pane cannot see any of this: the indicator is drawn by the client
# around the pane, not by the shell inside it, so the oracle is the real
# console screen buffer of the attached client (tests/conread.cs).
#
# The last check is about how fast the change reaches the screen. A copy mode
# command that moves the view rides out on the frame the move produces, but
# this one changes nothing the pane or the layout can see, so the server has to
# ask for a frame (tmux says this by returning WINDOW_COPY_CMD_REDRAW). Without
# that, measured on this rig, the indicator took 2629ms and 3775ms to go and
# once was still there after ten seconds, while a scroll key took 349ms.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i704tp" }
$SESSION = "i704_s"
$COLS = 100
$ROWS = 30

$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

$repoTests = Split-Path -Parent $MyInvocation.MyCommand.Path
# A shell running inside psmux hands its child the session markers, and a
# nested client refuses to start, so clear them before launching one.
foreach ($v in 'PSMUX_SESSION','PSMUX_TARGET_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') {
    Remove-Item "env:$v" -EA SilentlyContinue
}
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$root = Join-Path $env:TEMP "psmux_i704_tp"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

Write-Host ""
Write-Host "=== Issue #704: hiding the copy mode position indicator ===" -ForegroundColor Magenta
Write-Info "Binary: $PSMUX"
Write-Info "Namespace: $NS   data: $($env:PSMUX_DATA_DIR)"

function Invoke-Psmux([string[]]$psmuxArgs) { & $PSMUX -L $NS @psmuxArgs 2>&1 }
function Stop-Srv { & $PSMUX -L $NS kill-server 2>&1 | Out-Null; Start-Sleep -Milliseconds 400 }

function Exit-Test([int]$code) {
    Stop-Srv
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
    if ($null -ne $savedDataDir) { $env:PSMUX_DATA_DIR = $savedDataDir } else { Remove-Item env:PSMUX_DATA_DIR -EA SilentlyContinue }
    if ($null -ne $savedNoWarm)  { $env:PSMUX_NO_WARM  = $savedNoWarm }  else { Remove-Item env:PSMUX_NO_WARM  -EA SilentlyContinue }
    exit $code
}

# --- the screen oracle and the key injector --------------------------------
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$CONREAD = Join-Path $root "conread.exe"
$INJ = Join-Path $root "injector.exe"
if (Test-Path $csc) {
    & $csc /nologo /optimize /out:$CONREAD (Join-Path $repoTests "conread.cs") 2>&1 | Out-Null
    & $csc /nologo /optimize /out:$INJ (Join-Path $repoTests "injector.cs") 2>&1 | Out-Null
}
if (-not (Test-Path $CONREAD)) {
    Write-Skip "conread.exe could not be built, so the drawn screen cannot be read"
    Exit-Test 0
}

Stop-Srv
$proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"new-session","-s",$SESSION,"-x","$COLS","-y","$ROWS" -PassThru
Start-Sleep -Seconds 5
if ($proc.HasExited) {
    Write-Skip "the client exited before it attached, so there is no screen to read"
    Exit-Test 0
}

Invoke-Psmux @('set-option','-g','copy-mode-line-numbers','off') | Out-Null
# The speed check below scrolls with K, which only the vi table binds. Set it
# here so the check runs on a default config instead of being skipped.
Invoke-Psmux @('set-option','-g','mode-keys','vi') | Out-Null
Invoke-Psmux @('send-keys','-t',$SESSION,'1..200 | ForEach-Object { "line$_" }','Enter') | Out-Null
Start-Sleep -Seconds 3

function Get-Screen { (& $CONREAD $proc.Id 2>&1 | Out-String) }
function Get-Indicator {
    $m = [regex]::Match((Get-Screen), '\[\d+/\d+\]')
    if ($m.Success) { return $m.Value }
    return ""
}
function Get-TopRow { $s = (Get-Screen) -split "`n"; if ($s.Count -gt 0) { return $s[0].TrimEnd() }; return "" }
function Get-InMode { ((Invoke-Psmux @('display-message','-t',$SESSION,'-p','#{pane_in_mode}')) | Out-String).Trim() }

# --- 1. the -X verb --------------------------------------------------------
Write-Host ""
Write-Host "--- send-keys -X toggle-position ---" -ForegroundColor Yellow
Invoke-Psmux @('copy-mode','-t',$SESSION) | Out-Null
Start-Sleep -Seconds 2
$ind = Get-Indicator
Write-Info "entered copy mode, indicator='$ind'"
if ($ind -ne "") { Write-Pass "the indicator is there to begin with" }
else { Write-Fail "no indicator to hide; the rest of this file cannot run" }

$seen = @()
foreach ($i in 1, 2, 3, 4) {
    Invoke-Psmux @('send-keys','-t',$SESSION,'-X','toggle-position') | Out-Null
    Start-Sleep -Milliseconds 1200
    $seen += (Get-Indicator)
}
Write-Info "after four presses: $($seen | ForEach-Object { if ($_ -eq '') { '(hidden)' } else { $_ } })"
if ($seen[0] -eq "" -and $seen[1] -ne "" -and $seen[2] -eq "" -and $seen[3] -ne "") {
    Write-Pass "-X toggle-position alternates, starting by hiding (#704 did nothing)"
} else {
    Write-Fail "-X toggle-position did not alternate"
}
if ((Get-InMode) -eq "1") { Write-Pass "copy mode is still open" } else { Write-Fail "copy mode was left" }

# --- 2. the P key ----------------------------------------------------------
Write-Host ""
Write-Host "--- the P key, with no binding in the way ---" -ForegroundColor Yellow
if (-not (Test-Path $INJ)) {
    Write-Skip "the key injector could not be built"
} else {
    # The first injected key can be lost before the window takes focus, so warm
    # up on a key that does nothing here.
    & $INJ $proc.Id "0" | Out-Null
    Start-Sleep -Milliseconds 900
    $before = Get-Indicator
    $seen = @()
    foreach ($i in 1, 2, 3) {
        & $INJ $proc.Id "P" | Out-Null
        Start-Sleep -Milliseconds 1200
        $seen += (Get-Indicator)
    }
    Write-Info "from '$before' then: $($seen | ForEach-Object { if ($_ -eq '') { '(hidden)' } else { $_ } })"
    $alternates = ($seen[0] -ne $before) -and ($seen[1] -eq $before) -and ($seen[2] -ne $before)
    if ($alternates) {
        Write-Pass "P toggles the indicator with no binding (#704 had P unbound)"
    } else {
        Write-Fail "P did not alternate"
    }
}

# --- 3. how fast it reaches the screen -------------------------------------
Write-Host ""
Write-Host "--- the change reaches the screen as fast as a scroll does ---" -ForegroundColor Yellow
if (-not (Test-Path $INJ)) {
    Write-Skip "the key injector could not be built"
} else {
    function Measure-KeyToScreen([string]$key, [scriptblock]$read) {
        $was = & $read
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $INJ $proc.Id $key | Out-Null
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 250
            if ((& $read) -ne $was) { $sw.Stop(); return $sw.ElapsedMilliseconds }
        }
        $sw.Stop()
        return -1
    }
    $scrollMs = Measure-KeyToScreen "K" { Get-TopRow }
    $toggleMs = Measure-KeyToScreen "P" { Get-Indicator }
    Write-Info "K (scrolls the view) ${scrollMs}ms, P (changes only the flag) ${toggleMs}ms"
    if ($scrollMs -lt 0) {
        Write-Skip "the scroll key never reached the screen on this host"
    } elseif ($toggleMs -lt 0) {
        Write-Fail "P never reached the screen within ten seconds"
    } elseif ($toggleMs -le ($scrollMs * 3 + 500)) {
        Write-Pass "P lands in ${toggleMs}ms against ${scrollMs}ms for a scroll"
    } else {
        Write-Fail "P took ${toggleMs}ms against ${scrollMs}ms for a scroll, so it is waiting for someone else's frame"
    }
}

# --- 4. copy-mode -H -------------------------------------------------------
Write-Host ""
Write-Host "--- copy-mode -H ---" -ForegroundColor Yellow
Invoke-Psmux @('send-keys','-t',$SESSION,'-X','cancel') | Out-Null
Start-Sleep -Milliseconds 1000
if ((Get-Indicator) -eq "") { Write-Pass "no indicator outside copy mode" }
else { Write-Fail "the indicator survived copy mode" }

Invoke-Psmux @('copy-mode','-H','-t',$SESSION) | Out-Null
Start-Sleep -Milliseconds 1500
$inMode = Get-InMode
$ind = Get-Indicator
Write-Info "copy-mode -H: in_mode=$inMode indicator='$ind'"
if ($inMode -eq "1" -and $ind -eq "") {
    Write-Pass "copy-mode -H enters copy mode with the indicator hidden (#704 showed it)"
} else {
    Write-Fail "copy-mode -H gave in_mode=$inMode indicator='$ind'"
}

# --- 5. a later entry shows it again ---------------------------------------
Write-Host ""
Write-Host "--- leaving and re-entering forgets the flag, as tmux does ---" -ForegroundColor Yellow
Invoke-Psmux @('send-keys','-t',$SESSION,'-X','cancel') | Out-Null
Start-Sleep -Milliseconds 1000
Invoke-Psmux @('copy-mode','-t',$SESSION) | Out-Null
Start-Sleep -Milliseconds 1500
$ind = Get-Indicator
if ($ind -ne "") {
    Write-Pass "a plain entry after a hidden one shows the indicator again ('$ind')"
} else {
    Write-Fail "the hidden flag survived into a new copy mode entry"
}

# --- 6. copy-mode again inside copy mode keeps the toggle ------------------
# tmux's window_pane_set_mode returns early for a pane already in copy mode, so
# window_copy_init does not run and neither a plain entry nor -H touches the
# flag (cmd-copy-mode.c).
Write-Host ""
Write-Host "--- copy-mode run again inside copy mode ---" -ForegroundColor Yellow
Invoke-Psmux @('send-keys','-t',$SESSION,'-X','toggle-position') | Out-Null
Start-Sleep -Milliseconds 1200
Invoke-Psmux @('copy-mode','-t',$SESSION) | Out-Null
Start-Sleep -Milliseconds 1200
$ind = Get-Indicator
if ($ind -eq "") { Write-Pass "a plain copy-mode inside copy mode keeps the indicator hidden" }
else { Write-Fail "a plain copy-mode inside copy mode brought the indicator back ('$ind')" }
Invoke-Psmux @('send-keys','-t',$SESSION,'-X','toggle-position') | Out-Null
Start-Sleep -Milliseconds 1200
Invoke-Psmux @('copy-mode','-H','-t',$SESSION) | Out-Null
Start-Sleep -Milliseconds 1200
$ind = Get-Indicator
if ($ind -ne "") { Write-Pass "copy-mode -H inside copy mode leaves a shown indicator alone ('$ind')" }
else { Write-Fail "copy-mode -H inside copy mode hid the indicator" }

# --- 7. -u and -H together -------------------------------------------------
Write-Host ""
Write-Host "--- copy-mode -u -H ---" -ForegroundColor Yellow
Invoke-Psmux @('send-keys','-t',$SESSION,'-X','cancel') | Out-Null
Start-Sleep -Milliseconds 1000
Invoke-Psmux @('copy-mode','-u','-H','-t',$SESSION) | Out-Null
Start-Sleep -Milliseconds 1500
$ind = Get-Indicator
$sp = ((Invoke-Psmux @('display-message','-t',$SESSION,'-p','#{scroll_position}')) | Out-String).Trim()
if ($ind -eq "" -and [int]$sp -gt 0) { Write-Pass "copy-mode -u -H pages up ($sp) with the indicator hidden" }
else { Write-Fail "copy-mode -u -H gave scroll_position=$sp indicator='$ind'" }

# --- 8. a key bound to copy-mode -H ----------------------------------------
# tmux's own DoubleClick1Pane and TripleClick1Pane bindings use copy-mode -H,
# so the flag has to survive the binding path, not just the CLI.
Write-Host ""
Write-Host "--- a key bound to copy-mode -H ---" -ForegroundColor Yellow
Invoke-Psmux @('send-keys','-t',$SESSION,'-X','cancel') | Out-Null
Start-Sleep -Milliseconds 1000
if (-not (Test-Path $INJ)) {
    Write-Skip "the key injector could not be built"
} else {
    Invoke-Psmux @('bind-key','-n','F5','copy-mode','-H') | Out-Null
    & $INJ $proc.Id "{F5}" | Out-Null
    Start-Sleep -Milliseconds 1500
    $inMode = Get-InMode
    $ind = Get-Indicator
    if ($inMode -eq "1" -and $ind -eq "") { Write-Pass "F5 bound to copy-mode -H enters with the indicator hidden" }
    else { Write-Fail "F5 bound to copy-mode -H gave in_mode=$inMode indicator='$ind'" }
    Invoke-Psmux @('unbind-key','-n','F5') | Out-Null
}

# --- 9. copy-mode -q -------------------------------------------------------
# tmux: `-q` runs window_pane_reset_mode_all and returns before any entry.
Write-Host ""
Write-Host "--- copy-mode -q ---" -ForegroundColor Yellow
Invoke-Psmux @('copy-mode','-t',$SESSION) | Out-Null
Start-Sleep -Milliseconds 1000
Invoke-Psmux @('copy-mode','-q','-t',$SESSION) | Out-Null
Start-Sleep -Milliseconds 1200
$inMode = Get-InMode
if ($inMode -eq "0" -and (Get-Indicator) -eq "") { Write-Pass "copy-mode -q leaves copy mode" }
else { Write-Fail "copy-mode -q left in_mode=$inMode" }
Invoke-Psmux @('copy-mode','-q','-t',$SESSION) | Out-Null
Start-Sleep -Milliseconds 1200
$inMode = Get-InMode
if ($inMode -eq "0") { Write-Pass "copy-mode -q outside copy mode does not enter it" }
else { Write-Fail "copy-mode -q outside copy mode entered it" }

Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Magenta
Write-Host "  Passed:  $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed:  $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped: $script:TestsSkipped" -ForegroundColor Yellow
Exit-Test $(if ($script:TestsFailed -gt 0) { 1 } else { 0 })
