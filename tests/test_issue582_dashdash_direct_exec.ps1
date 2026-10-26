# Issue #582: every pane-creating path except the server-boot `-- argv`
# case funneled the command through `pwsh.exe -NoLogo -Command "<joined>"`,
# so `new-window -t S -- cmd.exe /k ...` ran cmd.exe under a hidden pwsh
# wrapper (and #{pane_pid} reported the wrapper, not the command).
#
# tmux semantics (spawn.c): a multi-argument command is execvp'd DIRECTLY;
# only a single string routes through the shell. The fix preserves the
# `--` argv boundary from CLI to spawn: multi-token `--` argv is exec'd
# directly for new-window / split-window / respawn-pane, single tokens and
# string commands keep the historical shell route.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "t582e2e"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$env:PSMUX_NO_WARM = "1"
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $SESSION -- cmd.exe /k echo hello582
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

function Get-PaneTree($panePid) {
    # Returns "direct" if the pane pid is cmd.exe itself, or "wrapped:<name>"
    # if it is a shell wrapper with the command as a child.
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$panePid" -ErrorAction SilentlyContinue
    if (-not $p) { return "missing" }
    if ($p.Name -eq 'cmd.exe') { return "direct" }
    $kids = Get-CimInstance Win32_Process | Where-Object { [int]$_.ParentProcessId -eq [int]$panePid }
    $cmdkid = $kids | Where-Object { $_.Name -eq 'cmd.exe' } | Select-Object -First 1
    if ($cmdkid) { return "wrapped:$($p.Name)" }
    return "other:$($p.Name)"
}

Write-Host "`n=== Issue #582: -- argv direct exec (tmux execvp parity) ===" -ForegroundColor Cyan

# --- Arm 1: new-session -- argv spawns directly (control, worked before) ---
Write-Host "[Arm 1] new-session -- argv is direct" -ForegroundColor Yellow
$pid0 = (& $PSMUX display-message -t "${SESSION}:0.0" -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$tree0 = Get-PaneTree $pid0
if ($tree0 -eq 'direct') { Write-Pass "session root pane is cmd.exe itself (pid $pid0)" }
else { Write-Fail "session root pane tree: $tree0 (pid=$pid0)" }

# --- Arm 2: new-window -- argv spawns directly (the reported bug) ---
Write-Host "[Arm 2] new-window -- argv is direct" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION -- cmd.exe /k echo hello582b
Start-Sleep -Seconds 3
$pid1 = (& $PSMUX display-message -t "${SESSION}:1.0" -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$tree1 = Get-PaneTree $pid1
if ($tree1 -eq 'direct') { Write-Pass "new-window -- pane is cmd.exe itself, no pwsh wrapper (pid $pid1)" }
else { Write-Fail "new-window -- pane tree: $tree1 (pid=$pid1)" }
$cap = & $PSMUX capture-pane -t "${SESSION}:1" -p 2>&1 | Out-String
if ($cap -match 'hello582b') { Write-Pass "argv arguments survived (echo output present)" }
else { Write-Fail "command arguments lost: [$($cap.Trim())]" }

# --- Arm 3: split-window -- argv spawns directly ---
Write-Host "[Arm 3] split-window -- argv is direct" -ForegroundColor Yellow
& $PSMUX split-window -d -t "${SESSION}:0" -- cmd.exe /k echo hello582c
Start-Sleep -Seconds 3
$pid01 = (& $PSMUX display-message -t "${SESSION}:0.1" -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$tree01 = Get-PaneTree $pid01
if ($tree01 -eq 'direct') { Write-Pass "split-window -- pane is cmd.exe itself (pid $pid01)" }
else { Write-Fail "split-window -- pane tree: $tree01 (pid=$pid01)" }

# --- Arm 4: a plain "exe + args" string is direct too (launch latency) ---
# This arm used to assert the opposite. The psmux CLI joins positional words
# into one string, so by the time a command reaches the spawn code a quoted
# "cmd.exe /k echo hi" and an unquoted cmd.exe /k echo hi are the SAME string:
# the argc distinction tmux keys on survives only through the explicit `--`
# marker the arms above cover. Keeping the shell for that shared string meant
# every `psmux new-session pwsh -NoLogo -NoProfile -File x.ps1` paid a second
# pwsh start, measured at 278ms of launch-to-prompt (and the wrapper, having no
# -NoProfile of its own, sourced the profile the inner flag had opted out of).
# So a bare program name with arguments that PATH resolves to an .exe/.com is
# now exec'd directly; shell-syntax strings, lone words and names that resolve
# to a .cmd/.ps1/extensionless launcher still get the shell (Arms 6 and 7).
Write-Host "[Arm 4] plain exe + args string is direct, output intact" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION "cmd.exe /k echo hello582d"
Start-Sleep -Seconds 3
$pid2 = (& $PSMUX display-message -t "${SESSION}:2.0" -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$tree2 = Get-PaneTree $pid2
if ($tree2 -eq 'direct') { Write-Pass "plain exe + args string is cmd.exe itself, no pwsh wrapper (pid $pid2)" }
else { Write-Fail "string form tree unexpected: $tree2 (pid=$pid2)" }
$cap = & $PSMUX capture-pane -t "${SESSION}:2" -p 2>&1 | Out-String
if ($cap -match 'hello582d') { Write-Pass "string form output intact" }
else { Write-Fail "string form output missing: [$($cap.Trim())]" }

# --- Arm 5: teammate idioms unaffected ---
Write-Host "[Arm 5] -- cat placeholder and quoted respawn still work" -ForegroundColor Yellow
$paneId = (& $PSMUX new-window -t $SESSION -P -F '#{pane_id}' -- cat 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 3
$dead = (& $PSMUX display-message -t $paneId -p '#{pane_dead}' 2>&1 | Out-String).Trim()
if ($dead -eq '0') { Write-Pass "new-window -- cat still blocks silently" }
else { Write-Fail "cat placeholder died (dead=$dead)" }
& $PSMUX respawn-pane -k -t $paneId -- "pwsh -NoProfile -Command Write-Output RESPAWN582; Start-Sleep 300" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$cap = & $PSMUX capture-pane -t $paneId -p 2>&1 | Out-String
if ($cap -match 'RESPAWN582') { Write-Pass "quoted-string respawn (teammate idiom) intact" }
else { Write-Fail "quoted respawn broken: [$($cap.Trim())]" }

# --- Arm 6: shell syntax still gets a real shell ---
Write-Host "[Arm 6] shell-syntax string still routes through the shell" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION "cmd.exe /k echo hello582f; Start-Sleep 300"
Start-Sleep -Seconds 3
$pid6 = (& $PSMUX display-message -t "${SESSION}:4.0" -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$p6 = Get-CimInstance Win32_Process -Filter "ProcessId=$pid6" -ErrorAction SilentlyContinue
if ($p6 -and $p6.Name -match '^(pwsh|powershell)') { Write-Pass "a `;` in the command keeps the shell ($($p6.Name))" }
else { Write-Fail "shell-syntax string did not get a shell: $($p6.Name) (pid=$pid6)" }

# --- Arm 7: a lone word keeps the shell (PowerShell alias semantics) ---
# `ls` means Get-ChildItem to every Windows user; only the shell resolves it,
# and tmux routes a single-argument command through the shell too.
Write-Host "[Arm 7] lone word keeps the shell" -ForegroundColor Yellow
$o7 = (& $PSMUX new-window -t $SESSION -P -F '#{pane_id}' ls 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 2
if ($o7 -notmatch 'not a valid Win32|error 193|failed') { Write-Pass "lone `ls` spawned through the shell, not CreateProcessW" }
else { Write-Fail "lone word was direct-spawned: [$o7]" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
