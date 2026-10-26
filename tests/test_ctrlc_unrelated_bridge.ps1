# An unrelated VT bridge must not break Ctrl+C in a plain shell pane.
#
# Regression class (reproduced, then fixed):
#   send_ctrl_c_event's issue #579 boot-window guard read
#       foreground_fell_back_to_root(pid) && any_vt_bridge_running()
#   The second half was SYSTEM-WIDE and unbounded, so a wsl.exe the user had
#   left open in an unrelated window for days satisfied it forever.  The first
#   half is true for an ordinary idle pane as well: a pwsh blocked inside a
#   builtin such as `Start-Sleep` has NO child process, so the pane shell looks
#   childless.  Both halves true, the router stripped ENABLE_PROCESSED_INPUT
#   (measured console mode 0x01F7), delivered only the raw 0x03 - which pwsh
#   ignores mid-cmdlet - and skipped the CTRL_C_EVENT that would actually have
#   cancelled it.  `send-keys C-c` silently stopped interrupting anything in
#   every shell pane on any machine with WSL running.
#
#   Fix: bound the system-wide check by process CREATION TIME.  Only a bridge
#   started inside the cold-boot window (the state in which no pane-scoped
#   attribution can see it) suppresses the broadcast.
#
# The bridge here is synthetic on purpose: a copy of ping.exe named wsl.exe.
# The router classifies bridges by IMAGE NAME, so this exercises the exact
# code path with no WSL distro required, and it is owned by this script so it
# can be killed by PID and never touches a real WSL session.
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$env:PSMUX_NO_WARM = "1"
$SOCK = "ccbridge"
$script:Bridges = @()

# The router's boot window (src/platform.rs BRIDGE_BOOT_WINDOW) is 10s.
$BootWindowSec = 10

$BridgeDir = Join-Path $env:TEMP "psmux_ctrlc_bridge_$PID"
New-Item -ItemType Directory -Force $BridgeDir | Out-Null
$BridgeExe = Join-Path $BridgeDir "wsl.exe"
Copy-Item "$env:WINDIR\System32\PING.EXE" $BridgeExe -Force -EA SilentlyContinue
if (-not (Test-Path $BridgeExe)) {
    Write-Host "SKIP: could not stage a synthetic bridge executable" -ForegroundColor Yellow
    exit 0
}

function Start-Bridge {
    # Long-lived, detached from any pane console, parented by this script -
    # never a descendant of a psmux pane, so only the SYSTEM-WIDE check can
    # ever see it.  That is precisely the check under test.
    $p = Start-Process -FilePath $BridgeExe -ArgumentList "-t","127.0.0.1" `
         -WindowStyle Hidden -PassThru
    $script:Bridges += $p.Id
    return $p
}
function Stop-Bridges {
    foreach ($id in $script:Bridges) { Stop-Process -Id $id -Force -EA SilentlyContinue }
    $script:Bridges = @()
}

function New-Pane([string]$S) {
    & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & $PSMUX -L $SOCK new-session -d -s $S 2>&1 | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 400
        & $PSMUX -L $SOCK send-keys -t $S "echo PANE_READY_$S" Enter 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        $c = & $PSMUX -L $SOCK capture-pane -t $S -p 2>&1 | Out-String
        if ($c -match "PANE_READY_$S") { return $true }
    }
    return $false
}
function Remove-Pane([string]$S) { & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null }

Write-Host "`n=== Ctrl+C vs an unrelated VT bridge ===" -ForegroundColor Cyan

try {

# --- Arm 1: a STALE unrelated bridge must not suppress the interrupt. ---
Write-Host "[Arm 1] stale unrelated bridge, C-c must cancel Start-Sleep" -ForegroundColor Yellow
$stale = Start-Bridge
Start-Sleep -Seconds ($BootWindowSec + 3)   # age it past the boot window
$age = [int]((Get-Date) - (Get-CimInstance Win32_Process -Filter "ProcessId=$($stale.Id)").CreationDate).TotalSeconds
Write-Host "  synthetic bridge pid=$($stale.Id) age=${age}s (window=${BootWindowSec}s)"

if (-not (New-Pane "iCCa1")) {
    Write-Fail "pane never reached a prompt"
} else {
    & $PSMUX -L $SOCK send-keys -t "iCCa1" "Start-Sleep 30" Enter
    Start-Sleep -Seconds 3
    & $PSMUX -L $SOCK send-keys -t "iCCa1" C-c
    Start-Sleep -Seconds 2
    & $PSMUX -L $SOCK send-keys -t "iCCa1" "echo CC_CANCELLED" Enter
    Start-Sleep -Seconds 4
    $cap = & $PSMUX -L $SOCK capture-pane -t "iCCa1" -p 2>&1 | Out-String
    if ($cap -match "CC_CANCELLED") {
        Write-Pass "Start-Sleep interrupted while an unrelated bridge (age ${age}s) was alive"
    } else {
        Write-Fail "pane stayed blocked - the boot-window guard fired for a stale bridge"
        Write-Host $cap
    }
}
Remove-Pane "iCCa1"
Stop-Bridges

# --- Arm 2: a FRESHLY started bridge must STILL be guarded (issue #579). ---
# Same pane shape, same childless-fallback state; only the bridge's age
# differs.  The guard must engage and the broadcast must be skipped, which is
# observable as the interrupt NOT landing.  Losing this arm means a mid-boot
# Ctrl+C would once again kill a booting WSL session.
Write-Host "[Arm 2] freshly started bridge, boot-window guard still engages" -ForegroundColor Yellow
if (-not (New-Pane "iCCa2")) {
    Write-Fail "pane never reached a prompt"
} else {
    & $PSMUX -L $SOCK send-keys -t "iCCa2" "Start-Sleep 30" Enter
    Start-Sleep -Seconds 3
    $fresh = Start-Bridge                       # bridge is now ~0s old
    Start-Sleep -Milliseconds 700
    & $PSMUX -L $SOCK send-keys -t "iCCa2" C-c
    Start-Sleep -Seconds 2
    & $PSMUX -L $SOCK send-keys -t "iCCa2" "echo CC_CANCELLED_2" Enter
    Start-Sleep -Seconds 4
    $cap = & $PSMUX -L $SOCK capture-pane -t "iCCa2" -p 2>&1 | Out-String
    if ($cap -match "CC_CANCELLED_2") {
        Write-Fail "guard did NOT engage for a bridge started 0.7s ago - #579 boot kill is back"
    } else {
        Write-Pass "boot-window guard still skips the broadcast for a just-started bridge"
    }
}
Remove-Pane "iCCa2"
Stop-Bridges

# --- Arm 3: with the fresh bridge gone, the same pane interrupts again. ---
# Proves the suppression in Arm 2 was attributable to the bridge's age and
# nothing else about the pane.
Write-Host "[Arm 3] bridge gone, the same shape interrupts again" -ForegroundColor Yellow
if (-not (New-Pane "iCCa3")) {
    Write-Fail "pane never reached a prompt"
} else {
    & $PSMUX -L $SOCK send-keys -t "iCCa3" "Start-Sleep 30" Enter
    Start-Sleep -Seconds 3
    & $PSMUX -L $SOCK send-keys -t "iCCa3" C-c
    Start-Sleep -Seconds 2
    & $PSMUX -L $SOCK send-keys -t "iCCa3" "echo CC_CANCELLED_3" Enter
    Start-Sleep -Seconds 4
    $cap = & $PSMUX -L $SOCK capture-pane -t "iCCa3" -p 2>&1 | Out-String
    if ($cap -match "CC_CANCELLED_3") { Write-Pass "interrupt works with no fresh bridge alive" }
    else { Write-Fail "interrupt failed with no fresh bridge alive"; Write-Host $cap }
}
Remove-Pane "iCCa3"

}
finally {
    Stop-Bridges
    foreach ($s in "iCCa1","iCCa2","iCCa3") { & $PSMUX -L $SOCK kill-session -t $s 2>&1 | Out-Null }
    Remove-Item -Recurse -Force $BridgeDir -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
