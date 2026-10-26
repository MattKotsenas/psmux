# Issue #586: `show-option` (singular) was rejected as an unknown command.
# tmux resolves unambiguous command-name prefixes, so the singular spellings
# `show-option` / `show-window-option` are valid there, and external tools
# type them: LazyVim probes `tmux show-option -qvg escape-time` (and
# focus-events, default-terminal) on startup and treated the rc 1 as a
# broken tmux. The control-mode dispatcher already knew both singulars; the
# CLI client, the TCP text dispatcher, and the internal dispatch did not.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "t586e2e"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$env:PSMUX_NO_WARM = "1"
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

Write-Host "`n=== Issue #586: show-option singular alias ===" -ForegroundColor Cyan

# --- Arm 1: the exact LazyVim probes ---
Write-Host "[Arm 1] LazyVim startup probes" -ForegroundColor Yellow
$o = (& $PSMUX show-option -qvg escape-time 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $o -match '^\d+$') { Write-Pass "show-option -qvg escape-time -> rc 0, value [$o]" }
else { Write-Fail "escape-time probe: rc=$LASTEXITCODE out=[$o]" }

$o = (& $PSMUX show-option -qvg focus-events 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $o -match '^(on|off)$') { Write-Pass "show-option -qvg focus-events -> rc 0, value [$o]" }
else { Write-Fail "focus-events probe: rc=$LASTEXITCODE out=[$o]" }

$o = (& $PSMUX show-option -qvg default-terminal 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $o -match 'term') { Write-Pass "show-option -qvg default-terminal -> rc 0, value [$o]" }
else { Write-Fail "default-terminal probe: rc=$LASTEXITCODE out=[$o]" }

# --- Arm 2: singular equals plural, targeted read ---
Write-Host "[Arm 2] singular and plural agree" -ForegroundColor Yellow
& $PSMUX set-option -t $SESSION '@k586' probe586 2>&1 | Out-Null
$sing = (& $PSMUX show-option -qv -t $SESSION '@k586' 2>&1 | Out-String).Trim()
$plur = (& $PSMUX show-options -qv -t $SESSION '@k586' 2>&1 | Out-String).Trim()
if ($sing -eq 'probe586' -and $sing -eq $plur) { Write-Pass "show-option and show-options return the same value" }
else { Write-Fail "singular=[$sing] plural=[$plur]" }

# --- Arm 3: show-window-option carries window scope ---
Write-Host "[Arm 3] show-window-option is window scoped" -ForegroundColor Yellow
$o = (& $PSMUX show-window-option -qv -t $SESSION automatic-rename 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $o -match '^(on|off)$') { Write-Pass "show-window-option -qv automatic-rename -> rc 0, value [$o]" }
else { Write-Fail "show-window-option: rc=$LASTEXITCODE out=[$o]" }

# --- Arm 4: no unknown-command noise anywhere ---
Write-Host "[Arm 4] no unknown-command error" -ForegroundColor Yellow
$o = (& $PSMUX show-option -qvg escape-time 2>&1 | Out-String)
if ($o -notmatch 'unknown command') { Write-Pass "no unknown-command error emitted" }
else { Write-Fail "still emits: [$($o.Trim())]" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
