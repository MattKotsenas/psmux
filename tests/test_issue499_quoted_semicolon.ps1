# Issue #499: set-option: ";" inside a double-quoted value split the one-shot
# command line (value truncated, remainder executed as its own command).
#
# Layer 1 (E2E via CLI + raw TCP) and Layer 2 (Win32 TUI visual verification).
# The severity check is Part C: the remainder used to EXECUTE, so a value of
# "x ; kill-server" killed the server.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue499"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

$SEP = [char]92 + ";"   # a literal \; argv token, kept out of the source text

function Remove-Session($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Get-ChildItem -Path $psmuxDir -Filter "$name.*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

function New-TestSession($name) {
    Remove-Session $name
    & $PSMUX new-session -d -s $name 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & $PSMUX has-session -t $name 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-Opt($name, $session = $SESSION) {
    (& $PSMUX show-options -qv -t $session $name 2>&1 | Out-String).TrimEnd("`r", "`n")
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
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

Write-Host "`n=== Issue #499 Tests ===" -ForegroundColor Cyan

if (-not (New-TestSession $SESSION)) {
    Write-Fail "Session creation failed"
    exit 1
}

# === PART A: CLI path - the exact reproduction from the issue ===
Write-Host "`n[Part A] CLI path: quoted semicolon must round-trip" -ForegroundColor Yellow

& $PSMUX set-option -t $SESSION '@key' "a ; b" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$v = Get-Opt '@key'
if ($v -eq "a ; b") { Write-Pass "@key round-trips as 'a ; b'" }
else { Write-Fail "@key expected 'a ; b', got '$v'" }

& $PSMUX set-option -t $SESSION '@key2' "a \; b" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$v2 = Get-Opt '@key2'
# tmux parity: a mid-argument `\;` is not unescaped (cmd_parse_from_arguments
# only rewrites a TRAILING `\;`), so the backslash is preserved verbatim.
if ($v2 -eq "a \; b") { Write-Pass "@key2 round-trips as 'a \; b' (tmux parity)" }
else { Write-Fail "@key2 expected 'a \; b', got '$v2'" }

& $PSMUX set-option -t $SESSION '@sq' 'p ; q' 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$vsq = Get-Opt '@sq'
if ($vsq -eq "p ; q") { Write-Pass "value with spaces around ';' round-trips" }
else { Write-Fail "expected 'p ; q', got '$vsq'" }

# === PART B: the remainder must NOT execute ===
Write-Host "`n[Part B] Remainder must not execute as a command" -ForegroundColor Yellow

& $PSMUX set-option -t $SESSION '@victim' "x ; set-option -t $SESSION @canary FIRED" 2>&1 | Out-Null
Start-Sleep -Seconds 1
$victim = Get-Opt '@victim'
$canary = Get-Opt '@canary'
if ($victim -eq "x ; set-option -t $SESSION @canary FIRED") { Write-Pass "@victim kept its full value" }
else { Write-Fail "@victim truncated to '$victim'" }
if ([string]::IsNullOrWhiteSpace($canary)) { Write-Pass "@canary never fired (no command injection)" }
else { Write-Fail "COMMAND INJECTION: @canary = '$canary'" }

# The exact severity case from the issue: the server must survive.
Write-Host "`n[Part B2] 'x ; kill-server' inside a quoted value" -ForegroundColor Yellow
$KILLS = "test_issue499_kill"
if (New-TestSession $KILLS) {
    & $PSMUX set-option -t $KILLS '@key3' "x ; kill-server" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $PSMUX has-session -t $KILLS 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Pass "Server survived a quoted 'kill-server' value" }
    else { Write-Fail "SERVER KILLED by a value inside quotes" }
    $v3 = Get-Opt '@key3' $KILLS
    if ($v3 -eq "x ; kill-server") { Write-Pass "@key3 kept its full value" }
    else { Write-Fail "@key3 expected 'x ; kill-server', got '$v3'" }
    Remove-Session $KILLS
} else {
    Write-Fail "Could not create kill-test session"
}

# === PART C: genuine chaining must still work ===
Write-Host "`n[Part C] Genuine chaining still works" -ForegroundColor Yellow

& $PSMUX set-option -t $SESSION '@c1' one $SEP set-option -t $SESSION '@c2' two 2>&1 | Out-Null
Start-Sleep -Seconds 1
$c1 = Get-Opt '@c1'; $c2 = Get-Opt '@c2'
if ($c1 -eq "one" -and $c2 -eq "two") { Write-Pass "'\;' chaining executed both sub-commands" }
else { Write-Fail "chaining broke: @c1='$c1' @c2='$c2'" }

& $PSMUX set-option -t $SESSION '@d1' three ";" set-option -t $SESSION '@d2' four 2>&1 | Out-Null
Start-Sleep -Seconds 1
$d1 = Get-Opt '@d1'; $d2 = Get-Opt '@d2'
if ($d1 -eq "three" -and $d2 -eq "four") { Write-Pass "bare ';' chaining executed both sub-commands" }
else { Write-Fail "bare ';' chaining broke: @d1='$d1' @d2='$d2'" }

# A real separator and a quoted semicolon on the same line.
& $PSMUX set-option -t $SESSION '@mix1' "l ; r" $SEP set-option -t $SESSION '@mix2' done 2>&1 | Out-Null
Start-Sleep -Seconds 1
$m1 = Get-Opt '@mix1'; $m2 = Get-Opt '@mix2'
if ($m1 -eq "l ; r" -and $m2 -eq "done") { Write-Pass "quoted ';' and a real separator coexist" }
else { Write-Fail "mixed line broke: @mix1='$m1' @mix2='$m2'" }

# Whitespace inside a quoted value must survive chaining (was collapsed before).
& $PSMUX set-option -t $SESSION '@w1' 1 $SEP set-option -t $SESSION '@w2' "x    y" 2>&1 | Out-Null
Start-Sleep -Seconds 1
$w2 = Get-Opt '@w2'
if ($w2 -eq "x    y") { Write-Pass "inner whitespace survives chaining (len $($w2.Length))" }
else { Write-Fail "whitespace collapsed: expected 'x    y', got '$w2' (len $($w2.Length))" }

# === PART D: tmux parity - a partial-token semicolon is not a separator ===
Write-Host "`n[Part D] tmux parity: partial-token ';' is not a separator" -ForegroundColor Yellow

& $PSMUX set-option -t $SESSION '@p1' "a; b" 2>&1 | Out-Null
& $PSMUX set-option -t $SESSION '@p2' "a;b" 2>&1 | Out-Null
Start-Sleep -Seconds 1
$p1 = Get-Opt '@p1'; $p2 = Get-Opt '@p2'
if ($p1 -eq "a; b") { Write-Pass "'a; b' round-trips" } else { Write-Fail "'a; b' became '$p1'" }
if ($p2 -eq "a;b") { Write-Pass "'a;b' round-trips" } else { Write-Fail "'a;b' became '$p2'" }

# === PART E: raw TCP server path ===
Write-Host "`n[Part E] Raw TCP server path" -ForegroundColor Yellow

$resp = Send-TcpCommand -Session $SESSION -Command 'set-option @tcp1 "m ; n"'
Start-Sleep -Milliseconds 800
$t1 = Get-Opt '@tcp1'
if ($t1 -eq "m ; n") { Write-Pass "TCP: quoted ';' round-trips (resp: $resp)" }
else { Write-Fail "TCP: expected 'm ; n', got '$t1'" }

$resp = Send-TcpCommand -Session $SESSION -Command "set-option @tcp2 'u ; v'"
Start-Sleep -Milliseconds 800
$t2 = Get-Opt '@tcp2'
if ($t2 -eq "u ; v") { Write-Pass "TCP: single-quoted ';' round-trips" }
else { Write-Fail "TCP: expected 'u ; v', got '$t2'" }

$resp = Send-TcpCommand -Session $SESSION -Command "set-option @tcp3 aa $SEP set-option @tcp4 bb"
Start-Sleep -Seconds 1
$t3 = Get-Opt '@tcp3'; $t4 = Get-Opt '@tcp4'
if ($t3 -eq "aa" -and $t4 -eq "bb") { Write-Pass "TCP: chaining executed both sub-commands" }
else { Write-Fail "TCP chaining broke: @tcp3='$t3' @tcp4='$t4'" }

# === PART F: edge cases ===
Write-Host "`n[Part F] Edge cases" -ForegroundColor Yellow

$resp = Send-TcpCommand -Session $SESSION -Command 'set-option @edge1 "unterminated ; quote'
Start-Sleep -Milliseconds 600
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "Unterminated quote did not kill the server" }
else { Write-Fail "Unterminated quote killed the server" }

& $PSMUX set-option -t $SESSION '@edge2' "C:\Program Files\Git\bin\bash.exe" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$e2 = Get-Opt '@edge2'
if ($e2 -eq "C:\Program Files\Git\bin\bash.exe") { Write-Pass "Windows path with spaces round-trips" }
else { Write-Fail "path expected 'C:\Program Files\Git\bin\bash.exe', got '$e2'" }

& $PSMUX set-option -t $SESSION '@edge3' "a ; b ; c ; d" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$e3 = Get-Opt '@edge3'
if ($e3 -eq "a ; b ; c ; d") { Write-Pass "Multiple quoted semicolons round-trip" }
else { Write-Fail "expected 'a ; b ; c ; d', got '$e3'" }

# A realistic user value: status-left with a semicolon.
& $PSMUX set-option -t $SESSION 'status-left' "[#S] ; ready" 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$sl = (& $PSMUX show-options -v status-left -t $SESSION 2>&1 | Out-String).TrimEnd("`r", "`n")
if ($sl -match "ready") { Write-Pass "status-left with ';' round-trips: '$sl'" }
else { Write-Fail "status-left lost its tail: '$sl'" }

Remove-Session $SESSION

# === PART G: Win32 TUI visual verification ===
Write-Host "`n[Part G] Win32 TUI visual verification" -ForegroundColor Yellow

$SESSION_TUI = "issue499_tui"
Remove-Session $SESSION_TUI
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session", "-s", $SESSION_TUI -PassThru
Start-Sleep -Seconds 5

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "TUI: attached session is alive"

    & $PSMUX set-option -t $SESSION_TUI '@tui1' "a ; b" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $tv = Get-Opt '@tui1' $SESSION_TUI
    if ($tv -eq "a ; b") { Write-Pass "TUI: quoted ';' round-trips against a live TUI" }
    else { Write-Fail "TUI: expected 'a ; b', got '$tv'" }

    & $PSMUX set-option -t $SESSION_TUI '@tui2' "z ; kill-server" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $PSMUX has-session -t $SESSION_TUI 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: survived a quoted 'kill-server' value" }
    else { Write-Fail "TUI: server killed by a quoted value" }

    # The TUI must still render and respond after all of the above.
    & $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1 | Out-String).Trim()
    if ($panes -eq "2") { Write-Pass "TUI: still functional (split-window created 2 panes)" }
    else { Write-Fail "TUI: expected 2 panes, got '$panes'" }
} else {
    Write-Fail "TUI: session did not start"
}

Remove-Session $SESSION_TUI
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
