# Issue #55: psmux should refuse to start a new session when already inside one
# Fix: checks PSMUX_ACTIVE=1 or PSMUX_SESSION=<non-empty>; prints
#      "psmux: sessions should be nested with care, unset PSMUX_SESSION to force"
#      and exits without spawning anything.
#
# Guard locations in main.rs:
#   PATH A (bare psmux / TUI): the nesting guard fires before any TUI or session is
#     spawned, even for a non-tty subprocess. Bare psmux with PSMUX_ACTIVE=1 or
#     PSMUX_SESSION set prints the "nested with care" warning and refuses,
#     mirroring tmux's nested-session refusal.
#   PATH B (new-session command): applied after flag parsing;
#     always reachable. Per issue #424 the guard only fires for an ATTACHING
#     new-session (no -d). A detached `new-session -d` is allowed nested because it
#     never grabs the current terminal (see tests/test_issue424_proof.ps1).
#
# Tests (T1/T2 use the ATTACHING form, no -d, which is the case the guard blocks):
#   T1. PSMUX_ACTIVE=1   + new-session -s gap55_a  => warning on stderr, session NOT created
#   T2. PSMUX_SESSION=x  + new-session -s gap55_b  => warning on stderr, session NOT created
#   T3. PSMUX_ACTIVE=1   + bare psmux (non-tty subprocess) => nesting guard fires
#       (tmux parity: refuses to nest);
#       assert: exits <5s AND no nested session file created AND guard warning printed
#   T4. PSMUX_ALLOW_NESTING=1 + PSMUX_ACTIVE=1 + new-session => guard bypassed, session created
#   T5. Clean env + new-session -d -s gap55_ok         => no warning, session created

$ErrorActionPreference = "Continue"
$PSMUX    = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

$script:Pass = 0
$script:Fail = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green;  $script:Pass++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:Fail++ }

function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 12000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -EA SilentlyContinue)
            if ($port -and $port.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Session-Exists {
    param([string]$Name)
    $pf = "$psmuxDir\$Name.port"
    if (-not (Test-Path $pf)) { return $false }
    $port = (Get-Content $pf -Raw -EA SilentlyContinue).Trim()
    if (-not ($port -match '^\d+$')) { return $false }
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.Close(); return $true
    } catch { return $false }
}

function Cleanup {
    foreach ($s in @("gap55_a","gap55_b","gap55_ok","gap55_allow")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 500
    foreach ($s in @("gap55_a","gap55_b","gap55_ok","gap55_allow")) {
        Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    }
}

Write-Host "`n=== Issue #55: Prevent nested psmux sessions ===" -ForegroundColor Cyan

Cleanup
Start-Sleep -Milliseconds 300

# -----------------------------------------------------------------------
# T1: PSMUX_ACTIVE=1 blocks new-session (PATH B guard)
# -----------------------------------------------------------------------
Write-Host "`n[Test 1] PSMUX_ACTIVE=1 blocks attaching new-session" -ForegroundColor Yellow

$env:PSMUX_ACTIVE = "1"
Remove-Item Env:PSMUX_SESSION       -EA SilentlyContinue
Remove-Item Env:PSMUX_ALLOW_NESTING -EA SilentlyContinue

# Attaching form (no -d): this is what the guard blocks per issue #424.
$out1     = & $PSMUX new-session -s gap55_a 2>&1 | Out-String
$created1 = Session-Exists "gap55_a"

Write-Host "  output:          $($out1.Trim())"
Write-Host "  session created: $created1"

if ($out1 -match "nested with care") { Write-Pass "T1: PSMUX_ACTIVE=1 printed nesting warning" }
else { Write-Fail "T1: no warning printed (got: '$($out1.Trim())')" }

if (-not $created1) { Write-Pass "T1: session gap55_a NOT created (guard blocked it)" }
else                 { Write-Fail "T1: session gap55_a WAS created despite PSMUX_ACTIVE=1" }

Remove-Item Env:PSMUX_ACTIVE -EA SilentlyContinue

# -----------------------------------------------------------------------
# T2: PSMUX_SESSION=<non-empty> blocks new-session (PATH B guard)
# -----------------------------------------------------------------------
Write-Host "`n[Test 2] PSMUX_SESSION=running blocks attaching new-session" -ForegroundColor Yellow

$env:PSMUX_SESSION = "running"
Remove-Item Env:PSMUX_ACTIVE        -EA SilentlyContinue
Remove-Item Env:PSMUX_ALLOW_NESTING -EA SilentlyContinue

# Attaching form (no -d): this is what the guard blocks per issue #424.
$out2     = & $PSMUX new-session -s gap55_b 2>&1 | Out-String
$created2 = Session-Exists "gap55_b"

Write-Host "  output:          $($out2.Trim())"
Write-Host "  session created: $created2"

if ($out2 -match "nested with care") { Write-Pass "T2: PSMUX_SESSION set printed nesting warning" }
else { Write-Fail "T2: no warning printed (got: '$($out2.Trim())')" }

if (-not $created2) { Write-Pass "T2: session gap55_b NOT created (guard blocked it)" }
else                 { Write-Fail "T2: session gap55_b WAS created despite PSMUX_SESSION being set" }

Remove-Item Env:PSMUX_SESSION -EA SilentlyContinue

# -----------------------------------------------------------------------
# T3: Bare `psmux` subprocess (non-tty) with PSMUX_ACTIVE=1
#
# The bare-TUI PATH A nesting guard fires even for a non-tty subprocess:
# psmux refuses to nest and prints
#   "psmux: sessions should be nested with care, unset PSMUX_SESSION to force"
# mirroring tmux's nested-session refusal (tmux exits nonzero with the same
# style of warning when $TMUX is set).
#
# What we assert here:
#   (a) Process exits quickly (does not hang as TUI)       => no nested TUI spawned
#   (b) No gap55_tui session file appears                  => no nested server created
#   (c) Output contains the nesting-guard warning          => guard fired (tmux parity)
# -----------------------------------------------------------------------
Write-Host "`n[Test 3] Bare 'psmux' + PSMUX_ACTIVE=1 (non-tty): guard fires, no session spawned" -ForegroundColor Yellow
Write-Host "  (PATH A guard fires before TUI/session spawn, tmux nested-session parity)" -ForegroundColor DarkGray

$env:PSMUX_ACTIVE  = "1"
$env:PSMUX_NO_WARM = "1"
Remove-Item Env:PSMUX_ALLOW_NESTING -EA SilentlyContinue

# Snapshot gap55_* port files before — only those would represent a nested session from this test
$gap55Before = (Get-ChildItem "$psmuxDir\gap55_*.port" -EA SilentlyContinue).Count

$sw3  = [System.Diagnostics.Stopwatch]::StartNew()
$out3 = & $PSMUX 2>&1 | Out-String
$exit3 = $LASTEXITCODE
$sw3.Stop()
$elapsed3ms = $sw3.ElapsedMilliseconds

$gap55After = (Get-ChildItem "$psmuxDir\gap55_*.port" -EA SilentlyContinue).Count

Write-Host "  output:          '$($out3.Trim())'"
Write-Host "  exit code:       $exit3"
Write-Host "  elapsed ms:      $elapsed3ms"
Write-Host "  gap55_* port files before/after: $gap55Before / $gap55After"

if ($elapsed3ms -lt 5000) { Write-Pass "T3: bare psmux (non-tty) exited in ${elapsed3ms}ms (no TUI blocked on tty)" }
else                       { Write-Fail "T3: bare psmux took ${elapsed3ms}ms (expected <5000)" }

if ($gap55After -le $gap55Before) { Write-Pass "T3: no new gap55_* session port file created (no nested session)" }
else                               { Write-Fail "T3: $($gap55After - $gap55Before) new gap55_* port file(s), nested session was created" }

if ($out3 -match "nested with care") { Write-Pass "T3: nesting-guard warning printed for bare psmux (tmux parity, exit=$exit3)" }
else                                  { Write-Fail "T3: expected nesting-guard warning, got: '$($out3.Trim())' (exit=$exit3)" }

Remove-Item Env:PSMUX_ACTIVE  -EA SilentlyContinue
Remove-Item Env:PSMUX_NO_WARM -EA SilentlyContinue

# -----------------------------------------------------------------------
# T4: PSMUX_ALLOW_NESTING=1 bypasses the guard
# -----------------------------------------------------------------------
Write-Host "`n[Test 4] PSMUX_ALLOW_NESTING=1 lets new-session through despite PSMUX_ACTIVE=1" -ForegroundColor Yellow

$env:PSMUX_ACTIVE        = "1"
$env:PSMUX_ALLOW_NESTING = "1"
Remove-Item Env:PSMUX_SESSION -EA SilentlyContinue

& $PSMUX new-session -d -s gap55_allow 2>&1 | Out-Null
$allowCreated = Wait-Session "gap55_allow"

Write-Host "  session gap55_allow created: $allowCreated"
if ($allowCreated) { Write-Pass "T4: PSMUX_ALLOW_NESTING=1 bypassed guard, session created" }
else               { Write-Fail "T4: PSMUX_ALLOW_NESTING=1 set but session not created" }

Remove-Item Env:PSMUX_ACTIVE        -EA SilentlyContinue
Remove-Item Env:PSMUX_ALLOW_NESTING -EA SilentlyContinue

# -----------------------------------------------------------------------
# T5: Clean env — no guard vars — new-session works normally
# -----------------------------------------------------------------------
Write-Host "`n[Test 5] Clean env allows new-session with no warning" -ForegroundColor Yellow

Remove-Item Env:PSMUX_ACTIVE        -EA SilentlyContinue
Remove-Item Env:PSMUX_SESSION       -EA SilentlyContinue
Remove-Item Env:PSMUX_ALLOW_NESTING -EA SilentlyContinue

$out5      = & $PSMUX new-session -d -s gap55_ok 2>&1 | Out-String
$okCreated = Wait-Session "gap55_ok"

Write-Host "  output:          $($out5.Trim())"
Write-Host "  session created: $okCreated"

if ($out5 -notmatch "nested with care") { Write-Pass "T5: clean env produced no nesting warning" }
else                                     { Write-Fail "T5: clean env printed nesting warning (false positive)" }

if ($okCreated) { Write-Pass "T5: session gap55_ok created normally" }
else             { Write-Fail "T5: session gap55_ok NOT created in clean env" }

Cleanup

Write-Host "`n=== Issue #55 Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) {"Red"} else {"Green"})
exit $script:Fail
