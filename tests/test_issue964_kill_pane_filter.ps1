# Issue #964 follow up: kill-pane -f. tmux 3.8 cmd-kill-pane.c:56 makes -f
# an error without -a, and cmd_kill_pane_filter (:96-115) kills only the
# other panes whose filter expands true. psmux dropped -f: `kill-pane -a -f
# <filter>` killed every other pane, and `kill-pane -f <x>` killed the
# current pane with exit 0.
#
# Fully isolated: a private PSMUX_DATA_DIR and config under %TEMP% and a
# namespace of its own. Cleans up with `-L <ns> kill-server` only.
#
# Usage: pwsh tests\test_issue964_kill_pane_filter.ps1 [-Exe path\to\psmux.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Continue'
if (-not $Exe) { $Exe = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { Join-Path $PSScriptRoot '..\target\release\psmux.exe' } }
if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "psmux binary not found: $Exe"; exit 2 }
$Exe = (Resolve-Path -LiteralPath $Exe).Path

$saved = @{}
foreach ($n in 'PSMUX_DATA_DIR', 'PSMUX_CONFIG_FILE', 'PSMUX_SERVER_MODE', 'TMUX', 'TMUX_PANE', 'PSMUX_TARGET_SESSION') {
    $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
}
$Root = Join-Path ([IO.Path]::GetTempPath()) "psmux-964f-$PID"
New-Item -ItemType Directory -Force (Join-Path $Root 'data') | Out-Null
$cfg = Join-Path $Root 'empty.conf'; [IO.File]::WriteAllText($cfg, '')
$env:PSMUX_DATA_DIR = Join-Path $Root 'data'
$env:PSMUX_CONFIG_FILE = $cfg
foreach ($n in 'PSMUX_SERVER_MODE', 'TMUX', 'TMUX_PANE', 'PSMUX_TARGET_SESSION') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }

$NS = "t964f$PID"
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$name, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output "PASS: $name" } else { $script:fail++; Write-Output "FAIL: $name $detail" }
}
function P { & $Exe -L $NS @args 2>&1 | ForEach-Object { "$_" } }
function Alive([string]$s) { P has-session -t $s | Out-Null; $LASTEXITCODE -eq 0 }
function Wait-For([scriptblock]$cond, [int]$ms = 8000) {
    $d = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $d) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 200 }
    [bool](& $cond)
}
function Ids([string]$t) { @(P list-panes -t $t -F '#{pane_id}') }
function Panes([string]$t) { (P list-panes -t $t -F '#{pane_id}:#{pane_active}') -join ' ' }
# A session whose window 0 has three panes, the first one active.
function ThreePanes([string]$s) {
    P new-session -d -s $s -x 120 -y 30 | Out-Null
    Wait-For { Alive $s } | Out-Null
    P split-window -d -t $s | Out-Null
    P split-window -d -t $s | Out-Null
    Wait-For { (Ids "${s}:0").Count -eq 3 } | Out-Null
    Start-Sleep -Milliseconds 300
}
function Done([string]$s) {
    P kill-session -t $s | Out-Null
    Wait-For { -not (Alive $s) } 4000 | Out-Null
}
# The filter is true for one pane id only.
function Only([string]$id) { "#{==:#{pane_id},$id}" }

try {
    Write-Output "== CLI"
    ThreePanes c1
    $ids = @(Ids 'c1:0')
    P kill-pane -a -f (Only $ids[2]) | Out-Null
    $rc = $LASTEXITCODE
    Wait-For { (Ids 'c1:0').Count -lt 3 } 3000 | Out-Null
    Start-Sleep -Milliseconds 500
    $left = (Ids 'c1:0') -join ' '
    Check ($left -eq "$($ids[0]) $($ids[1])" -and $rc -eq 0) "kill-pane -a -f kills only $($ids[2])" "(left $left, rc $rc)"
    Check ((Panes 'c1:0') -like "$($ids[0]):1*") "the active pane stays active" "($(Panes 'c1:0'))"
    Done c1

    ThreePanes c2
    $ids = @(Ids 'c2:0')
    P kill-pane -a -f 0 | Out-Null
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 800
    Check ((Ids 'c2:0').Count -eq 3 -and $rc -eq 0) 'kill-pane -a -f 0 kills nothing' "($(Panes 'c2:0'), rc $rc)"

    $out = (P kill-pane -f 1) -join ' '
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 800
    Check ((Ids 'c2:0').Count -eq 3) 'kill-pane -f without -a kills nothing' "($(Panes 'c2:0'))"
    Check ($rc -eq 1 -and $out -match '-f only valid with -a') 'kill-pane -f without -a is an error' "(rc $rc, out $out)"
    Done c2

    Write-Output "== raw TCP"
    foreach ($mode in 'oneshot', 'persistent') {
        $s = "r$mode"
        ThreePanes $s
        $ids = @(Ids "${s}:0")
        $port = [int](Get-Content (Join-Path $env:PSMUX_DATA_DIR "${NS}__$s.port") -Raw).Trim()
        $key = (Get-Content (Join-Path $env:PSMUX_DATA_DIR "${NS}__$s.key") -Raw).Trim()
        $cl = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)
        $st = $cl.GetStream(); $st.ReadTimeout = 3000
        $w = New-Object System.IO.StreamWriter($st); $w.NewLine = "`n"; $w.AutoFlush = $true
        $r = New-Object System.IO.StreamReader($st)
        $w.WriteLine("AUTH $key"); [void]$r.ReadLine()
        if ($mode -eq 'persistent') { $w.WriteLine('PERSISTENT') }
        $w.WriteLine("kill-pane -a -t $($ids[0]) -f '$(Only $ids[1])'")
        Wait-For { (Ids "${s}:0").Count -lt 3 } 3000 | Out-Null
        Start-Sleep -Milliseconds 500
        $cl.Close()
        $left = (Ids "${s}:0") -join ' '
        Check ($left -eq "$($ids[0]) $($ids[2])") "TCP $mode kill-pane -a -t $($ids[0]) -f kills only $($ids[1])" "(left $left)"
        Done $s
    }

    Write-Output "== control mode"
    ThreePanes k1
    $ids = @(Ids 'k1:0')
    $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in @('-L', $NS, '-C', 'attach', '-t', 'k1')) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $cp = [Diagnostics.Process]::Start($psi)
    $outTask = $cp.StandardOutput.ReadToEndAsync()
    Start-Sleep -Milliseconds 1500
    $cp.StandardInput.WriteLine('kill-pane -f 1')
    $cp.StandardInput.WriteLine("kill-pane -a -f '$(Only $ids[1])'")
    $cp.StandardInput.Flush()
    Wait-For { (Ids 'k1:0').Count -lt 3 } 4000 | Out-Null
    Start-Sleep -Milliseconds 800
    $cp.StandardInput.Close()
    if (-not $cp.WaitForExit(4000)) { $cp.Kill() }
    $ctl = if ($outTask.Wait(2000)) { $outTask.Result } else { '' }
    $left = (Ids 'k1:0') -join ' '
    Check ($left -eq "$($ids[0]) $($ids[2])") "control mode kill-pane -f 1 kills nothing, -a -f kills only $($ids[1])" "(left $left)"
    Check ($ctl -match '%error[^\n]*\r?\n-f only valid with -a') 'control mode reports -f only valid with -a' "(output: $(($ctl -split "`n" | Select-String 'error|valid') -join ' | '))"
    Done k1

    Write-Output "== hook (in server route)"
    ThreePanes h1
    $ids = @(Ids 'h1:0')
    P set-hook -t h1 after-split-window "kill-pane -a -f '$(Only $ids[1])'" | Out-Null
    P split-window -d -t "h1:0.0" | Out-Null
    Wait-For { (Ids 'h1:0').Count -eq 3 } 5000 | Out-Null
    Start-Sleep -Milliseconds 800
    $left = @(Ids 'h1:0')
    Check ($left.Count -eq 3 -and $ids[1] -notin $left -and $ids[0] -in $left -and $ids[2] -in $left) "hook kill-pane -a -f kills only $($ids[1])" "(left $($left -join ' '))"
    P set-hook -u -t h1 after-split-window | Out-Null
    P set-hook -t h1 after-split-window 'kill-pane -f 1' | Out-Null
    P split-window -d -t "h1:0.0" | Out-Null
    Start-Sleep -Milliseconds 1200
    Check ((Ids 'h1:0').Count -eq 4) 'hook kill-pane -f without -a kills nothing' "($(Panes 'h1:0'))"
    Done h1
} finally {
    P kill-server | Out-Null
    foreach ($n in $saved.Keys) {
        if ($null -eq $saved[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    }
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue
}
Write-Output "passed $script:pass, failed $script:fail"
exit $script:fail
