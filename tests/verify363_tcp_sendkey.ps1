# Deterministic verification of the #363 fix at the ROOT-CAUSE layer.
# The attached client emits the singular "send-key C-<x>" command on every real
# Ctrl+<letter>. That routes: connection.rs send-key -> CtrlReq::SendKey ->
# send_key_to_active -> write_named_key_to_pane (the function we fixed).
# We drive that exact path via raw TCP into a keylog child and count delivered
# bytes. Pre-fix: one "send-key C-w" delivered 0x17 TWICE. Post-fix: ONCE.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$childExe = "$env:TEMP\psmux_keylog.exe"
$logFile = "$env:TEMP\psmux_keylog.txt"
$SESSION = "v363tcp"
$pass = 0; $fail = 0
function Ok($m){ $script:pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad($m){ $script:fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }

# (re)build keylog child
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /out:$childExe "C:\Users\godwin\Documents\workspace\psmux\tests\keylog_child.cs" 2>&1 | Out-Null

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
Remove-Item $logFile -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION $childExe 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] no session" -ForegroundColor Red; exit 2 }
Start-Sleep -Seconds 1

function Send-Tcp([string]$cmd) {
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $st = $tcp.GetStream(); $w = [System.IO.StreamWriter]::new($st); $r = [System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
    $w.Write("$cmd`n"); $w.Flush()
    Start-Sleep -Milliseconds 300
    $tcp.Close()
}

Write-Host "`n=== Driving send-key (singular) over TCP into keylog child ===" -ForegroundColor Cyan
# One send-key per Ctrl combo
foreach ($k in @("C-w","C-g","C-k","C-a")) { Send-Tcp "send-key $k"; Start-Sleep -Milliseconds 250 }
Start-Sleep -Seconds 1

$log = Get-Content $logFile -Raw -EA SilentlyContinue
Write-Host "--- keylog ---"; Write-Host $log; Write-Host "--- end ---"

# Count each control byte: 0x17=C-w, 0x07=C-g, 0x0B=C-k, 0x01=C-a
$cw = ([regex]::Matches($log, "char=0x17")).Count
$cg = ([regex]::Matches($log, "char=0x07")).Count
$ck = ([regex]::Matches($log, "char=0x0B")).Count
$ca = ([regex]::Matches($log, "char=0x01")).Count
Write-Host "counts: C-w(0x17)=$cw  C-g(0x07)=$cg  C-k(0x0B)=$ck  C-a(0x01)=$ca"

if ($cw -eq 1) { Ok "send-key C-w delivered 0x17 exactly ONCE (was 2 pre-fix)" } else { Bad "C-w delivered $cw times (expected 1)" }
if ($cg -eq 1) { Ok "send-key C-g delivered 0x07 exactly ONCE" } else { Bad "C-g delivered $cg times (expected 1)" }
if ($ck -eq 1) { Ok "send-key C-k delivered 0x0B exactly ONCE" } else { Bad "C-k delivered $ck times (expected 1)" }
if ($ca -eq 1) { Ok "send-key C-a delivered 0x01 exactly ONCE" } else { Bad "C-a delivered $ca times (expected 1)" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Get-Process psmux_keylog -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Write-Host "`n=== RESULT: $pass passed, $fail failed ===" -ForegroundColor $(if($fail){"Red"}else{"Green"})
exit $fail
