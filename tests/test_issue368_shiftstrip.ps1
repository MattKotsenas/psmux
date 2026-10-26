# Issue #368 - confirm psmux strips the Shift modifier from Ctrl+Shift+<letter>
# when forwarding to the child (general, not V-specific). Clean sentinel clipboard.

$ErrorActionPreference = "Continue"
Set-Clipboard -Value "SENTINEL_CLIP"   # known text so any stray paste is identifiable
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
$SESSION = "iss368s"
$psmuxDir = "$env:USERPROFILE\.psmux"
function Line($m) { Write-Host $m }

& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Get-Process psmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\__warm__*","$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Remove-Item $KEYLOG -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION,$KEYLOG_CHILD -PassThru
Start-Sleep -Seconds 6
if (-not (Test-Path $KEYLOG)) { Line "[FAIL] keylog never created"; exit 1 }

function ResetLog { Set-Content -Path $KEYLOG -Value "RESET" -Encoding ASCII; Start-Sleep -Milliseconds 200 }
function Dump($label) {
    Start-Sleep -Milliseconds 700
    Line "--- [$label] child received ---"
    (Get-Content $KEYLOG | Where-Object { $_ -ne "RESET" }) | ForEach-Object { Line "    $_" }
}

# Ctrl+A   (vk=0x41 char=0x01 ctrl=CTRL)
ResetLog; & $INJECTOR $proc.Id "{RAW:41:01:0008}" | Out-Null; Dump "Ctrl+A  (expect key=A mods=Control)"
# Ctrl+Shift+A  (vk=0x41 char=0x01 ctrl=CTRL|SHIFT) -> does Shift survive?
ResetLog; & $INJECTOR $proc.Id "{RAW:41:01:0018}" | Out-Null; Dump "Ctrl+Shift+A (does mods show Shift?)"
# Ctrl+Shift+M  (vk=0x4D char=0x0D ctrl=CTRL|SHIFT)
ResetLog; & $INJECTOR $proc.Id "{RAW:4D:0D:0018}" | Out-Null; Dump "Ctrl+Shift+M"

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
& $PSMUX kill-server 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Line "done"
