# Issue #545: E2E for validated -t targeting.
# Part A: positive controls - valid targets must still work end-to-end.
# Part B: raw TCP server path - bad targets answered with ERROR, no execution.
# Part C: edge cases.
# Part D: Win32 TUI proof (Strategy A).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "t545v"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function Cleanup {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    & $PSMUX kill-session -t "t545tui" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$S.*","$psmuxDir\t545tui.*" -Force -EA SilentlyContinue
}
Cleanup

Write-Host "`n=== Issue #545 validation E2E ===" -ForegroundColor Cyan

# Setup: interactive window 0 (active), parked window 1 named park
& $PSMUX new-session -d -s $S -x 120 -y 30 -- pwsh -NoProfile -NoLogo
Start-Sleep -Seconds 4
& $PSMUX new-window -d -t $S -n park -- pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 2
& $PSMUX select-window -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# --- Part A: positive controls (valid targets still work) ---
Write-Host "`n[Part A] Valid targets still work" -ForegroundColor Yellow

# A1: send-keys to the VALID active window executes
& $PSMUX send-keys -t "${S}:0" 'echo GOOD_TARGET_A1' Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap = (& $PSMUX capture-pane -p -t "${S}:0" 2>&1) -join "`n"
if ($LASTEXITCODE -eq 0 -and $cap -match "GOOD_TARGET_A1") { Write-Pass "A1: send-keys valid window target executes" }
else { Write-Fail "A1: send-keys valid target broken (rc=$LASTEXITCODE)" }

# A2: capture-pane of the valid non-active window by NAME returns rc 0
$cap = & $PSMUX capture-pane -p -t "${S}:park" 2>&1
if ($LASTEXITCODE -eq 0) { Write-Pass "A2: capture-pane valid name target rc=0" }
else { Write-Fail "A2: capture-pane valid name target rc=$LASTEXITCODE" }

# A3: rename-window by valid name renames THAT window (not active)
& $PSMUX rename-window -t "${S}:park" parked2 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$wins = (& $PSMUX list-windows -t $S -F '#{window_index}|#{window_name}|#{window_active}' 2>&1) -join ";"
if ($wins -match "1\|parked2\|0" -and $wins -match "0\|.*\|1") { Write-Pass "A3: rename-window valid target renamed the TARGET ($wins)" }
else { Write-Fail "A3: rename-window valid target wrong result: $wins" }

# A4: display-message -t still resolves target window vars
$idx = (& $PSMUX display-message -p -t "${S}:parked2" '#{window_index}' 2>&1 | Out-String).Trim()
if ($idx -eq "1") { Write-Pass "A4: display-message -t resolves target (idx=$idx)" }
else { Write-Fail "A4: display-message -t expected idx 1, got '$idx'" }

# A5: kill-pane by valid %id kills that pane only (window 1's pane)
& $PSMUX split-window -v -t "${S}:0" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$panes = (& $PSMUX list-panes -t "${S}:0" -F '#{pane_id}' 2>&1)
$paneCount = ($panes | Measure-Object).Count
$lastPane = ($panes | Select-Object -Last 1).Trim()
& $PSMUX kill-pane -t "${S}:0.$lastPane" 2>&1 | Out-Null
Start-Sleep -Seconds 1
$paneCount2 = ((& $PSMUX list-panes -t "${S}:0" -F '#{pane_id}' 2>&1) | Measure-Object).Count
if ($paneCount -eq 2 -and $paneCount2 -eq 1) { Write-Pass "A5: kill-pane valid %id killed target pane ($paneCount -> $paneCount2)" }
else { Write-Fail "A5: kill-pane valid %id wrong ($paneCount -> $paneCount2)" }

# A6: active window count is intact (2 windows)
$wc = ((& $PSMUX list-windows -t $S -F '#{window_index}' 2>&1) | Measure-Object).Count
if ($wc -eq 2) { Write-Pass "A6: both windows intact after positive tests" }
else { Write-Fail "A6: window count expected 2, got $wc" }

# --- Part B: raw TCP server path ---
Write-Host "`n[Part B] Raw TCP server path" -ForegroundColor Yellow
function Send-Tcp {
    param([string]$Command)
    $port = (Get-Content "$psmuxDir\$S.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$S.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $st = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($st)
    $r = [System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush()
    $null = $r.ReadLine()
    $w.Write("$Command`n"); $w.Flush()
    $st.ReadTimeout = 5000
    try { $resp = $r.ReadLine() } catch { $resp = $null }
    $tcp.Close()
    return $resp
}

# B1: send-keys with bad -t over raw TCP answers ERROR and does not execute
$resp = Send-Tcp "send-keys -t ${S}:tcpnosuch 'echo TCP_MISROUTE' Enter"
Start-Sleep -Seconds 2
$cap = (& $PSMUX capture-pane -p -t "${S}:0" 2>&1) -join "`n"
if ($resp -match "ERROR: can't find window: tcpnosuch" -and $cap -notmatch "TCP_MISROUTE") {
    Write-Pass "B1: TCP send-keys bad target -> '$resp', not executed"
} else {
    Write-Fail "B1: TCP send-keys bad target resp='$resp', executed=$($cap -match 'TCP_MISROUTE')"
}

# B2: rename-window bad target over TCP answers ERROR, nothing renamed
$resp = Send-Tcp "rename-window -t ${S}:tcpnosuch TCPRENAMED"
Start-Sleep -Milliseconds 500
$wins = (& $PSMUX list-windows -t $S -F '#{window_name}' 2>&1) -join ";"
if ($resp -match "ERROR: can't find window" -and $wins -notmatch "TCPRENAMED") {
    Write-Pass "B2: TCP rename-window bad target -> ERROR, no rename"
} else {
    Write-Fail "B2: TCP rename-window bad target resp='$resp', wins=$wins"
}

# B3: valid TCP rename still works
$null = Send-Tcp "rename-window -t ${S}:parked2 tcpgood"
Start-Sleep -Milliseconds 500
$wins = (& $PSMUX list-windows -t $S -F '#{window_name}' 2>&1) -join ";"
if ($wins -match "tcpgood") { Write-Pass "B3: TCP rename-window valid target works" }
else { Write-Fail "B3: TCP rename-window valid target failed: $wins" }

# --- Part C: edge cases ---
Write-Host "`n[Part C] Edge cases" -ForegroundColor Yellow

# C1: bad @id form
$out = & $PSMUX rename-window -t "${S}:@999" NOPE 2>&1
if ($LASTEXITCODE -ne 0) { Write-Pass "C1: bad @id target rc=$LASTEXITCODE" }
else { Write-Fail "C1: bad @id target rc=0 ($out)" }

# C2: session-only target still fine (no window component)
& $PSMUX send-keys -t $S 'echo SESSION_ONLY_OK' Enter 2>&1 | Out-Null
$rcC2 = $LASTEXITCODE
Start-Sleep -Seconds 2
$cap = (& $PSMUX capture-pane -p -t $S 2>&1) -join "`n"
if ($rcC2 -eq 0 -and $cap -match "SESSION_ONLY_OK") { Write-Pass "C2: session-only -t unaffected" }
else { Write-Fail "C2: session-only -t rc=$rcC2 executed=$($cap -match 'SESSION_ONLY_OK')" }

# C3: numeric window index that exists
$out = & $PSMUX list-panes -t "${S}:1" -F '#{window_name}' 2>&1
if ($LASTEXITCODE -eq 0 -and ($out -join "") -match "tcpgood") { Write-Pass "C3: numeric index target works" }
else { Write-Fail "C3: numeric index target rc=$LASTEXITCODE out=$out" }

# C4: numeric window index that does NOT exist
$out = & $PSMUX list-panes -t "${S}:7" -F '#{window_name}' 2>&1
if ($LASTEXITCODE -ne 0) { Write-Pass "C4: nonexistent numeric index rc=$LASTEXITCODE" }
else { Write-Fail "C4: nonexistent numeric index rc=0 ($out)" }

# --- Part D: Win32 TUI proof (Strategy A) ---
Write-Host "`n[Part D] Win32 TUI visual verification" -ForegroundColor Yellow
$STUI = "t545tui"
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$STUI -PassThru
Start-Sleep -Seconds 5

& $PSMUX split-window -v -t $STUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panes = (& $PSMUX display-message -t $STUI -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes -eq "2") { Write-Pass "D1: TUI session functional (2 panes after split)" }
else { Write-Fail "D1: TUI expected 2 panes, got '$panes'" }

# Bad target against the attached session: must not kill anything
& $PSMUX kill-pane -t "${STUI}:ghostwin" 2>&1 | Out-Null
$rcD = $LASTEXITCODE
Start-Sleep -Milliseconds 800
$panes2 = (& $PSMUX display-message -t $STUI -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($rcD -ne 0 -and $panes2 -eq "2") { Write-Pass "D2: TUI bad-target kill-pane rc=$rcD, panes intact" }
else { Write-Fail "D2: TUI bad-target kill-pane rc=$rcD, panes=$panes2" }

# Valid rename against attached session works and TUI stays alive
& $PSMUX rename-window -t "${STUI}:0" tuiwin 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$wn = (& $PSMUX display-message -t $STUI -p '#{window_name}' 2>&1 | Out-String).Trim()
if ($wn -eq "tuiwin") { Write-Pass "D3: TUI valid rename applied ($wn)" }
else { Write-Fail "D3: TUI rename expected tuiwin, got '$wn'" }

& $PSMUX kill-session -t $STUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Cleanup
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
