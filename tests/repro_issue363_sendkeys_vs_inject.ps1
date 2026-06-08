# Cross-check #363: does the INDEPENDENT send-keys path also lose Ctrl+W into nvim?
# Also captures injector log immediately after a lone ^w to confirm what was injected.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$NVIM  = "C:\PROGRA~1\Neovim\bin\nvim.exe"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "repro363c"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Get-Process nvim -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}
function Cap { (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String) }

Cleanup
$proc = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$SESSION,"$NVIM --clean") -PassThru
Start-Sleep -Seconds 6
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] no session" -ForegroundColor Red; exit 2 }

Write-Host "=== PATH A: send-keys C-w then s (programmatic, bypasses real-keyboard input.rs) ===" -ForegroundColor Cyan
& $injectorExe $proc.Id "{ESC}{SLEEP:200}{ESC}"; Start-Sleep -Milliseconds 400
& $PSMUX send-keys -t $SESSION C-w
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION s
Start-Sleep -Milliseconds 900
$capA = Cap
$insertA = ($capA -match "-- INSERT --")
Write-Host ("send-keys C-w s -> INSERT (Ctrl+W lost on send-keys path): {0}" -f $insertA) -ForegroundColor $(if($insertA){"Red"}else{"Green"})
$lastA = (($capA -split "`n") | Where-Object {$_.Trim()} | Select-Object -Last 1)
Write-Host "   last line: $lastA"
& $injectorExe $proc.Id "{ESC}{SLEEP:200}{ESC}"; Start-Sleep -Milliseconds 400

Write-Host "`n=== PATH B: lone ^w via injector, then read injector log ===" -ForegroundColor Cyan
& $injectorExe $proc.Id "^w"
Start-Sleep -Milliseconds 600
$log = Get-Content "$env:TEMP\psmux_inject.log" -Raw -EA SilentlyContinue
Write-Host "--- injector log for ^w ---"
Write-Host $log
Write-Host "--- end log ---"
$capB = Cap
Write-Host "pane after lone ^w (last line): $((($capB -split "`n") | Where-Object {$_.Trim()} | Select-Object -Last 1))"

Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Write-Host "`n=== RESULT ===" -ForegroundColor Cyan
Write-Host "send-keys path lost Ctrl+W (insert): $insertA"
