# Docker environment: core psmux E2E over SSH (non-interactive exec path).
#
# Runs against the psmux-dev Windows container (docker\Run-PsmuxDev.ps1),
# where psmux is installed at C:\cargo\bin\psmux.exe on Windows build 20348.
# Every command below is executed inside the container through SSH exec,
# exactly the way a remote admin would script psmux over SSH.
#
# Covers: session lifecycle, CLI dispatch, server TCP handler (raw socket
# from inside the container), split/send-keys/capture-pane, windows,
# edge cases (duplicates, missing targets), and detached-session survival
# across SSH connections.

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\test_docker_ssh_lib.ps1"

$SESSION = "docker_e2e"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }

Write-Host "`n=== Docker/SSH E2E tests ===" -ForegroundColor Cyan
$ip = Get-ContainerIP
Write-Host "  container IP: $ip"

# --- Test 0: environment sanity ---
Write-Host "`n[Test 0] Container environment" -ForegroundColor Yellow
$hn = Invoke-CSsh $ip "hostname"
if ($hn.Trim().Length -gt 0 -and $script:CSshExit -eq 0) { Write-Pass "SSH exec works (hostname=$($hn.Trim()))" }
else { Write-Fail "SSH exec failed"; exit 1 }

$build = (Invoke-CSsh $ip "[System.Environment]::OSVersion.Version.Build").Trim()
if ($build -eq "20348") { Write-Pass "container is Windows build 20348 (ConPTY without mouse support)" }
else { Write-Fail "expected build 20348, got: $build" }

# psmux reports its version as "tmux <ver>" for tmux compatibility
$ver = Invoke-CSsh $ip "psmux -V"
if ($ver -match "tmux") { Write-Pass "psmux installed in container: $($ver.Trim())" }
else { Write-Fail "psmux not found in container: $ver"; exit 1 }

# --- clean slate ---
Invoke-CSsh $ip "psmux kill-server" | Out-Null
Start-Sleep -Seconds 1

# --- Test 1: session lifecycle over SSH ---
Write-Host "`n[Test 1] Session lifecycle" -ForegroundColor Yellow
New-ContainerSession $ip $SESSION
Invoke-CSsh $ip "psmux has-session -t $SESSION" | Out-Null
if ($script:CSshExit -eq 0) { Write-Pass "new-session -d created session (has-session exit 0)" }
else { Write-Fail "session not created" }

$name = (Invoke-CSsh $ip "psmux display-message -t $SESSION -p '#{session_name}'").Trim()
if ($name -eq $SESSION) { Write-Pass "display-message returns session_name=$name" }
else { Write-Fail "expected session_name=$SESSION, got: $name" }

# duplicate must be rejected
$dup = Invoke-CSsh $ip "psmux new-session -d -s $SESSION -- $($script:PaneShell)"
if ($dup -match "duplicate|exists|already" -or $script:CSshExit -ne 0) { Write-Pass "duplicate new-session rejected" }
else { Write-Fail "duplicate new-session was not rejected: $dup" }

# missing target
Invoke-CSsh $ip "psmux has-session -t no_such_session_xyz" | Out-Null
if ($script:CSshExit -ne 0) { Write-Pass "has-session on missing session exits non-zero" }
else { Write-Fail "has-session on missing session returned 0" }

# --- Test 2: panes and output ---
Write-Host "`n[Test 2] Split, send-keys, capture-pane" -ForegroundColor Yellow
Invoke-CSsh $ip "psmux split-window -v -t $SESSION" | Out-Null
Start-Sleep -Seconds 2
$panes = (Invoke-CSsh $ip "psmux display-message -t $SESSION -p '#{window_panes}'").Trim()
if ($panes -eq "2") { Write-Pass "split-window created 2 panes" }
else { Write-Fail "expected 2 panes, got: $panes" }

Invoke-CSsh $ip "psmux send-keys -t $SESSION 'echo DOCKER_E2E_MARKER' Enter" | Out-Null
Start-Sleep -Seconds 2
$cap = Invoke-CSsh $ip "psmux capture-pane -t $SESSION -p"
if ($cap -match "DOCKER_E2E_MARKER") { Write-Pass "send-keys output visible in capture-pane" }
else { Write-Fail "marker not found in capture-pane: $($cap.Substring(0,[Math]::Min(200,$cap.Length)))" }

# --- Test 3: windows ---
Write-Host "`n[Test 3] Windows" -ForegroundColor Yellow
Invoke-CSsh $ip "psmux new-window -t $SESSION -n testwin" | Out-Null
Start-Sleep -Seconds 2
$wins = (Invoke-CSsh $ip "psmux display-message -t $SESSION -p '#{session_windows}'").Trim()
if ($wins -eq "2") { Write-Pass "new-window created (session_windows=2)" }
else { Write-Fail "expected 2 windows, got: $wins" }

$lw = Invoke-CSsh $ip "psmux list-windows -t $SESSION"
if ($lw -match "testwin") { Write-Pass "list-windows shows named window" }
else { Write-Fail "testwin missing from list-windows: $lw" }

Invoke-CSsh $ip "psmux kill-window -t ${SESSION}:testwin" | Out-Null
Start-Sleep -Seconds 1
$wins2 = (Invoke-CSsh $ip "psmux display-message -t $SESSION -p '#{session_windows}'").Trim()
if ($wins2 -eq "1") { Write-Pass "kill-window removed window" }
else { Write-Fail "expected 1 window after kill, got: $wins2" }

# --- Test 4: raw TCP server path inside the container ---
Write-Host "`n[Test 4] Raw TCP handler (server/connection.rs) inside container" -ForegroundColor Yellow
$tcpScript = @'
$psmuxDir = "$env:USERPROFILE\.psmux"
$port = (Get-Content "$psmuxDir\docker_e2e.port" -Raw).Trim()
$key  = (Get-Content "$psmuxDir\docker_e2e.key"  -Raw).Trim()
$tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
$tcp.NoDelay = $true
$stream = $tcp.GetStream()
$writer = [System.IO.StreamWriter]::new($stream)
$reader = [System.IO.StreamReader]::new($stream)
$writer.Write("AUTH $key`n"); $writer.Flush()
$auth = $reader.ReadLine()
Write-Output "AUTH_RESP=$auth"
$writer.Write("list-sessions`n"); $writer.Flush()
$stream.ReadTimeout = 8000
try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
Write-Output "LIST_RESP=$resp"
$tcp.Close()
'@
$local = Join-Path $env:TEMP "psmux_docker_tcp_probe.ps1"
Set-Content -Path $local -Value $tcpScript -Encoding UTF8
Invoke-CSsh $ip "New-Item -ItemType Directory -Force C:\psmux_test | Out-Null" | Out-Null
if (Copy-ToContainer $ip $local "C:/psmux_test/tcp_probe.ps1") {
    $tcpOut = Invoke-CSsh $ip "pwsh -NoProfile -File C:\psmux_test\tcp_probe.ps1"
    if ($tcpOut -match "AUTH_RESP=OK") { Write-Pass "TCP AUTH accepted inside container" }
    else { Write-Fail "TCP AUTH failed: $tcpOut" }
    if ($tcpOut -match "LIST_RESP=.*$SESSION") { Write-Pass "TCP list-sessions returned session" }
    else { Write-Fail "TCP list-sessions bad response: $tcpOut" }
} else { Write-Fail "scp of tcp probe failed" }

# --- Test 5: session survives across SSH connections (detached persistence) ---
Write-Host "`n[Test 5] Detached session survives SSH disconnect" -ForegroundColor Yellow
Invoke-CSsh $ip "psmux send-keys -t $SESSION 'echo SURVIVES_DISCONNECT' Enter" | Out-Null
Start-Sleep -Seconds 2
# new independent SSH connection reads the same pane
$cap2 = Invoke-CSsh $ip "psmux capture-pane -t $SESSION -p"
if ($cap2 -match "SURVIVES_DISCONNECT") { Write-Pass "state persisted across independent SSH connections" }
else { Write-Fail "marker lost across SSH connections" }

# --- Test 6: kill-session ---
Write-Host "`n[Test 6] kill-session" -ForegroundColor Yellow
Invoke-CSsh $ip "psmux kill-session -t $SESSION" | Out-Null
Start-Sleep -Seconds 1
Invoke-CSsh $ip "psmux has-session -t $SESSION" | Out-Null
if ($script:CSshExit -ne 0) { Write-Pass "kill-session destroyed session" }
else { Write-Fail "session still alive after kill-session" }

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
