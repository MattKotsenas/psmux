# #358 ESC repro v2: target ESC-as-Alt-prefix disambiguation and rapid bursts.
# After each scenario, verify a clean i->ESC cycle still returns to NORMAL mode.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$NVIM  = "C:\PROGRA~1\Neovim\bin\nvim.exe"
$inj = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$s = "repro358b"
function Cap { (& $PSMUX capture-pane -t $s -p 2>&1 | Out-String) }
function InsMode { (Cap) -match "-- INSERT --" }

& $PSMUX kill-session -t $s 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
$p = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$s,"$NVIM --clean") -PassThru
Start-Sleep -Seconds 6
$pid2 = $p.Id
function CheckEscWorks($label) {
    & $inj $pid2 "i{SLEEP:80}"      # enter insert
    Start-Sleep -Milliseconds 150
    $inIns = InsMode
    & $inj $pid2 "{ESC}{SLEEP:150}" # ESC
    Start-Sleep -Milliseconds 200
    $stillIns = InsMode
    if ($inIns -and -not $stillIns) { Write-Host "  [OK] $label : ESC returned to normal" -ForegroundColor Green; return $true }
    else { Write-Host "  [ESC BROKEN] $label : enteredInsert=$inIns stillInsertAfterEsc=$stillIns" -ForegroundColor Red; return $false }
}

$broken = 0
Write-Host "=== S1: ESC immediately followed by a key (Alt-prefix disambiguation) x30 ===" -ForegroundColor Cyan
for ($i=0;$i -lt 30;$i++){
    & $inj $pid2 "i{SLEEP:30}x"        # insert + x
    & $inj $pid2 "{ESC}j"              # ESC immediately followed by j (no gap) -> Alt+j ambiguity
    Start-Sleep -Milliseconds 60
}
if (-not (CheckEscWorks "after S1")) { $broken++ }

Write-Host "=== S2: rapid ESC bursts (10 ESC back-to-back) x15 ===" -ForegroundColor Cyan
for ($i=0;$i -lt 15;$i++){
    & $inj $pid2 "{ESC}{ESC}{ESC}{ESC}{ESC}{ESC}{ESC}{ESC}{ESC}{ESC}"
    Start-Sleep -Milliseconds 50
}
if (-not (CheckEscWorks "after S2")) { $broken++ }

Write-Host "=== S3: ESC interleaved with Ctrl keys (^[ = ESC) x20 ===" -ForegroundColor Cyan
for ($i=0;$i -lt 20;$i++){
    & $inj $pid2 "i{SLEEP:20}ab"
    & $inj $pid2 "^["                  # Ctrl+[ = ESC alternative
    Start-Sleep -Milliseconds 60
}
if (-not (CheckEscWorks "after S3 (Ctrl+[)")) { $broken++ }

Write-Host "=== S4: ESC after Alt keys and fast paste-like bursts x20 ===" -ForegroundColor Cyan
for ($i=0;$i -lt 20;$i++){
    & $inj $pid2 "i{SLEEP:10}"
    & $inj $pid2 "abcdefghijklmnop"    # fast burst
    & $inj $pid2 "{ESC}"
    & $inj $pid2 "{ESC}"
    Start-Sleep -Milliseconds 40
}
if (-not (CheckEscWorks "after S4")) { $broken++ }

# Final repeated check: does ESC still work 5x in a row?
Write-Host "=== Final: 5 clean i->ESC cycles ===" -ForegroundColor Cyan
for ($i=0;$i -lt 5;$i++){ if (-not (CheckEscWorks "final cycle $i")) { $broken++ } }

& $PSMUX kill-session -t $s 2>&1 | Out-Null
try { Stop-Process -Id $pid2 -Force -EA SilentlyContinue } catch {}
Get-Process nvim -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Write-Host "`n=== VERDICT: ESC-broken events = $broken ===" -ForegroundColor $(if($broken){"Red"}else{"Green"})
exit $broken
