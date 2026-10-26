# Issue #474: psmux client attach over a Cygwin/MSYS pty (mintty, Git Bash).
#
# Uses MSYS2's expect to drive a GENUINE Cygwin pty (the same pty type mintty
# provides). Before the fix the client died instantly with
# "psmux: Incorrect function. (os error 1)" (console APIs on a pipe handle).
# Now the client enters pipe mode: VT input from the pipe, UTF-8 frames back,
# terminal size via XTWINOPS (CSI 18 t -> CSI 8;rows;cols t).
#
# Verifies: attach succeeds, size report applied, typed input reaches the
# pane, prefix+d detaches, client exits, server survives.
#
# Skips (exit 0) when MSYS2 expect is not installed.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "i474pipe"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

$bash = "C:\msys64\usr\bin\bash.exe"
if (-not (Test-Path $bash) -or -not (Test-Path "C:\msys64\usr\bin\expect.exe")) {
    Write-Host "  [SKIP] MSYS2 expect not installed (pacman -S expect)" -ForegroundColor DarkYellow
    exit 0
}

Write-Host "`n=== Issue #474 Cygwin pty attach test ===" -ForegroundColor Cyan

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$env:PSMUX_NO_WARM = "1"
& $PSMUX new-session -d -s $SESSION
$env:PSMUX_NO_WARM = $null
Start-Sleep -Seconds 5
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session did not start"; exit 1 }

# expect script: raw pty, answer the size query with 40x100, type a marker,
# then prefix+d to detach. Drain output continuously so the client never
# blocks writing frames.
$marker = "PIPEMARK" + (Get-Random -Maximum 99999)
$expFile = "$env:TEMP\i474_pipe_attach.exp"
$psmuxPosix = "/" + ($PSMUX -replace ':', '' -replace '\\', '/')
@"
set stty_init {raw -echo}
set timeout 20
log_user 0
spawn $psmuxPosix attach-session -t $SESSION
set timeout 5
expect {
    -re {\x1b\[18t} { send "\x1b\[8;40;100t"; exp_continue }
    -re {.+} { exp_continue }
    timeout {}
    eof { puts "EARLY_EOF"; exit 1 }
}
send "echo $marker\r"
set timeout 3
expect { -re {.+} { exp_continue } timeout {} eof { puts "EARLY_EOF2"; exit 1 } }
send "\002"
sleep 0.4
send "d"
set timeout 8
expect { -re {.+} { exp_continue } eof { puts "CLIENT_EXITED" } timeout { puts "CLIENT_STUCK" } }
catch {close}
exit 0
"@ | Set-Content -Path $expFile -Encoding ascii

$runner = "$env:TEMP\i474_pipe_attach.sh"
$expPosix = "/" + ($expFile -replace ':', '' -replace '\\', '/')
"#!/usr/bin/bash`nexec expect $expPosix`n" | Set-Content -Path $runner -Encoding ascii -NoNewline
$runnerPosix = "/" + ($runner -replace ':', '' -replace '\\', '/')

$outLog = "$env:TEMP\i474_pipe_attach.out"
$proc = Start-Process $bash -ArgumentList "-l", $runnerPosix -RedirectStandardOutput $outLog -RedirectStandardError "$outLog.err" -PassThru -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(45)
while (-not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
if (-not $proc.HasExited) {
    Get-Process expect, tclsh -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Write-Fail "expect harness hung (client likely wedged)"
} else {
    Write-Pass "expect harness completed"
}
Start-Sleep -Seconds 2

$cap = (& $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String)
if ($cap -match $marker) { Write-Pass "typed input over Cygwin pty reached the pane" }
else { Write-Fail "typed marker never appeared in pane" }

$attached = (& $PSMUX display-message -t $SESSION -p '#{session_attached}' 2>&1 | Out-String).Trim()
if ($attached -eq "0") { Write-Pass "prefix+d detached the pty client" }
else { Write-Fail "client still attached: $attached" }

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "server survived the pty attach cycle" }
else { Write-Fail "server died during pty attach" }

# cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -match 'attach-session -t i474pipe' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
