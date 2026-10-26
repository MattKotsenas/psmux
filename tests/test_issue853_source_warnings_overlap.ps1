# Issue #853: two source-file runs that overlap both keep their warnings.
#
# The server records the warnings of a runtime source-file in one list, which
# it writes to config-warnings.log. A source whose file holds commands runs
# them in a job (#842), and when the job finished it replaced the list with
# its own warnings. A second source that ran and finished while the first
# one's job was still running lost its warnings from the log as soon as the
# first job finished. Each client still heard of its own warnings.
#
# tmux keeps one list too (cfg.c:31, cfg_causes) and only adds to it
# (cfg_add_cause); a source-file prints what is there when it completes and
# empties it (cmd-source-file.c:76). Nothing replaces the list.
#
# The suite runs under -L in a PSMUX_DATA_DIR of its own and kills only its own
# namespace. Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0; $script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }
function Check($ok, $pass, $fail) { if ($ok) { Write-Pass $pass } else { Write-Fail $fail } }

$POWERSHELL = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
. "$PSScriptRoot\isolated_config.ps1" -Lines @("set -g default-shell $POWERSHELL")

$PSMUX = $env:PSMUX_TEST_BIN
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $cmd = Get-Command psmux -EA SilentlyContinue; if ($cmd) { $PSMUX = $cmd.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

foreach ($v in 'PSMUX_SESSION_NAME', 'PSMUX_SESSION', 'PSMUX_PANE', 'PSMUX_TARGET_SESSION', 'PSMUX_TARGET_FULL', 'TMUX', 'TMUX_PANE') {
    Remove-Item "Env:$v" -EA SilentlyContinue
}
$env:PSMUX_NO_WARM = "1"

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_swo_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null
$env:PSMUX_DATA_DIR = $TMP
$NS = "swo" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$S = "sw"
$LOG = Join-Path $TMP "config-warnings.log"

Write-Host "`n=== Issue #853: two source-file runs that overlap keep both warnings ===" -ForegroundColor Cyan
Write-Host "  Binary:   $PSMUX"
Write-Host "  Data dir: $TMP"

function P { & $PSMUX -L $NS @args 2>&1 }
# The warnings in config-warnings.log, without its `when` line.
function LogLines { ,@((Get-Content $LOG -EA SilentlyContinue) | Select-Object -Skip 1) }

# Start the CLI `source-file` on a file without waiting for it.
function Start-Source($path, $tag) {
    Start-Process -FilePath $PSMUX -ArgumentList @("-L", $NS, "source-file", "`"$path`"") -NoNewWindow -PassThru `
        -RedirectStandardError (Join-Path $TMP "$tag.err") -RedirectStandardOutput (Join-Path $TMP "$tag.out")
}
function Err($tag) { ((Get-Content (Join-Path $TMP "$tag.err") -Raw -EA SilentlyContinue) + "").Trim() }

function Reset-Session {
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item $LOG -EA SilentlyContinue
    P new-session -d -s $S -x 120 -y 30 | Out-Null
    $port = Join-Path $TMP "${NS}__${S}.port"
    for ($i = 0; $i -lt 60 -and -not (Test-Path $port); $i++) { Start-Sleep -Milliseconds 100 }
    Start-Sleep -Milliseconds 500
}

# A: a run-shell that waits two seconds, so the rest of the file runs in a job
# that takes that long (#851), then a bad option at the end.
$fa = Join-Path $TMP "a.conf"
@('run-shell -d 2', 'set -g no-such-option-a on') | Set-Content -Path $fa -Encoding ASCII
# B: only a bad option, so it has no job and finishes at once.
$fb = Join-Path $TMP "b.conf"
@('set -g no-such-option-b on') | Set-Content -Path $fb -Encoding ASCII
# C: a bad option too, run alone after the others.
$fc = Join-Path $TMP "c.conf"
@('set -g no-such-option-c on') | Set-Content -Path $fc -Encoding ASCII

try {
    Write-Head "A. B finishes while A's job runs"
    Reset-Session
    $pa = Start-Source $fa "a"
    Start-Sleep -Milliseconds 300
    $pb = Start-Source $fb "b"
    $pb.WaitForExit()
    $overlapped = -not $pa.HasExited
    Check $overlapped "B finished while A was still running" "A had already finished, so the two did not overlap"
    $pa.WaitForExit()
    Start-Sleep -Milliseconds 300
    $lines = LogLines
    $hasA = @($lines | Where-Object { $_ -match 'no-such-option-a' }).Count -eq 1
    $hasB = @($lines | Where-Object { $_ -match 'no-such-option-b' }).Count -eq 1
    Check ($hasA -and $hasB) "config-warnings.log keeps both warnings" "log [$($lines -join ' | ')]"

    Write-Head "B. each client hears only its own warning"
    $ea = Err "a"; $eb = Err "b"
    Check (($pa.ExitCode -eq 1) -and ($ea -match 'no-such-option-a') -and ($ea -notmatch 'no-such-option-b')) "A: exit 1, its own warning only" "exit $($pa.ExitCode), stderr [$ea]"
    Check (($pb.ExitCode -eq 1) -and ($eb -match 'no-such-option-b') -and ($eb -notmatch 'no-such-option-a')) "B: exit 1, its own warning only" "exit $($pb.ExitCode), stderr [$eb]"

    Write-Head "C. a source run after both starts the list over"
    $pc = Start-Source $fc "c"
    $pc.WaitForExit()
    Start-Sleep -Milliseconds 300
    $lines = LogLines
    Check (($lines.Count -eq 1) -and ($lines[0] -match 'no-such-option-c')) "the log holds only C's warning" "log [$($lines -join ' | ')], C exit $($pc.ExitCode), stderr [$(Err 'c')]"
} finally {
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-PsmuxIsolatedConfig
    Remove-Item Env:PSMUX_DATA_DIR, Env:PSMUX_NO_WARM -EA SilentlyContinue
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
}

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
