# Issue #402 CONFIRMATION: root cause is target-resolution from env in the bind path.
# Hypothesis: bare `psmux new-window` from bind fails because PSMUX_TARGET_FULL is empty.
# Predictions:
#   (a) bind run-shell "psmux new-window -t <explicit>"                       => WORKS
#   (b) bind run-shell "psmux new-window -t $env:PSMUX_TARGET_SESSION"        => WORKS
#   (c) bind run-shell "psmux new-window"  (bare, relies on env)             => FAILS (the bug)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402cf"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$script:P = 0; $script:F = 0
function Pass($m){Write-Host "  [PASS] $m" -f Green;$script:P++}
function Fail($m){Write-Host "  [FAIL] $m" -f Red;$script:F++}
function Info($m){Write-Host "  [INFO] $m" -f DarkCyan}

$conf = "$env:TEMP\psmux402_cf.conf"
@"
bind-key -T prefix X run-shell "psmux new-window -t $SESSION -n W_EXPLICIT"
bind-key -T prefix Y run-shell "psmux new-window -t `$env:PSMUX_TARGET_SESSION -n W_ENVSESSION"
bind-key -T prefix Z run-shell "psmux new-window -n W_BARE"
"@ | Set-Content -Path $conf -Encoding UTF8
Info "bind config:"
Get-Content $conf | ForEach-Object { Write-Host "      | $_" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

function Wins { (& $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String) }

Write-Host "`n=== #402 confirmation ===" -ForegroundColor Cyan

# (a) explicit -t <session>
& $injector $proc.Id "^b{SLEEP:400}X"; Start-Sleep -Seconds 3
$w = Wins; Info "after X: $($w -replace "`r?`n",' ')"
if ($w -match "W_EXPLICIT") { Pass "(a) explicit -t <session> from bind WORKS" } else { Fail "(a) explicit -t failed" }

# (b) -t $env:PSMUX_TARGET_SESSION
& $injector $proc.Id "^b{SLEEP:400}Y"; Start-Sleep -Seconds 3
$w = Wins; Info "after Y: $($w -replace "`r?`n",' ')"
if ($w -match "W_ENVSESSION") { Pass "(b) -t `$env:PSMUX_TARGET_SESSION from bind WORKS (env IS set)" } else { Fail "(b) env-session target failed" }

# (c) bare new-window (the reported bug)
& $injector $proc.Id "^b{SLEEP:400}Z"; Start-Sleep -Seconds 3
$w = Wins; Info "after Z: $($w -replace "`r?`n",' ')"
if ($w -match "W_BARE") { Pass "(c) bare new-window from bind WORKS (bug NOT present)" } else { Fail "(c) REPRODUCED: bare new-window from bind FAILS (the #402 bug)" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Write-Host "`n=== Results: Passed=$($script:P) Failed=$($script:F) ===" -ForegroundColor Cyan
