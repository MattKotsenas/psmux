# Issue #495: #{pane_current_path} stale after `cd` in a PowerShell pane.
# The Win32 process CWD is not updated by PowerShell's Set-Location; psmux
# installs a Set-Location hook (in psrl_init) that syncs it so
# pane_current_path tracks `cd`. Windows PowerShell 5.1 (powershell.exe) was
# excluded from that hook, so users without pwsh7 and all SSH sessions (which
# resolve to classic powershell.exe) saw a frozen path.
#
# We reproduce the reporter's environment by forcing cached_shell() to resolve
# powershell.exe: spawn the psmux server with a PATH that has no pwsh.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

function PanePath { param($S) (& $PSMUX display-message -t $S -p '#{pane_current_path}' 2>&1 | Out-String).Trim() }

Write-Host "`n=== Issue #495: pane_current_path tracks cd ===" -ForegroundColor Cyan

# ---- Part A: default pwsh pane (baseline, must always track) ----
$SA = "issue495_pwsh"
& $PSMUX kill-session -t $SA 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SA.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SA
Start-Sleep 5
& $PSMUX has-session -t $SA 2>$null
if ($LASTEXITCODE -eq 0) {
    & $PSMUX send-keys -t $SA 'cd C:\Windows\System32' Enter
    Start-Sleep 3
    $p = PanePath $SA
    if ($p -match 'System32$') { Write-Pass "default pane tracks cd (got $p)" }
    else { Write-Fail "default pane stale: $p" }
} else { Write-Fail "default session failed to start" }
& $PSMUX kill-session -t $SA 2>&1 | Out-Null

# ---- Part B: forced powershell.exe pane (the #495 reproduction) ----
$SB = "issue495_ps51"
& $PSMUX kill-session -t $SB 2>&1 | Out-Null
& $PSMUX kill-session -t __warm__ 2>&1 | Out-Null
Remove-Item "$psmuxDir\__warm__.*","$psmuxDir\$SB.*" -Force -EA SilentlyContinue
Start-Sleep 1

$oldPath = $env:PATH
$env:PATH = "C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0"
$env:PSMUX_NO_WARM = "1"
$pwshResolves = $null; try { $pwshResolves = (Get-Command pwsh -EA Stop).Source } catch {}

& $PSMUX new-session -d -s $SB
Start-Sleep 6
$panePid = (& $PSMUX display-message -t $SB -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$pname = if ($panePid -match '^\d+$') { (Get-Process -Id $panePid -EA SilentlyContinue).ProcessName } else { "?" }

if ($pwshResolves) {
    Write-Host "  [INFO] pwsh still resolved in minimal PATH; cannot force powershell.exe. Skipping Part B." -ForegroundColor DarkYellow
} elseif ($pname -ne "powershell") {
    Write-Host "  [INFO] pane shell is '$pname', not powershell.exe (env-specific). Skipping Part B." -ForegroundColor DarkYellow
} else {
    & $PSMUX send-keys -t $SB 'cd C:\Windows\System32' Enter
    Start-Sleep 3
    $a1 = PanePath $SB
    & $PSMUX send-keys -t $SB 'cd C:\Windows\Temp' Enter
    Start-Sleep 3
    $a2 = PanePath $SB
    if ($a1 -match 'System32$') { Write-Pass "powershell.exe pane tracks cd to System32 (got $a1)" }
    else { Write-Fail "powershell.exe pane STALE after cd System32: $a1 (issue #495)" }
    if ($a2 -match 'Temp$') { Write-Pass "powershell.exe pane tracks cd to Temp (got $a2)" }
    else { Write-Fail "powershell.exe pane STALE after cd Temp: $a2 (issue #495)" }
}

& $PSMUX kill-session -t $SB 2>&1 | Out-Null
$env:PATH = $oldPath
Remove-Item Env:PSMUX_NO_WARM -EA SilentlyContinue

# ---- Part C: cmd.exe pane (native CWD, must track) ----
$SC = "issue495_cmd"
& $PSMUX kill-session -t $SC 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SC.*" -Force -EA SilentlyContinue
$conf = "$env:TEMP\issue495_cmd.conf"
"set -g default-shell `"cmd.exe`"" | Set-Content -Path $conf -Encoding UTF8
$env:PSMUX_CONFIG_FILE = $conf
& $PSMUX new-session -d -s $SC
Start-Sleep 5
$env:PSMUX_CONFIG_FILE = $null
& $PSMUX send-keys -t $SC 'cd C:\Windows\System32' Enter
Start-Sleep 3
$pc = PanePath $SC
if ($pc -match 'System32$') { Write-Pass "cmd.exe pane tracks cd (got $pc)" }
else { Write-Fail "cmd.exe pane stale: $pc" }
& $PSMUX kill-session -t $SC 2>&1 | Out-Null
Remove-Item $conf -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
