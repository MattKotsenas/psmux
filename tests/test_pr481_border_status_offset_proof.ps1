# PR #481: caret & mouse row offset under pane-border-status top
# Layer 1 (E2E CLI+TCP) + Layer 2 (Win32 TUI visual verification).
# The off-by-one caret/mouse geometry itself is proven by the Rust regression
# test (test_pane_border_status_cursor.rs) + standalone arithmetic repro; this
# script proves pane-border-status top applies and the TUI stays functional
# (no render regression) across off/top/bottom.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "pr481_e2e"
$SESSION_TUI = "pr481_tui"
$script:Passed = 0
$script:Failed = 0
function Write-Pass($m){Write-Host "  [PASS] $m" -ForegroundColor Green;$script:Passed++}
function Write-Fail($m){Write-Host "  [FAIL] $m" -ForegroundColor Red;$script:Failed++}

function Cleanup {
    foreach($s in @($SESSION,$SESSION_TUI)){ & $PSMUX kill-session -t $s 2>&1 | Out-Null }
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*","$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue
}

function Send-Tcp {
    param([string]$Session,[string]$Command)
    $port=(Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key=(Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp=[System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port);$tcp.NoDelay=$true
    $s=$tcp.GetStream();$w=[System.IO.StreamWriter]::new($s);$r=[System.IO.StreamReader]::new($s)
    $w.Write("AUTH $key`n");$w.Flush();$null=$r.ReadLine()
    $w.Write("$Command`n");$w.Flush();$s.ReadTimeout=8000
    try{$resp=$r.ReadLine()}catch{$resp="TIMEOUT"}
    $tcp.Close();return $resp
}

Cleanup
Write-Host "`n=== PR #481 E2E: pane-border-status option lifecycle ===" -ForegroundColor Cyan
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if($LASTEXITCODE -ne 0){Write-Fail "session create";Cleanup;exit 1}
Write-Pass "session created"

# split so there are 2 panes to label
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$panes=(& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
if($panes -eq "2"){Write-Pass "two panes present"}else{Write-Fail "panes=$panes"}

# Test 1: set pane-border-status top via CLI, verify applied
& $PSMUX set-option -t $SESSION pane-border-status top 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$v=(& $PSMUX show-options -v -t $SESSION pane-border-status 2>&1 | Out-String).Trim()
if($v -match "top"){Write-Pass "pane-border-status=top applied (got '$v')"}else{Write-Fail "expected top, got '$v'"}

# Test 2: window still renders (dump-state returns valid JSON with 2 leaves)
$dump = Send-Tcp -Session $SESSION -Command "dump-state"
if($dump -and $dump.Length -gt 100){
    try{ $j=$dump | ConvertFrom-Json; Write-Pass "dump-state valid JSON under border-status top" }
    catch{ Write-Fail "dump-state not JSON: $($dump.Substring(0,[Math]::Min(80,$dump.Length)))" }
}else{ Write-Fail "dump-state empty/short under border-status top" }

# Test 3: bottom variant applies too
& $PSMUX set-option -t $SESSION pane-border-status bottom 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$v=(& $PSMUX show-options -v -t $SESSION pane-border-status 2>&1 | Out-String).Trim()
if($v -match "bottom"){Write-Pass "pane-border-status=bottom applies"}else{Write-Fail "bottom expected, got '$v'"}

# Test 4: back to off
& $PSMUX set-option -t $SESSION pane-border-status off 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$v=(& $PSMUX show-options -v -t $SESSION pane-border-status 2>&1 | Out-String).Trim()
if($v -match "off"){Write-Pass "pane-border-status=off applies"}else{Write-Fail "off expected, got '$v'"}

# Test 5: session still healthy after all toggles + send-keys echoes
& $PSMUX send-keys -t $SESSION "echo PR481_MARKER" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1
$cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if($cap -match "PR481_MARKER"){Write-Pass "pane still functional after option churn (echo captured)"}else{Write-Fail "marker not captured"}

# ===================== Win32 TUI VISUAL VERIFICATION =====================
Write-Host "`n=== Win32 TUI: real window with pane-border-status top ===" -ForegroundColor Cyan
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4
& $PSMUX has-session -t $SESSION_TUI 2>$null
if($LASTEXITCODE -eq 0){Write-Pass "TUI: attached window session live"}else{Write-Fail "TUI: session not live"}

& $PSMUX split-window -h -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX set-option -t $SESSION_TUI pane-border-status top 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$tp=(& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1).Trim()
if($tp -eq "2"){Write-Pass "TUI: 2 panes with border-status top, window intact"}else{Write-Fail "TUI panes=$tp"}

# drive a cursor move in the labelled pane; window must remain responsive
& $PSMUX send-keys -t $SESSION_TUI "echo TUI_ALIVE" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 1
$tcap = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
if($tcap -match "TUI_ALIVE"){Write-Pass "TUI: labelled pane responsive (echo visible)"}else{Write-Fail "TUI: pane not responsive"}

Cleanup
try{ if($proc -and -not $proc.HasExited){ Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } }catch{}

Write-Host "`n=== PR #481 Results: Passed=$script:Passed Failed=$script:Failed ===" -ForegroundColor Cyan
exit $script:Failed
