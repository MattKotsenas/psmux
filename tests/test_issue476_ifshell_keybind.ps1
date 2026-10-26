# Issue #476: if-shell / run-shell bound to a key never fire when triggered by a real keypress
# Proves the key dispatch path (input.rs) executes if-shell/run-shell branches, not just the CLI path.
# Layers: CLI baseline, TCP server path, WriteConsoleInput real keystroke injection, TUI Strategy A.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue476"
$psmuxDir = "$env:USERPROFILE\.psmux"
$repoTests = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item "$env:TEMP\psmux476_runshell_marker.txt" -Force -EA SilentlyContinue
}

function Get-UserOpt($name) {
    (& $PSMUX display-message -t $SESSION -p ('#{' + $name + '}') 2>&1 | Out-String).Trim()
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $authResp = $reader.ReadLine()
    if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 10000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

# Compile keystroke injector
$injectorExe = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe "$repoTests\injector.cs" 2>&1 | Out-Null
}
if (-not (Test-Path $injectorExe)) { Write-Fail "Injector compile failed"; exit 1 }

Write-Host "`n=== Issue #476 Tests: if-shell/run-shell on key bindings ===" -ForegroundColor Cyan

# === SETUP: real ATTACHED client (key dispatch requires a TUI client) ===
Cleanup
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    & $PSMUX has-session -t $SESSION 2>$null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
}
if (-not $ready) { Write-Fail "Attached session failed to start"; exit 1 }
Start-Sleep -Seconds 2

# === TEST 1: CLI baseline: if-shell -F true branch ===
Write-Host "`n[Test 1] CLI if-shell -F (baseline)" -ForegroundColor Yellow
& $PSMUX set-option -g -t $SESSION "@result" "INIT" 2>&1 | Out-Null
& $PSMUX if-shell -t $SESSION -F "1" "set -g @result CLI_MATCH" "set -g @result CLI_NOMATCH" 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$r = Get-UserOpt "@result"
if ($r -eq "CLI_MATCH") { Write-Pass "CLI if-shell true branch executed" }
else { Write-Fail "CLI if-shell expected CLI_MATCH, got '$r'" }

# === TEST 2: TCP server path: if-shell ===
Write-Host "`n[Test 2] TCP if-shell" -ForegroundColor Yellow
$null = Send-TcpCommand -Session $SESSION -Command "if-shell -F '1' 'set -g @result TCP_MATCH' 'set -g @result TCP_NOMATCH'"
Start-Sleep -Milliseconds 800
$r = Get-UserOpt "@result"
if ($r -eq "TCP_MATCH") { Write-Pass "TCP if-shell true branch executed" }
else { Write-Fail "TCP if-shell expected TCP_MATCH, got '$r'" }

# === TEST 3: THE BUG: key bound to if-shell, triggered by REAL keystroke (true branch) ===
Write-Host "`n[Test 3] Real Ctrl+h keypress -> if-shell -F '1' (true branch)" -ForegroundColor Yellow
& $PSMUX set-option -g -t $SESSION "@result" "UNTOUCHED" 2>&1 | Out-Null
& $PSMUX bind-key -t $SESSION -n C-h "if-shell -F '1' 'set -g @result KEY_MATCH' 'set -g @result KEY_NOMATCH'" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $injectorExe $proc.Id "^h"
Start-Sleep -Seconds 2
$r = Get-UserOpt "@result"
if ($r -eq "KEY_MATCH") { Write-Pass "Keypress if-shell executed true branch" }
else { Write-Fail "Keypress if-shell expected KEY_MATCH, got '$r' (bug #476 present if UNTOUCHED)" }

# === TEST 4: key bound to if-shell, false branch ===
Write-Host "`n[Test 4] Real Ctrl+h keypress -> if-shell -F '0' (false branch)" -ForegroundColor Yellow
& $PSMUX set-option -g -t $SESSION "@result" "UNTOUCHED" 2>&1 | Out-Null
& $PSMUX bind-key -t $SESSION -n C-h "if-shell -F '0' 'set -g @result KEY_MATCH' 'set -g @result KEY_NOMATCH'" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $injectorExe $proc.Id "^h"
Start-Sleep -Seconds 2
$r = Get-UserOpt "@result"
if ($r -eq "KEY_NOMATCH") { Write-Pass "Keypress if-shell executed false branch" }
else { Write-Fail "Keypress if-shell expected KEY_NOMATCH, got '$r'" }

# === TEST 5: key bound to if-shell with format condition on pane_current_command ===
Write-Host "`n[Test 5] Real keypress -> if-shell with #{pane_current_command} format condition" -ForegroundColor Yellow
& $PSMUX set-option -g -t $SESSION "@result" "UNTOUCHED" 2>&1 | Out-Null
& $PSMUX bind-key -t $SESSION -n C-y "if-shell -F '#{m/r:^(pwsh|powershell|cmd)$,#{pane_current_command}}' 'set -g @result SHELL_DETECTED' 'set -g @result OTHER_APP'" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $injectorExe $proc.Id "^y"
Start-Sleep -Seconds 2
$r = Get-UserOpt "@result"
if ($r -eq "SHELL_DETECTED" -or $r -eq "OTHER_APP") { Write-Pass "Keypress if-shell with format condition dispatched a branch ($r)" }
else { Write-Fail "Keypress if-shell with format condition did nothing, got '$r'" }

# === TEST 6: key bound to run-shell, triggered by REAL keystroke ===
Write-Host "`n[Test 6] Real Ctrl+k keypress -> run-shell writes marker file" -ForegroundColor Yellow
$marker = "$env:TEMP\psmux476_runshell_marker.txt"
Remove-Item $marker -Force -EA SilentlyContinue
$markerCmd = "run-shell 'Set-Content -Path """ + $marker + """ -Value FIRED'"
& $PSMUX bind-key -t $SESSION -n C-k $markerCmd 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $injectorExe $proc.Id "^k"
$found = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $marker) { $found = $true; break }
}
if ($found) { Write-Pass "Keypress run-shell executed (marker file written)" }
else { Write-Fail "Keypress run-shell never ran (no marker file)" }

# === TEST 7: control: unconditional binding on same key still works ===
Write-Host "`n[Test 7] Control: plain binding on C-h dispatches" -ForegroundColor Yellow
& $PSMUX set-option -g -t $SESSION "@plain" "UNTOUCHED" 2>&1 | Out-Null
& $PSMUX bind-key -t $SESSION -n C-h "set -g @plain PLAIN_FIRED" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $injectorExe $proc.Id "^h"
Start-Sleep -Seconds 2
$r = Get-UserOpt "@plain"
if ($r -eq "PLAIN_FIRED") { Write-Pass "Plain binding dispatched (control)" }
else { Write-Fail "Control plain binding failed, got '$r' (test env broken?)" }

# === TEST 8: prefix-table binding with if-shell (prefix then key) ===
Write-Host "`n[Test 8] Prefix table: prefix + g -> if-shell" -ForegroundColor Yellow
& $PSMUX set-option -g -t $SESSION "@result" "UNTOUCHED" 2>&1 | Out-Null
& $PSMUX bind-key -t $SESSION g "if-shell -F '1' 'set -g @result PREFIX_MATCH' 'set -g @result PREFIX_NOMATCH'" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $injectorExe $proc.Id "^b{SLEEP:400}g"
Start-Sleep -Seconds 2
$r = Get-UserOpt "@result"
if ($r -eq "PREFIX_MATCH") { Write-Pass "Prefix-table if-shell executed" }
else { Write-Fail "Prefix-table if-shell expected PREFIX_MATCH, got '$r'" }

# === TUI Strategy A: session still functional after all keypress tests ===
Write-Host "`n[TUI] Session functional checks" -ForegroundColor Yellow
$sn = (& $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1 | Out-String).Trim()
if ($sn -eq $SESSION) { Write-Pass "TUI: display-message responds ($sn)" }
else { Write-Fail "TUI: display-message wrong: '$sn'" }
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panes = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window works after keypress tests" }
else { Write-Fail "TUI: expected 2 panes, got '$panes'" }

# === TEARDOWN ===
Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
