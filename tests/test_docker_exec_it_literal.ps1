# Docker env: the LITERAL `docker exec -it psmux-dev psmux attach` path.
#
# The docker CLI refuses `-t` when its stdin is a redirected pipe ("the input
# device is not a TTY"), so this suite hosts docker.exe itself under a
# HOST-side ConPTY (same harness source as the in-container suites). docker
# then believes it has a real TTY, allocates the container-side TTY, and does
# its full stdio relay - the one layer the in-container harness bypasses.
#
# Path under test:
#   host ConPTY -> docker.exe exec -it -> dockerd -> container ConPTY
#   (conhost build 20348) -> psmux attach
#
# Checks: TUI render, typed keystroke round-trip, SGR click+wheel survival
# through the relay (wheel enters copy mode, q recovers - tmux parity),
# prefix+d detach exits docker cleanly, session survives.

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "test_docker_exec_lib.ps1")

$SESSION = "dkrit"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

Write-Host "`n=== literal docker exec -it attach (host ConPTY hosts docker.exe) ===" -ForegroundColor Cyan
Resolve-DockerEnv

# Compile the harness on the HOST (same source the container suites use).
$work = Join-Path $env:TEMP "psmux_docker_it"
New-Item -ItemType Directory -Force $work | Out-Null
$hostExe = Join-Path $work "attach_host.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /optimize /out:$hostExe (Join-Path $PSScriptRoot "docker_conpty_attach_host.cs") 2>&1 | Out-Null
if (-not (Test-Path $hostExe)) { Write-Fail "host-side harness compile failed"; exit 1 }

Invoke-CExec "psmux kill-server" | Out-Null
Start-Sleep -Seconds 1
if (-not (New-ContainerSession $SESSION)) { Write-Fail "session never reached a prompt"; exit 1 }
Invoke-CExec "psmux set-option -g mouse on" | Out-Null

$ctrl = Join-Path $work "ctrl.txt"; $outb = Join-Path $work "out.bin"; $log = Join-Path $work "log.txt"
Set-Content $ctrl "" -NoNewline; Set-Content $outb "" -NoNewline
function Send-It([string]$Line) { Add-Content $ctrl $Line }
function Get-ItStream {
    $fs=[IO.File]::Open($outb,'Open','Read','ReadWrite'); $b=New-Object byte[] $fs.Length
    [void]$fs.Read($b,0,$b.Length); $fs.Close(); return [Text.Encoding]::UTF8.GetString($b)
}

# --- Test 1: docker exec -it attach renders the TUI ---
Write-Host "`n[1] docker exec -it renders the TUI" -ForegroundColor Yellow
Start-Process -FilePath $hostExe -ArgumentList $ctrl,$outb,$log,"120","30","`"$($script:DockerExe)`"","exec","-it",$script:ContainerName,"psmux","attach","-t",$SESSION -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(40); $rendered = $false
while ((Get-Date) -lt $deadline) {
    if ((Get-ItStream) -match "\[$SESSION\] 0:") { $rendered = $true; break }
    Start-Sleep -Seconds 1
}
if ($rendered) { Write-Pass "status bar in the relayed VT stream (docker accepted the TTY)" }
else { Write-Fail "TUI never rendered; log: $(Get-Content $log -Raw -EA SilentlyContinue)" }

# --- Test 2: typed keystrokes cross docker's stdio relay ---
Write-Host "`n[2] typed keystrokes through the relay" -ForegroundColor Yellow
Send-It "TEXT echo VIA_DOCKER_IT"
Start-Sleep -Seconds 4
if ((Invoke-CExec "psmux capture-pane -t $SESSION -p") -match "VIA_DOCKER_IT") {
    Write-Pass "typed command executed in the pane"
} else { Write-Fail "typed input never reached the pane" }

# --- Test 3: SGR click + wheel through the relay; client survives ---
Write-Host "`n[3] SGR click + wheel survival through the relay" -ForegroundColor Yellow
Send-It "HEX 1b5b3c303b31353b354d1b5b3c303b31353b356d"   # click press+release
Start-Sleep -Seconds 2
Send-It "HEX 1b5b3c36343b34303b31304d"                    # wheel up (enters copy mode)
Start-Sleep -Seconds 2
if ((Get-Content $log -Raw) -notmatch "CHILD_EXIT") { Write-Pass "docker exec -it alive after click + wheel" }
else { Write-Fail "docker exec -it DIED on mouse reports: $(Get-Content $log -Raw)" }
Send-It "TYPE q"; Start-Sleep -Seconds 1                  # exit copy mode
Send-It "HEX 03"; Start-Sleep -Seconds 1                  # clear stray prompt input
Send-It "TEXT echo IT_MOUSE_OK"
Start-Sleep -Seconds 4
if ((Invoke-CExec "psmux capture-pane -t $SESSION -p") -match "IT_MOUSE_OK") {
    Write-Pass "input healthy after mouse abuse (copy mode exited with q)"
} else { Write-Fail "input dead after mouse abuse" }

# --- Test 4: prefix+d detach exits docker cleanly; session survives ---
Write-Host "`n[4] prefix+d detach" -ForegroundColor Yellow
Send-It "HEX 0264"
Start-Sleep -Seconds 4
if ((Get-Content $log -Raw) -match "CHILD_EXIT code=0") { Write-Pass "docker exec -it exited cleanly on detach" }
else { Write-Fail "docker exec -it did not exit on detach"; Send-It "QUIT" }
if (Test-ContainerSession $SESSION) { Write-Pass "session survived the detach" }
else { Write-Fail "session gone after detach" }

# --- Teardown ---
Invoke-CExec "psmux kill-session -t $SESSION" | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
