# Issue #368 - REGRESSION PROOF (asserting PASS/FAIL).
#
# Root cause (reproduced earlier): psmux collapsed Ctrl+Shift+<letter> to a plain
# Ctrl+<letter> on the wire, stripping Shift, so a child app reading the console
# input buffer could not tell Ctrl+Shift+V apart from Ctrl+V (issue #368).
#
# Fix: client.rs forwards `send-key C-S-<letter>` when Shift is held; the server
# (input.rs) injects ONE native KEY_EVENT carrying BOTH Ctrl and Shift via
# send_modified_key_event, and deliberately does NOT also write the raw C0 byte
# (which would double-deliver, regressing #363).
#
# This test injects real keystrokes into the attached psmux client console and
# asserts, via a keylog child in the pane, that:
#   1. plain Ctrl+A  arrives as    mods=Control                 (Shift absent)
#   2. Ctrl+Shift+A  arrives as     mods=Shift, Control         (Shift PRESERVED)
#   3. Ctrl+Shift+M  arrives as     key=M mods=Shift, Control   (NOT collapsed to Enter)
#   4. Ctrl+Shift+V  arrives as     key=V mods=Shift, Control   (the issue's subject)
#   5. each Ctrl+Shift combo produces EXACTLY ONE event         (no #363 double-deliver)

$ErrorActionPreference = "Continue"
Set-Clipboard -Value "SENTINEL_CLIP"
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
$SESSION = "iss368proof"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Passed = 0
$script:Failed = 0
function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }

foreach ($f in $KEYLOG_CHILD, $INJECTOR) {
    if (-not (Test-Path $f)) { Write-Host "[ABORT] helper missing: $f" -ForegroundColor Red; exit 2 }
}

& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Get-Process psmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\__warm__*", "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Remove-Item $KEYLOG -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session", "-s", $SESSION, $KEYLOG_CHILD -PassThru
Start-Sleep -Seconds 6
if (-not (Test-Path $KEYLOG)) { Fail "keylog never created"; exit 1 }

# Inject one combo, return the lines the child received (RESET sentinel filtered out).
function InjectAndRead($keys) {
    Set-Content -Path $KEYLOG -Value "RESET" -Encoding ASCII
    Start-Sleep -Milliseconds 200
    & $INJECTOR $proc.Id $keys | Out-Null
    Start-Sleep -Milliseconds 800
    return @(Get-Content $KEYLOG | Where-Object { $_ -ne "RESET" -and $_ -ne "" })
}

Write-Host "`n=== Issue #368 Shift-preserved regression proof ===" -ForegroundColor Cyan

# 1. Plain Ctrl+A: Control only, Shift must be ABSENT.
# (@(...) on the call site: a 1-element array unrolls to a scalar string on
#  function return, which would make $r[0] index a CHARACTER, not the line.)
$r = @(InjectAndRead "{RAW:41:01:0008}")
if ($r.Count -eq 1 -and $r[0] -match "key=A" -and $r[0] -match "Control" -and $r[0] -notmatch "Shift") {
    Pass "Ctrl+A -> Control only ($($r[0]))"
} else { Fail "Ctrl+A unexpected: $($r -join ' | ')" }

# 2. Ctrl+Shift+A: Shift must be PRESERVED, exactly one event.
$r = @(InjectAndRead "{RAW:41:01:0018}")
if ($r.Count -eq 1 -and $r[0] -match "key=A" -and $r[0] -match "Shift" -and $r[0] -match "Control") {
    Pass "Ctrl+Shift+A -> Shift preserved, single event ($($r[0]))"
} else { Fail "Ctrl+Shift+A BUG/regression: $($r -join ' | ') (count=$($r.Count))" }

# 3. Ctrl+Shift+M: must stay key=M with Shift, NOT collapse to Enter.
$r = @(InjectAndRead "{RAW:4D:0D:0018}")
if ($r.Count -eq 1 -and $r[0] -match "key=M" -and $r[0] -match "Shift" -and $r[0] -match "Control") {
    Pass "Ctrl+Shift+M -> key=M Shift+Control, not Enter ($($r[0]))"
} else { Fail "Ctrl+Shift+M unexpected: $($r -join ' | ') (count=$($r.Count))" }

# 4. Ctrl+Shift+V: the issue's subject. Shift+Control, single event.
$r = @(InjectAndRead "{RAW:56:16:0018}")
if ($r.Count -eq 1 -and $r[0] -match "key=V" -and $r[0] -match "Shift" -and $r[0] -match "Control") {
    Pass "Ctrl+Shift+V -> key=V Shift+Control, single event ($($r[0]))"
} else { Fail "Ctrl+Shift+V unexpected: $($r -join ' | ') (count=$($r.Count))" }

# teardown
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
& $PSMUX kill-server 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Passed" -ForegroundColor Green
Write-Host "  Failed: $script:Failed" -ForegroundColor $(if ($script:Failed) { "Red" } else { "Green" })
exit $script:Failed
