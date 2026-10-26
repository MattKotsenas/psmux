# Issue #408 / discussion #430: attach-session -t <name> must honour the target
# instead of reattaching to the `last_session` marker.
#
# Root cause: the global arg scan strips -t out of cmd_args, so the attach branch
# re-parsed -t from the stripped args (found none) and fell through to
# resolve_last_session_name_ns. Whenever last_session pointed at a DIFFERENT
# session, `attach-session -t s2` silently landed on last_session (e.g. s1).
#
# Deterministic proof without an interactive TTY: launch the attach client with
# Start-Process, then ask the server (via list-clients) which session the client
# actually joined. list-clients prints "<pts>: <session>: ...".

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$lastSessionFile = Join-Path $psmuxDir "last_session"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Reset-Server {
    & $PSMUX kill-server 2>&1 | Out-Null
    Get-Process psmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 700
}

# Returns the session name that the newest attach client is bound to, or "" if none.
function Get-AttachedSession {
    param([string[]]$ArgList, [string]$ForceLastSession)
    if ($ForceLastSession) { Set-Content $lastSessionFile -Value $ForceLastSession -NoNewline }
    $proc = Start-Process -FilePath $PSMUX -ArgumentList $ArgList -WindowStyle Minimized -PassThru
    Start-Sleep -Seconds 2
    # The session this attach client joined, found by its own pid (issue #724
    # made both the pid and the format available).
    $clients = & $PSMUX list-clients -F '#{client_pid} #{session_name}' 2>&1
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 400
    $line = ($clients | Where-Object { "$_" -like "$($proc.Id) *" } | Select-Object -Last 1)
    if ("$line" -match '^\d+ (\S+)$') { return $Matches[1] }
    return ""
}

function New-TwoDetachedSessions {
    Reset-Server
    & $PSMUX new-session -d -s s1 -- cmd.exe; Start-Sleep -Milliseconds 600
    & $PSMUX new-session -d -s s2 -- cmd.exe; Start-Sleep -Milliseconds 600
}

Write-Host "`n=== Issue #408 attach target regression ===" -ForegroundColor Cyan

# --- Test 1: subcommand -t, last_session points elsewhere (the reported bug) ---
Write-Host "`n[Test 1] attach-session -t s2 with last_session=s1" -ForegroundColor Yellow
New-TwoDetachedSessions
$landed = Get-AttachedSession -ArgList @('attach-session','-t','s2') -ForceLastSession 's1'
if ($landed -eq 's2') { Write-Pass "Client attached to s2 (target honoured)" }
else { Write-Fail "Client attached to '$landed', expected s2 (BUG: last_session won)" }

# --- Test 2: global -t placement, last_session points elsewhere ---
Write-Host "`n[Test 2] -t s2 attach-session with last_session=s1" -ForegroundColor Yellow
New-TwoDetachedSessions
$landed = Get-AttachedSession -ArgList @('-t','s2','attach-session') -ForceLastSession 's1'
if ($landed -eq 's2') { Write-Pass "Client attached to s2 (global -t honoured)" }
else { Write-Fail "Client attached to '$landed', expected s2" }

# --- Test 3: symmetric - target s1 while last_session=s2 ---
Write-Host "`n[Test 3] attach-session -t s1 with last_session=s2" -ForegroundColor Yellow
New-TwoDetachedSessions
$landed = Get-AttachedSession -ArgList @('attach-session','-t','s1') -ForceLastSession 's2'
if ($landed -eq 's1') { Write-Pass "Client attached to s1 (target honoured)" }
else { Write-Fail "Client attached to '$landed', expected s1" }

# --- Test 4: bare `attach` (no -t) picks the most recently active session ---
#
# This case used to assert the opposite, that a bare attach follows the
# `last_session` file, and called that tmux parity. It is not. Measured against
# tmux 3.4 with two detached sessions created in order s1 then s2 and no client
# anywhere:
#
#   s1 created=1787878619 activity=1787878619
#   s2 created=1787878620 activity=1787878620
#   tmux display-message -p '#S'  ->  s2
#
# tmux resolves an unqualified target through cmd_find_best_session, which ranks
# by activity_time and consults no "last session" file at all. psmux's global
# last_session file was written once per attach and never refreshed, so a
# session visited long ago and since detached kept winning: that is #603, and
# the fallback this case pinned was the bug rather than the contract.
#
# What #408 is actually about is that an EXPLICIT target must never lose to that
# fallback, which Tests 1, 2, 3 and 5 cover. Here the expectation is now tmux's:
# with no target given, the most recently active session wins, so pointing
# last_session at the OLDER s1 must not drag the attach away from s2.
# The activity ranking itself is proven in tests/test_issue603_bare_routing.ps1.
Write-Host "`n[Test 4] bare attach ignores a stale last_session and takes the newest" -ForegroundColor Yellow
New-TwoDetachedSessions
$landed = Get-AttachedSession -ArgList @('attach') -ForceLastSession 's1'
if ($landed -eq 's2') { Write-Pass "Bare attach used the most recently active session (tmux rule)" }
else { Write-Fail "Bare attach landed on '$landed', expected s2 (the newer session)" }

# --- Test 5: positional target `attach s2` still works (no regression) ---
Write-Host "`n[Test 5] positional 'attach s2' with last_session=s1" -ForegroundColor Yellow
New-TwoDetachedSessions
$landed = Get-AttachedSession -ArgList @('attach','s2') -ForceLastSession 's1'
if ($landed -eq 's2') { Write-Pass "Positional attach to s2 honoured" }
else { Write-Fail "Positional attach landed on '$landed', expected s2" }

# --- Teardown ---
Reset-Server

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
