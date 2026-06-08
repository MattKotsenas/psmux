# REAL-keyboard (WriteConsoleInput) proof of the #363 fix - the exact user scenario.
# Single clean session to avoid console contention. Injects <C-w>s like a real user.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$NVIM  = "C:\PROGRA~1\Neovim\bin\nvim.exe"
$inj = "$env:TEMP\psmux_injector.exe"
$s = "rk363"
$pass=0;$fail=0
function Ok($m){$script:pass++;Write-Host "  [PASS] $m" -ForegroundColor Green}
function Bad($m){$script:fail++;Write-Host "  [FAIL] $m" -ForegroundColor Red}
function Cap{(& $PSMUX capture-pane -t $s -p 2>&1|Out-String)}

& $PSMUX kill-session -t $s 2>&1|Out-Null;Start-Sleep -Milliseconds 500
$p=Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$s,"$NVIM --clean") -PassThru
Start-Sleep -Seconds 6
$pid2=$p.Id

# Real-user action: <C-w>s to split horizontally
& $inj $pid2 "{ESC}{SLEEP:300}^w{SLEEP:400}s"
Start-Sleep -Milliseconds 1200
$cap=Cap
$insert = $cap -match "-- INSERT --"
# winnr readback via send-keys -l (literal, '$' safe)
$wf="$env:TEMP\rk363_wc.txt";Remove-Item $wf -Force -EA SilentlyContinue
$fp=($wf -replace '\\','/')
& $PSMUX send-keys -t $s Escape 2>&1|Out-Null;Start-Sleep -Milliseconds 200
& $PSMUX send-keys -t $s -l ":call writefile([winnr('`$')],'$fp')" 2>&1|Out-Null
& $PSMUX send-keys -t $s Enter 2>&1|Out-Null
Start-Sleep -Milliseconds 700
$wc= if(Test-Path $wf){(Get-Content $wf -Raw).Trim()}else{"<none>"}
Write-Host "REAL-KEYBOARD <C-w>s : insert=$insert  winnr=$wc"
if(-not $insert -and $wc -eq "2"){Ok "REAL keyboard <C-w>s splits nvim (winnr=2), NOT insert mode - #363 FIXED"}
elseif($insert){Bad "REAL keyboard <C-w>s entered insert - bug still present"}
else{Bad "inconclusive: insert=$insert winnr=$wc"}

& $PSMUX kill-session -t $s 2>&1|Out-Null
try{Stop-Process -Id $pid2 -Force -EA SilentlyContinue}catch{}
Get-Process nvim -EA SilentlyContinue|Stop-Process -Force -EA SilentlyContinue
Write-Host "`n=== $pass passed, $fail failed ===" -ForegroundColor $(if($fail){"Red"}else{"Green"})
exit $fail
