# Copy mode parity with tmux 3.4, six gaps found side by side (WSL tmux 3.4,
# `tmux -L cp_N -f /dev/null`, 80x24 pane, `seq 1 200` in it):
#
#   1. `list-keys -T copy-mode-vi` printed nothing; tmux prints its 87 default
#      copy-mode-vi bindings (key-bindings.c), 72 for copy-mode. psmux now
#      lists the keys its built-in copy mode handles, and `unbind -T` on one
#      of them both drops the line and stops the key, as in tmux.
#   2. `send-keys -X history-top` on a pane in no mode ENTERED copy mode (rc 0);
#      tmux answers "not in a mode" at exit 1 and leaves the pane alone.
#   3. `send-keys -X history-top` left the cursor on its old screen row
#      (copy_cursor_y 23); tmux window_copy_cmd_history_top sets cy = cx = 0.
#   4. `send-keys -X -N 40 scroll-up` scrolled ONE line (scroll_position 1);
#      tmux scrolls 40. The CLI dropped -N before it reached the server, so
#      `send-keys -N 3 z` also typed a single z (tmux: zzz).
#   5. `copy-mode -Hu` from the CLI lost its clustered flags (entered copy
#      mode at scroll_position 0; tmux pages up to 22), and a root binding
#      `copy-mode -Hu` slipped past the scroll-enter-copy-mode off check,
#      which only looked for the literal text `-u`: the server then typed
#      PageUp into the pane instead of the key that was pressed.
#   6. A `copy-mode` line in a file run by `source-file` was ignored; tmux
#      enters copy mode (pane_mode copy-mode).
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0; $script:TestsFailed = 0
$script:Opened = @()

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null

# The default namespace must be untouched by this suite.
$defaultBefore = (& $PSMUX ls 2>&1 | Out-String).Trim()

$NS  = "cpp_" + [guid]::NewGuid().ToString('N').Substring(0, 8)
$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_cpp_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null
$savedDataDir = $env:PSMUX_DATA_DIR
$env:PSMUX_DATA_DIR = Join-Path $TMP "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"

function P { & $PSMUX -L $NS @args 2>&1 }
function Fmt($t, $f) { ((& $PSMUX -L $NS display-message -t $t -p $f 2>&1) | Out-String).Trim() }

function New-Sess($name) {
    P new-session -d -s $name -x 80 -y 24 | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        if ((Fmt $name '#{session_name}') -eq $name) { break }
    }
    Start-Sleep -Milliseconds 1200
}

function Fill($name) {
    P send-keys -t $name '1..200 | % { "line$_" }' Enter | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        if ([int](Fmt $name '#{history_size}') -ge 150) { break }
    }
    Start-Sleep -Milliseconds 500
}

function Cleanup {
    foreach ($id in $script:Opened) { try { Stop-Process -Id $id -Force -EA SilentlyContinue } catch {} }
    $script:Opened = @()
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
}

try {
    New-Sess "cp"
    Fill "cp"

    # ── 1. list-keys shows the copy-mode tables ───────────────────────────
    Write-Head "1. list-keys -T copy-mode / copy-mode-vi"
    $vi = @(P list-keys -T copy-mode-vi)
    $em = @(P list-keys -T copy-mode)
    Write-Info ("copy-mode-vi lines: {0}   copy-mode lines: {1}" -f $vi.Count, $em.Count)
    if ($vi.Count -ge 50) { Write-Pass "copy-mode-vi lists the built-in keys ($($vi.Count))" }
    else { Write-Fail "copy-mode-vi lists $($vi.Count) lines (tmux: 87)" }
    if ($em.Count -ge 50) { Write-Pass "copy-mode lists the built-in keys ($($em.Count))" }
    else { Write-Fail "copy-mode lists $($em.Count) lines (tmux: 72)" }
    foreach ($want in @(
        'bind-key -T copy-mode-vi v send-keys -X rectangle-toggle',
        'bind-key -T copy-mode-vi g send-keys -X history-top',
        'bind-key -T copy-mode-vi C-v send-keys -X rectangle-toggle',
        'bind-key -T copy-mode-vi Escape send-keys -X clear-selection')) {
        if ($vi -contains $want) { Write-Pass "listed: $want" } else { Write-Fail "missing: $want" }
    }
    foreach ($want in @(
        'bind-key -T copy-mode C-v send-keys -X page-down',
        'bind-key -T copy-mode M-< send-keys -X history-top',
        'bind-key -T copy-mode q send-keys -X cancel')) {
        if ($em -contains $want) { Write-Pass "listed: $want" } else { Write-Fail "missing: $want" }
    }
    if (-not ($em | Where-Object { $_ -match '^bind-key -T copy-mode g ' })) { Write-Pass "emacs table has no g (psmux only handles g for vi, like tmux)" }
    else { Write-Fail "emacs table lists g, which the emacs handler ignores" }
    $one = @(P list-keys -T copy-mode-vi v)
    if ($one.Count -eq 1 -and $one[0] -eq 'bind-key -T copy-mode-vi v send-keys -X rectangle-toggle') { Write-Pass "key filter returns the one line" }
    else { Write-Fail "key filter returned: $($one -join ' | ')" }

    # A rebind replaces the listed default.
    P bind-key -T copy-mode-vi v send-keys -X select-line | Out-Null
    $vi2 = @(P list-keys -T copy-mode-vi v)
    if ($vi2.Count -eq 1 -and $vi2[0] -match 'select-line') { Write-Pass "a rebind is listed instead of the default" }
    else { Write-Fail "after rebind: $($vi2 -join ' | ')" }

    # An unbind removes the line AND the key's action.
    P set -g mode-keys vi | Out-Null
    P copy-mode -t cp | Out-Null
    P send-keys -t cp v | Out-Null
    Start-Sleep -Milliseconds 300
    $selBound = Fmt cp '#{selection_present}'
    P send-keys -t cp -X cancel | Out-Null
    P unbind-key -T copy-mode-vi v | Out-Null
    $vi3 = @(P list-keys -T copy-mode-vi v | Where-Object { $_ -match '^bind-key' })
    if ($vi3.Count -eq 0) { Write-Pass "unbind drops v from the listing" } else { Write-Fail "after unbind: $($vi3 -join ' | ')" }
    P unbind-key -T copy-mode-vi V | Out-Null
    P copy-mode -t cp | Out-Null
    P send-keys -t cp V | Out-Null
    Start-Sleep -Milliseconds 300
    $selUnbound = Fmt cp '#{selection_present}'
    P send-keys -t cp -X cancel | Out-Null
    Write-Info "selection_present: bound v=$selBound  unbound V=$selUnbound"
    if ($selBound -eq '1' -and $selUnbound -eq '0') { Write-Pass "an unbound built-in key does nothing (tmux: no table entry)" }
    else { Write-Fail "bound v=$selBound (want 1), unbound V=$selUnbound (want 0)" }
    P set -g mode-keys emacs | Out-Null

    # ── 2. send-keys -X outside copy mode ─────────────────────────────────
    Write-Head "2. send-keys -X on a pane in no mode"
    $out = (& $PSMUX -L $NS send-keys -t cp -X history-top 2>&1 | Out-String).Trim()
    $rc = $LASTEXITCODE
    $mode = Fmt cp '#{pane_in_mode}'
    Write-Info "rc=$rc  stderr='$out'  pane_in_mode=$mode"
    if ($mode -eq '0') { Write-Pass "the pane stays out of copy mode" } else { Write-Fail "send-keys -X entered copy mode" }
    if ($rc -eq 1 -and $out -match 'not in a mode') { Write-Pass "refused with 'not in a mode' at exit 1" }
    else { Write-Fail "want rc 1 + 'not in a mode', got rc $rc '$out'" }

    # ── 3. history-top puts the cursor at 0,0 ─────────────────────────────
    Write-Head "3. history-top cursor"
    P copy-mode -t cp | Out-Null
    P send-keys -t cp -X history-top | Out-Null
    $pos = Fmt cp '#{copy_cursor_x},#{copy_cursor_y} #{scroll_position}/#{history_size}'
    Write-Info "after history-top: $pos"
    if ($pos -match '^0,0 (\d+)/(\d+)$' -and $Matches[1] -eq $Matches[2]) { Write-Pass "cursor 0,0 at the top of history" }
    else { Write-Fail "want 0,0 at top, got $pos" }
    P send-keys -t cp -X cancel | Out-Null

    # ── 4. -N repeat count ────────────────────────────────────────────────
    Write-Head "4. send-keys -N"
    P copy-mode -t cp | Out-Null
    P send-keys -t cp -X -N 40 scroll-up | Out-Null
    $sp = Fmt cp '#{scroll_position}'
    Write-Info "-X -N 40 scroll-up: scroll_position=$sp"
    if ($sp -eq '40') { Write-Pass "-X -N 40 scroll-up scrolls 40 lines" } else { Write-Fail "scroll_position $sp, want 40" }
    P send-keys -t cp -N 5 -X scroll-up | Out-Null
    $sp2 = Fmt cp '#{scroll_position}'
    if ($sp2 -eq '45') { Write-Pass "-N before -X counts too (45)" } else { Write-Fail "scroll_position $sp2, want 45" }
    P send-keys -t cp -X -N 4 history-top | Out-Null
    $top = Fmt cp '#{copy_cursor_y} #{scroll_position}/#{history_size}'
    if ($top -match '^0 (\d+)/(\d+)$' -and $Matches[1] -eq $Matches[2]) { Write-Pass "a command without a count ignores -N (history-top)" }
    else { Write-Fail "-N 4 history-top gave $top" }
    P send-keys -t cp -X cancel | Out-Null
    # No `clear` here: it would empty the history the -Hu check below pages into.
    P send-keys -t cp -N 3 z | Out-Null
    Start-Sleep -Milliseconds 700
    $cap = (P capture-pane -t cp -p | Out-String)
    if ($cap -match 'zzz') { Write-Pass "send-keys -N 3 z types zzz" } else { Write-Fail "send-keys -N 3 z did not type zzz" }
    P send-keys -t cp C-u | Out-Null

    # ── 5. copy-mode -Hu ──────────────────────────────────────────────────
    Write-Head "5. copy-mode -Hu"
    P copy-mode -Hu -t cp | Out-Null
    $r = Fmt cp '#{pane_in_mode} #{scroll_position}'
    Write-Info "copy-mode -Hu: in_mode scroll_position = $r"
    if ($r -match '^1 (\d+)$' -and [int]$Matches[1] -gt 0) { Write-Pass "clustered -Hu pages up like -H -u" }
    else { Write-Fail "copy-mode -Hu gave '$r' (tmux: 1 22)" }
    P send-keys -t cp -X cancel | Out-Null

    # Live: scroll-enter-copy-mode off and a root binding written -Hu. The
    # pressed key must reach the pane unchanged, as it does for plain -u.
    $reader = Join-Path $TMP "reader.ps1"
    @'
while ($true) { $k = [Console]::ReadKey($true); [Console]::Out.WriteLine("KEY=" + $k.Key) }
'@ | Set-Content -Path $reader -Encoding ASCII
    $conf = Join-Path $TMP "hu.conf"
    @"
set -g scroll-enter-copy-mode off
bind-key -n F5 copy-mode -Hu
bind-key -n F6 copy-mode -u
"@ | Set-Content -Path $conf -Encoding ASCII
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    if (-not (Test-Path $csc)) { $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" }
    $inj = Join-Path $TMP "keys.exe"
    & $csc /nologo /optimize /out:$inj (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
    if (-not (Test-Path $inj)) {
        Write-Fail "could not build tests\injector.cs"
    } else {
        $pwsh = (Get-Command pwsh -EA SilentlyContinue).Source
        $p = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"-f",$conf,"new-session","-s","hu","-x","100","-y","30",$pwsh,"-NoProfile","-File",$reader -PassThru
        $script:Opened += $p.Id
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 250
            if ((Fmt hu '#{session_name}') -eq 'hu') { break }
        }
        Start-Sleep -Seconds 3
        & $inj $p.Id "{F6}{SLEEP:600}{F5}{SLEEP:600}" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1200
        $cap = (P capture-pane -t hu -p | Out-String)
        $keys = @([regex]::Matches($cap, 'KEY=(\w+)') | ForEach-Object { $_.Groups[1].Value })
        $mode = Fmt hu '#{pane_in_mode}'
        Write-Info ("pane received: {0}   pane_in_mode={1}" -f ($keys -join ','), $mode)
        if ($keys.Count -ge 1 -and $keys[0] -eq 'F6') { Write-Pass "copy-mode -u binding skipped: F6 reached the pane" }
        else { Write-Fail "F6 (copy-mode -u) not delivered as F6: $($keys -join ',')" }
        if ($keys.Count -ge 2 -and $keys[1] -eq 'F5') { Write-Pass "copy-mode -Hu binding skipped too: F5 reached the pane" }
        else { Write-Fail "F5 (copy-mode -Hu) arrived as '$($keys[1])', want F5" }
        if ($mode -eq '0') { Write-Pass "no copy mode with scroll-enter-copy-mode off" } else { Write-Fail "pane entered copy mode" }
    }

    # One server per session: source-file below must reach "cp", so the
    # attached session goes first.
    foreach ($id in $script:Opened) { try { Stop-Process -Id $id -Force -EA SilentlyContinue } catch {} }
    $script:Opened = @()
    P kill-session -t hu | Out-Null
    Start-Sleep -Milliseconds 800

    # ── 6. copy-mode through source-file ──────────────────────────────────
    Write-Head "6. source-file runs copy-mode"
    $src = Join-Path $TMP "cm.conf"
    'copy-mode' | Set-Content -Path $src -Encoding ASCII
    P source-file $src | Out-Null
    Start-Sleep -Milliseconds 400
    $m = Fmt cp '#{pane_in_mode} #{pane_mode}'
    Write-Info "after source-file: $m"
    if ($m -eq '1 copy-mode') { Write-Pass "source-file entered copy mode" } else { Write-Fail "source-file left '$m' (tmux: 1 copy-mode)" }
    P send-keys -t cp -X cancel | Out-Null
}
finally {
    Cleanup
    $env:PSMUX_DATA_DIR = $savedDataDir
    Remove-Item Env:PSMUX_NO_WARM -EA SilentlyContinue
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
}

$defaultAfter = (& $PSMUX ls 2>&1 | Out-String).Trim()
if ($defaultAfter -eq $defaultBefore) { Write-Pass "default namespace unchanged" }
else { Write-Fail "default namespace changed: before '$defaultBefore' after '$defaultAfter'" }

Write-Host ("`nRESULT: {0} passed, {1} failed" -f $script:TestsPassed, $script:TestsFailed) -ForegroundColor Cyan
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
