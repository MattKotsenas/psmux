# Issue #368: Ctrl+Shift+V image paste does not reach apps that read clipboard directly
#
# The reporter hypothesizes that psmux "ends up injecting nothing or an empty bracketed
# paste" when Ctrl+Shift+V is pressed, so the child app never sees the raw keypress.
#
# This test injects a REAL Ctrl+Shift+V (and Ctrl+V baseline) into the psmux client's
# console input buffer and observes, via a keylog child running in the pane, EXACTLY
# what psmux forwards through ConPTY to the child process.
#
# This isolates the psmux side of the question: IF psmux receives Ctrl+Shift+V, does it
# forward the raw key to the child, or swallow/transform it?

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
$SESSION = "iss368"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Line($m) { Write-Host $m }

# --- cleanup ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Remove-Item $KEYLOG -Force -EA SilentlyContinue

Line "=== Issue #368: Ctrl+Shift+V passthrough test ==="
Line "psmux:    $PSMUX"
Line "keylog:   $KEYLOG_CHILD"
Line "injector: $INJECTOR"
Line ""

# --- launch an ATTACHED psmux window whose pane runs the keylog child ---
# Attached (no -d) so the client has a real console the injector can AttachConsole() to.
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION,$KEYLOG_CHILD -PassThru
Line "Launched psmux client pid=$($proc.Id)"
Start-Sleep -Seconds 5

if (-not (Test-Path $KEYLOG)) {
    Line "[FAIL] keylog file never created - child did not start. Aborting."
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    exit 1
}
Line "[OK] keylog child is running (file exists)"
Line ""

function Inject($keys, $label) {
    Line ">>> INJECT $label  ($keys)"
    & $INJECTOR $proc.Id $keys
    Start-Sleep -Milliseconds 800
}

# 1. Baseline plain char 'a' - proves the inject->psmux->child pipeline works
Inject "a" "plain 'a'"

# 2. Baseline plain Ctrl+V (ConHost-level paste key) via ^v
Inject "^v" "Ctrl+V (^v)"

# 3. THE TEST: Ctrl+Shift+V. VK=0x56(V), char=0x16(Ctrl-V char), ctrl=0x18 (CTRL|SHIFT)
Inject "{RAW:56:16:0018}" "Ctrl+Shift+V (RAW 56:16:0018)"

# 4. Ctrl+Shift+V variant with NUL char (char=0x00) in case 0x16 confuses things
Inject "{RAW:56:00:0018}" "Ctrl+Shift+V (RAW 56:00:0018)"

# 5. Trailing plain char 'b' - proves pipeline still alive after the combos
Inject "b" "plain 'b'"

Start-Sleep -Milliseconds 500

Line ""
Line "=== KEYLOG CONTENTS (what the child actually received via ConPTY) ==="
Get-Content $KEYLOG | ForEach-Object { Line "    $_" }
Line "=== END KEYLOG ==="
Line ""
Line "=== INJECTOR LOG (last run) ==="
Get-Content "$env:TEMP\psmux_inject.log" -EA SilentlyContinue | ForEach-Object { Line "    $_" }
Line "=== END INJECTOR LOG ==="

# --- teardown ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Milliseconds 300
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
