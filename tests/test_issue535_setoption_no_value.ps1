# Issue #535: `set-option` silently ignored a command that carried no value.
#
# Reported symptom: `psmux set -g @foo` (one positional, no -q) set nothing,
# wrote nothing to stderr and exited 0. In PowerShell a bare `@name` is the
# splatting operator, so `psmux set -g @vpn_pill $undefined` reaches psmux as
# `set -g <text>` and vanished, which is undiagnosable from a script.
#
# Expected behaviour is taken from tmux 3.4, measured directly (WSL), not
# assumed:
#   set -g @foo            -> exit 1, stderr "empty value"
#   set -gq @foo           -> exit 1, "empty value"   (-q does NOT cover this;
#                             tmux scopes -q to unknown/ambiguous options only)
#   set -ga @foo           -> exit 1, "empty value"   (append needs a value)
#   set -g                 -> exit 1, "too few arguments (need at least 1)"
#   set -g mouse           -> exit 0, TOGGLES the flag (no error)
#   set -gu @foo           -> exit 0, unsets (1 positional is legal with -u)
#   set -g @foo ""         -> exit 0, sets the empty string (explicit value)
#
# Covers the CLI dispatch path (main.rs) and the TCP server path
# (server/connection.rs), which is where the command was being dropped.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue535"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function S($v) { if ($null -eq $v) { "" } else { ([string]$v).Trim() } }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# Run psmux capturing exit code, stdout and stderr separately.
function Run-Psmux([string[]]$ArgList) {
    $so = "$env:TEMP\t535_o.txt"; $se = "$env:TEMP\t535_e.txt"
    Remove-Item $so,$se -Force -EA SilentlyContinue
    $p = Start-Process -FilePath $PSMUX -ArgumentList $ArgList -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $so -RedirectStandardError $se
    return @{
        Code = $p.ExitCode
        Out  = S (Get-Content $so -Raw -EA SilentlyContinue)
        Err  = S (Get-Content $se -Raw -EA SilentlyContinue)
    }
}

function Get-Opt([string]$name) {
    (Run-Psmux @("show","-gv",$name,"-t",$SESSION)).Out
}

# Assert a no-value set-option fails loudly (exit 1 + stderr mentioning the problem).
function Assert-LoudFailure($label, $argList, $expectFragment) {
    $r = Run-Psmux $argList
    if ($r.Code -ne 0 -and $r.Err -match $expectFragment) {
        Write-Pass "$label -> exit $($r.Code), stderr '$($r.Err)'"
    } elseif ($r.Code -eq 0) {
        Write-Fail "$label -> exit 0 (issue #535: silently ignored). stderr=[$($r.Err)]"
    } else {
        Write-Fail "$label -> exit $($r.Code) but stderr did not match '$expectFragment': [$($r.Err)]"
    }
}

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] session creation failed" -ForegroundColor Red; exit 1 }

Write-Host "`n=== Issue #535: set-option with no value ===" -ForegroundColor Cyan

# --- Test 1: the exact reproduction from the report ---------------------------
Write-Host "`n[Test 1] Reported repro: set -g @foo bar; set -g @foo" -ForegroundColor Yellow
$null = Run-Psmux @("set","-g","@foo","bar","-t",$SESSION)
$before = Get-Opt "@foo"
if ($before -eq "bar") { Write-Pass "Baseline: 'set -g @foo bar' stored 'bar'" }
else { Write-Fail "Baseline failed: expected 'bar', got '$before'" }

Assert-LoudFailure "set -g @foo (one positional, no -q)" `
    @("set","-g","@foo","-t",$SESSION) "empty value"

$after = Get-Opt "@foo"
if ($after -eq $before) { Write-Pass "Value left untouched by the rejected command ('$after')" }
else { Write-Fail "Rejected command still mutated the option: '$before' -> '$after'" }

# --- Test 2: -q must NOT suppress this (tmux 3.4 parity) ---------------------
Write-Host "`n[Test 2] -q does not suppress 'empty value' (tmux parity)" -ForegroundColor Yellow
Assert-LoudFailure "set -gq @foo" @("set","-gq","@foo","-t",$SESSION) "empty value"
Assert-LoudFailure "set -q @foo (no -g)" @("set","-q","@foo","-t",$SESSION) "empty value"

# --- Test 3: zero positionals -------------------------------------------------
Write-Host "`n[Test 3] Zero positionals" -ForegroundColor Yellow
Assert-LoudFailure "set -g" @("set","-g","-t",$SESSION) "too few arguments"
Assert-LoudFailure "set -gu (unset, no name)" @("set","-gu","-t",$SESSION) "too few arguments"

# --- Test 4: append needs a value --------------------------------------------
Write-Host "`n[Test 4] -a (append) with no value" -ForegroundColor Yellow
Assert-LoudFailure "set -ga @foo" @("set","-ga","@foo","-t",$SESSION) "empty value"

# --- Test 5: built-in (non-user) options too ----------------------------------
Write-Host "`n[Test 5] Built-in options, not just @user options" -ForegroundColor Yellow
Assert-LoudFailure "set -g status-left (string opt)" `
    @("set","-g","status-left","-t",$SESSION) "empty value"
Assert-LoudFailure "set -g history-limit (number opt)" `
    @("set","-g","history-limit","-t",$SESSION) "empty value"
Assert-LoudFailure "setw -g @wfoo (setw alias)" `
    @("setw","-g","@wfoo","-t",$SESSION) "empty value"
Assert-LoudFailure "set-option -g @sofoo (full name)" `
    @("set-option","-g","@sofoo","-t",$SESSION) "empty value"

# A rejected command must not have damaged the real option.
$hl = Get-Opt "history-limit"
if ($hl -match '^\d+$') { Write-Pass "history-limit still intact after rejection ('$hl')" }
else { Write-Fail "history-limit corrupted by rejected command: '$hl'" }

# --- Test 6: BOOLEAN options still toggle (must NOT become an error) ----------
# tmux toggles flag options given no value; psmux did this for config files
# (#278) but the CLI/TCP path dropped the command entirely, so `psmux set -g
# mouse` was a silent no-op. Fixing #535 must make it toggle, not error.
Write-Host "`n[Test 6] Boolean options toggle instead of erroring (tmux parity)" -ForegroundColor Yellow
$null = Run-Psmux @("set","-g","mouse","on","-t",$SESSION)
$m0 = Get-Opt "mouse"
$r = Run-Psmux @("set","-g","mouse","-t",$SESSION)
$m1 = Get-Opt "mouse"
if ($r.Code -eq 0 -and $r.Err -eq "") { Write-Pass "set -g mouse exits 0 with no stderr" }
else { Write-Fail "set -g mouse should succeed quietly, got exit $($r.Code) stderr=[$($r.Err)]" }
if ($m0 -eq "on" -and $m1 -eq "off") { Write-Pass "mouse toggled on -> off" }
else { Write-Fail "mouse should toggle on->off, got '$m0' -> '$m1'" }

$null = Run-Psmux @("set","-g","mouse","-t",$SESSION)
$m2 = Get-Opt "mouse"
if ($m2 -eq "on") { Write-Pass "mouse toggled back off -> on" }
else { Write-Fail "mouse should toggle off->on, got '$m2'" }

# bold-is-bright is parsed as a boolean by the server, so it must toggle too.
$b0 = Get-Opt "bold-is-bright"
$r = Run-Psmux @("set","-g","bold-is-bright","-t",$SESSION)
$b1 = Get-Opt "bold-is-bright"
if ($r.Code -eq 0 -and $b1 -ne $b0) { Write-Pass "bold-is-bright toggled '$b0' -> '$b1'" }
else { Write-Fail "bold-is-bright should toggle, got exit $($r.Code), '$b0' -> '$b1'" }

# --- Test 7: legitimate forms must keep working -------------------------------
Write-Host "`n[Test 7] Valid invocations still succeed" -ForegroundColor Yellow
$r = Run-Psmux @("set","-g","@ok","hello","-t",$SESSION)
if ($r.Code -eq 0 -and (Get-Opt "@ok") -eq "hello") { Write-Pass "set -g @ok hello" }
else { Write-Fail "set -g @ok hello failed: exit $($r.Code) value '$(Get-Opt "@ok")'" }

# Explicit empty string is a real value (tmux allows it), not a missing one.
# NOTE: this case MUST use a native call. Start-Process -ArgumentList joins the
# array with spaces, so an empty element disappears before psmux is launched
# and the test would "fail" on an argument psmux never received. The option
# name is held in a variable because a bare @name in PowerShell argument
# position is the splatting operator, the very accident behind this issue.
$optName = "@ok"
$emptyOut = & $PSMUX set -g $optName "" -t $SESSION 2>&1
$emptyCode = $LASTEXITCODE
$v = Get-Opt "@ok"
if ($emptyCode -eq 0 -and $v -eq "") { Write-Pass "set -g @ok `"`" sets the empty string (exit 0)" }
else { Write-Fail "set -g @ok `"`" should succeed and clear, got exit $emptyCode value '$v' msg=[$emptyOut]" }

# -u legitimately takes a single positional.
$null = Run-Psmux @("set","-g","@tounset","x","-t",$SESSION)
$r = Run-Psmux @("set","-gu","@tounset","-t",$SESSION)
if ($r.Code -eq 0 -and $r.Err -eq "") { Write-Pass "set -gu @tounset (1 positional) still allowed" }
else { Write-Fail "set -gu should succeed, got exit $($r.Code) stderr=[$($r.Err)]" }

# Multi-word values must be unaffected.
$r = Run-Psmux @("set","-g","@multi","one two three","-t",$SESSION)
$v = Get-Opt "@multi"
if ($r.Code -eq 0 -and $v -match "one two three") { Write-Pass "Multi-word value preserved ('$v')" }
else { Write-Fail "Multi-word value broken: exit $($r.Code) value '$v'" }

# A -t target value must never be mistaken for the missing option value.
$r = Run-Psmux @("set","-g","@tgt","val","-t",$SESSION)
if ($r.Code -eq 0 -and (Get-Opt "@tgt") -eq "val") { Write-Pass "-t target not counted as a positional" }
else { Write-Fail "-t handling regressed: exit $($r.Code) value '$(Get-Opt "@tgt")'" }

# --- Test 8: the reporter's actual PowerShell splatting accident -------------
Write-Host "`n[Test 8] Real-world case: PowerShell swallows an undefined `$var" -ForegroundColor Yellow
$text = $null   # undefined, exactly as in the dotfiles-Windows status refresher
$splatArgs = @("set","-g","@vpn_pill") + @($text | Where-Object { $_ }) + @("-t",$SESSION)
$r = Run-Psmux $splatArgs
if ($r.Code -ne 0 -and $r.Err -match "empty value") {
    Write-Pass "Undefined value now reported: exit $($r.Code), '$($r.Err)'"
} else {
    Write-Fail "The reported scenario is still silent: exit $($r.Code) stderr=[$($r.Err)]"
}
if ($r.Err -match "@vpn_pill") { Write-Pass "Error names the offending option (@vpn_pill)" }
else { Write-Fail "Error should name the option, got: [$($r.Err)]" }

# --- Test 9: TCP server path (server/connection.rs) --------------------------
# The server arm is where the command was dropped. It cannot return an exit
# code, but it must no longer discard a boolean toggle, and must not corrupt
# an option when the value is missing.
Write-Host "`n[Test 9] Raw TCP server path" -ForegroundColor Yellow
$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$key  = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
function Send-Tcp([string]$cmd) {
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $st = $tcp.GetStream()
    $w = [System.IO.StreamWriter]::new($st); $rd = [System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush()
    if ($rd.ReadLine() -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $w.Write("$cmd`n"); $w.Flush()
    $st.ReadTimeout = 5000
    try { $resp = $rd.ReadLine() } catch { $resp = "" }
    $tcp.Close()
    return $resp
}
$null = Send-Tcp "set -g @tcpopt keepme"
Start-Sleep -Milliseconds 300
$null = Send-Tcp "set -g @tcpopt"
Start-Sleep -Milliseconds 300
$tcpVal = Get-Opt "@tcpopt"
if ($tcpVal -eq "keepme") { Write-Pass "TCP: value-less set left '@tcpopt' = 'keepme' intact" }
else { Write-Fail "TCP: '@tcpopt' should stay 'keepme', got '$tcpVal'" }

$null = Send-Tcp "set -g mouse on"
Start-Sleep -Milliseconds 300
$t0 = Get-Opt "mouse"
$null = Send-Tcp "set -g mouse"
Start-Sleep -Milliseconds 500
$t1 = Get-Opt "mouse"
if ($t0 -eq "on" -and $t1 -eq "off") { Write-Pass "TCP: boolean toggle now reaches the server (on -> off)" }
else { Write-Fail "TCP: boolean toggle dropped by server: '$t0' -> '$t1'" }

# --- Test 10: Win32 TUI visual verification ----------------------------------
# A real attached window, driven by CLI commands, proving the new validation
# does not disturb a live session and that a toggle lands on the running TUI.
Write-Host "`n[Test 10] Win32 TUI visual verification" -ForegroundColor Yellow
$SESSION_TUI = "test535_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

$so = "$env:TEMP\t535_tui_o.txt"; $se = "$env:TEMP\t535_tui_e.txt"
$p = Start-Process -FilePath $PSMUX -ArgumentList @("set","-g","@tui_opt","-t",$SESSION_TUI) `
     -NoNewWindow -Wait -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
$tuiErr = S (Get-Content $se -Raw -EA SilentlyContinue)
if ($p.ExitCode -ne 0 -and $tuiErr -match "empty value") {
    Write-Pass "TUI: value-less set rejected against a live attached session"
} else {
    Write-Fail "TUI: expected loud failure, got exit $($p.ExitCode) stderr=[$tuiErr]"
}

# The session must still be alive and responsive after the rejection.
& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: session survived the rejected command" }
else { Write-Fail "TUI: session died after a rejected set-option" }

$panesBefore = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1 | Out-String).Trim()
& $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panesAfter = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panesBefore -eq "1" -and $panesAfter -eq "2") { Write-Pass "TUI: still functional (split 1 -> 2 panes)" }
else { Write-Fail "TUI: split failed, panes '$panesBefore' -> '$panesAfter'" }

$mouseTui0 = (& $PSMUX show -gv mouse -t $SESSION_TUI 2>&1 | Out-String).Trim()
& $PSMUX set -g mouse -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$mouseTui1 = (& $PSMUX show -gv mouse -t $SESSION_TUI 2>&1 | Out-String).Trim()
if ($mouseTui0 -ne $mouseTui1) { Write-Pass "TUI: 'set -g mouse' toggled live ('$mouseTui0' -> '$mouseTui1')" }
else { Write-Fail "TUI: mouse toggle had no effect ('$mouseTui0' -> '$mouseTui1')" }

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

Cleanup
Remove-Item "$env:TEMP\t535_*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
