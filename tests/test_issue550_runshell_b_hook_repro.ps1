# Issue #550: a hook whose command is `run-shell -b "..."` never executes when
# the hook's session has a client ATTACHED. Same hook without -b fires; same
# hook with -b on a DETACHED session fires. rc=0 throughout.
# Three-case matrix on ONE server, only attachment differs.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SA = "t550att"   # attached session (real TUI window)
$SD = "t550det"   # detached probe session, same server? (psmux: one server per session)
$psmuxDir = "$env:USERPROFILE\.psmux"
$logDir = Join-Path $env:TEMP "psmux_t550"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

& $PSMUX kill-session -t $SA 2>&1 | Out-Null
& $PSMUX kill-session -t $SD 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SA.*","$psmuxDir\$SD.*" -Force -EA SilentlyContinue
Remove-Item $logDir -Recurse -Force -EA SilentlyContinue
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

Write-Host "`n=== Issue #550 repro ===" -ForegroundColor Cyan

function HookCmd([string]$Marker, [string]$File, [bool]$Background) {
    $p = (Join-Path $logDir $File).Replace('\', '/')
    $b = if ($Background) { "-b " } else { "" }
    return 'run-shell ' + $b + '"' + "'$Marker' | Out-File -Append -Encoding ascii '$p'" + '"'
}

# --- A) -b on a DETACHED session ---
& $PSMUX new-session -d -s $SD -n p0 -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 3
& $PSMUX new-window -d -t $SD -n p1 -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 2
& $PSMUX set-hook -t $SD after-select-window (HookCmd "DETACHED-B" "b_det.log" $true) 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX select-window -t "${SD}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX select-window -t "${SD}:0" 2>&1 | Out-Null
Start-Sleep -Seconds 3
if (Test-Path "$logDir\b_det.log") { Write-Pass "A: -b on DETACHED session fires" }
else { Write-Fail "A: -b on DETACHED session did not fire" }

# --- Attached session: real TUI client via Start-Process ---
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SA -PassThru
Start-Sleep -Seconds 5
& $PSMUX new-window -d -t $SA -n w1 -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 2
$att = (& $PSMUX display-message -p -t $SA '#{session_attached}' 2>&1 | Out-String).Trim()
Write-Host "  session_attached=$att"
if ($att -ne "1") { Write-Fail "setup: session not attached ($att)" }

# --- B) -b on the ATTACHED session ---
& $PSMUX set-hook -t $SA after-select-window (HookCmd "ATTACHED-B" "b_att.log" $true) 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX select-window -t "${SA}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX select-window -t "${SA}:0" 2>&1 | Out-Null
Start-Sleep -Seconds 3
if (Test-Path "$logDir\b_att.log") { Write-Pass "B: -b on ATTACHED session fires" }
else { Write-Fail "B: BUG - -b on ATTACHED session did NOT fire" }

# --- C) no -b on the ATTACHED session (control) ---
& $PSMUX set-hook -t $SA -u after-select-window 2>&1 | Out-Null
& $PSMUX set-hook -t $SA after-select-window (HookCmd "ATTACHED-NOB" "nob_att.log" $false) 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX select-window -t "${SA}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX select-window -t "${SA}:0" 2>&1 | Out-Null
Start-Sleep -Seconds 3
if (Test-Path "$logDir\nob_att.log") { Write-Pass "C: control - no -b on ATTACHED session fires" }
else { Write-Fail "C: control - no -b on ATTACHED session did not fire either" }

& $PSMUX kill-session -t $SA 2>&1 | Out-Null
& $PSMUX kill-session -t $SD 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
