# Discussion #310: prefix + prefix (send-prefix) must forward a literal prefix
# byte (Ctrl+B = 0x02) to the active pane, so a nested multiplexer (tmux over
# SSH) receives its own prefix. Regression: the interactive client re-armed the
# prefix on the second Ctrl+B instead of dispatching `bind -T prefix C-b
# send-prefix`, so no 0x02 was delivered AND the following key was swallowed.
#
# This test drives REAL keystrokes into the console input buffer via the
# WriteConsoleInput injector (the CLI/TCP paths cannot exercise the interactive
# prefix dispatch in client.rs). A Python byte-reader runs inside the pane and
# logs every raw byte it receives so we can prove the literal 0x02 arrives.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue310"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

# --- byte reader written into a temp file, launched inside the pane ---
$reader = "$env:TEMP\psmux_bytereader_310.py"
@'
import msvcrt, sys
with open(sys.argv[1], "w") as f:
    f.write("READER_READY\n"); f.flush()
    while True:
        b = msvcrt.getch()[0]
        f.write("BYTE %02x\n" % b); f.flush()
        if b == 0x71:  # 'q' quits
            f.write("QUIT\n"); f.flush(); break
'@ | Set-Content -Path $reader -Encoding ASCII
$bytelog = "$env:TEMP\psmux_bytes_310.log"

# --- compile the WriteConsoleInput injector ---
$injectorExe = "$env:TEMP\psmux_injector.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}
& $csc /nologo /optimize /out:$injectorExe (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $injectorExe)) { Write-Fail "injector compile failed"; exit 2 }

function Bytes { (Get-Content $bytelog -EA SilentlyContinue | Where-Object { $_ -match "^BYTE" } | ForEach-Object { $_ -replace "BYTE ","" }) }

# --- setup ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Remove-Item $bytelog -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session did not start"; exit 2 }

Write-Host "`n=== Discussion #310: send-prefix (prefix+prefix) ===" -ForegroundColor Cyan

# Test 1: prove the injector's Ctrl+B genuinely arms the prefix (prefix+c => new window)
$w0 = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
& $injectorExe $proc.Id "^b{SLEEP:400}c"
Start-Sleep -Seconds 2
$w1 = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
if ($w0 -eq "1" -and $w1 -eq "2") { Write-Pass "Ctrl+B arms prefix (prefix+c created a window: $w0 -> $w1)" }
else { Write-Fail "prefix+c did not create a window ($w0 -> $w1); injector Ctrl+B not registering as prefix" }
& $PSMUX kill-window -t "${SESSION}:1" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Start the byte reader in the (remaining) pane
& $PSMUX send-keys -t $SESSION "python `"$reader`" `"$bytelog`"" Enter
Start-Sleep -Seconds 3
$ready = $false
for ($i=0; $i -lt 20; $i++) { if ((Test-Path $bytelog) -and ((Get-Content $bytelog -Raw) -match "READER_READY")) { $ready=$true; break }; Start-Sleep -Milliseconds 250 }
if ($ready) { Write-Pass "byte reader ready in pane" } else { Write-Fail "byte reader never became ready" }

# Test 2: plain char sanity (0x78 = 'x')
& $injectorExe $proc.Id "x"
Start-Sleep -Milliseconds 800
if ((Bytes) -contains "78") { Write-Pass "plain 'x' reached pane (0x78)" } else { Write-Fail "plain 'x' not delivered" }

# Test 3: THE FEATURE. prefix+prefix must deliver a literal 0x02 to the pane
& $injectorExe $proc.Id "^b{SLEEP:500}^b"
Start-Sleep -Seconds 1
$c02 = ((Bytes) | Where-Object { $_ -eq "02" }).Count
if ($c02 -ge 1) { Write-Pass "prefix+prefix delivered literal 0x02 to pane" }
else { Write-Fail "prefix+prefix delivered NO 0x02 (send-prefix broken)" }

# Test 4: the key AFTER send-prefix must NOT be swallowed (prefix cleared cleanly)
& $injectorExe $proc.Id "y"
Start-Sleep -Milliseconds 800
if ((Bytes) -contains "79") { Write-Pass "key after send-prefix reached pane (0x79 'y', prefix cleared)" }
else { Write-Fail "key after send-prefix was swallowed (client stuck in prefix)" }

# Test 5: three prefix+prefix pairs => three 0x02 bytes
& $injectorExe $proc.Id "^b{SLEEP:400}^b{SLEEP:400}^b{SLEEP:400}^b{SLEEP:400}^b{SLEEP:400}^b"
Start-Sleep -Seconds 1
$c02b = ((Bytes) | Where-Object { $_ -eq "02" }).Count
if ($c02b -ge 4) { Write-Pass "multiple prefix+prefix pairs each deliver 0x02 (total $c02b)" }
else { Write-Fail "repeated send-prefix undercounted (total 0x02 = $c02b, expected >= 4)" }

# quit reader + cleanup
& $injectorExe $proc.Id "q"
Start-Sleep -Milliseconds 700
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item $reader,$bytelog -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) {"Red"} else {"Green"})
exit $script:TestsFailed
