# Confirm the SAME double-delivery hits PSReadLine via the REAL keyboard path.
# Type "hello world", inject real-keyboard Ctrl+W (BackwardKillWord).
#   Correct single delivery: "hello world" -> "hello "
#   Bug double delivery    : "hello world" -> ""   (both words deleted)
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$injectorExe = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "repro363psr"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}
function Cap { (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String) }

Cleanup
$proc = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$SESSION,"pwsh -NoLogo -NoProfile") -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] no session" -ForegroundColor Red; exit 2 }
# wait for prompt
for ($i=0; $i -lt 20; $i++){ Start-Sleep -Milliseconds 400; if ((Cap) -match 'PS\s'){break} }

# Type hello world via injector (real keyboard path), then real Ctrl+W
& $injectorExe $proc.Id "hello world"
Start-Sleep -Milliseconds 600
$before = (Cap -split "`n" | Where-Object { $_ -match 'PS\s' } | Select-Object -Last 1)
Write-Host "Before Ctrl+W: '$before'"
& $injectorExe $proc.Id "^w"
Start-Sleep -Milliseconds 800
$after = (Cap -split "`n" | Where-Object { $_ -match 'PS\s' } | Select-Object -Last 1)
Write-Host "After  Ctrl+W: '$after'"

if ($after -match 'hello\s*$') {
    Write-Host "[SINGLE] Ctrl+W deleted one word ('world') - correct" -ForegroundColor Green
    $verdict = "single"
} elseif ($after -match '>\s*$' -or $after -notmatch 'hello') {
    Write-Host "[DOUBLE] Ctrl+W deleted BOTH words - DOUBLE DELIVERY BUG" -ForegroundColor Red
    $verdict = "double"
} else {
    Write-Host "[?] unexpected: '$after'" -ForegroundColor Yellow
    $verdict = "unknown"
}

Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Get-Process pwsh -EA SilentlyContinue | Where-Object { $_.Id -ne $PID } | ForEach-Object { } # leave other pwsh alone
Write-Host "`nVERDICT: $verdict"
