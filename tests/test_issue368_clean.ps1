# Issue #368 - CLEAN repro: what does psmux forward when it receives Ctrl+Shift+V?
# Resets the keylog right before each controlled injection to defeat warm-pane
# contamination. One session, foreground, warm server cleared first.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$KEYLOG_CHILD = "$env:TEMP\keylog_child.exe"
if (-not (Test-Path $KEYLOG_CHILD)) {
    # Auto-compile the keylog helper from source (same pattern as the injector);
    # it was previously built by hand into TEMP, which gets cleaned periodically.
    $cscPath = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    if (-not (Test-Path $cscPath)) { $cscPath = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" }
    if (Test-Path $cscPath) { & $cscPath /nologo /optimize /out:$KEYLOG_CHILD "$PSScriptRoot\keylog_child.cs" 2>&1 | Out-Null }
}
if (-not (Test-Path $KEYLOG_CHILD)) {
    Write-Host "[SKIP] keylog_child.exe missing and csc compile unavailable" -ForegroundColor Yellow
    exit 0
}
$INJECTOR = "$env:TEMP\psmux_injector.exe"
$KEYLOG = "$env:TEMP\psmux_keylog.txt"
$SESSION = "iss368c"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Line($m) { Write-Host $m }

# kill everything + clear warm server (contamination source)
& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Get-Process psmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\__warm__*" -Force -EA SilentlyContinue
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Remove-Item $KEYLOG -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION,$KEYLOG_CHILD -PassThru
Line "psmux client pid=$($proc.Id)"
Start-Sleep -Seconds 6   # let startup contamination (if any) land

if (-not (Test-Path $KEYLOG)) { Line "[FAIL] keylog never created"; exit 1 }

function ResetLog { Set-Content -Path $KEYLOG -Value "RESET" -Encoding ASCII; Start-Sleep -Milliseconds 200 }
function Dump($label) {
    Start-Sleep -Milliseconds 700
    Line "--- child received after [$label] ---"
    (Get-Content $KEYLOG | Where-Object { $_ -ne "RESET" }) | ForEach-Object { Line "    $_" }
}

# Each injection isolated by a fresh log reset
ResetLog
& $INJECTOR $proc.Id "a" | Out-Null
Dump "plain a (sanity)"

ResetLog
& $INJECTOR $proc.Id "^v" | Out-Null
Dump "Ctrl+V (^v)"

ResetLog
& $INJECTOR $proc.Id "{RAW:56:16:0018}" | Out-Null
Dump "Ctrl+Shift+V  char=0x16 ctrl=CTRL|SHIFT"

ResetLog
& $INJECTOR $proc.Id "{RAW:56:00:0018}" | Out-Null
Dump "Ctrl+Shift+V  char=0x00 ctrl=CTRL|SHIFT"

ResetLog
& $INJECTOR $proc.Id "{RAW:56:16:0008}" | Out-Null
Dump "Ctrl+V (RAW, ctrl=CTRL only)  control vs above"

# teardown
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
& $PSMUX kill-server 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Line "done"
