# DEFINITIVE Ctrl regression proof using a RAW-MODE (VT-native) reader, which is
# how real apps (nvim, opencode, Claude Code, PSReadLine) read input. Every
# Ctrl+<letter> must arrive EXACTLY once with the correct raw control byte.
# This is the representative test (the cooked-mode keylog child mislabels
# Ctrl+S/H/I/M as flow-control/Backspace/Tab/Enter; a raw reader does not).
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$childExe = "$env:TEMP\psmux_vtread.exe"
$logFile = "$env:TEMP\psmux_vtread.txt"
$SESSION = "v363regvt"
$pass=0;$fail=0
function Ok($m){$script:pass++;Write-Host "  [PASS] $m" -ForegroundColor Green}
function Bad($m){$script:fail++;Write-Host "  [FAIL] $m" -ForegroundColor Red}

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /out:$childExe "C:\Users\godwin\Documents\workspace\psmux\tests\vtread_child.cs" 2>&1 | Out-Null
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
Remove-Item $logFile -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION $childExe 2>&1 | Out-Null
Start-Sleep -Seconds 3; Start-Sleep -Seconds 1

function Send-Tcp([string]$cmd){
    $port=(Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim();$key=(Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
    $tcp=[System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port);$tcp.NoDelay=$true
    $st=$tcp.GetStream();$w=[System.IO.StreamWriter]::new($st);$r=[System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n");$w.Flush();$null=$r.ReadLine();$w.Write("$cmd`n");$w.Flush();Start-Sleep -Milliseconds 300;$tcp.Close()
}

# All Ctrl+letters except C (signal). Send each isolated with generous spacing.
$letters = @('a','b','d','e','f','g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y','z')
Write-Host "`n=== Sending each Ctrl+<letter> once to RAW-MODE reader ===" -ForegroundColor Cyan
foreach($L in $letters){ Send-Tcp "send-key C-$L"; Start-Sleep -Milliseconds 250 }
Start-Sleep -Seconds 1

$log = Get-Content $logFile -Raw -EA SilentlyContinue
$allOk = $true
foreach($L in $letters){
    $b = ([byte][char]([char]::ToUpper($L)) - 64)
    $hex = "0x{0:X2}" -f $b
    $count = ([regex]::Matches($log, [regex]::Escape($hex))).Count
    if ($count -ne 1) { Write-Host "  [FAIL] C-$L ($hex): $count times (expected 1)" -ForegroundColor Red; $allOk=$false; $fail++ }
}
if ($allOk) { Ok "All 25 Ctrl+<letter> delivered EXACTLY once to a raw-mode reader (incl. Ctrl+S=0x13)" }

Write-Host "`n--- vtread log ---"; Write-Host $log; Write-Host "--- end ---"
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Get-Process psmux_vtread -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Write-Host "`n=== RESULT: $pass passed, $fail failed ===" -ForegroundColor $(if($fail){"Red"}else{"Green"})
exit $fail
