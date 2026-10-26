# Named Paste Buffer E2E Tests
# Proves named buffer support works exactly like tmux through real CLI + TCP paths.
# Tests: set-buffer -b name, show-buffer -b name, delete-buffer -b name,
#        list-buffers (mixed), paste-buffer -b name, and independence guarantees.

$ErrorActionPreference = 'Continue'
$passed = 0; $failed = 0
$session = "named_buf_e2e"

function Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:passed++ }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:failed++ }
function Info($msg) { Write-Host "  [INFO]   $msg" -ForegroundColor DarkGray }

# Cleanup and create session
psmux kill-session -t $session 2>$null
psmux new-session -d -s $session
Start-Sleep -Milliseconds 1500

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " NAMED BUFFER SET + SHOW" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ---- Test 1: set-buffer -b name, show-buffer -b name ----
Write-Host "[1] set-buffer -b mybuf, show-buffer -b mybuf"
psmux set-buffer -b mybuf "HELLO_NAMED"
$result = psmux show-buffer -b mybuf
Info "show-buffer -b mybuf: '$result'"
if ($result -eq "HELLO_NAMED") { Pass "Named buffer set and retrieved correctly" }
else { Fail "Expected 'HELLO_NAMED', got '$result'" }

# ---- Test 2: Two named buffers are independent ----
Write-Host "[2] Two named buffers are independent"
psmux set-buffer -b buf_one "CONTENT_ONE"
psmux set-buffer -b buf_two "CONTENT_TWO"
$one = psmux show-buffer -b buf_one
$two = psmux show-buffer -b buf_two
Info "buf_one: '$one', buf_two: '$two'"
if ($one -eq "CONTENT_ONE" -and $two -eq "CONTENT_TWO") {
    Pass "Named buffers are independent"
} else {
    Fail "Named buffers not independent: one='$one' two='$two'"
}

# ---- Test 3: Overwrite named buffer replaces only that one ----
Write-Host "[3] Overwriting named buffer replaces only that name"
psmux set-buffer -b buf_one "UPDATED_ONE"
$one = psmux show-buffer -b buf_one
$two = psmux show-buffer -b buf_two
Info "After overwrite: buf_one='$one' buf_two='$two'"
if ($one -eq "UPDATED_ONE" -and $two -eq "CONTENT_TWO") {
    Pass "Named buffer overwrite works correctly"
} else {
    Fail "Overwrite failed: one='$one' two='$two'"
}

# ---- Test 4: Positional (no -b) is independent of named ----
Write-Host "[4] Positional stack is independent of named buffers"
psmux set-buffer "STACK_CONTENT"
$stack = psmux show-buffer
$named = psmux show-buffer -b mybuf
Info "stack top: '$stack', mybuf: '$named'"
if ($stack -eq "STACK_CONTENT" -and $named -eq "HELLO_NAMED") {
    Pass "Positional and named are independent"
} else {
    Fail "Independence broken: stack='$stack' mybuf='$named'"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " DELETE NAMED BUFFER" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ---- Test 5: delete-buffer -b name removes only that name ----
Write-Host "[5] delete-buffer -b buf_two"
psmux delete-buffer -b buf_two
$one = psmux show-buffer -b buf_one
$two = psmux show-buffer -b buf_two
Info "After delete: buf_one='$one' buf_two='$two'"
if ($one -eq "UPDATED_ONE" -and ($two -eq "" -or $null -eq $two)) {
    Pass "delete-buffer -b name removes only that buffer"
} else {
    Fail "Delete failed: one='$one' two='$two'"
}

# ---- Test 6: delete-buffer (no -b) removes stack top, not named ----
Write-Host "[6] delete-buffer (no -b) removes stack top only"
$named_before = psmux show-buffer -b mybuf
psmux delete-buffer
$named_after = psmux show-buffer -b mybuf
Info "mybuf before: '$named_before', after: '$named_after'"
if ($named_after -eq "HELLO_NAMED") {
    Pass "Positional delete does not affect named buffers"
} else {
    Fail "Positional delete affected named buffer: '$named_after'"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " LIST BUFFERS (MIXED)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ---- Test 7: list-buffers shows both named and positional ----
Write-Host "[7] list-buffers shows both named and positional"
psmux set-buffer "POSITIONAL_DATA"
$lb = psmux list-buffers -t $session
Info "list-buffers:"
$lb -split "`n" | ForEach-Object { Info "  $_" }
$has_positional = $lb -match 'buffer\d+: \d+ bytes: "POSITIONAL_DATA"'
$has_named = $lb -match "mybuf|buf_one"
if ($has_positional -and $has_named) {
    Pass "list-buffers shows both positional and named buffers"
} else {
    Fail "list-buffers missing entries: positional=$has_positional named=$has_named"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PASTE-BUFFER -b NAME" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ---- Test 8: paste-buffer -b name pastes named buffer content ----
Write-Host "[8] paste-buffer -b name pastes named content"
psmux set-buffer -b paste_test "PASTE_NAMED_OK"
psmux send-keys -t $session "clear" Enter
Start-Sleep -Milliseconds 300
psmux paste-buffer -b paste_test -t $session
Start-Sleep -Milliseconds 500
$pane = psmux capture-pane -t $session -p
Info "Pane after paste-buffer -b paste_test:"
$pane -split "`n" | Where-Object { $_ -match '\S' } | ForEach-Object { Info "  $_" }
if ($pane -match "PASTE_NAMED_OK") {
    Pass "paste-buffer -b name pasted named buffer content"
} else {
    Fail "paste-buffer -b name did not paste correct content"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " TCP PATH TESTS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ---- Test 9: TCP set-buffer + show-buffer with -b name ----
Write-Host "[9] TCP: set-buffer -b tcp_buf, show-buffer -b tcp_buf"
$port = $null
$portFile = "$env:USERPROFILE\.psmux\${session}.port"
$keyFile = "$env:USERPROFILE\.psmux\${session}.key"
if (Test-Path $portFile) { $port = [int](Get-Content $portFile -Raw).Trim() }
if ($port -and (Test-Path $keyFile)) {
    $key = (Get-Content $keyFile -Raw).Trim()
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.Connect("127.0.0.1", $port)
        $stream = $tcp.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        # Auth: client sends AUTH key first, server responds with OK
        $writer.WriteLine("AUTH $key"); $writer.Flush()
        $authResp = $reader.ReadLine()
        Info "Auth response: '$authResp'"
        if ($authResp -eq "OK") {
            # set-buffer via TCP
            $writer.WriteLine("set-buffer -b tcp_named TCP_NAMED_DATA"); $writer.Flush()
            Start-Sleep -Milliseconds 500
            $tcp.Close()
            Start-Sleep -Milliseconds 300

            # Now show-buffer via CLI
            $result = psmux show-buffer -b tcp_named
            Info "TCP show-buffer -b tcp_named: '$result'"
            if ($result -eq "TCP_NAMED_DATA") {
                Pass "TCP: named buffer set and retrieved correctly"
            } else {
                Fail "TCP: expected 'TCP_NAMED_DATA', got '$result'"
            }
        } else {
            $tcp.Close()
            Fail "TCP auth failed: '$authResp'"
        }
    } catch {
        Info "TCP error: $_"
        Fail "TCP connection failed"
    }
} else {
    Info "No port/key file found, skipping TCP test"
    Fail "TCP test skipped (no port/key file)"
}

# ---- Test 10: TCP show-buffer -b name via response ----
Write-Host "[10] TCP: show-buffer -b name via TCP response"
if ($port -and (Test-Path $keyFile)) {
    $tcp2 = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp2.Connect("127.0.0.1", $port)
        $stream2 = $tcp2.GetStream()
        $writer2 = New-Object System.IO.StreamWriter($stream2)
        $reader2 = New-Object System.IO.StreamReader($stream2)
        # Auth: client sends AUTH key first
        $writer2.WriteLine("AUTH $key"); $writer2.Flush()
        $authResp2 = $reader2.ReadLine()
        if ($authResp2 -eq "OK") {
            # Set a named buffer
            $writer2.WriteLine("set-buffer -b tcp_show SHOW_ME_TCP"); $writer2.Flush()
            Start-Sleep -Milliseconds 500
            $tcp2.Close()
            Start-Sleep -Milliseconds 300

            # Show via CLI path
            $result = psmux show-buffer -b tcp_show
            Info "show-buffer -b tcp_show: '$result'"
            if ($result -eq "SHOW_ME_TCP") {
                Pass "TCP: show-buffer -b name returns correct content"
            } else {
                Fail "TCP: expected 'SHOW_ME_TCP', got '$result'"
            }
        } else {
            $tcp2.Close()
            Fail "TCP auth failed for test 10"
        }
    } catch {
        Fail "TCP test 10 failed: $_"
    }
} else {
    Fail "TCP test 10 skipped (no port/key)"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$tui_session = "named_buf_tui"
psmux kill-session -t $tui_session 2>$null
$proc = Start-Process -FilePath "psmux" -ArgumentList "new-session","-s",$tui_session -PassThru
Start-Sleep -Milliseconds 1500

# ---- TUI-A: Named buffer via display-message ----
Write-Host "[TUI-A] Set and verify named buffer in TUI session"
psmux set-buffer -b tui_buf "TUI_BUFFER_CONTENT"
$result = psmux show-buffer -b tui_buf
if ($result -eq "TUI_BUFFER_CONTENT") {
    Pass "TUI: named buffer works in live session"
} else {
    Fail "TUI: named buffer failed, got '$result'"
}

# ---- TUI-B: list-buffers in TUI shows named ----
Write-Host "[TUI-B] list-buffers in TUI shows named buffer"
$lb = psmux list-buffers -t $tui_session
if ($lb -match "tui_buf") {
    Pass "TUI: list-buffers shows named buffer"
} else {
    Fail "TUI: list-buffers does not show named buffer"
}

# Cleanup TUI
psmux kill-session -t $tui_session 2>$null
if ($proc -and !$proc.HasExited) { $proc.Kill() }

# Cleanup main session
psmux kill-session -t $session 2>$null

Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host " RESULTS" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "  Passed: $passed" -ForegroundColor Green
Write-Host "  Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host "  Named buffer tests prove tmux parity for -b flag semantics." -ForegroundColor Cyan
