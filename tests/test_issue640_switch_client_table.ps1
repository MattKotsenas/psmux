# Issue #640: `switch-client -T <table>` did not switch the client's key table.
#
# The reporter's config was
#
#     bind-key s switch-client -T SPLIT
#     bind-key -T SPLIT v split-window -h -c "#{pane_current_path}"
#     bind-key -T SPLIT h split-window -v -c "#{pane_current_path}"
#
# with prefix C-a, and: "after i type `s` it seem to just return to my shell
# rather then executing the command ... then returns and types the character
# `v` or `h` into my shell."
#
# The bindings registered fine (`list-keys` showed the SPLIT table), so this
# was never a parser problem. The attached client's key dispatcher knew only
# the `root` and `prefix` tables and routed every binding starting with
# `switch-client` to the session-navigation branch, so `-T SPLIT` was read as
# "previous session" and the next key fell straight through to the pane.
#
# tmux parity (cmd-switch-client.c + server-client.c):
#   * `-T` sets `tc->keytable` and returns, before any -n/-p/-l handling.
#   * `key_bindings_get_table(name, 0)` does not create, so an unknown table
#     name is an error, not a latch.
#   * the prefix always takes precedence and forces the prefix table.
#   * a key handled in the custom table drops the client back to `root`.
#   * a key missing in the custom table is retried in `root`.
#   * a key missing in both is SWALLOWED, not forwarded to the pane.
#
# Layers here: config-file boot registration, the live CLI route, and a Win32
# TUI section that injects real keystrokes into an attached client's console
# input buffer, which is the reporter's actual route.
#
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"

$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$dataDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$TMP = Join-Path $env:TEMP "psmux_640"
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
$SOCK = "i640"
$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary:  $PSMUX" -ForegroundColor Cyan
Write-Host "dataDir: $dataDir" -ForegroundColor Cyan

function Write-Ascii([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.ASCIIEncoding))
}
function Kill-Sess([string]$n) {
    & $PSMUX -L $SOCK kill-session -t $n 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$dataDir\${SOCK}__$n.*" -Force -EA SilentlyContinue
}
function KeyTable([string]$s) {
    (& $PSMUX -L $SOCK display-message -p -t $s "#{client_key_table}" 2>&1 | Out-String).Trim()
}
function PaneCount([string]$s) {
    $v = (& $PSMUX -L $SOCK display-message -p -t $s "#{window_panes}" 2>&1 | Out-String).Trim()
    if ($v -match '^\d+$') { return [int]$v }
    return -1
}

# The reporter's config, verbatim apart from the prefix lines that make C-a the
# prefix the way his own config does.
$conf = Join-Path $TMP "i640.conf"
Write-Ascii $conf @"
set -g prefix C-a
unbind-key C-b
bind-key C-a send-prefix
bind-key s switch-client -T SPLIT
bind-key -T SPLIT v split-window -h
bind-key -T SPLIT h split-window -v
bind-key -T SPLIT r display-message "SPLIT-R-FIRED"
"@

# ---------------------------------------------------------------------------
# Part A: the tables exist after a config-file boot.
# ---------------------------------------------------------------------------
Write-Host "`n=== Part A: config boot registers both tables ===" -ForegroundColor Cyan
$SA = "i640_a"
Kill-Sess $SA
$bootOut = (& $PSMUX -L $SOCK -f $conf new-session -d -s $SA -x 120 -y 30 2>&1 | Out-String).Trim()
if ($bootOut) { Write-Info "new-session said: $bootOut" }
for ($i = 0; $i -lt 60; $i++) {
    if (Test-Path "$dataDir\${SOCK}__$SA.port") { break }
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 2

$lk = (& $PSMUX -L $SOCK list-keys 2>&1 | Out-String)
if ($lk -match 'bind-key -T prefix s\s+switch-client -T SPLIT') {
    Write-Pass "prefix s is bound to switch-client -T SPLIT"
} else {
    Write-Fail "prefix s binding missing from list-keys"
}
if (($lk -match 'bind-key -T SPLIT v\s+split-window -h') -and ($lk -match 'bind-key -T SPLIT h\s+split-window -v')) {
    Write-Pass "the custom SPLIT table is in list-keys"
} else {
    Write-Fail "the custom SPLIT table is missing from list-keys"
}

# ---------------------------------------------------------------------------
# Part B: the CLI route. `switch-client -T` must latch, and must reject a
# table that does not exist (tmux: "table %s doesn't exist").
# ---------------------------------------------------------------------------
Write-Host "`n=== Part B: switch-client -T over the CLI ===" -ForegroundColor Cyan
$t0 = KeyTable $SA
if ($t0 -eq "root") {
    Write-Pass "a fresh client reports #{client_key_table} = root"
} else {
    Write-Fail "a fresh client reports #{client_key_table} = '$t0', expected root"
}

& $PSMUX -L $SOCK switch-client -T SPLIT 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$t1 = KeyTable $SA
if ($t1 -eq "SPLIT") {
    Write-Pass "switch-client -T SPLIT latched the table (#{client_key_table} = SPLIT)"
} else {
    Write-Fail "switch-client -T SPLIT did not latch, #{client_key_table} = '$t1' (issue #640)"
}

& $PSMUX -L $SOCK switch-client -T root 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$t2 = KeyTable $SA
if ($t2 -eq "root") {
    Write-Pass "switch-client -T root returns the client to the default table"
} else {
    Write-Fail "switch-client -T root left the client in '$t2'"
}

$errOut = (& $PSMUX -L $SOCK switch-client -T NOSUCHTABLE 2>&1 | Out-String).Trim()
$errRc = $LASTEXITCODE
Start-Sleep -Milliseconds 600
$t3 = KeyTable $SA
if ($t3 -eq "root") {
    Write-Pass "an unknown table is rejected, the client stays in root"
} else {
    Write-Fail "an unknown table latched anyway, #{client_key_table} = '$t3'"
}
# tmux: cmdq_error "table %s doesn't exist" and a non-zero exit.
if ($errRc -ne 0 -and $errOut -match "table NOSUCHTABLE doesn't exist") {
    Write-Pass "unknown table exits $errRc with tmux's message: $errOut"
} else {
    Write-Fail "unknown table exited $errRc saying '$errOut'"
}
Kill-Sess $SA

# ---------------------------------------------------------------------------
# Part C: the reporter's route. Real keystrokes into an attached client's
# console input buffer, outcome measured over the CLI.
# ---------------------------------------------------------------------------
Write-Host "`n=== Part C: attached client, injected keystrokes ===" -ForegroundColor Cyan
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$keyInj = Join-Path $TMP "keys640.exe"
Remove-Item $keyInj -Force -EA SilentlyContinue
& $csc /nologo /optimize /out:$keyInj (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $keyInj)) {
    Write-Fail "could not compile tests/injector.cs, skipping the TUI section"
} else {
    $SC = "i640_c"
    $launchCmd = Join-Path $TMP "launch640.cmd"
    @"
@echo off
set PSMUX_SESSION=
set PSMUX_SESSION_NAME=
set PSMUX_PANE=
set TMUX=
set TMUX_PANE=
set PSMUX=
set NO_COLOR=
set PSMUX_NO_WARM=1
set PSMUX_DATA_DIR=$dataDir
"$PSMUX" -L $SOCK -f "$conf" new-session -s %1 -x 120 -y 30 cmd
"@ | Set-Content -Path $launchCmd -Encoding ASCII

    Kill-Sess $SC
    $null = Start-Process -FilePath $launchCmd -ArgumentList $SC -PassThru
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path "$dataDir\${SOCK}__$SC.port") { break }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Seconds 4
    # The client process can take a moment to show up in the process table.
    $cpid = 0
    for ($k = 0; $k -lt 12; $k++) {
        $cli = Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" |
            Where-Object { $_.CommandLine -match "new-session -s\s+$SC\b" } | Select-Object -First 1
        if ($cli) { $cpid = [int]$cli.ProcessId; break }
        Start-Sleep -Milliseconds 700
    }
    if ($cpid -eq 0) {
        Write-Fail "attached client did not start, skipping the TUI section"
    } else {
        Write-Info "attached client pid=$cpid"

        # C1: prefix + s must latch the SPLIT table, not navigate sessions.
        & $keyInj $cpid "^a" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
        $tp = KeyTable $SC
        if ($tp -eq "prefix") {
            Write-Pass "C-a armed the prefix (#{client_key_table} = prefix)"
        } else {
            Write-Fail "C-a did not arm the prefix, #{client_key_table} = '$tp'"
        }
        & $keyInj $cpid "s" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1200
        $ts = KeyTable $SC
        if ($ts -eq "SPLIT") {
            Write-Pass "prefix + s latched the SPLIT table (#{client_key_table} = SPLIT)"
        } else {
            Write-Fail "prefix + s left the client in '$ts', expected SPLIT (issue #640)"
        }

        # C2: the next key fires the SPLIT-table binding, and the shell never
        # sees the character. This is the reporter's exact complaint.
        $before = PaneCount $SC
        & $keyInj $cpid "v" 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $after = PaneCount $SC
        if ($after -eq $before + 1) {
            Write-Pass "v in the SPLIT table ran split-window -h, panes $before -> $after"
        } else {
            Write-Fail "v did not split, panes $before -> $after (issue #640)"
        }
        $cap = (& $PSMUX -L $SOCK capture-pane -t $SC -p 2>&1 | Out-String)
        $lastLine = (($cap -split "`r?`n" | Where-Object { $_ -match '\S' }) | Select-Object -Last 1)
        if ($lastLine -notmatch 'v\s*$') {
            Write-Pass "the literal 'v' was not typed into the shell"
        } else {
            Write-Fail "the shell echoed the key: last pane line '$lastLine' (issue #640)"
        }

        # C3: the latch is consumed, exactly one key deep.
        $tr = KeyTable $SC
        if ($tr -eq "root") {
            Write-Pass "the client fell back to root after the chord (tmux one-key latch)"
        } else {
            Write-Fail "the client is still in '$tr' after the chord fired"
        }

        # C4: a second chord works, proving the latch is re-armable and that
        # the second key of the chord is looked up in the custom table only.
        & $keyInj $cpid "^a{SLEEP:600}s{SLEEP:800}r" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $msgCap = (& $PSMUX -L $SOCK display-message -p -t $SC "#{client_key_table}" 2>&1 | Out-String).Trim()
        $scr = (& $PSMUX -L $SOCK capture-pane -t $SC -p 2>&1 | Out-String)
        # display-message paints the status line, which capture-pane does not
        # show, so the observable proof is that the key was consumed: the
        # table is back to root and the shell did not echo an 'r'.
        $lastLine2 = (($scr -split "`r?`n" | Where-Object { $_ -match '\S' }) | Select-Object -Last 1)
        if ($msgCap -eq "root" -and $lastLine2 -notmatch 'r\s*$') {
            Write-Pass "a second prefix+s chord fired its SPLIT binding and reset to root"
        } else {
            Write-Fail "second chord: table='$msgCap' lastline='$lastLine2'"
        }

        # C5: a key with no binding in the latched table is swallowed, not
        # forwarded to the pane (tmux: "if (first != table) ... goto out").
        & $keyInj $cpid "^a{SLEEP:600}s" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1200
        $t5 = KeyTable $SC
        Write-Info "before the unbound key the table is '$t5'"
        & $keyInj $cpid "Z" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $cap5 = (& $PSMUX -L $SOCK capture-pane -t $SC -p 2>&1 | Out-String)
        $lastLine5 = (($cap5 -split "`r?`n" | Where-Object { $_ -match '\S' }) | Select-Object -Last 1)
        $t5after = KeyTable $SC
        if ($lastLine5 -notmatch 'Z\s*$') {
            Write-Pass "an unbound key in a custom table is swallowed, not echoed"
        } else {
            Write-Fail "the unbound key reached the shell: '$lastLine5'"
        }
        if ($t5after -eq "root") {
            Write-Pass "the client returned to root after the unbound key"
        } else {
            Write-Fail "the client is stuck in '$t5after' after an unbound key"
        }

        # C6: the prefix outranks a pending latch (tmux: "The prefix always
        # takes precedence and forces a switch to the prefix table").
        & $keyInj $cpid "^a{SLEEP:600}s" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1200
        & $keyInj $cpid "^a" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
        $t6 = KeyTable $SC
        if ($t6 -eq "prefix") {
            Write-Pass "the prefix key overrides a pending SPLIT latch"
        } else {
            Write-Fail "after prefix over a latch the table is '$t6', expected prefix"
        }
        # Leave the client in a clean state.
        & $keyInj $cpid "{ESC}" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500

        try { Stop-Process -Id $cpid -Force -EA SilentlyContinue } catch {}
    }
    Kill-Sess $SC
}

Write-Host "`n=== Issue #640 results: $script:Pass passed, $script:Fail failed ===" -ForegroundColor Cyan
if ($script:Fail -gt 0) { exit 1 }
exit 0
