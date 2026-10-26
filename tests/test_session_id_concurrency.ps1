# Root-cause regression test for the flaky `session_id_is_unique`:
# allocate_session_id did a non-atomic read-modify-write on the shared
# `.psmux/next_session_id` counter, so sessions created concurrently (each in
# its own server process) could be handed the SAME tmux session id ($N).
# This drives several concurrent `new-session` calls and asserts every
# resulting #{session_id} is distinct.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$dir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$N = 8
$names = 0..($N-1) | ForEach-Object { "sidrace_$_" }
foreach ($s in $names) { & $PSMUX kill-session -t $s 2>&1 | Out-Null; Remove-Item "$dir\$s.*" -Force -EA SilentlyContinue }
Start-Sleep -Milliseconds 500

Write-Host "`n=== Concurrent session_id uniqueness ($N sessions) ===" -ForegroundColor Cyan

# Fire all new-session calls as concurrently as possible (each a separate process)
# so their allocate_session_id() calls overlap - the exact race the fix closes.
$procs = foreach ($s in $names) {
    Start-Process -FilePath $PSMUX -ArgumentList "new-session","-d","-s",$s -PassThru -WindowStyle Hidden
}

# Poll each session up to 20s (8 simultaneous cold starts contend for CPU).
$ids = @()
$started = 0
foreach ($s in $names) {
    $up = $false
    for ($i = 0; $i -lt 80; $i++) {
        & $PSMUX has-session -t $s 2>$null
        if ($LASTEXITCODE -eq 0) { $up = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if ($up) {
        $started++
        $id = (& $PSMUX display-message -t $s -p '#{session_id}' 2>&1).Trim()
        $ids += $id
        Write-Host "  $s -> session_id=$id"
    } else {
        Write-Host "  $s did not start within 20s (startup contention, not an id issue)" -ForegroundColor DarkYellow
    }
}

# The real assertion: every session that started got a DISTINCT id.
$unique = ($ids | Sort-Object -Unique).Count
if ($started -ge 2 -and $unique -eq $ids.Count) {
    Write-Pass "$($ids.Count) concurrently-created sessions all got distinct session_id values"
} else {
    Write-Fail "DUPLICATE session_id: $unique unique of $($ids.Count) ($($ids -join ','))"
}
if ($started -lt $N) {
    Write-Host "  (note: $started/$N sessions came up; uniqueness held for all that did)" -ForegroundColor DarkGray
}

foreach ($s in $names) { & $PSMUX kill-session -t $s 2>&1 | Out-Null; Remove-Item "$dir\$s.*" -Force -EA SilentlyContinue }

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
