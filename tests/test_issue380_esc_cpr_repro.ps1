# Issue #380: bare <Esc> swallowed after a CPR round-trip under WIN32_INPUT_MODE
#
# Phase A (control): inject <Esc> with a CLEAN parser -> child should get 0x1b.
# Phase B (trigger): child emits ESC[6n; psmux writes ESC[..R into the PTY pipe.
# Phase C (test):    inject <Esc> AFTER the CPR reply -> is 0x1b swallowed?
# Phase D (recover): inject a printable char then <Esc> -> does it ever recover?
#
# A bare <Esc> arrives as a log line exactly "RX 1b".
# A CPR reply arrives as a multi-byte line "RX 1b 5b ... 52".

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue380_cpr"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$readerLog = "$env:TEMP\esc_reader2_380.log"
$readerPy = (Resolve-Path "$PSScriptRoot\esc_reader2.py").Path
$py = (Get-Command python -EA Stop).Source

$script:Pass = 0; $script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function Count-BareEsc { (Get-Content $readerLog -EA SilentlyContinue | Where-Object { $_ -match "^\[.*\] RX 1b$" }).Count }
function Count-Cpr     { (Get-Content $readerLog -EA SilentlyContinue | Where-Object { $_ -match "RX 1b 5b" }).Count }
function Show-Log      { Write-Host "  --- child log ---" -ForegroundColor DarkGray; Get-Content $readerLog -EA SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Get-Process psmux -EA SilentlyContinue | Where-Object { $_.Id -eq $script:procId } | Stop-Process -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Write-Host "`n=== Issue #380: Esc-after-CPR reproduction ===" -ForegroundColor Cyan
Write-Host "psmux: $PSMUX" -ForegroundColor DarkGray

Cleanup
Remove-Item $readerLog -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
$script:procId = $proc.Id
Start-Sleep -Seconds 4
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session did not start"; exit 1 }

# Start the CPR-aware reader child
& $PSMUX send-keys -t $SESSION "& '$py' '$readerPy' '$readerLog'" Enter
Start-Sleep -Seconds 4
if (-not (Test-Path $readerLog)) { Write-Fail "reader child never started"; Cleanup; exit 1 }
if ((Get-Content $readerLog -Raw) -match "set_ok=True") { Write-Pass "reader up, VT input mode ON" }
else { Write-Fail "reader VT mode not set"; Show-Log }

# === Phase A: control Esc with a clean parser ===
Write-Host "`n[Phase A] control <Esc> (clean parser)" -ForegroundColor Yellow
$a0 = Count-BareEsc
& $injectorExe $proc.Id "{SLEEP:300}{ESC}"
Start-Sleep -Seconds 2
$a1 = Count-BareEsc
if ($a1 -gt $a0) { Write-Pass "control <Esc> delivered (0x1b) before any CPR" }
else { Write-Fail "control <Esc> NOT delivered even before CPR" }

# === Phase B: trigger CPR round-trip ===
Write-Host "`n[Phase B] trigger CPR: child emits ESC[6n, psmux replies ESC[..R" -ForegroundColor Yellow
$c0 = Count-Cpr
& $injectorExe $proc.Id "p"
Start-Sleep -Seconds 2
$c1 = Count-Cpr
if ($c1 -gt $c0) { Write-Pass "psmux answered CPR (ESC[..R) into the pane pipe" }
else { Write-Fail "no CPR reply observed (server did not respond)"; Show-Log }

# === Phase C: the actual test - Esc AFTER the CPR reply ===
Write-Host "`n[Phase C] TEST <Esc> after CPR reply" -ForegroundColor Yellow
$t0 = Count-BareEsc
& $injectorExe $proc.Id "{SLEEP:300}{ESC}"
Start-Sleep -Seconds 3
$t1 = Count-BareEsc
if ($t1 -gt $t0) {
    Write-Pass "post-CPR <Esc> delivered -> Esc works"
} else {
    Write-Fail "post-CPR <Esc> SWALLOWED -> BUG #380 REPRODUCED"
}

# === Phase D: recovery - does a later keystroke un-stick it? ===
Write-Host "`n[Phase D] recovery: type 'x' then <Esc> again" -ForegroundColor Yellow
$r0 = Count-BareEsc
& $injectorExe $proc.Id "x{SLEEP:300}{ESC}"
Start-Sleep -Seconds 3
$r1 = Count-BareEsc
if ($r1 -gt $r0) { Write-Host "  note: <Esc> recovered after another keystroke" -ForegroundColor DarkYellow }
else { Write-Host "  note: <Esc> still dead after another keystroke (never recovers)" -ForegroundColor DarkYellow }

Show-Log
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass" -ForegroundColor Green
Write-Host "  Failed: $script:Fail" -ForegroundColor $(if($script:Fail){"Red"}else{"Green"})
exit $script:Fail
