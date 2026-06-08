# Decisive: is Ctrl+W SWALLOWED or REORDERED relative to following printable keys?
# paste_pend buffers printable chars; cmd_batch carries control keys (send-key).
# If they flush out of order, 's' reaches nvim before C-w -> insert mode.
#   Short gap  ^w s : bug shows insert
#   Long  gap  ^w .... s : if SPLIT now -> reordering/timing bug; if still insert -> swallow
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$NVIM  = "C:\PROGRA~1\Neovim\bin\nvim.exe"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "repro363d"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Get-Process nvim -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}
function Cap { (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String) }
function Reset-Normal { & $injectorExe $proc.Id "{ESC}{SLEEP:250}{ESC}{SLEEP:250}u{SLEEP:250}"; Start-Sleep -Milliseconds 300 }
function WinCount {
    # count distinct '[No Name]' status lines as a split indicator
    $c = Cap
    ([regex]::Matches($c, "\[No Name\]")).Count
}

Cleanup
$proc = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$SESSION,"$NVIM --clean") -PassThru
Start-Sleep -Seconds 6
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] no session" -ForegroundColor Red; exit 2 }

Write-Host "=== TEST 1: SHORT gap  ^w s ===" -ForegroundColor Cyan
Reset-Normal
& $injectorExe $proc.Id "^w{SLEEP:50}s"
Start-Sleep -Milliseconds 1000
$c1 = Cap
$insert1 = ($c1 -match "-- INSERT --"); $wins1 = ([regex]::Matches($c1,"\[No Name\]")).Count
Write-Host ("  insert={0}  noNameStatusLines={1}" -f $insert1,$wins1)
& $injectorExe $proc.Id "{ESC}{SLEEP:200}{ESC}"; Start-Sleep -Milliseconds 300

Write-Host "=== TEST 2: LONG gap  ^w ....1500ms.... s ===" -ForegroundColor Cyan
# fully reset: close extra windows with :only, undo
& $injectorExe $proc.Id "{ESC}{SLEEP:200}:only{ENTER}{SLEEP:300}"
Start-Sleep -Milliseconds 400
& $injectorExe $proc.Id "^w{SLEEP:1500}s"
Start-Sleep -Milliseconds 1200
$c2 = Cap
$insert2 = ($c2 -match "-- INSERT --"); $wins2 = ([regex]::Matches($c2,"\[No Name\]")).Count
Write-Host ("  insert={0}  noNameStatusLines={1}" -f $insert2,$wins2)
Write-Host "--- pane (long gap) ---"; Write-Host $c2; Write-Host "--- end ---"
& $injectorExe $proc.Id "{ESC}{SLEEP:200}:only{ENTER}"; Start-Sleep -Milliseconds 400

Write-Host "=== TEST 3: lone ^w then check pending window-cmd via 'v' (vsplit) ===" -ForegroundColor Cyan
& $injectorExe $proc.Id "{ESC}{SLEEP:200}:only{ENTER}{SLEEP:300}"
Start-Sleep -Milliseconds 300
& $injectorExe $proc.Id "^w"        # send lone C-w
Start-Sleep -Milliseconds 1200      # nvim should now wait for 2nd window-cmd char
& $injectorExe $proc.Id "v"         # complete it: <C-w>v = vertical split
Start-Sleep -Milliseconds 1200
$c3 = Cap
$insert3 = ($c3 -match "-- INSERT --"); $vsplit3 = ([regex]::Matches($c3,"\[No Name\]")).Count
Write-Host ("  insert={0}  noNameStatusLines(vsplit?)={1}" -f $insert3,$vsplit3)

Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Write-Host "`n=== VERDICT ===" -ForegroundColor Cyan
Write-Host "T1 short-gap insert: $insert1 (bug visible)"
Write-Host "T2 long-gap  insert: $insert2  (if FALSE => timing/reorder bug, not swallow)"
Write-Host "T3 lone^w then v vsplit lines: $vsplit3 (>=2 => C-w DID reach nvim when isolated)"
