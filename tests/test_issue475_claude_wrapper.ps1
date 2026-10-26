# Issue #475: PSMUX_CLAUDE_TEAMMATE_MODE injected a Global:claude wrapper that
# hardcoded `& claude.exe`. npm/nvm4w installs of Claude Code ship only
# claude.cmd + claude.ps1 (no exe), so every `claude` invocation inside a psmux
# pane failed with "The term 'claude.exe' is not recognized".
#
# Fix: the wrapper resolves the real command at call time via
# Get-Command claude -CommandType Application,ExternalScript.
#
# Optional: set $env:PSMUX_TEST_NPM_CLAUDE_BIN to a directory containing a real
# npm install's claude.cmd/claude.ps1 to also run the real-binary proof.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue475"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# Fake npm-style install: claude.cmd + claude.ps1, NO claude.exe
$fakeDir = "$env:TEMP\psmux_test475_fake_npm"
New-Item -ItemType Directory -Force $fakeDir | Out-Null
Set-Content -Path "$fakeDir\claude.cmd" -Value "@echo off`r`necho FAKE_NPM_CLAUDE_RAN args=%*" -Encoding ASCII
Set-Content -Path "$fakeDir\claude.ps1" -Value 'Write-Output "FAKE_NPM_CLAUDE_RAN args=$args"' -Encoding ASCII

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 4
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== Issue #475 Tests ===" -ForegroundColor Cyan

# Helper: run a command inside the pane and capture output after a settle delay
function Invoke-InPane([string]$cmd, [int]$sleepSec = 3) {
    & $PSMUX send-keys -t $SESSION "clear; $cmd" Enter
    Start-Sleep -Seconds $sleepSec
    return (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
}

# Save the pane's pristine PATH so later tests can restore it after the
# npm-only PATH mutations in Tests 3/4.
& $PSMUX send-keys -t $SESSION "`$env:__ORIG475PATH = `$env:PATH" Enter
Start-Sleep -Seconds 1

# === TEST 1: wrapper function is injected and no longer hardcodes claude.exe ===
Write-Host "`n[Test 1] Wrapper injected, resolves via Get-Command" -ForegroundColor Yellow
$out = Invoke-InPane "(Get-Command claude).CommandType; ((Get-Command claude).Definition -match 'Get-Command claude -CommandType')"
if ($out -match "Function") { Write-Pass "Global:claude wrapper is injected" }
else { Write-Fail "Wrapper not injected: $out" }
if ($out -match "True") { Write-Pass "Wrapper resolves via Get-Command (no hardcoded claude.exe)" }
else { Write-Fail "Wrapper still hardcodes claude.exe: $out" }

# === TEST 2: PSMUX_CLAUDE_TEAMMATE_MODE is set (wrapper gate) ===
Write-Host "`n[Test 2] Teammate mode env var present" -ForegroundColor Yellow
$out = Invoke-InPane "`$env:PSMUX_CLAUDE_TEAMMATE_MODE"
if ($out -match "tmux") { Write-Pass "PSMUX_CLAUDE_TEAMMATE_MODE=tmux set in pane" }
else { Write-Fail "PSMUX_CLAUDE_TEAMMATE_MODE not set: $out" }

# === TEST 3: THE BUG - npm-only PATH (no claude.exe) must still work ===
Write-Host "`n[Test 3] npm-only install (claude.cmd/ps1, no exe) works in pane" -ForegroundColor Yellow
$pathCmd = "`$env:PATH = '$fakeDir;' + ((`$env:PATH -split ';' | Where-Object { -not (Test-Path (Join-Path `$_ 'claude.exe')) }) -join ';')"
# Isolation (psmux#399): the wrapper now skips --teammate-mode injection when
# teammateMode is configured in any settings.json Claude Code reads.  Point
# CLAUDE_CONFIG_DIR at an empty dir and cd outside the user profile so this
# machine's real ~/.claude/settings.json cannot suppress the injection this
# test asserts.
$isoCwd = Join-Path $env:PUBLIC "psmux_test475_iso"
$isoCfg = Join-Path $isoCwd "cfg"
New-Item -ItemType Directory -Force $isoCfg | Out-Null
$isoCmd = "`$env:CLAUDE_CONFIG_DIR='$isoCfg'; cd '$isoCwd'"
$out = Invoke-InPane "$pathCmd; $isoCmd; claude --version"
if ($out -match "not recognized") { Write-Fail "BUG #475 PRESENT: claude.exe not recognized error" }
else { Write-Pass "No 'claude.exe not recognized' error" }
if ($out -match "FAKE_NPM_CLAUDE_RAN") { Write-Pass "npm-style claude executed through wrapper" }
else { Write-Fail "npm-style claude did not run: $out" }
if ($out -match "--teammate-mode tmux") { Write-Pass "--teammate-mode tmux auto-injected" }
else { Write-Fail "--teammate-mode not injected: $out" }

# === TEST 4: explicit --teammate-mode passes through once ===
Write-Host "`n[Test 4] Explicit --teammate-mode passthrough" -ForegroundColor Yellow
$out = Invoke-InPane "$pathCmd; claude --teammate-mode off --print hi"
if ($out -match "args=--teammate-mode off --print hi") { Write-Pass "Explicit flag passed through untouched" }
else { Write-Fail "Explicit flag mangled: $out" }

# === TEST 5: native claude.exe layout still works (regression guard) ===
Write-Host "`n[Test 5] Native claude.exe install still works" -ForegroundColor Yellow
if (Get-Command claude.exe -EA SilentlyContinue) {
    $out = Invoke-InPane "`$env:PATH = `$env:__ORIG475PATH; claude --version" 8
    if ($out -match "\d+\.\d+\.\d+") { Write-Pass "Native claude.exe runs through wrapper: version printed" }
    else { Write-Fail "Native claude.exe failed through wrapper: $out" }
} else {
    Write-Host "  [SKIP] No native claude.exe on this machine" -ForegroundColor DarkGray
}

# === TEST 6: REAL npm Claude Code binary (if provided) ===
Write-Host "`n[Test 6] Real npm Claude Code install" -ForegroundColor Yellow
$npmBin = $env:PSMUX_TEST_NPM_CLAUDE_BIN
if ($npmBin -and (Test-Path "$npmBin\claude.ps1") -and -not (Test-Path "$npmBin\claude.exe")) {
    $npmPathCmd = "`$env:PATH = '$npmBin;' + ((`$env:__ORIG475PATH -split ';' | Where-Object { -not (Test-Path (Join-Path `$_ 'claude.exe')) }) -join ';')"
    $out = Invoke-InPane "$npmPathCmd; claude --version" 20
    if ($out -match "not recognized") { Write-Fail "BUG #475 PRESENT with real npm claude: $out" }
    elseif ($out -match "\d+\.\d+\.\d+") { Write-Pass "Real npm Claude Code prints version inside psmux pane" }
    else { Write-Fail "Real npm claude gave unexpected output: $out" }
} else {
    Write-Host "  [SKIP] Set PSMUX_TEST_NPM_CLAUDE_BIN to an npm .bin dir to enable" -ForegroundColor DarkGray
}

# === TEARDOWN ===
Cleanup

# ============================================================
# Win32 TUI VISUAL VERIFICATION (Layer 2)
# ============================================================
Write-Host "`n=== Win32 TUI Visual Verification ===" -ForegroundColor Cyan
$SESSION_TUI = "test475_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: attached session alive" }
else { Write-Fail "TUI: session not created" }

& $PSMUX send-keys -t $SESSION_TUI "(Get-Command claude).CommandType" Enter
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
if ($cap -match "Function") { Write-Pass "TUI: wrapper present in attached TUI pane" }
else { Write-Fail "TUI: wrapper missing in attached pane: $cap" }

& $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" }
else { Write-Fail "TUI: expected 2 panes, got $panes" }

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Remove-Item $fakeDir -Recurse -Force -EA SilentlyContinue
Remove-Item (Join-Path $env:PUBLIC "psmux_test475_iso") -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
