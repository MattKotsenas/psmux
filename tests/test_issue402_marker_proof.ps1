# Issue #402 root-cause narrowing: does run-shell from a BIND execute its shell command AT ALL?
# Bind run-shell to write a marker file. If the file never appears, run-shell action is a
# no-op on the client/bind dispatch path (not a psmux-spawn problem).
# Control: also bind the SAME marker write via a command that we know works from bind (new-window
# won't write a file, so we use run-shell from CLI as the known-good baseline separately).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402mark"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$marker = "$env:TEMP\psmux402_bind_marker.txt"
$markerCli = "$env:TEMP\psmux402_cli_marker.txt"
$script:P = 0; $script:F = 0
function Pass($m){Write-Host "  [PASS] $m" -f Green;$script:P++}
function Fail($m){Write-Host "  [FAIL] $m" -f Red;$script:F++}
function Info($m){Write-Host "  [INFO] $m" -f DarkCyan}

Remove-Item $marker,$markerCli -Force -EA SilentlyContinue

$conf = "$env:TEMP\psmux402_mark.conf"
@"
bind-key -T prefix S run-shell "Set-Content -Path '$marker' -Value BIND_RAN"
"@ | Set-Content -Path $conf -Encoding UTF8

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

Write-Host "`n=== #402 marker proof ===" -ForegroundColor Cyan

# Baseline: same run-shell command via CLI must create markerCli
Info "Baseline via CLI: run-shell Set-Content markerCli"
& $PSMUX run-shell -t $SESSION "Set-Content -Path '$markerCli' -Value CLI_RAN" 2>&1 | Out-Null
Start-Sleep -Seconds 2
if (Test-Path $markerCli) { Pass "CLI run-shell wrote its marker (run-shell command execution works via CLI)" }
else { Fail "CLI run-shell did NOT write marker (unexpected)" }

# Suspect: run-shell via BIND (prefix+S)
Info "Suspect via BIND: inject prefix+S"
& $injector $proc.Id "^b{SLEEP:400}S"
Start-Sleep -Seconds 3
if (Test-Path $marker) { Pass "BIND run-shell wrote its marker (run-shell DOES execute from bind)" }
else { Fail "REPRODUCED: BIND run-shell did NOT write marker => run-shell is a NO-OP on the bind/client dispatch path" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*",$marker,$markerCli -Force -EA SilentlyContinue

Write-Host "`n=== Results: Passed=$($script:P) Failed=$($script:F) ===" -ForegroundColor Cyan
