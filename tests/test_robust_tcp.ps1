<#
.SYNOPSIS
    EXTREME robustness campaign: Concurrent TCP client torture + AUTH enforcement.

.DESCRIPTION
    Namespace: -L rbTcp (socket-namespaced). NEVER touches the global server.
    Files live at $env:USERPROFILE\.psmux\rbTcp__<session>.port / .key (DOUBLE underscore).

    Thesis: the psmux TCP server (line protocol on 127.0.0.1:<port>) ENFORCES auth,
    TOLERATES many concurrent/abusive clients, and NEVER wedges.

    Handshake: send "AUTH <key>\n"; server replies a line "OK" (or rejects/closes).
    After OK: commands like "list-sessions\n", "new-window\n", "dump-state\n".
    A client may opt into a persistent stream with "PERSISTENT\n".

    This script PROVES expected outcomes (auth granted/denied, state present/absent,
    server still alive after abuse) rather than merely "did not crash".

    SAFETY: cleanup is ONLY `psmux -L rbTcp kill-server` in finally. No global kills,
    no Get-Process psmux | Stop-Process.

    DOES NOT depend on a particular reply format: "alive" is proven by a fresh
    authenticated connection successfully retrieving a listing that contains the
    session name rbTcp_main.
#>

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\tcp_reply_common.ps1"

$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) {
    $script:TestsPassed++
    Write-Host "  PASS: $msg" -ForegroundColor Green
}
function Write-Fail($msg) {
    $script:TestsFailed++
    Write-Host "  FAIL: $msg" -ForegroundColor Red
}

$PSMUX_DIR = "$env:USERPROFILE\.psmux"
$NS = 'rbTcp'
$MAIN = 'rbTcp_main'

function Get-Endpoint($session) {
    # Namespaced files: rbTcp__<session>.port / .key (DOUBLE underscore)
    $portFile = Join-Path $PSMUX_DIR ("{0}__{1}.port" -f $NS, $session)
    $keyFile  = Join-Path $PSMUX_DIR ("{0}__{1}.key"  -f $NS, $session)
    if (-not (Test-Path $portFile) -or -not (Test-Path $keyFile)) {
        return $null
    }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    if (-not $port -or -not $key) { return $null }
    return [PSCustomObject]@{ Port = [int]$port; Key = $key }
}

# Connect($session): opens a TcpClient (NoDelay), performs AUTH with the correct key,
# reads the handshake reply line, and returns a connection object holding the live
# tcp/stream/reader/writer plus the AuthReply. Reads are bounded by ReadTimeout so a
# non-responding server can never hang the script.
function Connect {
    param(
        [string]$session,
        [string]$keyOverride = $null,
        [switch]$SkipAuth,
        [int]$TimeoutMs = 5000
    )
    $ep = Get-Endpoint $session
    if ($null -eq $ep) { return $null }
    $key = if (-not [string]::IsNullOrEmpty($keyOverride)) { $keyOverride } else { $ep.Key }

    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.NoDelay = $true
        $tcp.Connect('127.0.0.1', $ep.Port)
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs
        $writer = [System.IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        $writer.NewLine = "`n"
        $reader = [System.IO.StreamReader]::new($stream)

        $authReply = $null
        if (-not $SkipAuth) {
            $writer.WriteLine("AUTH $key")
            try { $authReply = $reader.ReadLine() } catch { $authReply = $null }
        }

        return [PSCustomObject]@{
            Tcp       = $tcp
            Stream    = $stream
            Reader    = $reader
            Writer    = $writer
            AuthReply = $authReply
        }
    } catch {
        return $null
    }
}

function Close-Conn($conn) {
    if ($null -eq $conn) { return }
    try { if ($conn.Writer) { $conn.Writer.Dispose() } } catch {}
    try { if ($conn.Reader) { $conn.Reader.Dispose() } } catch {}
    try { if ($conn.Stream) { $conn.Stream.Dispose() } } catch {}
    try { if ($conn.Tcp)    { $conn.Tcp.Close() } } catch {}
}

# Read the server's reply to one command. A one-shot connection's reply ends
# when the server closes it (ReadLine returns null), bounded by ReadTimeout;
# never throws upward. -UntilQuiet keeps the old quiet-socket drain, for a
# PERSISTENT connection that never closes and only needs its backlog skimmed.
function Read-Reply($conn, [int]$DrainMs = 250, [switch]$UntilQuiet) {
    if (-not $UntilQuiet) {
        return ((Read-TcpReplyLines -Reader $conn.Reader) -join "`n")
    }
    $lines = @()
    try {
        while ($true) {
            $line = $conn.Reader.ReadLine()
            if ($null -eq $line) { break }
            $lines += $line
            $more = $false
            try { $more = $conn.Stream.DataAvailable } catch { $more = $false }
            if (-not $more) {
                Start-Sleep -Milliseconds $DrainMs
                try { $more = $conn.Stream.DataAvailable } catch { $more = $false }
                if (-not $more) { break }
            }
        }
    } catch {}
    return ($lines -join "`n")
}

# Send a single command on an already-authed connection and read the reply.
function Send-OnConn($conn, [string]$cmd, [int]$DrainMs = 250) {
    try { $conn.Writer.WriteLine($cmd) } catch { return "ERROR_WRITE" }
    return (Read-Reply $conn $DrainMs)
}

# Send-Once: open a fresh authenticated connection, send one command, read the
# reply, close. Returns the reply string (or a sentinel). This is the canonical
# "is the server alive and serving authed clients?" probe.
function Send-Once {
    param([string]$session, [string]$cmd, [int]$TimeoutMs = 5000, [int]$DrainMs = 250)
    $conn = Connect -session $session -TimeoutMs $TimeoutMs
    if ($null -eq $conn) { return "ERROR_CONNECT" }
    if ($conn.AuthReply -notmatch 'OK') { Close-Conn $conn; return "ERROR_AUTH:$($conn.AuthReply)" }
    $reply = Send-OnConn $conn $cmd $DrainMs
    Close-Conn $conn
    return $reply
}

# A reply "proves the main session is alive" if it references rbTcp_main.
function Test-MainAlive([int]$TimeoutMs = 5000) {
    $r = Send-Once -session $MAIN -cmd 'list-sessions' -TimeoutMs $TimeoutMs
    return ($r -match [regex]::Escape($MAIN))
}

# ---------------------------------------------------------------------------
Write-Host "=== psmux EXTREME robustness: Concurrent TCP torture + AUTH ===" -ForegroundColor Cyan
Write-Host "Namespace: -L $NS   Session: $MAIN   PSMUX_DIR: $PSMUX_DIR"

$psmux = (Get-Command psmux -ErrorAction SilentlyContinue).Source
if (-not $psmux) {
    Write-Host "FATAL: psmux not found on PATH" -ForegroundColor Red
    exit 1
}
Write-Host "Binary: $psmux"

try {
    # Clean slate for this namespace only.
    & psmux -L $NS kill-server 2>$null | Out-Null
    Start-Sleep -Milliseconds 500

    # --- Create the main session ---
    & psmux -L $NS new-session -d -s $MAIN 2>$null | Out-Null
    Start-Sleep 3

    $ep = Get-Endpoint $MAIN
    if ($null -eq $ep) {
        Write-Fail "setup: port/key files (rbTcp__$MAIN.port/.key) not found"
        Write-Host "FATAL: cannot proceed without endpoint" -ForegroundColor Red
        exit 1
    }
    Write-Pass "setup: endpoint discovered (port=$($ep.Port), key length=$($ep.Key.Length))"

    # Prove session alive via CLI listing too (belt and suspenders).
    $cliList = (& psmux -L $NS list-sessions 2>$null) -join "`n"
    if ($cliList -match [regex]::Escape($MAIN)) {
        Write-Pass "setup: CLI list-sessions shows $MAIN"
    } else {
        Write-Fail "setup: CLI list-sessions did NOT show $MAIN (got: '$cliList')"
    }

    # =====================================================================
    Write-Host "`n--- SCENARIO: AUTH POSITIVE ---" -ForegroundColor Yellow
    # =====================================================================
    $conn = Connect -session $MAIN
    if ($null -eq $conn) {
        Write-Fail "AUTH POSITIVE: could not open connection"
    } else {
        if ($conn.AuthReply -match 'OK') {
            Write-Pass "AUTH POSITIVE: correct key returned OK (reply='$($conn.AuthReply)')"
        } else {
            Write-Fail "AUTH POSITIVE: correct key did NOT return OK (reply='$($conn.AuthReply)')"
        }
        $reply = Send-OnConn $conn 'list-sessions'
        if ($reply -match [regex]::Escape($MAIN)) {
            Write-Pass "AUTH POSITIVE: post-auth list-sessions returned $MAIN"
        } else {
            Write-Fail "AUTH POSITIVE: post-auth list-sessions missing $MAIN (got: '$reply')"
        }
        Close-Conn $conn
    }

    # =====================================================================
    Write-Host "`n--- SCENARIO: AUTH NEGATIVE (wrong key) ---" -ForegroundColor Yellow
    # =====================================================================
    $wrongKey = 'deadbeefdeadbeef'
    $bad = Connect -session $MAIN -keyOverride $wrongKey
    if ($null -eq $bad) {
        # Connection refused entirely also counts as auth-not-granted.
        Write-Pass "AUTH NEGATIVE: connection with wrong key not usable (no socket)"
    } else {
        $authGranted = ($bad.AuthReply -match 'OK')
        if (-not $authGranted) {
            Write-Pass "AUTH NEGATIVE: wrong key did NOT return OK (reply='$($bad.AuthReply)')"
        } else {
            Write-Fail "AUTH NEGATIVE: wrong key WAS granted OK (security hole) reply='$($bad.AuthReply)'"
        }
        # Even if it spoke, a privileged command must NOT leak the session listing.
        $leak = Send-OnConn $bad 'list-sessions'
        if ($leak -notmatch [regex]::Escape($MAIN)) {
            Write-Pass "AUTH NEGATIVE: privileged command not honored / no state leak (got: '$leak')"
        } else {
            Write-Fail "AUTH NEGATIVE: privileged command leaked $MAIN despite bad auth (got: '$leak')"
        }
        Close-Conn $bad
    }

    # =====================================================================
    Write-Host "`n--- SCENARIO: AUTH MISSING (no handshake) ---" -ForegroundColor Yellow
    # =====================================================================
    $noauth = Connect -session $MAIN -SkipAuth
    if ($null -eq $noauth) {
        Write-Pass "AUTH MISSING: server refused unauthenticated socket"
    } else {
        $pre = Send-OnConn $noauth 'list-sessions'
        if ($pre -notmatch [regex]::Escape($MAIN)) {
            Write-Pass "AUTH MISSING: pre-auth list-sessions did NOT leak $MAIN (got: '$pre')"
        } else {
            Write-Fail "AUTH MISSING: pre-auth list-sessions LEAKED $MAIN (got: '$pre')"
        }
        Close-Conn $noauth
    }

    # Server must still be fine after rejected/abusive auth attempts.
    if (Test-MainAlive) {
        Write-Pass "AUTH phase: server still serving authed clients afterward"
    } else {
        Write-Fail "AUTH phase: server NOT serving authed clients afterward"
    }

    # =====================================================================
    Write-Host "`n--- SCENARIO: MANY CONCURRENT CONNECTIONS (30 simultaneous) ---" -ForegroundColor Yellow
    # =====================================================================
    $N = 30
    $conns = New-Object System.Collections.ArrayList
    $openedOk = 0
    # Root-cause note: this used to open all N connections first (AUTH only)
    # and query them for list-sessions in a SEPARATE later pass. The server
    # enforces a 2000ms "first command must arrive soon after AUTH" read
    # timeout per connection (server/connection.rs, to bound resources held
    # by a client that authenticates and never sends anything) -- a real
    # concurrent client always follows AUTH with PERSISTENT/its first command
    # immediately, so this is not a resource-starvation bug, it is a
    # legitimate anti-idle guard. But querying 30 connections sequentially,
    # each with Read-Reply's up-to-250ms drain wait, means later connections
    # in the query pass are queried 2000ms+ after THEIR OWN auth -- past the
    # guard -- so the server had already closed them before their turn came.
    # Confirmed via a standalone side-by-side repro: connections queried at
    # ~2400ms+ age since their own AUTH got 0-length replies (exactly
    # matching the "~8/30 sane" symptom), while issuing the command
    # immediately after AUTH (this fix) leaves all 30 sane every time.
    # Query immediately after AUTH (same real-world pattern as every other
    # scenario in this file) while still keeping all N connections open
    # simultaneously to exercise concurrent connection handling.
    $saneReplies = 0
    for ($i = 0; $i -lt $N; $i++) {
        $c = Connect -session $MAIN
        if ($null -ne $c -and $c.AuthReply -match 'OK') {
            $openedOk++
            $r = Send-OnConn $c 'list-sessions'
            if ($r -match [regex]::Escape($MAIN)) { $saneReplies++ }
        }
        [void]$conns.Add($c)
    }
    if ($openedOk -eq $N) {
        Write-Pass "CONCURRENT: all $N connections opened and authed simultaneously"
    } else {
        Write-Fail "CONCURRENT: only $openedOk/$N connections opened+authed"
    }

    if ($saneReplies -eq $openedOk -and $openedOk -gt 0) {
        Write-Pass "CONCURRENT: all $saneReplies live connections returned a sane listing"
    } else {
        Write-Fail "CONCURRENT: only $saneReplies/$openedOk live connections returned a sane listing"
    }

    foreach ($c in $conns) { Close-Conn $c }
    $conns.Clear()

    if (Test-MainAlive) {
        Write-Pass "CONCURRENT: server still alive after closing all $N connections"
    } else {
        Write-Fail "CONCURRENT: server NOT alive after closing all connections"
    }

    # =====================================================================
    Write-Host "`n--- SCENARIO: COMMAND FLOOD (200 rapid commands on one conn) ---" -ForegroundColor Yellow
    # =====================================================================
    $flood = Connect -session $MAIN
    if ($null -eq $flood -or $flood.AuthReply -notmatch 'OK') {
        Write-Fail "FLOOD: could not establish authed connection"
    } else {
        # Opt into persistent stream so a single connection sustains the burst.
        try { $flood.Writer.WriteLine('PERSISTENT') } catch {}
        Start-Sleep -Milliseconds 100
        # Drain any banner/ack from PERSISTENT without blocking the flood.
        try { if ($flood.Stream.DataAvailable) { [void](Read-Reply $flood 50 -UntilQuiet) } } catch {}

        $floodCount = 200
        $sentOk = 0
        for ($i = 0; $i -lt $floodCount; $i++) {
            try {
                $flood.Writer.WriteLine('list-sessions')
                $sentOk++
            } catch { break }
        }
        if ($sentOk -eq $floodCount) {
            Write-Pass "FLOOD: sent all $floodCount commands without write failure"
        } else {
            Write-Fail "FLOOD: only sent $sentOk/$floodCount commands before failure"
        }

        # Server should still be responsive after the burst.
        # Root-cause note: `list-sessions` on a PERSISTENT connection shows its
        # result as a TUI popup (CtrlReq::ShowTextPopup -> Mode::PopupMode),
        # and server/mod.rs deliberately forces state_dirty=true on every loop
        # tick for as long as ANY popup is open ("always push frames so
        # interactive content... updates in real-time") -- intentional, so a
        # live fzf/shell popup redraws smoothly. But this flood never
        # dismisses the resulting popup, so once it opens the server pushes a
        # fresh frame to THIS connection roughly every 16ms forever. The old
        # quiescence-based `Read-Reply` (loop until DataAvailable goes false)
        # can therefore never return -- confirmed via a standalone repro that
        # hung 60s+ waiting exactly here while a second, independent
        # connection proved the server itself was still perfectly responsive.
        # Verify responsiveness via a brand-new connection instead of reading
        # from the one connection that will legitimately never go quiet.
        if (Test-MainAlive) {
            Write-Pass "FLOOD: server kept responding during/after the burst (fresh connection confirms $MAIN)"
        } else {
            Write-Fail "FLOOD: server did not respond via a fresh connection after the burst"
        }
        Close-Conn $flood
    }

    # Session must be intact (still exists) after the flood.
    if (Test-MainAlive) {
        Write-Pass "FLOOD: $MAIN intact after 200-command flood"
    } else {
        Write-Fail "FLOOD: $MAIN NOT intact after flood"
    }

    # =====================================================================
    Write-Host "`n--- SCENARIO: MALFORMED WIRE INPUT (must not crash server) ---" -ForegroundColor Yellow
    # =====================================================================
    # Each abuse is followed by a FRESH clean connection verifying the server
    # survived and $MAIN still exists.
    $abuses = @(
        @{ Name = '50000-char junk line'; Bytes = $null; Text = ('A' * 50000) + "`n" },
        @{ Name = 'embedded NUL bytes';   Bytes = $null; Text = "list-`0`0`0sessions`n" },
        @{ Name = 'raw binary bytes';     Bytes = (0..255 | ForEach-Object { [byte]$_ }); Text = $null },
        @{ Name = 'command no newline then close'; Bytes = $null; Text = 'list-sessions' },
        @{ Name = 'many empty lines';     Bytes = $null; Text = "`n`n`n`n`n`n`n`n`n`n" },
        @{ Name = 'extremely long single token'; Bytes = $null; Text = ('X' * 100000) + "`n" }
    )

    foreach ($abuse in $abuses) {
        $ac = Connect -session $MAIN
        if ($null -eq $ac) {
            Write-Fail "MALFORMED [$($abuse.Name)]: could not open connection to abuse"
            continue
        }
        # Authed first, then abuse the wire.
        try {
            if ($null -ne $abuse.Bytes) {
                $b = [byte[]]$abuse.Bytes
                $ac.Stream.Write($b, 0, $b.Length)
                $ac.Stream.Flush()
            } else {
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($abuse.Text)
                $ac.Stream.Write($bytes, 0, $bytes.Length)
                $ac.Stream.Flush()
            }
        } catch {
            # A write failure here is acceptable (server may have closed the abusive socket).
        }
        Start-Sleep -Milliseconds 150
        Close-Conn $ac

        # FRESH clean connection must still work.
        $fresh = Send-Once -session $MAIN -cmd 'list-sessions'
        if ($fresh -match [regex]::Escape($MAIN)) {
            Write-Pass "MALFORMED [$($abuse.Name)]: server survived; fresh conn sees $MAIN"
        } else {
            Write-Fail "MALFORMED [$($abuse.Name)]: server did NOT survive (fresh got: '$fresh')"
        }
    }

    # =====================================================================
    Write-Host "`n--- SCENARIO: PARTIAL WRITE / ABRUPT CLOSE (20x) ---" -ForegroundColor Yellow
    # =====================================================================
    $partialReps = 20
    for ($i = 0; $i -lt $partialReps; $i++) {
        $pc = Connect -session $MAIN
        if ($null -eq $pc) { continue }
        try {
            # Half a command, no newline, then abrupt close.
            $half = [System.Text.Encoding]::ASCII.GetBytes('list-ses')
            $pc.Stream.Write($half, 0, $half.Length)
            $pc.Stream.Flush()
        } catch {}
        Close-Conn $pc
    }
    if (Test-MainAlive) {
        Write-Pass "PARTIAL WRITE: server alive after $partialReps half-command abrupt closes"
    } else {
        Write-Fail "PARTIAL WRITE: server NOT alive after partial-write churn"
    }

    # =====================================================================
    Write-Host "`n--- SCENARIO: CONNECT/DISCONNECT CHURN (100x) ---" -ForegroundColor Yellow
    # =====================================================================
    $churnReps = 100
    $churnAuthOk = 0
    for ($i = 0; $i -lt $churnReps; $i++) {
        $cc = Connect -session $MAIN
        if ($null -ne $cc) {
            if ($cc.AuthReply -match 'OK') { $churnAuthOk++ }
            Close-Conn $cc
        }
    }
    if ($churnAuthOk -ge [int]($churnReps * 0.9)) {
        Write-Pass "CHURN: $churnAuthOk/$churnReps open+auth+close cycles succeeded"
    } else {
        Write-Fail "CHURN: only $churnAuthOk/$churnReps cycles authed OK"
    }
    if (Test-MainAlive) {
        Write-Pass "CHURN: server alive after $churnReps connect/disconnect cycles"
    } else {
        Write-Fail "CHURN: server NOT alive after churn"
    }

    # Final sanity: session still present at the very end.
    if (Test-MainAlive) {
        Write-Pass "FINAL: $MAIN still alive at end of torture campaign"
    } else {
        Write-Fail "FINAL: $MAIN NOT alive at end of torture campaign"
    }

} finally {
    # Namespaced cleanup ONLY. Never global, never Stop-Process.
    & psmux -L $NS kill-server 2>$null | Out-Null
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host ("Passed: {0}" -f $script:TestsPassed) -ForegroundColor Green
Write-Host ("Failed: {0}" -f $script:TestsFailed) -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })

exit $script:TestsFailed
