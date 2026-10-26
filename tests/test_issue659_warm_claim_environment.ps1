# Issue #659: "warm server claimed by a new session keeps the spawner's
# environment (plugins then cannot find psmux.exe)".
#
# WHAT WAS REPRODUCED (psmux 3.3.8, master e70323c, unmodified installed binary)
#
#   A standby is spawned by whatever needs a server first. Claiming it only
#   renames the session, so the standby keeps the environment of its spawner
#   for life, and every run-shell child the SERVER starts inherits it:
#
#     seed shell   PATH without the psmux dir, POISON=seed
#     claim shell  PATH with the psmux dir,    POISON=client
#
#     claimed session pid == standby pid          (the claim really happened)
#     server side run-shell child:
#         resolved=NOT_FOUND count=0 marker=POISONED seedvar=seed_value clientvar=
#
#   That is the reported failure: every shipped plugin resolves the binary with
#   `Get-Command psmux`, so in such a session none of them run, and psmux shows
#   the "not recognized as the name of a cmdlet" output in a modal popup.
#
#   Note the reporter's literal recipe (`psmux run-shell '...'` from a normal
#   shell) does NOT reproduce it: the CLI runs a run-shell without `#{` itself,
#   in the CLIENT process (src/main.rs, "run-shell" arm), so it reports the
#   client's own healthy PATH. The failure needs a run-shell the SERVER starts:
#   a hook, a key binding, a plugin, or any command containing `#{`.
#
# tmux PARITY
#
#   tmux fills its server wide base environment once, from whoever started the
#   server (tmux.c:418-422), and never refreshes it; a session environment is
#   seeded from it and refreshed from the CLIENT for the `update-environment`
#   list only (environ.c:186 environ_update, cmd-new-session.c:283,
#   cmd-attach-session.c:135). Jobs - which is what run-shell is - are spawned
#   with environ_for_session (job.c), i.e. base plus session environment.
#
#   In tmux the server is ALWAYS started by a real client, so "the server's
#   environment is some user shell's" holds. psmux's warm pool is the part tmux
#   does not have: it breaks that invariant. psmux's own cold path keeps it
#   (platform.rs spawn_server_hidden passes a null lpEnvironment, so a cold
#   spawned server inherits the client's block verbatim), so the fix is for a
#   claimed standby to adopt the claiming client's environment - exactly what a
#   cold spawn would have given it.
#
# WHAT THIS SUITE PINS
#   * the claim really lands on the parked standby (pid identity)
#   * a server side run-shell child sees the CLAIMING client's PATH
#   * a variable only the claiming client had reaches that child
#   * a variable only the standby's spawner had is gone from that child
#   * the child can resolve the psmux binary
#   * a window created after the claim gets the claiming client's environment
#   * the claiming client's cwd is still honoured (#{pane_current_path})
#
# Set PSMUX_TEST_BIN to test a non-installed binary.
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue659_warm_claim_environment.ps1

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else {
    $local = Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue
    if ($local) { $local.Path } else { (Get-Command psmux -EA Stop).Source }
}
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

# Inherited routing would aim every call at somebody else's server.
foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX_TARGET_SESSION') {
    Set-Item -Path "env:$v" -Value $null -EA SilentlyContinue
}

$NS        = "e659"                       # isolated namespace, never the default one
$PSMUX_DIR = Split-Path $PSMUX -Parent
$DATA      = Join-Path $env:USERPROFILE ".psmux"
$rig       = Join-Path $env:TEMP ("psmux659-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$seedCwd   = Join-Path $rig 'seed'
$clientCwd = Join-Path $rig 'client'
$probe     = Join-Path $rig 'probe.ps1'
$report    = Join-Path $rig 'report.txt'
# A directory only the claiming shell has on PATH. Unlike the psmux directory
# it cannot be supplied by anything else, so seeing it in the child proves the
# CLIENT's PATH is what the server is running with.
$CLIENT_DIR = Join-Path $rig 'client-only-bin'
New-Item -ItemType Directory -Force -Path $rig, $seedCwd, $clientCwd, $CLIENT_DIR | Out-Null

function Norm([string]$p) { return $p.TrimEnd([char[]]("\", "/")) }

@'
param([string]$Tag, [string]$Out, [string]$PsmuxDir, [string]$ClientDir)
$entries = @($env:PATH -split ';')
function Count-Entry([string]$dir) {
    return @($entries | Where-Object { $_.TrimEnd([char[]]("\", "/")) -ieq $dir.TrimEnd([char[]]("\", "/")) }).Count
}
$found = Get-Command psmux -ErrorAction SilentlyContinue
$resolved  = if ($found) { $found.Source } else { "NOT_FOUND" }
$psmuxSeen = Count-Entry $PsmuxDir
$clientSeen = Count-Entry $ClientDir
$lines = @(
    "tag=$Tag",
    "resolved=$resolved",
    "psmuxdir=$psmuxSeen",
    "clientdir=$clientSeen",
    "seedvar=$env:PSMUX659_SEED",
    "clientvar=$env:PSMUX659_CLIENT"
)
Add-Content -LiteralPath $Out -Value $lines
'@ | Set-Content -LiteralPath $probe -Encoding UTF8

function Cleanup {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    Remove-Item "$DATA\$NS`_*" -Force -EA SilentlyContinue
    Remove-Item "$DATA\$NS`__*" -Force -EA SilentlyContinue
}

# A standby is only claimable once its .port beacon is on disk; a claim sent
# before that cold spawns instead and would not exercise this code path at all.
function Wait-Standby([int]$TimeoutMs = 12000) {
    $port = Join-Path $DATA "$($NS)____warm__.port"
    $pidf = Join-Path $DATA "$($NS)____warm__.pid"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Test-Path $port) -and (Test-Path $pidf)) {
            $raw = (Get-Content $pidf -Raw -EA SilentlyContinue)
            if ($raw) {
                $id = ($raw.Trim() -split ':')[0]
                if ($id -and (Get-Process -Id ([int]$id) -EA SilentlyContinue)) { return $id }
            }
        }
        Start-Sleep -Milliseconds 150
    }
    return ''
}

function Read-Report([string]$Tag) {
    if (-not (Test-Path $report)) { return $null }
    $cur = @{}; $out = $null
    foreach ($line in Get-Content -LiteralPath $report) {
        $kv = $line -split '=', 2
        if ($kv.Count -ne 2) { continue }
        if ($kv[0] -eq 'tag') { $cur = @{}; $cur['tag'] = $kv[1] }
        else { $cur[$kv[0]] = $kv[1] }
        if ($cur['tag'] -eq $Tag -and $cur.ContainsKey('clientvar')) { $out = $cur.Clone() }
    }
    return $out
}

# Run a script in its own pwsh with a given PATH / marker, and wait for it.
function Invoke-InShell([string]$Body) {
    $f = Join-Path $rig ("shell-" + [guid]::NewGuid().ToString('N').Substring(0,6) + ".ps1")
    Set-Content -LiteralPath $f -Value $Body -Encoding UTF8
    pwsh -NoProfile -ExecutionPolicy Bypass -File $f | Out-Null
}

try {

Cleanup
Remove-Item $report -Force -EA SilentlyContinue

# ── 1. park a standby whose environment is deliberately wrong ───────────────
$seedPath = (@($env:PATH -split ';' | Where-Object { (Norm $_) -ine (Norm $PSMUX_DIR) }) -join ';')
Invoke-InShell @"
Set-Location '$seedCwd'
`$env:PATH = '$seedPath'
`$env:PSMUX659_SEED = 'seed_value'
`$env:PSMUX659_CLIENT = `$null
& '$PSMUX' -L $NS new-session -d -s seed
"@
$warmPid = Wait-Standby
if ($warmPid) {
    Write-Pass "a warm standby was parked by the seed shell (pid $warmPid)"
} else {
    Write-Skip "no standby was parked (warm pool disabled on this box?) - nothing to claim"
}

# Drop the seed session; the standby stays.
& $PSMUX -L $NS kill-session -t seed 2>&1 | Out-Null
$warmPid2 = Wait-Standby
if (-not $warmPid2) { $warmPid2 = $warmPid }

# ── 2. claim it from a shell with a healthy, DIFFERENT environment ──────────
Invoke-InShell @"
Set-Location '$clientCwd'
`$env:PATH = '$CLIENT_DIR;' + '$env:PATH'
`$env:PSMUX659_CLIENT = 'client_value'
`$env:PSMUX659_SEED = `$null
& '$PSMUX' -L $NS new-session -d -s claimed
"@
Start-Sleep -Milliseconds 1500

$sessPid = (& $PSMUX -L $NS display-message -t claimed -p '#{pid}' 2>&1 | Out-String).Trim()
if ($warmPid2 -and $sessPid -eq $warmPid2) {
    Write-Pass "the new session claimed the parked standby (pid $sessPid)"
} else {
    Write-Skip "the new session cold spawned (session pid '$sessPid', standby '$warmPid2') - the claim path was not exercised"
}

# ── 3. a run-shell the SERVER runs (the plugin path) ────────────────────────
# `#{pane_id}` is what routes a run-shell through the server instead of letting
# the CLI run it in the client process.
$probeCmd = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$probe`" HOOK `"$report`" `"$PSMUX_DIR`" `"$CLIENT_DIR`" #{pane_id}"
& $PSMUX -L $NS run-shell -b $probeCmd 2>&1 | Out-Null

$deadline = [DateTime]::Now.AddSeconds(30)
while (-not (Read-Report 'HOOK') -and [DateTime]::Now -lt $deadline) { Start-Sleep -Milliseconds 300 }
$r = Read-Report 'HOOK'

if (-not $r) {
    Write-Fail "the server side run-shell child never reported back"
} else {
    Write-Info ("child: resolved={0} psmuxdir={1} clientdir={2} seedvar='{3}' clientvar='{4}'" -f `
        $r['resolved'], $r['psmuxdir'], $r['clientdir'], $r['seedvar'], $r['clientvar'])

    if ($r['clientdir'] -eq '1') {
        Write-Pass "the child PATH carries the claiming client's own directory"
    } else {
        Write-Fail "the child PATH has no entry for $CLIENT_DIR (clientdir=$($r['clientdir'])) - the server is still running with the standby's PATH"
    }

    if ($r['clientvar'] -eq 'client_value') {
        Write-Pass "a variable only the claiming client had reached the child"
    } else {
        Write-Fail "PSMUX659_CLIENT is '$($r['clientvar'])', expected 'client_value'"
    }

    if ([string]::IsNullOrEmpty($r['seedvar'])) {
        Write-Pass "the standby spawner's variable is gone from the child"
    } else {
        Write-Fail "PSMUX659_SEED is still '$($r['seedvar'])' - the standby's environment outlived the claim"
    }

    if ($r['resolved'] -and $r['resolved'] -ne 'NOT_FOUND') {
        Write-Pass "the child can resolve psmux ($($r['resolved'])) - plugins work in this session"
    } else {
        Write-Fail "the child cannot resolve psmux, which is what breaks every shipped plugin"
    }
}

# ── 4. the claiming client's cwd is still honoured (no regression) ──────────
# Read it BEFORE creating another window: #{pane_current_path} without a pane
# target follows the ACTIVE pane, which a new window would take over.
$pcp = (& $PSMUX -L $NS display-message -t claimed:0.0 -p '#{pane_current_path}' 2>&1 | Out-String).Trim()
if ((Norm $pcp) -ieq (Norm $clientCwd)) {
    Write-Pass "the claimed session re-homed to the claiming client's cwd"
} else {
    Write-Fail "#{pane_current_path} is '$pcp', expected '$clientCwd'"
}

# ── 5. a pane created AFTER the claim ───────────────────────────────────────
& $PSMUX -L $NS new-window -t claimed 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500
& $PSMUX -L $NS send-keys -t claimed:1.0 "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$probe`" PANE `"$report`" `"$PSMUX_DIR`" `"$CLIENT_DIR`"" Enter 2>&1 | Out-Null
$deadline = [DateTime]::Now.AddSeconds(30)
while (-not (Read-Report 'PANE') -and [DateTime]::Now -lt $deadline) { Start-Sleep -Milliseconds 300 }
$p = Read-Report 'PANE'
if (-not $p) {
    Write-Fail "the pane created after the claim never reported back"
} else {
    Write-Info ("pane: seedvar='{0}' clientvar='{1}'" -f $p['seedvar'], $p['clientvar'])
    if ($p['clientvar'] -eq 'client_value' -and [string]::IsNullOrEmpty($p['seedvar'])) {
        Write-Pass "a window created after the claim inherits the claiming client's environment"
    } else {
        Write-Fail "a window created after the claim still carries the standby's environment (seedvar='$($p['seedvar'])' clientvar='$($p['clientvar'])')"
    }
}

}
finally {
    Cleanup
    Remove-Item -LiteralPath $rig -Recurse -Force -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed:  $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:Skip)" -ForegroundColor Yellow
exit $script:Fail
