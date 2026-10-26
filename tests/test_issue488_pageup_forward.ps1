# Issue #488: PageUp activates copy-mode instead of being forwarded to the app
# tmux parity: root table has NO PPage binding (PageUp forwarded to app);
#              prefix table has "bind PPage copy-mode -u";
#              copy-mode tables bind PPage to page-up.
# This test injects a REAL PageUp keystroke into an attached TUI window and
# verifies (a) copy mode is NOT entered, (b) the underlying app receives PageUp.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue488"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# Compile injector to a DEDICATED exe name: test_keystroke_injection.ps1
# compiles its own limited inline injector over $env:TEMP\psmux_injector.exe,
# which silently drops {PGUP}/{DOWN} tokens for every suite that runs after
# it. Always rebuild from tests/injector.cs (the full key map).
$injectorExe = "$env:TEMP\psmux_injector_full.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /optimize /out:$injectorExe tests\injector.cs 2>&1 | Out-Null
if (-not (Test-Path $injectorExe)) { Write-Fail "injector compile failed"; exit 1 }

function Get-CopyModeState {
    param([string]$Name)
    $port = (Get-Content "$psmuxDir\$Name.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Name.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    $writer.Write("dump-state`n"); $writer.Flush()
    $best = $null
    for ($j = 0; $j -lt 50; $j++) {
        try { $line = $reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
        if ($best) { $tcp.ReceiveTimeout = 100 }
    }
    $tcp.Close()
    if ($best) {
        $json = $best | ConvertFrom-Json
        return [bool]$json.layout.copy_mode
    }
    return $null
}

# Cleanup any stale session
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #488: PageUp forwarding ===" -ForegroundColor Cyan

# Launch REAL attached window
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

# Start a key-reporting loop in the pane so we can see what the APP receives
& $PSMUX send-keys -t $SESSION 'while($true){ $k=[Console]::ReadKey($true); Write-Host ("GOT=" + $k.Key) }' Enter
Start-Sleep -Seconds 2

# === TEST 1: bare PageUp must NOT enter copy mode ===
Write-Host "`n[Test 1] Bare PageUp does not enter copy mode" -ForegroundColor Yellow
& $injectorExe $proc.Id "{PGUP}"
Start-Sleep -Seconds 2
$cm = Get-CopyModeState $SESSION
if ($cm -eq $false) { Write-Pass "copy_mode stays false after bare PageUp" }
elseif ($cm -eq $true) { Write-Fail "BUG: bare PageUp entered copy mode" }
else { Write-Fail "could not read copy_mode state" }

# === TEST 2: the app must RECEIVE the PageUp key ===
Write-Host "`n[Test 2] App receives PageUp" -ForegroundColor Yellow
$captured = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($captured -match "GOT=PageUp") { Write-Pass "App received PageUp key" }
else { Write-Fail "App did NOT receive PageUp. Capture:`n$captured" }

# If we're stuck in copy mode from test 1, escape it so later tests work
& $injectorExe $proc.Id "q"
Start-Sleep -Milliseconds 500

# === TEST 3: sanity - PageDown / Home / End also forwarded ===
Write-Host "`n[Test 3] PageDown forwarded" -ForegroundColor Yellow
& $injectorExe $proc.Id "{PGDN}"
Start-Sleep -Seconds 2
$captured = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($captured -match "GOT=PageDown") { Write-Pass "App received PageDown key" }
else { Write-Fail "App did NOT receive PageDown" }

# === TEST 4: prefix + PageUp DOES enter copy mode (tmux parity) ===
Write-Host "`n[Test 4] Prefix+PageUp enters copy mode (scrolled up)" -ForegroundColor Yellow
& $injectorExe $proc.Id "^b{SLEEP:300}{PGUP}"
Start-Sleep -Seconds 2
$cm = Get-CopyModeState $SESSION
if ($cm -eq $true) { Write-Pass "prefix+PageUp entered copy mode" }
else { Write-Fail "prefix+PageUp did NOT enter copy mode (tmux binds PPage in prefix table)" }

# Exit copy mode
& $injectorExe $proc.Id "q"
Start-Sleep -Milliseconds 500

# === TEST 5: PageUp works inside copy mode (pages up) ===
Write-Host "`n[Test 5] PageUp inside copy mode still pages" -ForegroundColor Yellow
& $PSMUX copy-mode -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$cm = Get-CopyModeState $SESSION
if ($cm -eq $true) {
    & $injectorExe $proc.Id "{PGUP}"
    Start-Sleep -Milliseconds 800
    $cm2 = Get-CopyModeState $SESSION
    if ($cm2 -eq $true) { Write-Pass "copy mode retained after PageUp inside copy mode" }
    else { Write-Fail "PageUp inside copy mode exited copy mode" }
    & $injectorExe $proc.Id "q"
} else {
    Write-Fail "copy-mode command did not enter copy mode"
}

# === TEARDOWN ===
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
