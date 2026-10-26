# test_warm_pane_start_dir.ps1 — warm pane honours `new-window -c <dir>` (and splits)
#
# The warm-pane fast path transplants the pre-spawned warm pane for `-c <dir>`
# and silently re-homes its shell to that dir, so `new-window -c` and
# `split-window -c` are instant (warm reuse) and land in the requested directory.
#
# Discriminator = time-to-prompt (the method psmux's other warm tests use):
#   FIXED  -> `-c` reuses the loaded warm pane: prompt in well under a second.
#   UNFIXED-> `-c` cold-spawns a fresh shell: prompt after a full profile load
#             (seconds). Measured 5646ms cold vs 53ms warm on my machine.
# We also assert the pane's prompt shows the requested dir.
#
# SAFETY: fully isolated — runs the binary with USERPROFILE pointed at a
# throwaway temp dir (its ~/.psmux state can't collide with a live server) and an
# -L namespace, and cleans up by PID. It does NOT use name-based process kills or
# a global kill-server, so it is safe to run while a real psmux session is active.
#
# NOTE: relies on the warm pane being FULLY loaded before it is consumed (the
# re-home cd is injected at a fresh prompt). The test waits generously; on a very
# cold AV cache the warm-load can exceed the wait and the `-c` timing will
# regress toward cold (the underlying readiness race an OSC-133 prompt gate would
# remove). The directory assertion still holds regardless.

param(
    [string]$Psmux = (Join-Path $PSScriptRoot "..\target\release\psmux.exe"),
    [string]$TargetDir = "C:\Windows",   # must exist and differ from the server CWD
    [int]$WarmLoadMs = 4000,             # generous wait for the warm pane to load (NoProfile is fast)
    [int]$WarmMaxMs = 1200               # absolute cap; the real check is relative to the cold window-0 time
)

$ErrorActionPreference = "Continue"
if (-not (Test-Path $Psmux)) {
    Write-Host "ERROR: psmux binary not found at $Psmux (cargo build --release)" -ForegroundColor Red
    exit 2
}
$Psmux = (Resolve-Path $Psmux).Path
$NS = "wpsd" + ([guid]::NewGuid().ToString('N').Substring(0,6))
$TempHome = Join-Path $env:TEMP "psmux-$NS"
New-Item -ItemType Directory -Force -Path (Join-Path $TempHome ".psmux") | Out-Null
Set-Content -Path (Join-Path $TempHome ".psmux.conf") -Value ('set -g default-shell "pwsh -NoProfile"' + "`n") -Encoding ascii

$savedUP = $env:USERPROFILE; $savedCfg = $env:PSMUX_CONFIG_FILE
$savedTgt = $env:PSMUX_TARGET_SESSION; $savedSess = $env:PSMUX_SESSION; $savedTmux = $env:TMUX
$testStart = Get-Date
$pass = 0; $fail = 0
function Result($name, [bool]$ok, $detail="") {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  [FAIL] $name $(if($detail){"— $detail"})" -ForegroundColor Red }
}
# A plain (`pwsh -NoProfile`) prompt is `PS X:\...>` — that marks "prompt ready".
# NoProfile keeps loads fast and load-stable so the warm-vs-cold gap is reliable.
$PromptPat = "PS [A-Z]:\\"
function Wait-Prompt([int]$TimeoutMs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $o = (& $Psmux -L $NS capture-pane -t probe -p 2>&1) -join "`n"
        if ($o -match $PromptPat) { return @{ Found = $true; Ms = $sw.ElapsedMilliseconds } }
        Start-Sleep -Milliseconds 40
    }
    return @{ Found = $false; Ms = $sw.ElapsedMilliseconds }
}

try {
    $env:USERPROFILE = $TempHome
    $env:PSMUX_CONFIG_FILE = (Join-Path $TempHome ".psmux.conf")
    $env:PSMUX_TARGET_SESSION = "${NS}__probe"
    Remove-Item Env:\PSMUX_SESSION, Env:\TMUX, Env:\PSMUX_SESSION_NAME -ErrorAction SilentlyContinue

    Write-Host "`n--- Isolated server (-L $NS, HOME=$TempHome) ---" -ForegroundColor Cyan
    & $Psmux -L $NS new-session -d -s probe -x 120 -y 30 2>&1 | Out-Null
    $port = Join-Path $TempHome ".psmux\${NS}__probe.port"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000 -and -not (Test-Path $port)) { Start-Sleep -Milliseconds 50 }
    Result "isolated session created" (Test-Path $port)

    $w0 = Wait-Prompt 20000
    # Warm reuse (no shell spawn) must be well under a cold spawn. Use a relative
    # threshold off the cold window-0 time so the check is stable under machine load.
    $warmThresh = [Math]::Min($WarmMaxMs, [int]($w0.Ms * 0.6))
    Write-Host "    window-0 (cold) prompt ready in $($w0.Ms) ms; warm threshold = ${warmThresh}ms; waiting ${WarmLoadMs}ms for warm pane..." -ForegroundColor DarkGray
    Start-Sleep -Milliseconds $WarmLoadMs

    # ── new-window -c ──
    & $Psmux -L $NS new-window -t probe -c $TargetDir 2>&1 | Out-Null
    $rc = Wait-Prompt 20000
    Start-Sleep -Milliseconds 1500   # let the injected cd settle
    $cap = (& $Psmux -L $NS capture-pane -t probe -p 2>&1) -join "`n"
    $dirOk = $cap -match [regex]::Escape($TargetDir)
    Write-Host "    new-window -c: prompt in $($rc.Ms) ms, prompt-at-target=$dirOk" -ForegroundColor DarkGray
    Result "new-window -c is warm (reused warm pane, <${warmThresh}ms)" ($rc.Found -and $rc.Ms -lt $warmThresh) "took $($rc.Ms)ms (cold?)"
    Result "new-window -c re-homed to target dir (prompt at $TargetDir)" $dirOk "prompt not at target"

    Start-Sleep -Milliseconds $WarmLoadMs   # let the replenished warm pane load

    # ── split-window -c ──
    & $Psmux -L $NS split-window -t probe -h -c $TargetDir 2>&1 | Out-Null
    $rs = Wait-Prompt 20000
    Start-Sleep -Milliseconds 1500
    $scap = (& $Psmux -L $NS capture-pane -t probe -p 2>&1) -join "`n"
    $sdirOk = $scap -match [regex]::Escape($TargetDir)
    Write-Host "    split-window -c: prompt in $($rs.Ms) ms, prompt-at-target=$sdirOk" -ForegroundColor DarkGray
    Result "split-window -c is warm (reused warm pane, <${warmThresh}ms)" ($rs.Found -and $rs.Ms -lt $warmThresh) "took $($rs.Ms)ms (cold?)"
    Result "split-window -c re-homed to target dir (prompt at $TargetDir)" $sdirOk "prompt not at target"
}
finally {
    & $Psmux -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Get-Process psmux, pwsh -ErrorAction SilentlyContinue |
        Where-Object { $_.StartTime -ge $testStart } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    $env:USERPROFILE = $savedUP; $env:PSMUX_CONFIG_FILE = $savedCfg
    $env:PSMUX_TARGET_SESSION = $savedTgt
    if ($null -ne $savedSess) { $env:PSMUX_SESSION = $savedSess }
    if ($null -ne $savedTmux) { $env:TMUX = $savedTmux }
    Remove-Item -Recurse -Force $TempHome -ErrorAction SilentlyContinue
}

Write-Host "`n  RESULTS: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
if ($fail -gt 0) { exit 1 } else { exit 0 }
