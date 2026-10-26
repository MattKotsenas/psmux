# Issue #402 ROOT CAUSE: does the BIND (client) run-shell set PSMUX_TARGET_* env for its child?
# CLI run-shell child sees PSMUX_TARGET_SESSION / PSMUX_TARGET_FULL (that's how bare
# `psmux new-window` finds the session). Prove whether the bind path sets them.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402env"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$envBind = "$env:TEMP\psmux402_env_bind.txt"
$envCli  = "$env:TEMP\psmux402_env_cli.txt"
$script:P = 0; $script:F = 0
function Pass($m){Write-Host "  [PASS] $m" -f Green;$script:P++}
function Fail($m){Write-Host "  [FAIL] $m" -f Red;$script:F++}
function Info($m){Write-Host "  [INFO] $m" -f DarkCyan}

Remove-Item $envBind,$envCli -Force -EA SilentlyContinue

# Bind run-shell dumps all PSMUX/TMUX env vars to a file
$dumpCmd = "Get-ChildItem env: | Where-Object { `$_.Name -match 'PSMUX|TMUX' } | ForEach-Object { `$_.Name + '=' + `$_.Value } | Set-Content '$envBind'"
$conf = "$env:TEMP\psmux402_env.conf"
"bind-key -T prefix S run-shell `"$dumpCmd`"" | Set-Content -Path $conf -Encoding UTF8

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

Write-Host "`n=== #402 env propagation proof ===" -ForegroundColor Cyan

# CLI path dump
$dumpCmdCli = "Get-ChildItem env: | Where-Object { `$_.Name -match 'PSMUX|TMUX' } | ForEach-Object { `$_.Name + '=' + `$_.Value } | Set-Content '$envCli'"
& $PSMUX run-shell -t $SESSION $dumpCmdCli 2>&1 | Out-Null
Start-Sleep -Seconds 2

# Bind path dump (inject prefix+S)
& $injector $proc.Id "^b{SLEEP:400}S"
Start-Sleep -Seconds 3

Info "--- CLI run-shell child env (PSMUX/TMUX) ---"
$cliEnv = if (Test-Path $envCli) { Get-Content $envCli } else { @() }
$cliEnv | ForEach-Object { Write-Host "      | $_" }
Info "--- BIND run-shell child env (PSMUX/TMUX) ---"
$bindEnv = if (Test-Path $envBind) { Get-Content $envBind } else { @() }
if ($bindEnv.Count -eq 0) { Write-Host "      | (file missing or empty)" }
$bindEnv | ForEach-Object { Write-Host "      | $_" }

$cliHasTarget  = ($cliEnv  -join "`n") -match "PSMUX_TARGET_SESSION"
$bindHasTarget = ($bindEnv -join "`n") -match "PSMUX_TARGET_SESSION"

if ($cliHasTarget) { Pass "CLI run-shell child HAS PSMUX_TARGET_SESSION" }
else { Fail "CLI run-shell child missing PSMUX_TARGET_SESSION (unexpected)" }

if ($bindHasTarget) {
    Pass "BIND run-shell child HAS PSMUX_TARGET_SESSION (env is propagated - root cause is elsewhere)"
} else {
    Fail "ROOT CAUSE CONFIRMED: BIND run-shell child is MISSING PSMUX_TARGET_SESSION => bare 'psmux new-window' cannot find the session"
}

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results: Passed=$($script:P) Failed=$($script:F) ===" -ForegroundColor Cyan
