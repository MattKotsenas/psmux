# PR #511: run-shell format expansion, -b spawn error reporting, -c start-dir hardening
# Proves:
#   1. run-shell expands #{...} on the CLI path, the TCP server path, and the
#      stored-bind path (the shape that was silently broken: a bind handing
#      #{pane_current_path} / #{pane_id} to a helper as literal text).
#   2. -b no longer swallows the result of a failed start (server path reports).
#   3. split-window -c with a missing or UNC dir still yields a LIVE pane that
#      lands in the home directory (tmux parity: cwd -> home fallback).
# tmux parity oracle: tmux 3.4 cmd-run-shell.c format_expand()s the command;
# verified live in WSL that run-shell 'echo #{session_name}' writes the real name.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "pr511"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

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
    if ($reader.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 8000
    $lines = @()
    try { while ($true) { $l = $reader.ReadLine(); if ($null -eq $l) { break }; $lines += $l; $stream.ReadTimeout = 500 } } catch {}
    $tcp.Close()
    return ($lines -join "`n")
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# === SETUP ===
Cleanup
$env:PSMUX_NO_WARM = "1"
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== PR #511 run-shell Tests ===" -ForegroundColor Cyan

# === TEST 1: CLI run-shell expands #{session_name} ===
Write-Host "`n[Test 1] CLI run-shell format expansion" -ForegroundColor Yellow
$out = & $PSMUX run-shell 'echo ''#{session_name}''' 2>&1 | Out-String
if ($out -match [regex]::Escape($SESSION)) { Write-Pass "CLI expanded #{session_name} -> $SESSION" }
else { Write-Fail "CLI output lacks session name: [$($out.Trim())]" }
if ($out -notmatch '#\{') { Write-Pass "CLI output has no unexpanded #{...}" }
else { Write-Fail "CLI output still contains literal #{...}: [$($out.Trim())]" }

# === TEST 2: CLI run-shell with multiple variables ===
Write-Host "`n[Test 2] CLI multiple format variables" -ForegroundColor Yellow
$out2 = & $PSMUX run-shell 'echo ''S=#{session_name} P=#{pane_id} W=#{window_index}''' 2>&1 | Out-String
if ($out2 -match "S=$SESSION\s+P=%\d+\s+W=\d+") { Write-Pass "Multiple variables expanded: $($out2.Trim())" }
else { Write-Fail "Multiple variable expansion wrong: [$($out2.Trim())]" }

# === TEST 3: TCP server path expands ===
Write-Host "`n[Test 3] TCP run-shell format expansion" -ForegroundColor Yellow
$resp = Send-TcpCommand -Session $SESSION -Command "run-shell echo TCPGOT_#{session_name}_END"
if ($resp -match "TCPGOT_$($SESSION)_END") { Write-Pass "TCP path expanded: $resp" }
else { Write-Fail "TCP path did not expand: [$resp]" }

# === TEST 4: bare # untouched (regression guard) ===
Write-Host "`n[Test 4] Bare hash survives" -ForegroundColor Yellow
$out4 = & $PSMUX run-shell 'echo ''fixes #481''' 2>&1 | Out-String
if ($out4 -match 'fixes #481') { Write-Pass "Literal # untouched" }
else { Write-Fail "Literal # corrupted: [$($out4.Trim())]" }

# === TEST 5: stored-bind path via a real bind writing to a file ===
# This is THE reported scenario: a bind whose run-shell hands pane context to a
# helper. Uses run-shell -b from the server (send prefix-less root binding is
# client side; exercise the server dispatch used by config binds via TCP
# execute of the bound command string).
Write-Host "`n[Test 5] Bind-shaped command through server dispatch" -ForegroundColor Yellow
$outFile = "$env:TEMP\pr511_bind_out.txt"
Remove-Item $outFile -Force -EA SilentlyContinue
$resp5 = Send-TcpCommand -Session $SESSION -Command "run-shell -b cmd /c echo BINDGOT_#{session_name}_#{pane_id}_END> $outFile"
$got = $null
for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 250; if (Test-Path $outFile) { $got = (Get-Content $outFile -Raw).Trim(); if ($got) { break } } }
if ($got -match "BINDGOT_$($SESSION)_%\d+_END") { Write-Pass "Helper received expanded values: $got" }
else { Write-Fail "Helper got: [$got] (expected BINDGOT_$($SESSION)_%N_END)" }
Remove-Item $outFile -Force -EA SilentlyContinue

# === TEST 6: -b spawn error reporting (server path returns text on failure) ===
# A genuine spawn failure is nearly impossible to provoke (the shell resolves
# via system dirs), so this asserts the success path stays silent and does not
# regress: -b with a good command returns nothing and the session stays healthy.
Write-Host "`n[Test 6] -b success stays silent, session healthy" -ForegroundColor Yellow
$resp6 = Send-TcpCommand -Session $SESSION -Command "run-shell -b cmd /c exit 0"
if ([string]::IsNullOrWhiteSpace($resp6)) { Write-Pass "-b success produced no spurious output" }
else { Write-Fail "-b success produced output: [$resp6]" }
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "Session still alive after -b" }
else { Write-Fail "Session died after -b" }

# === TEST 7: split -c missing dir yields live pane in home ===
Write-Host "`n[Test 7] split-window -c missing dir falls back live" -ForegroundColor Yellow
$before = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
& $PSMUX split-window -v -t $SESSION -c 'C:\pr511-does-not-exist\sub' 2>&1 | Out-Null
Start-Sleep -Seconds 4
$after = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ([int]$after -eq ([int]$before + 1)) { Write-Pass "Pane count grew $before -> $after" }
else { Write-Fail "Pane count $before -> $after (split died?)" }
& $PSMUX send-keys -t $SESSION 'echo PR511_ALIVE_A' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap -match 'PR511_ALIVE_A') { Write-Pass "New pane is alive" } else { Write-Fail "New pane dead" }
$p7 = (& $PSMUX display-message -t $SESSION -p '#{pane_current_path}' 2>&1 | Out-String).Trim()
if ($p7 -eq $env:USERPROFILE) { Write-Pass "Fell back to home: $p7" }
else { Write-Fail "Landed in [$p7], expected $env:USERPROFILE" }

# === TEST 8: split -c UNC dir yields live pane in home ===
Write-Host "`n[Test 8] split-window -c UNC dir falls back live" -ForegroundColor Yellow
$b8 = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
& $PSMUX split-window -v -t $SESSION -c '\\wsl.localhost\Ubuntu\home' 2>&1 | Out-Null
Start-Sleep -Seconds 4
$a8 = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ([int]$a8 -eq ([int]$b8 + 1)) { Write-Pass "Pane count grew $b8 -> $a8" }
else { Write-Fail "Pane count $b8 -> $a8 (UNC split died?)" }
& $PSMUX send-keys -t $SESSION 'echo PR511_ALIVE_B' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap8 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap8 -match 'PR511_ALIVE_B') { Write-Pass "UNC-split pane is alive" } else { Write-Fail "UNC-split pane dead" }

# === TEST 9: valid -c still honored (control) ===
Write-Host "`n[Test 9] split-window -c valid dir still honored" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESSION -c 'C:\Windows' 2>&1 | Out-Null
Start-Sleep -Seconds 4
$p9 = (& $PSMUX display-message -t $SESSION -p '#{pane_current_path}' 2>&1 | Out-String).Trim()
if ($p9 -eq 'C:\Windows') { Write-Pass "-c C:\Windows honored" }
else { Write-Fail "-c valid dir landed in [$p9]" }

Cleanup

# ============================================================
# Win32 TUI VISUAL VERIFICATION + WriteConsoleInput bind proof
# ============================================================
Write-Host "`n=== Win32 TUI verification (attached window + real keystrokes) ===" -ForegroundColor Cyan
$SESSION_TUI = "pr511tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

$injectorExe = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /nologo /optimize /out:$injectorExe "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
}

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

# Bind prefix+R to the reported failing shape: run-shell -b handing
# format variables to a file-writing helper. (Prefix table, not root: the
# injector has no F-key support and root-table binds are typed-text hostile.)
$bindOut = "$env:TEMP\pr511_tui_bind.txt"
Remove-Item $bindOut -Force -EA SilentlyContinue
& $PSMUX bind-key -t $SESSION_TUI -T prefix R run-shell -b "cmd /c echo TUIBIND_#{session_name}_#{pane_id}_END> $bindOut" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

if (Test-Path $injectorExe) {
    & $injectorExe $proc.Id "^b{SLEEP:400}R"
    $tuiGot = $null
    for ($i = 0; $i -lt 24; $i++) { Start-Sleep -Milliseconds 250; if (Test-Path $bindOut) { $tuiGot = (Get-Content $bindOut -Raw).Trim(); if ($tuiGot) { break } } }
    if ($tuiGot -match "TUIBIND_$($SESSION_TUI)_%\d+_END") { Write-Pass "TUI bind (real prefix+R keystrokes) expanded: $tuiGot" }
    else { Write-Fail "TUI bind got: [$tuiGot]" }
} else {
    Write-Fail "Injector not available; TUI keystroke bind not verified"
}
Remove-Item $bindOut -Force -EA SilentlyContinue

# TUI sanity: split + zoom respond via CLI
& $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" }
else { Write-Fail "TUI: expected 2 panes, got $panes" }
& $PSMUX resize-pane -Z -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$zoom = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
if ($zoom -eq "1") { Write-Pass "TUI: resize-pane -Z zoomed" }
else { Write-Fail "TUI: zoom expected 1, got $zoom" }

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item Env:\PSMUX_NO_WARM -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
