# Issue #647 (WIN-02): `show-options -v` must print the value and nothing else.
#
# A gateway controller compares the stdout of
#   show-options -p -v -t %0 remain-on-exit
# with the literal strings `on` and `off`. psmux answered `remain-on-exit on`
# because the pane scope branch ignored both the option name and `-v` and
# echoed the whole pane store instead.
#
# tmux prints the value alone under `-v` in every scope:
#   cmd-show-options.c:192-194
#       value = options_to_string(o, array_key, 0);
#       if (args_has(args, 'v'))
#               cmdq_print(item, "%s", value);
# and prints nothing at all when the option is not set in that scope's own
# store, unless `-A` asks for the inherited value.
#
# Measured against tmux 3.4 under WSL (LANG=C.UTF-8):
#   show-options -p -v  -t %0 remain-on-exit  => []    rc=0   before set -p
#   show-options -pA -v -t %0 remain-on-exit  => [off] rc=0   inherited
#   show-options -p -v  -t %0 remain-on-exit  => [on]  rc=0   after set -p on
#   show-options -p     -t %0 remain-on-exit  => [remain-on-exit on]
#   show-options -w -v / -g -v / -s -v / -gv  => value only, every time
$ErrorActionPreference = "Continue"
if ($env:PSMUX_TEST_EXE) { $PSMUX = $env:PSMUX_TEST_EXE }
else { $PSMUX = (Get-Command psmux -EA Stop).Source }
$SESSION = "t647opt"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$env:PSMUX_NO_WARM = "1"
function Cleanup { & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null }

Cleanup
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $SESSION -n zero 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

Write-Host "`n=== Issue #647 WIN-02: show-options -v is value only ===" -ForegroundColor Cyan

$pane = ((& $PSMUX list-panes -t $SESSION -F '#{pane_id}') | Select-Object -First 1).Trim()
Write-Host "  target pane: $pane"

# --- Arm 1: pane scope, the reported case ---
Write-Host "[Arm 1] pane scope (-p -v and -pv)" -ForegroundColor Yellow
& $PSMUX set-option -p -t $pane remain-on-exit on 2>&1 | Out-Null
foreach ($flags in @(@('-p','-v'), @('-pv'))) {
    $out = ((& $PSMUX show-options @flags -t $pane remain-on-exit 2>&1) -join "`n").Trim()
    if ($out -eq 'on') { Write-Pass "show-options $($flags -join ' ') -t $pane remain-on-exit => [on]" }
    else { Write-Fail "show-options $($flags -join ' ') printed [$out], expected [on]" }
}

# Without -v the name comes back with the value, exactly as tmux prints it.
$out = ((& $PSMUX show-options -p -t $pane remain-on-exit 2>&1) -join "`n").Trim()
if ($out -eq 'remain-on-exit on') { Write-Pass "show-options -p (no -v) => [remain-on-exit on]" }
else { Write-Fail "show-options -p (no -v) printed [$out], expected [remain-on-exit on]" }

# A named query answers with that one option, never the whole pane store.
& $PSMUX set-option -p -t $pane '@mouse-force' on 2>&1 | Out-Null
$out = ((& $PSMUX show-options -p -v -t $pane '@mouse-force' 2>&1) -join "`n").Trim()
if ($out -eq 'on') { Write-Pass "a named query answers with one option (@mouse-force => [on])" }
else { Write-Fail "@mouse-force query printed [$out], expected [on]" }
$out = ((& $PSMUX show-options -p -v -t $pane remain-on-exit 2>&1) -join "`n").Trim()
if ($out -eq 'on') { Write-Pass "remain-on-exit still answers alone with two options stored" }
else { Write-Fail "remain-on-exit query printed [$out], expected [on]" }

# The bare listing (issue #580's contract) is untouched.
$listing = ((& $PSMUX show-options -p -t $pane 2>&1) -join "`n")
if ($listing -match 'remain-on-exit on' -and $listing -match '@mouse-force on') {
    Write-Pass "bare show-options -p still lists the whole pane store"
} else {
    Write-Fail "bare show-options -p listing regressed: [$listing]"
}

# --- Arm 2: an option the pane does not store ---
Write-Host "[Arm 2] unset pane option prints nothing, -A shows the inherited value" -ForegroundColor Yellow
$pane2 = ((& $PSMUX split-window -d -t $SESSION -P -F '#{pane_id}' 2>&1) -join '').Trim()
Start-Sleep -Seconds 2
if ($pane2 -notmatch '^%\d+$') {
    Write-Fail "could not create a second pane (got [$pane2])"
} else {
    $out = ((& $PSMUX show-options -p -v -t $pane2 remain-on-exit 2>&1) -join "`n").Trim()
    $rc = $LASTEXITCODE
    if ($out -eq '') { Write-Pass "unset pane option prints nothing (tmux parity)" }
    else { Write-Fail "unset pane option printed [$out], expected nothing" }
    if ($rc -eq 0) { Write-Pass "unset pane option still exits 0" }
    else { Write-Fail "unset pane option exited $rc, expected 0" }

    $out = ((& $PSMUX show-options -pA -v -t $pane2 remain-on-exit 2>&1) -join "`n").Trim()
    if ($out -eq 'off' -or $out -eq 'on') { Write-Pass "-A falls back to the inherited value ([$out])" }
    else { Write-Fail "-A printed [$out], expected the inherited on/off" }
}

# --- Arm 3: every other scope stays value only ---
Write-Host "[Arm 3] window, session, server and user scopes" -ForegroundColor Yellow
& $PSMUX set-option -g '@i647' 'barvalue' 2>&1 | Out-Null
$cases = @(
    @{ Name = '-w -v  remain-on-exit'; Args = @('-w','-v','-t',"${SESSION}:zero",'remain-on-exit'); Expect = '^(on|off)$' }
    @{ Name = '-wv    remain-on-exit'; Args = @('-wv','-t',"${SESSION}:zero",'remain-on-exit');     Expect = '^(on|off)$' }
    @{ Name = '-g -v  remain-on-exit'; Args = @('-g','-v','remain-on-exit');                        Expect = '^(on|off)$' }
    @{ Name = '-gv    remain-on-exit'; Args = @('-gv','remain-on-exit');                            Expect = '^(on|off)$' }
    @{ Name = '-s -v  exit-empty';     Args = @('-s','-v','exit-empty');                            Expect = '^(on|off)$' }
    @{ Name = '-sv    exit-empty';     Args = @('-sv','exit-empty');                                Expect = '^(on|off)$' }
    @{ Name = '-g -v  @i647';          Args = @('-g','-v','@i647');                                 Expect = '^barvalue$' }
    @{ Name = '-gv    @i647';          Args = @('-gv','@i647');                                     Expect = '^barvalue$' }
)
foreach ($c in $cases) {
    $out = ((& $PSMUX show-options @($c.Args) 2>&1) -join "`n").Trim()
    if ($out -match $c.Expect) { Write-Pass "show-options $($c.Name) => [$out]" }
    else { Write-Fail "show-options $($c.Name) printed [$out], expected /$($c.Expect)/" }
    if ($out -match '\s') { Write-Fail "show-options $($c.Name) leaked the option name into a -v answer" }
}

Cleanup
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------------------
# Win32 TUI verification: the same contract on the attached command route,
# which dispatches through a different handler than the one-shot CLI.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 60)
Write-Host "Win32 TUI VISUAL VERIFICATION"
Write-Host ("=" * 60)

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION,"-n","zero" -PassThru
Start-Sleep -Seconds 6
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "TUI: attached session did not start"
} else {
    $tpane = ((& $PSMUX list-panes -t $SESSION -F '#{pane_id}') | Select-Object -First 1).Trim()
    & $PSMUX set-option -p -t $tpane remain-on-exit on 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    $out = ((& $PSMUX show-options -p -v -t $tpane remain-on-exit 2>&1) -join "`n").Trim()
    if ($out -eq 'on') { Write-Pass "TUI: show-options -p -v on an attached session => [on]" }
    else { Write-Fail "TUI: attached show-options -p -v printed [$out], expected [on]" }

    $out = ((& $PSMUX show-options -p -t $tpane remain-on-exit 2>&1) -join "`n").Trim()
    if ($out -eq 'remain-on-exit on') { Write-Pass "TUI: show-options -p (no -v) => [remain-on-exit on]" }
    else { Write-Fail "TUI: attached show-options -p printed [$out]" }

    $listing = ((& $PSMUX show-options -p -t $tpane 2>&1) -join "`n")
    if ($listing -match 'remain-on-exit on') { Write-Pass "TUI: bare show-options -p still lists the store" }
    else { Write-Fail "TUI: bare show-options -p listing regressed: [$listing]" }
}

Cleanup
if ($proc) { try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {} }
Start-Sleep -Milliseconds 500

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
