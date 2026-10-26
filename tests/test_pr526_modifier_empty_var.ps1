# PR #526: a modifier over an empty-but-real variable must render nothing,
# not the variable's own name.
#
# Bug (reproduced on master f86cec1): #{b:pane_path} rendered the literal text
# "pane_path" whenever the shell had not yet announced a cwd via OSC 7, while
# a bare #{pane_path} correctly rendered empty. Every modifier (b: d: q: =N:)
# over an optional-but-real variable echoed the variable name.
#
# tmux 3.4 parity oracle: a modifier over an empty-but-real variable renders
# empty. (tmux also renders unknown names empty; psmux intentionally keeps the
# literal-echo fallback for genuinely unknown names, pinned in Part C.)
#
# Uses cmd.exe as the pane command so no OSC 7 ever arrives and pane_path is
# deterministically empty.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_pr526"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Get-Fmt($fmt) {
    (& $PSMUX display-message -t $SESSION -p $fmt 2>&1 | Out-String).Trim()
}

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION -- cmd.exe /k "echo ready"
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== PR #526 modifier-over-empty-variable tests ===" -ForegroundColor Cyan

# === PART A: CLI path (display-message -p) ===
Write-Host "`n[Part A] CLI path" -ForegroundColor Yellow

$bare = Get-Fmt '[#{pane_path}]'
if ($bare -eq "[]") { Write-Pass "bare #{pane_path} renders empty" }
else { Write-Fail "bare #{pane_path} expected [], got: $bare" }

foreach ($mod in @('b','d','q','=3')) {
    $out = Get-Fmt "[#{$($mod):pane_path}]"
    if ($out -eq "[]") { Write-Pass "#{$($mod):pane_path} renders empty (was echoing the name)" }
    else { Write-Fail "#{$($mod):pane_path} expected [], got: $out" }
}

$pop = Get-Fmt '[#{=3:session_name}]'
if ($pop -eq "[tes]") { Write-Pass "#{=3:session_name} still trims a populated variable" }
else { Write-Fail "#{=3:session_name} expected [tes], got: $pop" }

$bpop = Get-Fmt '[#{b:pane_current_path}]'
if ($bpop -ne "[]" -and $bpop -ne "[pane_current_path]") { Write-Pass "#{b:pane_current_path} yields a real basename: $bpop" }
else { Write-Fail "#{b:pane_current_path} expected a basename, got: $bpop" }

# === PART B: TCP server path ===
Write-Host "`n[Part B] TCP server path" -ForegroundColor Yellow
function Send-TcpCommand {
    param([string]$Command)
    $port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    if ($reader.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 10000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

$tcpOut = Send-TcpCommand 'display-message -p [#{b:pane_path}]'
if ($tcpOut -eq "[]") { Write-Pass "TCP display-message #{b:pane_path} renders empty" }
else { Write-Fail "TCP #{b:pane_path} expected [], got: $tcpOut" }

$tcpPop = Send-TcpCommand 'display-message -p [#{=3:session_name}]'
if ($tcpPop -eq "[tes]") { Write-Pass "TCP #{=3:session_name} trims populated variable" }
else { Write-Fail "TCP #{=3:session_name} expected [tes], got: $tcpPop" }

# === PART C: Edge cases and pinned intentional behavior ===
Write-Host "`n[Part C] Edge cases" -ForegroundColor Yellow

$unk = Get-Fmt '[#{b:definitely_not_a_var}]'
if ($unk -eq "[definitely_not_a_var]") { Write-Pass "genuinely unknown name still echoes as literal (intentional psmux behavior)" }
else { Write-Fail "unknown-name fallback changed: expected [definitely_not_a_var], got: $unk" }

$bareUnk = Get-Fmt '[#{definitely_not_a_var}]'
if ($bareUnk -eq "[]") { Write-Pass "bare unknown name renders empty (tmux parity)" }
else { Write-Fail "bare unknown expected [], got: $bareUnk" }

$nul = Get-Fmt '[#{b:pane_path}#{q:pane_path}#{pane_path}]'
if ($nul -eq "[]" -and $nul -notmatch "psmux:unknown") { Write-Pass "sentinel never leaks into combined output" }
else { Write-Fail "combined empties expected [], got: $nul" }

$nested = Get-Fmt '[#{?#{b:pane_path},HAS,NONE}]'
if ($nested -eq "[NONE]") { Write-Pass "conditional over #{b:pane_path} sees empty (NONE branch)" }
else { Write-Fail "conditional expected [NONE], got: $nested" }

# === PART D: Config-driven status bar (the reported real-world shape) ===
Write-Host "`n[Part D] status-right with a cwd pill" -ForegroundColor Yellow
& $PSMUX set-option -t $SESSION -g status-right '[#{b:pane_path}]' 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
$sr = (& $PSMUX show-options -g -v status-right -t $SESSION 2>&1 | Out-String).Trim()
if ($sr -eq '[#{b:pane_path}]') { Write-Pass "status-right option stored" }
else { Write-Fail "status-right expected [#{b:pane_path}], got: $sr" }
$direct = Get-Fmt '[#{b:pane_path}]'
if ($direct -eq "[]") { Write-Pass "cwd pill renders empty, not the text pane_path" }
else { Write-Fail "cwd pill rendered: $direct" }

Cleanup

# === Win32 TUI VISUAL VERIFICATION ===
Write-Host "`n=== Win32 TUI verification ===" -ForegroundColor Cyan
$SESSION_TUI = "pr526_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI,"--","cmd.exe" -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: attached session alive" }
else { Write-Fail "TUI: session not created" }

& $PSMUX set-option -t $SESSION_TUI -g status-right 'CWD[#{b:pane_path}]END' 2>&1 | Out-Null
Start-Sleep -Seconds 1
$tuiFmt = (& $PSMUX display-message -t $SESSION_TUI -p '[#{b:pane_path}]' 2>&1 | Out-String).Trim()
if ($tuiFmt -eq "[]") { Write-Pass "TUI: live status-bar format expands empty, not pane_path" }
else { Write-Fail "TUI: expected [], got: $tuiFmt" }

$tuiName = (& $PSMUX display-message -t $SESSION_TUI -p '#{=4:session_name}' 2>&1 | Out-String).Trim()
if ($tuiName -eq "pr52") { Write-Pass "TUI: populated variable still trims through modifier" }
else { Write-Fail "TUI: expected pr52, got: $tuiName" }

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
