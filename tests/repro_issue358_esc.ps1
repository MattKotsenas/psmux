# Repro for discussion #358: ESC stops switching nvim modes "after some time".
# Strategy: stress ESC on the real-keyboard path in nvim. Cycle insert<->normal
# many times, interleave Alt keys / pastes (ESC is the Alt-prefix lead byte and a
# likely culprit for a stuck escape state), and after each ESC verify nvim
# actually returned to NORMAL mode (no "-- INSERT --").
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$NVIM  = "C:\PROGRA~1\Neovim\bin\nvim.exe"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "repro358"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Get-Process nvim -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}
function Cap { (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String) }
function InInsert { (Cap) -match "-- INSERT --" }

Cleanup
$proc = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$SESSION,"$NVIM --clean") -PassThru
Start-Sleep -Seconds 6
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] no session" -ForegroundColor Red; exit 2 }

$fails = 0; $cycles = 0
Write-Host "=== PHASE 1: rapid insert<->normal ESC cycles (40x) ===" -ForegroundColor Cyan
for ($i=0; $i -lt 40; $i++) {
    & $injectorExe $proc.Id "i"            # enter insert
    Start-Sleep -Milliseconds 60
    & $injectorExe $proc.Id "{ESC}"        # back to normal
    Start-Sleep -Milliseconds 90
    $cycles++
    if ((InInsert)) { $fails++; Write-Host "  [ESC FAIL] still INSERT after ESC at cycle $i" -ForegroundColor Red }
}
Write-Host "Phase1: $fails/$cycles ESC failures"

Write-Host "=== PHASE 2: ESC interleaved with Alt keys + fast typing (30x) ===" -ForegroundColor Cyan
$f2 = 0
for ($i=0; $i -lt 30; $i++) {
    & $injectorExe $proc.Id "iabc{SLEEP:30}"      # insert + text
    & $injectorExe $proc.Id "{ESC}{SLEEP:40}"
    & $injectorExe $proc.Id "{ESC}{SLEEP:40}"     # double ESC
    # an Alt key in normal mode (ESC-prefixed); then ESC again
    & $injectorExe $proc.Id "i{SLEEP:20}{ESC}{SLEEP:60}"
    if ((InInsert)) { $f2++; Write-Host "  [ESC FAIL] phase2 cycle $i still INSERT" -ForegroundColor Red }
}
Write-Host "Phase2: $f2/30 ESC failures"

Write-Host "=== PHASE 3: ESC after a bracketed-paste burst (15x) ===" -ForegroundColor Cyan
$f3 = 0
for ($i=0; $i -lt 15; $i++) {
    & $injectorExe $proc.Id "i"                       # insert
    & $injectorExe $proc.Id "thequickbrownfoxjumps"   # fast burst (paste-like)
    Start-Sleep -Milliseconds 80
    & $injectorExe $proc.Id "{ESC}{SLEEP:120}"
    if ((InInsert)) { $f3++; Write-Host "  [ESC FAIL] phase3 cycle $i still INSERT" -ForegroundColor Red }
}
Write-Host "Phase3: $f3/15 ESC failures"

$total = $fails + $f2 + $f3
Write-Host "`n--- final pane ---"; Write-Host (Cap); Write-Host "--- end ---"
Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Write-Host "`n=== VERDICT: total ESC failures = $total ===" -ForegroundColor $(if($total -gt 0){"Red"}else{"Green"})
exit $total
