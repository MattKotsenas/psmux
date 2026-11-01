# Issue #960: in shared mode (#798) a server wide write whose operands name a
# sibling session (`bind -n F7 send-keys -t B: -l XQ`) was delivered to the
# other sessions through their listeners, moved to B by the router, never
# matched its echo and was delivered again, forever: the server passed 4,000
# threads within a second. The fix delivers on the session's own handler.
#
# This suite checks both modes with the same line:
#  * shared: the server's thread count stays flat, the binding is in every
#    session once, the server still answers;
#  * default (PSMUX_SERVER_MODE unset): exactly what master does, one per
#    session server per session, the binding only in the session it was sent
#    to, no thread growth in either server.
#
# Isolation: a unique -L namespace per case, a private PSMUX_DATA_DIR and an
# empty config; servers are found by `display -p '#{pid}'` and cleaned up with
# `-L <ns> kill-server`, then by PID if one is left. The default namespace's
# `ls` is compared before and after. Pass -Exe or set PSMUX_TEST_EXE.
param(
    [string]$Exe = $(if ($env:PSMUX_TEST_EXE) { $env:PSMUX_TEST_EXE } else { (Get-Command psmux -EA Stop).Source }),
    [int]$WatchMs = 3000,
    [int]$ThreadLimit = 200
)

$ErrorActionPreference = "Continue"
$Exe = (Resolve-Path $Exe).Path
$script:Passed = 0
$script:Failed = 0
function Check($ok, $message, $detail) {
    if ($ok) { Write-Host "  [PASS] $message" -ForegroundColor Green; $script:Passed++ }
    else { Write-Host "  [FAIL] $message ($detail)" -ForegroundColor Red; $script:Failed++ }
}

$saved = @{}
foreach ($n in 'PSMUX_DATA_DIR', 'PSMUX_CONFIG_FILE', 'PSMUX_SERVER_MODE', 'TMUX', 'TMUX_PANE', 'PSMUX_SESSION', 'PSMUX_TARGET_SESSION', 'PSMUX_SESSION_NAME') {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n)
    Remove-Item "Env:\$n" -EA SilentlyContinue
}
$defaultBefore = (& $Exe ls 2>&1 | Out-String).Trim()
$root = Join-Path ([IO.Path]::GetTempPath()) "psmux_960_$(Get-Random)"
New-Item -ItemType Directory $root -Force | Out-Null
$conf = Join-Path $root 'empty.conf'
'' | Set-Content $conf

function Run-Case([string]$mode) {
    $ns = "t960$mode$(Get-Random)"
    $env:PSMUX_DATA_DIR = Join-Path $root $ns
    New-Item -ItemType Directory $env:PSMUX_DATA_DIR -Force | Out-Null
    $env:PSMUX_CONFIG_FILE = $conf
    if ($mode -eq 'shared') { $env:PSMUX_SERVER_MODE = 'shared' } else { Remove-Item Env:\PSMUX_SERVER_MODE -EA SilentlyContinue }
    $pids = @()
    try {
        & $Exe -L $ns new-session -d -s A -x 120 -y 30 2>&1 | Out-Null
        & $Exe -L $ns new-session -d -s B -x 120 -y 30 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1500
        foreach ($s in 'A', 'B') { $pids += [int]((& $Exe -L $ns display -p -t $s '#{pid}' 2>&1 | Out-String) -replace '\D', '') }
        $pids = @($pids | Sort-Object -Unique)
        $expectServers = if ($mode -eq 'shared') { 1 } else { 2 }
        Check ($pids.Count -eq $expectServers) "${mode}: $expectServers server process(es) for A and B" "pids $($pids -join ',')"
        $before = 0; foreach ($p in $pids) { $before += (Get-Process -Id $p).Threads.Count }

        & $Exe -L $ns bind -n F7 send-keys -t B: -l XQ 2>&1 | Out-Null
        $peak = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $WatchMs) {
            $n = 0; foreach ($p in $pids) { $pr = Get-Process -Id $p -EA SilentlyContinue; if ($pr) { $n += $pr.Threads.Count } }
            if ($n -gt $peak) { $peak = $n }
            if ($n -gt $ThreadLimit * $pids.Count) { break }
            Start-Sleep -Milliseconds 100
        }
        Check ($peak -le $ThreadLimit * $pids.Count) "${mode}: threads stay bounded after the bind (before $before, peak $peak)" "peak $peak"
        $sw.Restart()
        $pong = (& $Exe -L $ns display -p -t A pong 2>&1 | Out-String).Trim()
        Check ($pong -eq 'pong') "${mode}: the server still answers ($($sw.ElapsedMilliseconds) ms)" "'$pong'"
        $pattern = '(?m)^bind-key\s+-T root\s+F7\s+send-keys -t B: -l XQ\s*$'
        foreach ($s in 'A', 'B') {
            $keys = & $Exe -L $ns list-keys -T root -t $s 2>&1 | Out-String
            $count = ([regex]::Matches($keys, $pattern)).Count
            # Shared: key tables are server wide (tmux key-bindings.c), so the
            # bind is in both sessions once. Default: each session is its own
            # server, and the CLI sends this line to B (the server its operand
            # names), so only B has it, exactly as on master.
            $want = if ($mode -eq 'shared' -or $s -eq 'B') { 1 } else { 0 }
            Check ($count -eq $want) "${mode}: F7 is bound $want time(s) in $s" "seen $count"
        }
    } finally {
        & $Exe -L $ns kill-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        foreach ($p in $pids) { if (Get-Process -Id $p -EA SilentlyContinue) { Stop-Process -Id $p -Force -EA SilentlyContinue } }
    }
}

try {
    Write-Host "`n=== #960: a server wide write naming a sibling, both modes ===" -ForegroundColor Cyan
    Write-Host "  Binary: $Exe"
    Run-Case 'shared'
    Run-Case 'default'
} finally {
    foreach ($n in $saved.Keys) {
        if ($null -eq $saved[$n]) { Remove-Item "Env:\$n" -EA SilentlyContinue } else { Set-Item "Env:\$n" $saved[$n] }
    }
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}
$prevData = $env:PSMUX_DATA_DIR; Remove-Item Env:\PSMUX_DATA_DIR -EA SilentlyContinue
$defaultAfter = (& $Exe ls 2>&1 | Out-String).Trim()
if ($prevData) { $env:PSMUX_DATA_DIR = $prevData }
Check ($defaultAfter -eq $defaultBefore) "the default namespace is unchanged" "'$defaultBefore' -> '$defaultAfter'"

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Passed)"
Write-Host "  Failed: $($script:Failed)"
exit $script:Failed
