# Ground truth: what char codes does psmux forward for real-keyboard ^g, ^w, ^v?
# Runs a keylog child inside psmux, injects each Ctrl combo, reads the log.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$injectorExe = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "repro363log"
$childExe = "$env:TEMP\psmux_keylog.exe"
$logFile = "$env:TEMP\psmux_keylog.txt"

# Compile child
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /out:$childExe "C:\Users\godwin\Documents\workspace\psmux\tests\keylog_child.cs" 2>&1 | Select-Object -Last 3
if (-not (Test-Path $childExe)) { Write-Host "[FATAL] child build failed" -ForegroundColor Red; exit 2 }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}
Cleanup
Remove-Item $logFile -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$SESSION,$childExe) -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] no session" -ForegroundColor Red; exit 2 }
Start-Sleep -Seconds 1

Write-Host "=== Injecting Ctrl+G, Ctrl+W, Ctrl+V (each isolated) ===" -ForegroundColor Cyan
& $injectorExe $proc.Id "^g"; Start-Sleep -Milliseconds 700
& $injectorExe $proc.Id "^w"; Start-Sleep -Milliseconds 700
& $injectorExe $proc.Id "^v"; Start-Sleep -Milliseconds 700
# also a plain letter as a control
& $injectorExe $proc.Id "x"; Start-Sleep -Milliseconds 500
Start-Sleep -Seconds 1

Write-Host "`n--- psmux_keylog.txt (what the child actually received) ---" -ForegroundColor Yellow
if (Test-Path $logFile) { Get-Content $logFile -Raw } else { Write-Host "<no log>" }
Write-Host "--- end log ---" -ForegroundColor Yellow

Write-Host "`nExpected if all forwarded: char=0x07 (G), 0x17 (W), 0x16 (V), 0x78 (x)"
Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Get-Process psmux_keylog -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
