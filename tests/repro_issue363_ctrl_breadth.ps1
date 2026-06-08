# Breadth probe for #363: which Ctrl combos reach nvim and which are swallowed?
# Each probe starts from a clean normal-mode nvim and uses a distinct discriminator.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$NVIM  = "C:\PROGRA~1\Neovim\bin\nvim.exe"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "repro363b"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Get-Process nvim -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}
function Cap { (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String) }
function Reset-Normal { & $injectorExe $proc.Id "{ESC}{SLEEP:200}{ESC}{SLEEP:200}"; Start-Sleep -Milliseconds 300 }

Cleanup
$proc = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$SESSION,"$NVIM --clean") -PassThru
Start-Sleep -Seconds 6
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] no session" -ForegroundColor Red; exit 2 }

# Control test: plain ':' must reach nvim (proves non-ctrl path works) -> shows ':' command line
Reset-Normal
& $injectorExe $proc.Id ":"
Start-Sleep -Milliseconds 800
$capColon = Cap
$colonOk = ($capColon -split "`n" | Where-Object { $_ -match '^\s*:\s*$' -or $_ -match ':\s*$' } | Select-Object -Last 1)
Write-Host "[CONTROL] plain ':' last line -> shows command line: $([bool]($capColon -match ':\s*$'))" -ForegroundColor Cyan
& $injectorExe $proc.Id "{ESC}"; Start-Sleep -Milliseconds 300

# Probe Ctrl+G : in normal mode shows file info like  "[No Name]" ... --No lines in buffer--
Reset-Normal
& $injectorExe $proc.Id "^g"
Start-Sleep -Milliseconds 800
$capG = Cap
$ctrlG_reached = ($capG -match "No lines in buffer" -or $capG -match '"\[No Name\]"')
Write-Host ("[Ctrl+G] file-info shown (reached nvim): {0}" -f $ctrlG_reached) -ForegroundColor $(if($ctrlG_reached){"Green"}else{"Red"})
Write-Host "         last line: $((($capG -split "`n") | Where-Object {$_.Trim()} | Select-Object -Last 1))"

# Probe Ctrl+W s : split or insert?
Reset-Normal
& $injectorExe $proc.Id "^w{SLEEP:300}s"
Start-Sleep -Milliseconds 900
$capW = Cap
$ctrlW_insert = ($capW -match "-- INSERT --")
Write-Host ("[Ctrl+W s] entered INSERT (bug = Ctrl+W lost): {0}" -f $ctrlW_insert) -ForegroundColor $(if($ctrlW_insert){"Red"}else{"Green"})
& $injectorExe $proc.Id "{ESC}{SLEEP:200}{ESC}"; Start-Sleep -Milliseconds 300

# Probe Ctrl+V in normal mode -> "-- VISUAL BLOCK --" if reached
Reset-Normal
& $injectorExe $proc.Id "^v"
Start-Sleep -Milliseconds 800
$capV = Cap
$ctrlV_reached = ($capV -match "VISUAL BLOCK")
Write-Host ("[Ctrl+V] entered VISUAL BLOCK (reached nvim): {0}" -f $ctrlV_reached) -ForegroundColor $(if($ctrlV_reached){"Green"}else{"Red"})
& $injectorExe $proc.Id "{ESC}"; Start-Sleep -Milliseconds 300

Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Write-Host "`n=== SCOPE SUMMARY ===" -ForegroundColor Cyan
Write-Host "Ctrl+G reached : $ctrlG_reached"
Write-Host "Ctrl+W swallowed (insert): $ctrlW_insert"
Write-Host "Ctrl+V reached : $ctrlV_reached"
