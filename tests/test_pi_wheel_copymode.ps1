# Mouse wheel input over an inline TUI such as pi must enter copy mode and
# scroll psmux's buffer, not reach the child.
#
# The test pane combines the signals that exercise pane_wheel_forward:
#   - foreground process is NOT a shell (node.exe)
#   - the pane reports an active mouse protocol (PSReadLine enables mouse
#     tracking spuriously on ConPTY; the sim enables DECSET 1002/1006 itself)
#   - screen filled, cursor at a bottom input box
#
# The sim app records any arrow/SGR-wheel sequence reaching its stdin into a
# leak file; the test asserts copy_mode turns on AND the leak file is empty.
#
# This drives a REAL attached psmux client in classic conhost and injects REAL
# console mouse-wheel events via WriteConsoleInput, then verifies copy_mode via
# TCP dump-state.  (Harness adapted from test_issue360_mouse_wheel_copymode.ps1.)
$ErrorActionPreference="Continue"
$PSMUX=(Get-Command psmux -EA Stop).Source
$NODE=(Get-Command node -EA SilentlyContinue).Source
if (-not $NODE) { Write-Host "SKIP: node.exe not found (required for pi simulator)" -ForegroundColor Yellow; exit 0 }
$MINJ="$env:LOCALAPPDATA\Temp\psmux_mouse_injector.exe"
$psmuxDir="$env:USERPROFILE\.psmux"
$S="tpiwheel"
$script:Pass=0; $script:Fail=0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

# write the pi simulator + leak file to temp
$simDir=Join-Path $env:LOCALAPPDATA "Temp\psmux_pi_sim"
New-Item -ItemType Directory -Force -Path $simDir | Out-Null
$sim=Join-Path $simDir "pi-sim.js"
$leak=Join-Path $simDir "pi-sim-leak.txt"
if (Test-Path $leak) { Remove-Item $leak -Force }
@'
const fs = require('fs');
const leakFile = process.argv[2];
process.stdout.write('\x1b[?1002h\x1b[?1006h'); // mouse tracking like PSReadLine/pi
const rows = process.stdout.rows || 40;
for (let i = 1; i <= rows - 2; i++) process.stdout.write(`transcript line ${i}\n`);
process.stdout.write('> input box (focused)');
process.stdin.setRawMode(true);
process.stdin.resume();
process.stdin.on('data', (d) => {
  const s = d.toString('utf8');
  if (s.includes('\x1b[A') || s.includes('\x1b[B') ||
      s.includes('\x1b[<64') || s.includes('\x1b[<65')) {
    fs.appendFileSync(leakFile, JSON.stringify(s) + '\n');
  }
  if (s.includes('q')) process.exit(0);
});
setInterval(() => {}, 1000);
'@ | Set-Content -Path $sim -Encoding UTF8

# compile mouse injector if missing
if (-not (Test-Path $MINJ)) {
    $csc="C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $src=Join-Path (Split-Path $PSScriptRoot -Parent) "tests\mouse_injector.cs"
    if (-not (Test-Path $src)) { $src="$PSScriptRoot\mouse_injector.cs" }
    & $csc /nologo /optimize /out:$MINJ $src 2>&1 | Out-Null
}

$sk="HKCU:\Console\%%Startup"; if(-not(Test-Path $sk)){New-Item -Path $sk -Force|Out-Null}
$oDC=(Get-ItemProperty $sk -EA SilentlyContinue).DelegationConsole; $oDT=(Get-ItemProperty $sk -EA SilentlyContinue).DelegationTerminal
$classic="{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}"
Set-ItemProperty $sk -Name DelegationConsole -Value $classic; Set-ItemProperty $sk -Name DelegationTerminal -Value $classic
function Restore { if($oDC){Set-ItemProperty $sk -Name DelegationConsole -Value $oDC}else{Remove-ItemProperty $sk -Name DelegationConsole -EA SilentlyContinue}; if($oDT){Set-ItemProperty $sk -Name DelegationTerminal -Value $oDT}else{Remove-ItemProperty $sk -Name DelegationTerminal -EA SilentlyContinue} }
function Get-CopyMode { param($Session)
    $port=(Get-Content "$psmuxDir\$Session.port" -Raw).Trim(); $key=(Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp=[System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port); $tcp.NoDelay=$true; $tcp.ReceiveTimeout=4000
    $st=$tcp.GetStream(); $w=[System.IO.StreamWriter]::new($st); $r=[System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine(); $w.Write("dump-state`n"); $w.Flush()
    $best=$null; for($j=0;$j -lt 60;$j++){ try{$l=$r.ReadLine()}catch{break}; if($null -eq $l){break}; if($l -ne "NC" -and $l.Length -gt 100){$best=$l;break} }
    $tcp.Close(); if($best -match '"copy_mode"\s*:\s*true'){return $true}else{return $false} }

Write-Host "=== pi wheel regression: copy mode, no input leak ===" -ForegroundColor Cyan
& $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 600
$conhost="$env:WINDIR\System32\conhost.exe"
$cmd="$NODE `"$sim`" `"$leak`""
$proc=Start-Process -FilePath $conhost -ArgumentList $PSMUX,"new-session","-s",$S,$cmd -PassThru
Start-Sleep -Seconds 6
$child=Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" | Where-Object {$_.Name -like 'psmux*'} | Select-Object -First 1
$cpid=if($child){[int]$child.ProcessId}else{$proc.Id}

& $PSMUX set-option -g mouse on -t $S 2>&1 | Out-Null
& $PSMUX set-option -g scroll-enter-copy-mode on -t $S 2>&1 | Out-Null
Start-Sleep -Seconds 2

$before = Get-CopyMode $S
# Inject with retry: WriteConsoleInput occasionally lands before the client's
# input loop is ready (same timing sensitivity as the other mouse E2E suites).
$after = $false
for ($try = 0; $try -lt 3 -and -not $after; $try++) {
    & $MINJ $cpid up 4 40 10 | Out-Null
    Start-Sleep -Seconds 2
    $after = Get-CopyMode $S
}
Write-Host "  pi-like pane wheel-up: copy_mode before=$before after=$after"
if (-not $before -and $after) { Write-Pass "wheel-up entered copy mode (transcript scrolls)" }
else { Write-Fail "wheel-up did NOT enter copy mode (before=$before after=$after)" }

Start-Sleep -Seconds 1
if (Test-Path $leak) {
    $c = Get-Content $leak -Raw
    Write-Fail "input leaked into the app (would cycle pi prompt history): $c"
} else {
    Write-Pass "no arrows/wheel leaked into the app's stdin"
}

& $PSMUX kill-session -t $S 2>&1 | Out-Null
try{Stop-Process -Id $proc.Id -Force -EA SilentlyContinue}catch{}
Restore
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
