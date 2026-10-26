# Issue #402: is the quoted-arg mangling in the stored-bind extraction, or in execute_command_string?
# Compare the SAME run-shell command via:
#   (A) command prompt  (prefix + : ... Enter)  -> execute_command_string directly, NO bind extraction
#   (B) a stored key binding                     -> goes through config bind-key extraction first

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402pvb"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$DIR = "$env:USERPROFILE\psmux_test402\project"
$script:P = 0; $script:F = 0
function Pass($m){Write-Host "  [PASS] $m" -f Green;$script:P++}
function Fail($m){Write-Host "  [FAIL] $m" -f Red;$script:F++}
function Info($m){Write-Host "  [INFO] $m" -f DarkCyan}

# Stored bind uses single-quoted -c path
$conf = "$env:TEMP\psmux402_pvb.conf"
"bind-key -T prefix 1 run-shell ""psmux new-window -n W_BIND -c '$DIR'""" | Set-Content -Path $conf -Encoding UTF8

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

function Wins { (& $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String) }

Write-Host "`n=== #402 command-prompt vs stored-bind ===" -ForegroundColor Cyan

# (A) Command prompt path: prefix : run-shell "psmux new-window -n W_PROMPT -c 'PATH'" Enter
# The injector types the command. Single quotes are literal keystrokes. Path has backslashes.
Info "[A] via command prompt (prefix + :)"
$promptCmd = "run-shell {SLEEP:150}psmux new-window -n W_PROMPT -c '$DIR'"
& $injector $proc.Id "^b{SLEEP:400}:{SLEEP:500}$promptCmd{SLEEP:300}{ENTER}"
Start-Sleep -Seconds 3
$wa = Wins; Info "windows: $($wa -replace "`r?`n",' ')"
if ($wa -match "W_PROMPT") { Pass "[A] command-prompt single-quoted -c WORKS" }
else { Fail "[A] command-prompt single-quoted -c FAILS" }

# (B) Stored bind path: prefix 1
Info "[B] via stored key binding (prefix + 1)"
& $injector $proc.Id "^b{SLEEP:400}1"
Start-Sleep -Seconds 3
$wb = Wins; Info "windows: $($wb -replace "`r?`n",' ')"
if ($wb -match "W_BIND") { Pass "[B] stored-bind single-quoted -c WORKS" }
else { Fail "[B] stored-bind single-quoted -c FAILS (defect is in bind-key extraction/storage)" }

Info "list-keys stored form:"
(& $PSMUX list-keys -t $SESSION 2>&1 | Out-String) -split "`n" | Where-Object { $_ -match "W_BIND" } | ForEach-Object { Write-Host "      | $($_.Trim())" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Write-Host "`n=== Results: Passed=$($script:P) Failed=$($script:F) ===" -ForegroundColor Cyan
