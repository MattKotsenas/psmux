# Issue #399 (comment 5041988743): the PSMUX_CLAUDE_TEAMMATE_MODE claude
# wrapper injected `--teammate-mode tmux` into every claude invocation.
# Claude Code gives CLI flags the highest priority and current builds DO read
# `teammateMode` from settings.json, so the blind injection silently overrode
# a user's explicit `"teammateMode": "..."` configuration.
#
# Fix under test: the wrapper only injects when teammateMode is NOT already
# configured (explicit CLI flag, managed settings, user scope via
# CLAUDE_CONFIG_DIR / ~/.claude, or project .claude/settings(.local).json
# found by walking up from the CWD at call time).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue399tm"
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

# Fake claude (echoes args) so no real Claude Code binary is ever launched.
$fakeDir = "$env:TEMP\psmux_test399_fake_claude"
New-Item -ItemType Directory -Force $fakeDir | Out-Null
Set-Content -Path "$fakeDir\claude.cmd" -Value "@echo off`r`necho FAKE_CLAUDE_ARGS=%*" -Encoding ASCII

# All scratch dirs live under $env:PUBLIC (outside the user profile) so the
# wrapper's ancestor walk cannot see this machine's real ~/.claude settings.
$base = Join-Path $env:PUBLIC "psmux_test399"
Remove-Item $base -Recurse -Force -EA SilentlyContinue
$emptyCfg = Join-Path $base "empty_cfg"          # user scope with NO settings
$userCfg  = Join-Path $base "user_cfg"           # user scope WITH teammateMode
$projDir  = Join-Path $base "proj"               # project WITH teammateMode
$projSub  = Join-Path $projDir "src\deep"        # subdir of that project
$noKeyDir = Join-Path $base "nokey"              # project settings WITHOUT the key
$plainDir = Join-Path $base "plain"              # no settings anywhere
New-Item -ItemType Directory -Force $emptyCfg, $userCfg, $projSub, "$projDir\.claude", "$noKeyDir\.claude", $plainDir | Out-Null
Set-Content "$userCfg\settings.json" '{ "teammateMode": "in-process" }' -Encoding ASCII
Set-Content "$projDir\.claude\settings.json" '{ "teammateMode": "in-process" }' -Encoding ASCII
Set-Content "$noKeyDir\.claude\settings.json" '{ "model": "opus" }' -Encoding ASCII

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 4
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== Issue #399 teammate-mode settings priority ===" -ForegroundColor Cyan

function Invoke-InPane([string]$cmd, [int]$sleepSec = 3) {
    & $PSMUX send-keys -t $SESSION "clear; $cmd" Enter
    Start-Sleep -Seconds $sleepSec
    return (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
}

$pathCmd = "`$env:PATH = '$fakeDir;' + ((`$env:PATH -split ';' | Where-Object { -not (Test-Path (Join-Path `$_ 'claude.exe')) }) -join ';')"

# === TEST 1: baseline - unconfigured everywhere, injection still happens ===
Write-Host "`n[Test 1] No teammateMode anywhere: wrapper still injects (original #399 workaround)" -ForegroundColor Yellow
$out = Invoke-InPane "$pathCmd; `$env:CLAUDE_CONFIG_DIR='$emptyCfg'; cd '$plainDir'; claude --print hi"
if ($out -match "FAKE_CLAUDE_ARGS=--teammate-mode tmux --print hi") { Write-Pass "Injected --teammate-mode tmux when unconfigured" }
else { Write-Fail "Baseline injection missing: $out" }

# === TEST 2: THE BUG - project .claude/settings.json must suppress injection ===
Write-Host "`n[Test 2] Project settings.json teammateMode suppresses injection" -ForegroundColor Yellow
$out = Invoke-InPane "cd '$projDir'; claude --print hi"
if ($out -match "FAKE_CLAUDE_ARGS=--print hi") { Write-Pass "No injection: settings.json teammateMode respected" }
elseif ($out -match "--teammate-mode") { Write-Fail "BUG #399 PRESENT: injected despite project settings.json: $out" }
else { Write-Fail "Unexpected output: $out" }

# === TEST 3: subdirectory of the project (ancestor walk) ===
Write-Host "`n[Test 3] Ancestor walk finds project settings from a subdir" -ForegroundColor Yellow
$out = Invoke-InPane "cd '$projSub'; claude --print hi"
if ($out -match "FAKE_CLAUDE_ARGS=--print hi") { Write-Pass "No injection from project subdirectory" }
else { Write-Fail "Ancestor walk failed: $out" }

# === TEST 4: user-scope settings (CLAUDE_CONFIG_DIR) suppress injection ===
Write-Host "`n[Test 4] User-scope settings.json teammateMode suppresses injection" -ForegroundColor Yellow
$out = Invoke-InPane "`$env:CLAUDE_CONFIG_DIR='$userCfg'; cd '$plainDir'; claude --print hi"
if ($out -match "FAKE_CLAUDE_ARGS=--print hi") { Write-Pass "No injection: user-scope teammateMode respected" }
else { Write-Fail "User-scope settings ignored: $out" }

# === TEST 5: settings.json WITHOUT teammateMode does not suppress ===
Write-Host "`n[Test 5] settings.json without teammateMode key still injects" -ForegroundColor Yellow
$out = Invoke-InPane "`$env:CLAUDE_CONFIG_DIR='$emptyCfg'; cd '$noKeyDir'; claude --print hi"
if ($out -match "FAKE_CLAUDE_ARGS=--teammate-mode tmux --print hi") { Write-Pass "Still injects when key absent" }
else { Write-Fail "Injection wrongly suppressed: $out" }

# === TEST 6: explicit CLI flag passes through once, even with settings ===
Write-Host "`n[Test 6] Explicit --teammate-mode passthrough with settings present" -ForegroundColor Yellow
$out = Invoke-InPane "cd '$projDir'; claude --teammate-mode tmux --print hi"
if ($out -match "FAKE_CLAUDE_ARGS=--teammate-mode tmux --print hi") { Write-Pass "Explicit flag passed through untouched" }
else { Write-Fail "Explicit flag mangled: $out" }
$flagCount = ([regex]::Matches($out, "--teammate-mode")).Count
if ($flagCount -le 2) { Write-Pass "No duplicate injection (echoed command + output)" }
else { Write-Fail "Flag duplicated: $out" }

# === TEARDOWN ===
Cleanup

# ============================================================
# Win32 TUI VISUAL VERIFICATION (Layer 2)
# ============================================================
Write-Host "`n=== Win32 TUI Visual Verification ===" -ForegroundColor Cyan
$SESSION_TUI = "test399_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: attached session alive" }
else { Write-Fail "TUI: session not created" }

# The wrapper and its settings probe must both exist in a real attached pane.
& $PSMUX send-keys -t $SESSION_TUI "(Get-Command claude).CommandType; [bool](Get-Command _psmux_tmcfg -EA 0)" Enter
Start-Sleep -Seconds 2
$cap = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
if ($cap -match "Function") { Write-Pass "TUI: claude wrapper present in attached pane" }
else { Write-Fail "TUI: wrapper missing: $cap" }
if ($cap -match "True") { Write-Pass "TUI: _psmux_tmcfg settings probe defined" }
else { Write-Fail "TUI: settings probe missing: $cap" }

# Functional check inside the attached TUI pane: project settings suppress injection.
& $PSMUX send-keys -t $SESSION_TUI "clear; $pathCmd; cd '$projDir'; claude --print hi" Enter
Start-Sleep -Seconds 3
$cap = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
if ($cap -match "FAKE_CLAUDE_ARGS=--print hi") { Write-Pass "TUI: settings.json respected in attached pane" }
else { Write-Fail "TUI: injection not suppressed in attached pane: $cap" }

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Remove-Item $fakeDir -Recurse -Force -EA SilentlyContinue
Remove-Item $base -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
