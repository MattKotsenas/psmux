# Issue #553: set-option -U SETS the option instead of unsetting it (opposite
# of tmux). CLI treats -U as unset (clears the empty-value guard), server
# treats it as a plain set. Unknown flags (-Z) are also silently accepted on
# set-option and show-options.
# tmux 3.4: -U unsets (trailing value ignored); unknown flag -> rc=1
# "command set-option: unknown flag -Z", nothing written.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "t553"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #553 repro ===" -ForegroundColor Cyan

& $PSMUX new-session -d -s $S -- pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 3
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "setup: session not created"; exit 1 }

function Get-Opt([string]$Name) {
    (& $PSMUX show-options -qv -t $S $Name 2>&1 | Out-String).Trim()
}

# --- Baseline set works ---
& $PSMUX set-option -t $S '@uu' KEEP 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$v = Get-Opt '@uu'
if ($v -eq "KEEP") { Write-Pass "baseline: set @uu KEEP round-trips" }
else { Write-Fail "baseline: expected KEEP got [$v]" }

# --- 1: set -U with no value must UNSET ---
& $PSMUX set-option -U -t $S '@uu' 2>&1 | Out-Null
$rc1 = $LASTEXITCODE
Start-Sleep -Milliseconds 300
$v = Get-Opt '@uu'
if ($rc1 -eq 0 -and $v -eq "") { Write-Pass "set -U @uu unsets (rc=0, empty)" }
else { Write-Fail "BUG: set -U @uu rc=$rc1 read=[$v] (expected empty)" }

# --- 2: set -U with a trailing value must still UNSET (value ignored) ---
& $PSMUX set-option -t $S '@uu' KEEP 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX set-option -U -t $S '@uu' XX 2>&1 | Out-Null
$rc2 = $LASTEXITCODE
Start-Sleep -Milliseconds 300
$v = Get-Opt '@uu'
if ($rc2 -eq 0 -and $v -eq "") { Write-Pass "set -U @uu XX unsets, value ignored (rc=0, empty)" }
elseif ($v -eq "XX") { Write-Fail "BUG: set -U @uu XX SET the value to XX (asked to unset)" }
else { Write-Fail "set -U @uu XX rc=$rc2 read=[$v]" }

# --- 3: control - lowercase -u works ---
& $PSMUX set-option -t $S '@vv' V1 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX set-option -u -t $S '@vv' 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$v = Get-Opt '@vv'
if ($v -eq "") { Write-Pass "control: set -u @vv unsets correctly" }
else { Write-Fail "control: set -u @vv read=[$v]" }

# --- 4: unknown flag on set-option must be rejected, nothing written ---
$out = & $PSMUX set-option -Z -t $S '@zz' Z 2>&1
$rc4 = $LASTEXITCODE
Start-Sleep -Milliseconds 300
$v = Get-Opt '@zz'
if ($rc4 -ne 0 -and $v -eq "") { Write-Pass "set-option -Z rejected (rc=$rc4, nothing written): $out" }
elseif ($v -eq "Z") { Write-Fail "BUG: set-option -Z @zz Z rc=$rc4 wrote Z (unknown flag accepted)" }
else { Write-Fail "set-option -Z rc=$rc4 read=[$v] out=[$out]" }

# --- 5: unknown flag on show-options must be rejected ---
& $PSMUX set-option -t $S '@ww' W 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$out = & $PSMUX show-options -Z -v -t $S '@ww' 2>&1
$rc5 = $LASTEXITCODE
if ($rc5 -ne 0) { Write-Pass "show-options -Z rejected (rc=$rc5): $out" }
else { Write-Fail "BUG: show-options -Z rc=0, printed [$out]" }

# --- 6: valid flags still work after the fix (-g, -q, -a) ---
& $PSMUX set-option -g -t $S '@gg' GVAL 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$v = (& $PSMUX show-options -g -qv -t $S '@gg' 2>&1 | Out-String).Trim()
if ($v -eq "GVAL") { Write-Pass "valid flags: set -g / show -g -qv unaffected" }
else { Write-Fail "valid flags broken: set -g read=[$v]" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
