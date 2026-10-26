# PR #591: the PROC_THREAD_ATTRIBUTE_LIST buffer handed to
# InitializeProcThreadAttributeList is now `vec![0; bytes_required]` instead
# of `Vec::with_capacity` + `unsafe set_len`. Every ConPTY child spawn goes
# through that buffer, so this script proves each spawn path still produces a
# live child with a rendered prompt / output:
#   new-session -d, split-window -h, split-window -v, new-window,
#   respawn-pane -k, `new-window -- cmd /c echo hi` (direct exec), and
#   new-session -d -x 200 -y 50.
#
# Binary: $env:PSMUX_EXE if set, else `psmux` on PATH.
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_EXE) { $env:PSMUX_EXE } else { (Get-Command psmux -EA Stop).Source }
$env:PSMUX_NO_WARM = "1"
$env:NO_COLOR = $null
$S = "p591_spawn"
$BIG = "p591_big"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

function Wait-Prompt([string]$target, [int]$timeoutMs = 15000) {
    # Poll capture-pane until a shell prompt or command output is visible.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $cap = (& $PSMUX capture-pane -p -t $target 2>$null) -join "`n"
        if ($cap -match '(PS [^\r\n]*>|\$ ?$|C:\\[^\r\n]*>)') { return $cap }
        Start-Sleep -Milliseconds 100
    }
    return (& $PSMUX capture-pane -p -t $target 2>$null) -join "`n"
}
function Wait-Text([string]$target, [string]$pattern, [int]$timeoutMs = 15000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $cap = (& $PSMUX capture-pane -p -t $target 2>$null) -join "`n"
        if ($cap -match $pattern) { return $cap }
        Start-Sleep -Milliseconds 100
    }
    return (& $PSMUX capture-pane -p -t $target 2>$null) -join "`n"
}
function Get-PaneInfo([string]$target) {
    $line = (& $PSMUX display-message -p -t $target '#{pane_id}|#{pane_pid}|#{pane_current_command}|#{pane_dead}|#{pane_width}x#{pane_height}' 2>$null)
    $f = "$line".Trim().Split('|')
    [pscustomobject]@{ id = $f[0]; pid = $f[1]; cmd = $f[2]; dead = $f[3]; size = $f[4]; raw = "$line".Trim() }
}
function Assert-LivePane([string]$label, [string]$target, [string]$capture) {
    $info = Get-PaneInfo $target
    $alive = $false
    if ($info.pid -match '^\d+$' -and [int]$info.pid -gt 0) {
        $alive = [bool](Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue)
    }
    $firstLine = ($capture -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
    if ($alive -and $capture.Trim().Length -gt 0) {
        Write-Pass "$label -> $($info.raw) live=$alive text=[$firstLine]"
    } else {
        Write-Fail "$label -> $($info.raw) live=$alive text=[$firstLine]"
    }
}

Write-Host "`n=== PR #591: ConPTY spawn paths with zeroed attribute list ($PSMUX) ===" -ForegroundColor Cyan
Write-Host "binary: $(& $PSMUX -V)"
& $PSMUX kill-session -t $S 2>&1 | Out-Null
& $PSMUX kill-session -t $BIG 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# --- Arm 1: new-session -d ---
Write-Host "[Arm 1] new-session -d" -ForegroundColor Yellow
& $PSMUX new-session -d -s $S
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "new-session -d failed"; exit 1 }
$cap = Wait-Prompt "${S}:0.0"
Assert-LivePane "new-session pane" "${S}:0.0" $cap

# --- Arm 2: split-window -h / -v ---
Write-Host "[Arm 2] split-window -h and -v" -ForegroundColor Yellow
& $PSMUX split-window -h -t "${S}:0"
$cap = Wait-Prompt "${S}:0.1"
Assert-LivePane "split -h pane" "${S}:0.1" $cap
& $PSMUX split-window -v -t "${S}:0.1"
$cap = Wait-Prompt "${S}:0.2"
Assert-LivePane "split -v pane" "${S}:0.2" $cap
$panes = (& $PSMUX list-panes -t "${S}:0" -F '#{pane_index}:#{pane_pid}') -join ' '
if (($panes -split ' ').Count -eq 3) { Write-Pass "window 0 has 3 panes: $panes" } else { Write-Fail "expected 3 panes: $panes" }

# --- Arm 3: new-window ---
Write-Host "[Arm 3] new-window" -ForegroundColor Yellow
& $PSMUX new-window -t $S -n nw
$cap = Wait-Prompt "${S}:nw"
Assert-LivePane "new-window pane" "${S}:nw" $cap

# --- Arm 4: respawn-pane -k (kills and re-spawns through the attribute list) ---
Write-Host "[Arm 4] respawn-pane -k" -ForegroundColor Yellow
$before = Get-PaneInfo "${S}:nw"
& $PSMUX respawn-pane -k -t "${S}:nw"
Start-Sleep -Milliseconds 300
$cap = Wait-Prompt "${S}:nw"
$after = Get-PaneInfo "${S}:nw"
Assert-LivePane "respawned pane" "${S}:nw" $cap
if ($before.pid -ne $after.pid -and $after.pid -match '^\d+$') { Write-Pass "respawn changed pane_pid $($before.pid) -> $($after.pid)" }
else { Write-Fail "respawn pane_pid unchanged or blank: before=$($before.pid) after=$($after.pid)" }
if (-not (Get-Process -Id ([int]$before.pid) -ErrorAction SilentlyContinue)) { Write-Pass "old pid $($before.pid) is gone" }
else { Write-Fail "old pid $($before.pid) still alive after respawn -k" }

# --- Arm 5: window running `cmd /c echo hi` via -- (direct exec) ---
Write-Host "[Arm 5] new-window -- cmd /c echo hi" -ForegroundColor Yellow
& $PSMUX set-option -t $S remain-on-exit on | Out-Null
& $PSMUX new-window -t $S -n echo -- cmd /c echo hi
$cap = Wait-Text "${S}:echo" 'hi'
$info = Get-PaneInfo "${S}:echo"
if ($cap -match '(^|\n)hi\s*(\n|$)') { Write-Pass "direct-exec window printed 'hi' (pane: $($info.raw))" }
else { Write-Fail "direct-exec window did not print hi: [$cap] pane: $($info.raw)" }
# A long-lived direct exec so pane_pid can be checked as a live process too.
& $PSMUX new-window -t $S -n echolive -- cmd /c "echo hi && ping -n 60 127.0.0.1 >nul"
$cap = Wait-Text "${S}:echolive" 'hi'
$info = Get-PaneInfo "${S}:echolive"
$alive = ($info.pid -match '^\d+$') -and [bool](Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue)
if ($cap -match 'hi' -and $alive -and $info.cmd -match 'ping|cmd') { Write-Pass "direct-exec long-lived window: $($info.raw) live=$alive" }
else { Write-Fail "direct-exec long-lived window: $($info.raw) live=$alive cap=[$cap]" }
& $PSMUX set-option -t $S remain-on-exit off | Out-Null

# --- Arm 6: new-session -d -s p591_big -x 200 -y 50 ---
Write-Host "[Arm 6] new-session -d -x 200 -y 50" -ForegroundColor Yellow
& $PSMUX new-session -d -s $BIG -x 200 -y 50
$cap = Wait-Prompt "${BIG}:0.0"
Assert-LivePane "200x50 session pane" "${BIG}:0.0" $cap
$sz = (& $PSMUX display-message -p -t "${BIG}:0.0" '#{window_width}x#{window_height}').Trim()
if ($sz -eq '200x50') { Write-Pass "window size is 200x50" } else { Write-Fail "window size is $sz, expected 200x50" }

# --- Arm 7: every pane in both sessions has a live pane_pid ---
Write-Host "[Arm 7] every pane_pid is a live process" -ForegroundColor Yellow
$all = & $PSMUX list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_dead}|#{pane_current_command}' 2>$null |
    Where-Object { $_ -like 'p591_spawn:*' -or $_ -like 'p591_big:*' }
$bad = 0
foreach ($row in $all) {
    $f = $row.Split('|')
    if ($f[2] -eq '1') { Write-Host "    (dead by design: $row)"; continue }
    $ok = ($f[1] -match '^\d+$') -and [bool](Get-Process -Id ([int]$f[1]) -ErrorAction SilentlyContinue)
    Write-Host "    $row live=$ok"
    if (-not $ok) { $bad++ }
}
if ($all.Count -ge 7 -and $bad -eq 0) { Write-Pass "$($all.Count) panes listed, all non-dead panes have live pids" }
else { Write-Fail "$($all.Count) panes listed, $bad without a live pid" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
& $PSMUX kill-session -t $BIG 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Pass "sessions cleaned up" } else { Write-Fail "session $S still present" }

Write-Host "`nResults: $($script:TestsPassed) passed, $($script:TestsFailed) failed" -ForegroundColor Cyan
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
