# Issue #640, follow-up: a STICKY key table, built the tmux way by having every
# binding in the table re-arm the table as the last command of a chain.
#
# The reporter's config:
#
#     set -g status-right '#{client_key_table}'
#     unbind z
#     bind-key z switch-client -T MOVE
#     bind-key -T MOVE h select-pane -L \; switch-client -T MOVE
#     bind-key -T MOVE l select-pane -R \; switch-client -T MOVE
#     bind-key -T MOVE k select-pane -U \; switch-client -T MOVE
#     bind-key -T MOVE j select-pane -D \; switch-client -T MOVE
#
# "after prefix then z then h, the pane DOES move but the client falls back to
# the root table instead of staying in MOVE, so a second h/j/k/l is not handled
# by the MOVE table."
#
# He is right, and this is the canonical tmux idiom. tmux clears the client's
# key table BEFORE it runs the binding, so a `switch-client -T` inside the
# binding survives. server-client.c:
#
#     1571		c->flags &= ~CLIENT_REPEAT;
#     1572		server_client_set_key_table(c, NULL);
#     1573	}
#     1574	server_status_client(c);
#     1575
#     1576	/* Execute the key binding. */
#     1577	key_bindings_dispatch(bd, item, c, event, &fs);
#
# and cmd-switch-client.c:96 simply assigns the table each time it runs, so the
# last `-T` in a command list wins:
#
#      96	tablename = args_get(args, 'T');
#      97	if (tablename != NULL) {
#      98		table = key_bindings_get_table(tablename, 0);
#      99		if (table == NULL) {
#     100			cmdq_error(item, "table %s doesn't exist", tablename);
#     101			return (CMD_RETURN_ERROR);
#     102		}
#     103		table->references++;
#     104		key_bindings_unref_table(tc->keytable);
#     105		tc->keytable = table;
#     106		return (CMD_RETURN_NORMAL);
#     107	}
#
# psmux matched the WHOLE binding string, so `select-pane -L \; switch-client
# -T MOVE` never reached the switch-client arm at all; it fell to the generic
# chain splitter, which forwarded every element to the server but never re-armed
# the client's own latch, and the client then emitted its reset to `root` AFTER
# the binding, wiping the server side too.
#
# This file drives an attached client with real WriteConsoleInput keystrokes,
# which is the reporter's actual route: `send-keys` takes a different code path
# and would not show the bug.
#
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"

$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$dataDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$TMP = Join-Path $env:TEMP "psmux_640s"
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
$SOCK = "i640s"
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
function ActivePane([string]$s) {
    (& $PSMUX -L $SOCK display-message -p -t $s "#{pane_index}" 2>&1 | Out-String).Trim()
}

# The reporter's config verbatim, plus the prefix lines that make C-a the
# prefix the way his own config does, plus two extra MOVE bindings that pin the
# behaviour a sticky table must NOT lose: a one-shot binding with no re-arm
# still drops back to root, and a key bound in neither table is swallowed.
$conf = Join-Path $TMP "i640s.conf"
Write-Ascii $conf @"
set -g prefix C-a
unbind-key C-b
bind-key C-a send-prefix
set -g status-right '#{client_key_table}'
unbind z
bind-key z switch-client -T MOVE
bind-key -T MOVE h select-pane -L \; switch-client -T MOVE
bind-key -T MOVE l select-pane -R \; switch-client -T MOVE
bind-key -T MOVE k select-pane -U \; switch-client -T MOVE
bind-key -T MOVE j select-pane -D \; switch-client -T MOVE
bind-key -T MOVE q select-pane -L
"@

# ---------------------------------------------------------------------------
# Part A: the chained bindings survive the config parser and reach list-keys
# with their `\;` intact, which is the form the client dispatches.
# ---------------------------------------------------------------------------
Write-Host "`n=== Part A: config boot registers the chained MOVE table ===" -ForegroundColor Cyan
$SA = "i640s_a"
Kill-Sess $SA
& $PSMUX -L $SOCK -f $conf new-session -d -s $SA -x 120 -y 30 2>&1 | Out-Null
for ($i = 0; $i -lt 60; $i++) {
    if (Test-Path "$dataDir\${SOCK}__$SA.port") { break }
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 2

$lk = (& $PSMUX -L $SOCK list-keys 2>&1 | Out-String)
if ($lk -match 'bind-key -T prefix z\s+switch-client -T MOVE') {
    Write-Pass "prefix z is bound to switch-client -T MOVE"
} else {
    Write-Fail "prefix z binding missing from list-keys"
}
$chained = 0
foreach ($pair in @(@('h','-L'), @('l','-R'), @('k','-U'), @('j','-D'))) {
    $k = $pair[0]; $d = $pair[1]
    if ($lk -match "bind-key -T MOVE $k\s+select-pane $d \\; switch-client -T MOVE") { $chained++ }
}
if ($chained -eq 4) {
    Write-Pass "all four MOVE bindings kept their trailing switch-client -T MOVE"
} else {
    Write-Fail "only $chained of 4 MOVE bindings kept the chain"
}

# ---------------------------------------------------------------------------
# Part B: the CLI route still rejects a table that does not exist, which is the
# original #640 guarantee (tmux cmd-switch-client.c:100).
# ---------------------------------------------------------------------------
Write-Host "`n=== Part B: an unknown table is still an error ===" -ForegroundColor Cyan
$bad = (& $PSMUX -L $SOCK switch-client -T NOSUCHTABLE 2>&1 | Out-String).Trim()
$badRc = $LASTEXITCODE
if ($badRc -eq 1 -and $bad -match "table NOSUCHTABLE doesn't exist") {
    Write-Pass "switch-client -T NOSUCHTABLE exits 1 with tmux's message"
} else {
    Write-Fail "switch-client -T NOSUCHTABLE gave rc=$badRc out='$bad'"
}
& $PSMUX -L $SOCK switch-client -T MOVE 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$tm = KeyTable $SA
if ($tm -eq "MOVE") {
    Write-Pass "switch-client -T MOVE latches over the CLI (#{client_key_table} = MOVE)"
} else {
    Write-Fail "switch-client -T MOVE left the client in '$tm'"
}
Kill-Sess $SA

# ---------------------------------------------------------------------------
# Part C: the reporter's route. Real keystrokes into an attached client's
# console input buffer.
# ---------------------------------------------------------------------------
Write-Host "`n=== Part C: physical keystrokes, sticky MOVE table ===" -ForegroundColor Cyan
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$keyInj = Join-Path $TMP "inj640s.exe"
Remove-Item $keyInj -Force -EA SilentlyContinue
& $csc /nologo /optimize /out:$keyInj (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $keyInj)) {
    Write-Fail "could not compile tests/injector.cs, skipping the TUI section"
} else {
    $SC = "i640s_c"
    $launchCmd = Join-Path $TMP "launch640s.cmd"
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
"$PSMUX" -L $SOCK -f "$conf" new-session -s %1 -x 140 -y 34 cmd
"@ | Set-Content -Path $launchCmd -Encoding ASCII

    Kill-Sess $SC
    $null = Start-Process -FilePath $launchCmd -ArgumentList $SC -PassThru
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path "$dataDir\${SOCK}__$SC.port") { break }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Seconds 4
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

        # A left column and a right column split in two, so every one of
        # -L/-R/-U/-D has an unambiguous destination:
        #
        #     +--------+--------+
        #     |        |   1    |
        #     |   0    +--------+
        #     |        |   2    |
        #     +--------+--------+
        & $PSMUX -L $SOCK split-window -h -t $SC 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        & $PSMUX -L $SOCK split-window -v -t $SC 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $start = ActivePane $SC
        Write-Info "layout built, active pane=$start"
        if ($start -ne "2") {
            Write-Info "unexpected starting pane, selecting pane 2 explicitly"
            & $PSMUX -L $SOCK select-pane -t "${SC}.2" 2>&1 | Out-Null
            Start-Sleep -Milliseconds 800
        }

        # C1: prefix + z arms the MOVE table.
        & $keyInj $cpid "^a" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
        $tp = KeyTable $SC
        if ($tp -eq "prefix") {
            Write-Pass "C-a armed the prefix (#{client_key_table} = prefix)"
        } else {
            Write-Fail "C-a did not arm the prefix, #{client_key_table} = '$tp'"
        }
        & $keyInj $cpid "z" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1200
        $tz = KeyTable $SC
        if ($tz -eq "MOVE") {
            Write-Pass "prefix + z latched the MOVE table"
        } else {
            Write-Fail "prefix + z left the client in '$tz', expected MOVE"
        }

        # C2: four moves in a row, no prefix in between. Each one must move the
        # pane AND leave the client in MOVE. This is the whole report.
        #   pane 2 --k--> 1 --h--> 0 --l--> 1 --j--> 2
        $steps = @(
            @{ key = 'k'; want = '1' },
            @{ key = 'h'; want = '0' },
            @{ key = 'l'; want = '1' },
            @{ key = 'j'; want = '2' }
        )
        $n = 0
        foreach ($s in $steps) {
            $n++
            & $keyInj $cpid $s.key 2>&1 | Out-Null
            Start-Sleep -Milliseconds 1800
            $tbl = KeyTable $SC
            $pane = ActivePane $SC
            Write-Info "key #$n '$($s.key)': table='$tbl' pane=$pane (want table=MOVE pane=$($s.want))"
            if ($pane -eq $s.want) {
                Write-Pass "key #$n '$($s.key)' moved to pane $pane"
            } else {
                Write-Fail "key #$n '$($s.key)' left the active pane at $pane, expected $($s.want)"
            }
            if ($tbl -eq "MOVE") {
                Write-Pass "key #$n '$($s.key)' re-armed MOVE (the trailing switch-client -T)"
            } else {
                Write-Fail "key #$n '$($s.key)' dropped the client to '$tbl', expected MOVE (issue #640 follow-up)"
            }
        }

        # C3: none of those keys reached the shell.
        foreach ($idx in @(0, 1, 2)) {
            $cap = (& $PSMUX -L $SOCK capture-pane -t "${SC}.$idx" -p 2>&1 | Out-String)
            $line = (($cap -split "`r?`n" | Where-Object { $_ -match '\S' }) | Select-Object -Last 1)
            if ($line -match '[hjkl]{1,}\s*$' -and $line -notmatch '[\\/:]\s*[hjkl]*>') {
                Write-Fail "pane $idx echoed movement keys: '$line'"
            } else {
                Write-Pass "pane $idx shows no typed movement keys"
            }
        }

        # C4: a MOVE binding that does NOT re-arm still drops back to root, so
        # the stickiness comes from the chain and not from the table itself.
        & $keyInj $cpid "q" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $tq = KeyTable $SC
        if ($tq -eq "root") {
            Write-Pass "a MOVE binding without the trailing switch-client falls back to root"
        } else {
            Write-Fail "a one-shot MOVE binding left the client in '$tq', expected root"
        }

        # C5: a key bound in neither MOVE nor root is swallowed, and the client
        # returns to root (tmux: "if (first != table) ... goto out").
        & $keyInj $cpid "^a{SLEEP:700}z" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1500
        $preZ = KeyTable $SC
        Write-Info "before the unbound key the table is '$preZ'"
        $paneNow = ActivePane $SC
        $capB = (& $PSMUX -L $SOCK capture-pane -t "${SC}.$paneNow" -p 2>&1 | Out-String)
        $lineB = (($capB -split "`r?`n" | Where-Object { $_ -match '\S' }) | Select-Object -Last 1)
        & $keyInj $cpid "Z" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $capA = (& $PSMUX -L $SOCK capture-pane -t "${SC}.$paneNow" -p 2>&1 | Out-String)
        $lineA = (($capA -split "`r?`n" | Where-Object { $_ -match '\S' }) | Select-Object -Last 1)
        if ($lineA -eq $lineB) {
            Write-Pass "an unbound key in the sticky table is swallowed, not echoed"
        } else {
            Write-Fail "the unbound key reached the shell: '$lineB' -> '$lineA'"
        }
        $tZ = KeyTable $SC
        if ($tZ -eq "root") {
            Write-Pass "the client returned to root after an unbound key"
        } else {
            Write-Fail "the client is stuck in '$tZ' after an unbound key"
        }

        # C6: the prefix outranks a sticky latch and clears it.
        & $keyInj $cpid "^a{SLEEP:700}z" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1500
        & $keyInj $cpid "h" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1800
        $tBefore = KeyTable $SC
        & $keyInj $cpid "^a" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1000
        $tPrefix = KeyTable $SC
        if ($tBefore -eq "MOVE" -and $tPrefix -eq "prefix") {
            Write-Pass "the prefix overrides a sticky MOVE latch (MOVE -> prefix)"
        } else {
            Write-Fail "prefix over a sticky latch: '$tBefore' -> '$tPrefix', expected MOVE -> prefix"
        }
        & $keyInj $cpid "{ESC}" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        $tEsc = KeyTable $SC
        if ($tEsc -eq "root") {
            Write-Pass "escaping the prefix leaves the client on root, with no latch left over"
        } else {
            Write-Fail "after escaping the prefix the table is '$tEsc', expected root"
        }

        try { Stop-Process -Id $cpid -Force -EA SilentlyContinue } catch {}
    }
    Kill-Sess $SC
}

Write-Host "`n=== Issue #640 sticky table results: $script:Pass passed, $script:Fail failed ===" -ForegroundColor Cyan
if ($script:Fail -gt 0) { exit 1 }
exit 0
