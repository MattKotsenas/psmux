# Issue #402: capture WHY `psmux new-window -c <path>` fails from a bind but not CLI.
# The bind run-shell command captures the child psmux's stdout+stderr, exit code, and CWD.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402why"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$DIR = "$env:USERPROFILE\psmux_test402\project"
$outBind = "$env:TEMP\psmux402_why_bind.txt"
$outCli  = "$env:TEMP\psmux402_why_cli.txt"
function Info($m){Write-Host "  [INFO] $m" -f DarkCyan}
Remove-Item $outBind,$outCli -Force -EA SilentlyContinue

# Command template: run new-window -c PATH, capture everything.
# Use `& psmux` and redirect. Write cwd + exit + output.
$tmpl = "Set-Content '{0}' ('cwd=' + (Get-Location).Path); `$o = & psmux new-window -n W_WHY -c '$DIR' 2>&1 | Out-String; Add-Content '{0}' ('exit=' + `$LASTEXITCODE); Add-Content '{0}' ('out=' + `$o)"
$bindCmd = $tmpl -f $outBind
$cliCmd  = $tmpl -f $outCli

$conf = "$env:TEMP\psmux402_why.conf"
"bind-key -T prefix W run-shell `"$bindCmd`"" | Set-Content -Path $conf -Encoding UTF8

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

Write-Host "`n=== #402 why-does-c-fail ===" -ForegroundColor Cyan

# CLI path
& $PSMUX run-shell -t $SESSION $cliCmd 2>&1 | Out-Null
Start-Sleep -Seconds 3
# Bind path
& $injector $proc.Id "^b{SLEEP:400}W"
Start-Sleep -Seconds 3

Info "=== CLI child result ==="
if (Test-Path $outCli) { Get-Content $outCli | ForEach-Object { Write-Host "      | $_" } } else { Write-Host "      | (missing)" }
Info "=== BIND child result ==="
if (Test-Path $outBind) { Get-Content $outBind | ForEach-Object { Write-Host "      | $_" } } else { Write-Host "      | (missing)" }

Info "final windows: $((& $PSMUX list-windows -t $SESSION -F '#{window_name}' 2>&1 | Out-String) -replace "`r?`n",' ')"

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Write-Host "`n=== done ===" -ForegroundColor Cyan
