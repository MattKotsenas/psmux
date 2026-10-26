# Issue #580 (item 4, reported by BuKyungBuKyung): `#{pane_start_command}` was
# hardcoded to the SERVER's default shell (`src/format.rs`:
# `"pane_start_command" => app.default_shell.clone()`), so every pane in a
# server answered with the same string and a pane created with an explicit
# command never reported that command. The reporter measured 24 panes and ONE
# distinct value.
#
# Real impact: oh-my-codex creates its HUD pane with a marker embedded in the
# command and gates every later mutation (adopt, resize, kill) on
# `#{m:*<marker>*,#{pane_start_command}}`. The predicate could never be true,
# so cleanup never ran and one orphaned pane leaked per prompt submission.
#
# tmux semantics this pins (tmux 3.4, and format.c / spawn.c):
#   * default-shell pane            -> EMPTY string
#   * `new-window "sleep 300"`      -> `"sleep 300"` (args_escape quotes it)
#   * `new-window -- prog a b`      -> `prog a b`    (each word escaped alone)
#   * respawn WITH a command        -> replaced
#   * respawn WITHOUT a command     -> the original is kept AND re-run
#
# Covered here: the four creation paths, the omx-style marker predicate through
# both display-message and if-shell, the respawn cases, the warm pane pool ON
# and OFF (a claimed warm spare must report EMPTY, never the pool's
# powershell-pane.cmd wrapper), and a short attached-TUI check.
#
# Set PSMUX_BIN to test a non-installed binary.
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_BIN) { $env:PSMUX_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = "i580ns"
$MARK = "omx-580-marker-9f3a1c"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

# A long lived pane command whose PATH carries the marker, the same shape as
# oh-my-codex embedding its uuid in the HUD command.
$HUDDIR = Join-Path $env:TEMP "i580_hud"
New-Item -ItemType Directory -Force -Path $HUDDIR | Out-Null
$HUD = Join-Path $HUDDIR "hud_$MARK.ps1"
Set-Content -Path $HUD -Value 'Start-Sleep -Seconds 900' -Encoding ASCII
$HUDCMD = "pwsh -NoLogo -NoProfile -File $HUD"

function P { param([string[]]$A) & $PSMUX -L $NS @A 2>&1 }
function Ask($target, $fmt) { (P @('display-message','-p','-t',$target,$fmt) | Out-String).Trim() }
function StartOf($target) { Ask $target '#{pane_start_command}' }

function Reset-Server {
    P @('kill-server') | Out-Null
    Start-Sleep -Milliseconds 700
}

# ---------------------------------------------------------------------------
# One full arm: build the four pane kinds and assert every rule.
# ---------------------------------------------------------------------------
function Run-Arm([string]$Session, [bool]$NoWarm) {
    if ($NoWarm) { $env:PSMUX_NO_WARM = "1" } else { Remove-Item Env:\PSMUX_NO_WARM -EA SilentlyContinue }
    $label = if ($NoWarm) { "warm pool OFF" } else { "warm pool ON" }
    Write-Host "`n=== Arm: $label (session $Session) ===" -ForegroundColor Cyan

    Reset-Server
    P @('new-session','-d','-s',$Session) | Out-Null
    Start-Sleep -Seconds 3
    P @('has-session','-t',$Session) | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "$label : session did not start"; return }

    # w1: default shell. With the pool on this CLAIMS a pre-spawned warm pane.
    P @('new-window','-t',$Session,'-d') | Out-Null
    Start-Sleep -Seconds 2
    # w2: string command operand carrying the marker.
    P @('new-window','-t',$Session,'-d',$HUDCMD) | Out-Null
    Start-Sleep -Seconds 2
    # w2.1: split-window with a command operand.
    P @('split-window','-t',"${Session}:2.0",'-d',$HUDCMD) | Out-Null
    # w3: `-- <argv>` direct exec path (#582).
    P @('new-window','-t',$Session,'-d','--','pwsh','-NoLogo','-NoProfile','-File',$HUD) | Out-Null
    Start-Sleep -Seconds 4

    $listing = (P @('list-panes','-a','-F','#{pane_id} #{window_index}.#{pane_index}|START=[#{pane_start_command}]')) -join "`n"
    Write-Host $listing

    # --- Rule 1: a default-shell pane reports the EMPTY string ---
    $w0 = StartOf "${Session}:0.0"
    if ($w0 -eq '') { Write-Pass "$label : new-session pane reports empty (tmux: argc 0 -> `"`")" }
    else { Write-Fail "$label : new-session pane reported [$w0], want empty" }

    $w1 = StartOf "${Session}:1.0"
    if ($w1 -eq '') {
        $extra = if ($NoWarm) { "" } else { " (warm-pool claim: no powershell-pane.cmd wrapper leaked)" }
        Write-Pass "$label : default-shell new-window reports empty$extra"
    } else { Write-Fail "$label : default-shell new-window reported [$w1], want empty" }

    # --- Rule 2: a command pane reports ITS OWN command ---
    $w2 = StartOf "${Session}:2.0"
    if ($w2 -like "*$MARK*") { Write-Pass "$label : new-window <command> reports the command" }
    else { Write-Fail "$label : new-window <command> reported [$w2]" }

    $w21 = StartOf "${Session}:2.1"
    if ($w21 -like "*$MARK*") { Write-Pass "$label : split-window <command> reports the command" }
    else { Write-Fail "$label : split-window <command> reported [$w21]" }

    $w3 = StartOf "${Session}:3.0"
    if ($w3 -like "*$MARK*") { Write-Pass "$label : new-window -- <argv> reports the argv" }
    else { Write-Fail "$label : new-window -- <argv> reported [$w3]" }
    # tmux escapes each argv word separately, so the argv form is NOT wrapped
    # in one pair of quotes the way the single string form is.
    if ($w3 -notlike '"*') { Write-Pass "$label : argv form renders as a bare token list (tmux parity)" }
    else { Write-Fail "$label : argv form came back quoted as one word: [$w3]" }
    if ($w2 -like '"*"') { Write-Pass "$label : string form with spaces renders quoted (tmux args_escape)" }
    else { Write-Fail "$label : string form not quoted: [$w2]" }

    # --- Rule 3: the panes do NOT all report one value (the reported symptom) ---
    $distinct = (P @('list-panes','-a','-F','#{pane_start_command}')) | Sort-Object -Unique
    if ($distinct.Count -ge 2) { Write-Pass "$label : $($distinct.Count) distinct START values across the panes (was 1)" }
    else { Write-Fail "$label : still only $($distinct.Count) distinct value" }

    # --- Rule 4: the omx ownership predicate ---
    $hit = Ask "${Session}:2.0" "#{m:*$MARK*,#{pane_start_command}}"
    if ($hit -eq '1') { Write-Pass "$label : marker predicate matches the HUD pane" }
    else { Write-Fail "$label : marker predicate on the HUD pane = [$hit], want 1" }
    $miss = Ask "${Session}:0.0" "#{m:*$MARK*,#{pane_start_command}}"
    if ($miss -eq '0') { Write-Pass "$label : marker predicate does NOT match a shell pane" }
    else { Write-Fail "$label : marker predicate on the shell pane = [$miss], want 0" }

    # The same predicate through if-shell -F, which is how a tmux control tool
    # actually gates its cleanup.
    P @('set-option','-t',$Session,'@i580','none') | Out-Null
    P @('if-shell','-t',"${Session}:2.0",'-F',"#{m:*$MARK*,#{pane_start_command}}",
        "set-option -t $Session @i580 owned") | Out-Null
    Start-Sleep -Milliseconds 800
    $flag = (P @('show-options','-qv','-t',$Session,'@i580') | Out-String).Trim()
    if ($flag -eq 'owned') { Write-Pass "$label : if-shell -F predicate fires on the HUD pane" }
    else { Write-Fail "$label : if-shell -F gave [$flag], want owned" }

    P @('set-option','-t',$Session,'@i580','none') | Out-Null
    P @('if-shell','-t',"${Session}:0.0",'-F',"#{m:*$MARK*,#{pane_start_command}}",
        "set-option -t $Session @i580 wrongly-owned") | Out-Null
    Start-Sleep -Milliseconds 800
    $flag = (P @('show-options','-qv','-t',$Session,'@i580') | Out-String).Trim()
    if ($flag -eq 'none') { Write-Pass "$label : if-shell -F does not fire on a shell pane" }
    else { Write-Fail "$label : if-shell -F wrongly fired: [$flag]" }

    # --- Rule 5: respawn semantics (tmux spawn.c) ---
    # 5a. respawn WITH a command replaces the record.
    P @('respawn-pane','-k','-t',"${Session}:1.0",$HUDCMD) | Out-Null
    Start-Sleep -Seconds 3
    $r = StartOf "${Session}:1.0"
    if ($r -like "*$MARK*") { Write-Pass "$label : respawn-pane <command> replaces the record" }
    else { Write-Fail "$label : respawn-pane <command> left [$r]" }

    # 5b. respawn WITHOUT a command keeps the original.
    $before = StartOf "${Session}:2.0"
    P @('respawn-pane','-k','-t',"${Session}:2.0") | Out-Null
    Start-Sleep -Seconds 3
    $after = StartOf "${Session}:2.0"
    if ($after -eq $before -and $after -like "*$MARK*") { Write-Pass "$label : bare respawn-pane keeps the original command" }
    else { Write-Fail "$label : bare respawn-pane changed [$before] -> [$after]" }
    # It must also RE-RUN it, not silently fall back to a shell.
    $cur = Ask "${Session}:2.0" '#{pane_current_command}'
    if ($cur -match 'pwsh') { Write-Pass "$label : bare respawn re-ran the recorded command (running: $cur)" }
    else { Write-Fail "$label : bare respawn is running [$cur]" }

    # 5c. a bare respawn of a default-shell pane stays EMPTY.
    P @('respawn-pane','-k','-t',"${Session}:0.0") | Out-Null
    Start-Sleep -Seconds 3
    $r = StartOf "${Session}:0.0"
    if ($r -eq '') { Write-Pass "$label : bare respawn of a shell pane stays empty" }
    else { Write-Fail "$label : bare respawn of a shell pane reported [$r]" }

    # 5d. respawn-window with a command operand replaces the record too.
    P @('respawn-window','-k','-t',"${Session}:0",$HUDCMD) | Out-Null
    Start-Sleep -Seconds 3
    $r = StartOf "${Session}:0.0"
    if ($r -like "*$MARK*") { Write-Pass "$label : respawn-window <command> replaces the record" }
    else { Write-Fail "$label : respawn-window <command> left [$r]" }

    # --- Rule 6: the value is the USER's command, with no psmux spawn
    #     machinery (the shell wrapper, the `cat` blocker substitution) in it ---
    P @('new-window','-t',$Session,'-d','--','cat') | Out-Null
    Start-Sleep -Seconds 3
    $catwin = (P @('list-panes','-a','-F','#{window_index}|#{pane_start_command}')) | Where-Object { $_ -like '*|cat' }
    if ($catwin) { Write-Pass "$label : `-- cat` reports cat, not the blocker it actually runs" }
    else { Write-Fail "$label : `-- cat` pane did not report cat" }
    $anywrapper = (P @('list-panes','-a','-F','#{pane_start_command}')) | Where-Object { $_ -match 'powershell-pane|__warm__' }
    if (-not $anywrapper) { Write-Pass "$label : no warm-pool wrapper leaked into any pane" }
    else { Write-Fail "$label : wrapper leaked: [$anywrapper]" }

    P @('kill-session','-t',$Session) | Out-Null
    Start-Sleep -Milliseconds 500
}

Write-Host "=== Issue #580: #{pane_start_command} is the pane's own command ===" -ForegroundColor Cyan
Run-Arm -Session "i580warm" -NoWarm $false
Run-Arm -Session "i580cold" -NoWarm $true

# ---------------------------------------------------------------------------
# Attached TUI check: the same values must be correct while a real client is
# attached and rendering, not only for detached CLI queries.
# ---------------------------------------------------------------------------
Write-Host "`n=== Arm: attached TUI ===" -ForegroundColor Cyan
Remove-Item Env:\PSMUX_NO_WARM -EA SilentlyContinue
Remove-Item Env:\PSMUX_SESSION -EA SilentlyContinue
Remove-Item Env:\PSMUX_SESSION_NAME -EA SilentlyContinue
$TS = "i580tui"
Reset-Server
$proc = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"new-session","-s",$TS -PassThru -WindowStyle Normal
Start-Sleep -Seconds 6
P @('has-session','-t',$TS) | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [SKIP] attached client did not come up" -ForegroundColor Yellow
} else {
    P @('new-window','-t',$TS,'-d',$HUDCMD) | Out-Null
    Start-Sleep -Seconds 4
    $tui0 = StartOf "${TS}:0.0"
    $tui1 = StartOf "${TS}:1.0"
    if ($tui0 -eq '') { Write-Pass "attached TUI : attached session's own pane reports empty" }
    else { Write-Fail "attached TUI : attached pane reported [$tui0]" }
    if ($tui1 -like "*$MARK*") { Write-Pass "attached TUI : command pane reports its command under an attached client" }
    else { Write-Fail "attached TUI : command pane reported [$tui1]" }
    # The status line renders formats through the same path.
    P @('set-option','-t',$TS,'status-right',"#{pane_start_command}") | Out-Null
    Start-Sleep -Seconds 2
    $vis = (P @('display-message','-p','-t',"${TS}:1.0",'#{pane_start_command}') | Out-String).Trim()
    if ($vis -like "*$MARK*") { Write-Pass "attached TUI : format still resolves after a status-right redraw" }
    else { Write-Fail "attached TUI : format resolved to [$vis] after redraw" }
    P @('kill-session','-t',$TS) | Out-Null
}
Start-Sleep -Seconds 1
if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue }

Reset-Server
Remove-Item -Recurse -Force $HUDDIR -EA SilentlyContinue

Write-Host "`n============================================================" -ForegroundColor Magenta
Write-Host "  Passed: $script:TestsPassed   Failed: $script:TestsFailed" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
