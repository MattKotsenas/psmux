# Issue #402 ROOT CAUSE (disambiguated): bind run-shell writes an UNCONDITIONAL sentinel line
# plus the literal value of $env:PSMUX_TARGET_SESSION. This distinguishes:
#   - file has sentinel, target empty  => command RAN, env genuinely MISSING (root cause)
#   - file missing                     => command did not run

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test402env2"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$out = "$env:TEMP\psmux402_env2.txt"
$outCli = "$env:TEMP\psmux402_env2_cli.txt"
function Info($m){Write-Host "  [INFO] $m" -f DarkCyan}

Remove-Item $out,$outCli -Force -EA SilentlyContinue

# Unconditional one-line dump. Note: single-quote the literal parts, concat $env values.
$dump = "Set-Content -Path '{0}' -Value ('SENTINEL402 target=[' + `$env:PSMUX_TARGET_SESSION + '] full=[' + `$env:PSMUX_TARGET_FULL + '] envcount=' + (Get-ChildItem env:).Count)"
$dumpBind = $dump -f $out
$dumpCli  = $dump -f $outCli

$conf = "$env:TEMP\psmux402_env2.conf"
"bind-key -T prefix S run-shell `"$dumpBind`"" | Set-Content -Path $conf -Encoding UTF8
Info "bind config line:"
Get-Content $conf | ForEach-Object { Write-Host "      | $_" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null

Write-Host "`n=== #402 env proof (disambiguated) ===" -ForegroundColor Cyan

& $PSMUX run-shell -t $SESSION $dumpCli 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $injector $proc.Id "^b{SLEEP:400}S"
Start-Sleep -Seconds 3

Info "CLI path result:"
if (Test-Path $outCli) { Get-Content $outCli | ForEach-Object { Write-Host "      | $_" } } else { Write-Host "      | (missing)" }
Info "BIND path result:"
if (Test-Path $out) { Get-Content $out | ForEach-Object { Write-Host "      | $_" } } else { Write-Host "      | (missing - bind command did not run)" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Write-Host "`n=== done ===" -ForegroundColor Cyan
