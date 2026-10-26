#!/usr/bin/env pwsh
# Issue #29: [feature request] attach shortcut
# Request: `psmux a` (and `psmux attach`) should work as a shortcut for
# `psmux attach-session`, mirroring `tmux a`.
#
# NOTE on method: a successful foreground attach becomes a live TUI and never
# returns, which used to hang this script forever. So:
#   * Alias recognition and routing (T2 to T5) is proven WITHOUT attaching, by
#     invoking each form against a NONEXISTENT session. A fast nonzero exit
#     with a missing session error (not "unknown command") proves the form
#     routed to attach-session and returned promptly.
#   * One real attach (T6) is proven by launching the attach in ITS OWN
#     window via Start-Process, then polling list-clients and
#     #{session_attached} from the detached CLI, then tearing down.
#
# Assertions:
#   1. list-commands output shows attach-session with (attach) alias
#   2. `psmux a`              routes to attach-session (missing session error)
#   3. `psmux at`             routes to attach-session (missing session error)
#   4. `psmux attach`         routes to attach-session (missing session error)
#   5. `psmux attach-session` routes to attach-session (missing session error)
#   6. `psmux a -t <live session>` really attaches (own window, list-clients)

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION  = "gap29"
$MISSING  = "no_such_session_gap29_xyz"

$script:Pass = 0
$script:Fail = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:Fail++ }

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 12000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path "$psmuxDir\$Name.port") {
            $raw = (Get-Content "$psmuxDir\$Name.port" -Raw -EA SilentlyContinue)
            if ($raw -and $raw.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$raw.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Cleanup

Write-Host "`n=== Issue #29: attach shortcut (a / at / attach / attach-session) ===" -ForegroundColor Cyan

# T1: list-commands shows the alias
Write-Host "`n[T1] list-commands shows 'attach-session (attach)' alias" -ForegroundColor Yellow
$cmds = & $PSMUX list-commands 2>&1 | Out-String
if ($cmds -match "attach-session\s*\(attach\)") {
    Write-Pass "list-commands: 'attach-session (attach)' present"
} else {
    Write-Fail "list-commands: 'attach-session (attach)' not found. Output: $cmds"
}

# T2 to T5: each shortcut form routes to attach-session, proven WITHOUT
# attaching. We target a session that does not exist: the form must fail fast
# with a missing session error. "unknown command" would mean the alias is not
# wired up; exit 0 or an unrelated error would mean it did not route to
# attach-session.
function Test-AttachFormRouting {
    param([string]$Form)
    $out = & $PSMUX $Form -t $MISSING 2>&1 | Out-String
    $rc  = $LASTEXITCODE
    if ($out -match "unknown command|unrecognized") {
        Write-Fail "'psmux $Form' not recognised as a command: $out"
    } elseif ($rc -ne 0 -and ($out -match [regex]::Escape($MISSING) -or $out -match "can't find|no such|not found|no session")) {
        Write-Pass "'psmux $Form -t $MISSING' routed to attach-session (exit $rc, missing session error)"
    } elseif ($rc -eq 0) {
        Write-Fail "'psmux $Form -t $MISSING' exited 0 for a nonexistent session; expected a fast missing session error. Output: $out"
    } else {
        Write-Fail "'psmux $Form -t $MISSING' exit ${rc} but the error does not mention the missing session: $out"
    }
}

Write-Host "`n[T2] psmux a -t <nonexistent> fails fast with missing session error" -ForegroundColor Yellow
Test-AttachFormRouting "a"

Write-Host "`n[T3] psmux at -t <nonexistent> fails fast with missing session error" -ForegroundColor Yellow
Test-AttachFormRouting "at"

Write-Host "`n[T4] psmux attach -t <nonexistent> fails fast with missing session error" -ForegroundColor Yellow
Test-AttachFormRouting "attach"

Write-Host "`n[T5] psmux attach-session -t <nonexistent> fails fast with missing session error" -ForegroundColor Yellow
Test-AttachFormRouting "attach-session"

# T6: one real attach proof. Launch `psmux a -t <session>` in ITS OWN window
# so it can stay attached without blocking this script, then observe the
# client from the detached CLI.
Write-Host "`n[T6] real attach: psmux a -t $SESSION in its own window" -ForegroundColor Yellow
& $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
$up = Wait-Session $SESSION
if (-not $up) {
    Write-Fail "session $SESSION never came up; cannot run the real attach proof"
} else {
    Start-Sleep -Milliseconds 300
    $p = Start-Process -FilePath $PSMUX -ArgumentList 'a','-t',$SESSION -PassThru
    $attached = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        $att = (& $PSMUX display-message -t $SESSION -p '#{session_attached}' 2>&1) -join ''
        if ($att.Trim() -match '^[1-9]\d*$') { $attached = $true; break }
        $clients = & $PSMUX list-clients -t $SESSION 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $clients.Trim().Length -gt 0 -and $clients -notmatch "error|can't find|no such") {
            $attached = $true; break
        }
        Start-Sleep -Milliseconds 400
    }
    if ($attached) {
        Write-Pass "'psmux a -t $SESSION' produced a live attached client (session_attached / list-clients)"
    } else {
        Write-Fail "no client attached to $SESSION within 15s (attach process exited=$($p.HasExited))"
    }
    # Teardown: never leave the attach process running
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    if ($p -and -not $p.HasExited) {
        $null = $p.WaitForExit(5000)
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue }
    }
}

Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
$failColor = if ($script:Fail -gt 0) { "Red" } else { "Green" }
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $failColor
exit $script:Fail
