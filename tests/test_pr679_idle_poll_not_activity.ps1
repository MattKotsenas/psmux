# PR #679: an attached client's automatic traffic must not move
# `window-size latest`.
#
# WHAT WAS REPORTED
# -----------------
# A full screen program (pi) repainted continuously while it was idle, on the
# SSH/Termius client and on the local one at the same time, and it stopped the
# instant the phone disconnected.
#
# WHY IT HAPPENED
# ---------------
# `server/connection.rs` pinged `CtrlReq::ClientActivity` for EVERY command
# line a persistent client sent, with only bare pointer motion excluded (#604).
# An idle client sends `dump-state` once a second (IDLE_FLOOR_MS, #658), so
# with two clients of different sizes attached each poll handed
# `window-size latest` to the other client: `note_client_activity` recomputed
# the geometry, `refresh_dynamic_window_sizes` reported a change,
# `resize_all_panes` pushed a new size down to the pane's PTY, and the program
# inside repainted its whole screen. One client alone could not show it,
# because its own poll left the latest client where it already was and
# `note_client_activity` returned early.
#
# WHAT WAS MEASURED, on b053bb7, with the two clients below and NOTHING but
# their own once-a-second polls touching the server:
#
#   before  geometry  120x40 60x20 120x40 60x20 ...  (20 of 20 samples flip)
#           server answered every poll with a full frame, 1.37 MB over 10 s
#   after   geometry  60x20 x20, never once flipped
#           0.36 MB over the same 10 s
#
# tmux parity: tmux moves `w->latest` only from `server_client_update_latest`,
# and it has exactly three callers (server-client.c:385 re-election when the
# latest client dies, :1654 the `out:` label of the key callback, :2590
# MSG_RESIZE). A tmux client sends nothing at all on a timer, so there is no
# poll there to exclude. The `out:` caller is guarded by
# `key != KEYC_FOCUS_OUT`, which is why cell 3 exists.
#
# THE CELLS
# ---------
# 1. STABILITY. Two idle clients of different sizes must leave the window
#    geometry alone. This is the reported bug.
# 2. HANDOVER. The feature must still work: typing in a client takes the
#    window to that client's size, both ways. A fix that froze the geometry
#    would pass cell 1 and be useless.
# 3. FOCUS. A client reporting that its terminal LOST focus must not take the
#    window, and one reporting that it GAINED focus still must. tmux filters
#    exactly focus-out and nothing else at server-client.c:1653.
#
# The clients here are raw persistent sockets speaking the wire protocol the
# real client speaks (AUTH / PERSISTENT / client-attach / client-size, then
# `dump-state`). That is deliberate: it puts the exact bytes on the socket
# that a real attach does, with no console, no ConPTY and no repaint timing to
# make the result ambiguous.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_pr679_idle_poll_not_activity.ps1

param(
    [string]$Binary = "",
    # Seconds of idle polling in cell 1. Each second produces two geometry
    # samples, one after each client's poll.
    [int]$IdleSecs = 8,
    [int]$WideCols = 120,
    [int]$WideRows = 40,
    [int]$NarrowCols = 60,
    [int]$NarrowRows = 20
)

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green;  $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:TestsFailed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }
function Write-Test($m) { Write-Host "`n[$m]" -ForegroundColor Cyan }

if (-not $Binary) { $Binary = $env:PSMUX_TEST_EXE }
if (-not $Binary) { $Binary = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path }
if (-not $Binary) { $Binary = (Get-Command psmux -EA SilentlyContinue).Source }
if (-not $Binary -or -not (Test-Path $Binary)) { Write-Host "psmux not found"; exit 1 }
Write-Info "binary under test: $Binary"

# This shell's own session routing must never leak into the session under test.
foreach ($v in @('PSMUX_SESSION','PSMUX_SESSION_NAME','PSMUX_PANE','PSMUX_PANE_ID','PSMUX_SOCKET','TMUX','TMUX_PANE','PSMUX','PSMUX_PTY_TRACE')) {
    Remove-Item "Env:\$v" -EA SilentlyContinue
}

$NS   = "pr679_$PID"
$SESS = "s679"
$root = Join-Path $env:USERPROFILE '.psmux'

function P { & $Binary -L $NS @args 2>&1 | Out-String }
function Geo { return (P display-message -p '#{window_width}x#{window_height}').Trim() }

# ── a client, as the wire sees one ───────────────────────────────────────────
function New-WireClient([int]$w, [int]$h, [string]$label) {
    $portFile = Join-Path $root "$NS`__$SESS.port"
    $keyFile  = Join-Path $root "$NS`__$SESS.key"
    if (-not (Test-Path $portFile) -or -not (Test-Path $keyFile)) { return $null }
    $port = (Get-Content $portFile -EA SilentlyContinue | Select-Object -First 1)
    $key  = (Get-Content $keyFile  -EA SilentlyContinue | Select-Object -First 1)
    if (-not $port -or -not $key) { return $null }
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$port.Trim())
    } catch { return $null }
    $st = $tcp.GetStream()
    $st.ReadTimeout = 5000
    $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $true
    $rd = New-Object System.IO.StreamReader($st)
    $wr.WriteLine("AUTH $($key.Trim())")
    if (($rd.ReadLine()) -ne 'OK') { try { $tcp.Close() } catch {}; return $null }
    $wr.WriteLine('PERSISTENT')
    Start-Sleep -Milliseconds 150
    $wr.WriteLine('client-attach')
    Start-Sleep -Milliseconds 250
    $wr.WriteLine("client-size $w $h")
    Start-Sleep -Milliseconds 450
    return [pscustomobject]@{ Label = $label; Size = "${w}x${h}"; Tcp = $tcp; Stream = $st; Writer = $wr }
}

# Read and discard whatever the server has pushed, so the socket never backs
# up and a later reply is never mistaken for an earlier one.
function Drain($c) {
    $buf = New-Object byte[] 65536
    while ($c.Stream.DataAvailable) {
        if (($c.Stream.Read($buf, 0, $buf.Length)) -le 0) { break }
        Start-Sleep -Milliseconds 15
    }
}
function Say($c, [string]$line) {
    try { $c.Writer.WriteLine($line) } catch { return $false }
    Start-Sleep -Milliseconds 650
    Drain $c
    return $true
}
function Close-WireClient($c) {
    if (-not $c) { return }
    try { $c.Writer.WriteLine('client-detach') } catch {}
    Start-Sleep -Milliseconds 120
    try { $c.Tcp.Close() } catch {}
}

# ── session under test ───────────────────────────────────────────────────────
P kill-session -t $SESS | Out-Null
P new-session -d -s $SESS | Out-Null
Start-Sleep -Milliseconds 1000
P set-option -g window-size latest | Out-Null
Start-Sleep -Milliseconds 300

$wide   = New-WireClient $WideCols   $WideRows   'wide'
$narrow = New-WireClient $NarrowCols $NarrowRows 'narrow'

if (-not $wide -or -not $narrow) {
    Write-Skip "could not attach two persistent clients to -L $NS ($SESS); nothing to measure"
    Close-WireClient $wide
    Close-WireClient $narrow
    & $Binary -L $NS kill-server 2>&1 | Out-Null
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed:  $($script:TestsPassed)" -ForegroundColor Green
    Write-Host "  Failed:  $($script:TestsFailed)" -ForegroundColor Green
    Write-Host "  Skipped: $($script:TestsSkipped)" -ForegroundColor Yellow
    exit $script:TestsFailed
}
Start-Sleep -Milliseconds 1200
Drain $wide
Drain $narrow

# ── cell 1: two idle clients must leave the geometry alone ───────────────────
Write-Test "CELL 1: idle frame polls do not move window-size latest"
$samples = @()
for ($i = 0; $i -lt $IdleSecs; $i++) {
    $wide.Writer.WriteLine('dump-state');   Start-Sleep -Milliseconds 250; Drain $wide
    $samples += (Geo)
    $narrow.Writer.WriteLine('dump-state'); Start-Sleep -Milliseconds 250; Drain $narrow
    $samples += (Geo)
    Start-Sleep -Milliseconds 350
}
$distinct = @($samples | Select-Object -Unique)
Write-Info ("geometry over $($samples.Count) samples: " + ($samples -join ' '))
if ($distinct.Count -eq 1) {
    Write-Pass "geometry held at $($distinct[0]) across $($samples.Count) samples with both clients polling"
} else {
    Write-Fail ("the window resized $($distinct.Count) different ways while both clients sat idle (" + ($distinct -join ', ') + "). " +
                'A dump-state is a timer, not the user: check is_client_poll_cmd and the two ClientActivity pings in server/connection.rs (PR #679)')
}

# ── cell 2: the feature it exists for still works ────────────────────────────
Write-Test "CELL 2: typing still hands the window to the client being typed in"
Say $wide   'send-key a' | Out-Null
$afterWide = Geo
if ($afterWide -eq $wide.Size) {
    Write-Pass "typing in the $($wide.Size) client took the window to $afterWide"
} else {
    Write-Fail "typing in the $($wide.Size) client left the window at $afterWide. window-size latest must still follow real input (#663)"
}
Say $narrow 'send-key b' | Out-Null
$afterNarrow = Geo
if ($afterNarrow -eq $narrow.Size) {
    Write-Pass "typing in the $($narrow.Size) client took the window to $afterNarrow"
} else {
    Write-Fail "typing in the $($narrow.Size) client left the window at $afterNarrow. window-size latest must still follow real input (#663)"
}

# ── cell 3: focus out is the one key tmux refuses to count ───────────────────
Write-Test "CELL 3: losing focus does not take the window, gaining focus does"
Say $wide 'send-key a' | Out-Null
$base = Geo
if ($base -ne $wide.Size) {
    Write-Skip "could not park the window on the $($wide.Size) client (it reads $base), so the focus cells have no baseline"
} else {
    Say $narrow 'focus-out' | Out-Null
    $afterOut = Geo
    if ($afterOut -eq $wide.Size) {
        Write-Pass "focus-out from the idle $($narrow.Size) client left the window at $afterOut"
    } else {
        Write-Fail ("focus-out from the idle $($narrow.Size) client dragged the window to $afterOut. " +
                    'tmux updates the latest client under "key != KEYC_FOCUS_OUT" (server-client.c:1653): the terminal the user just left must not take the size')
    }
    Say $narrow 'focus-in' | Out-Null
    $afterIn = Geo
    if ($afterIn -eq $narrow.Size) {
        Write-Pass "focus-in from the $($narrow.Size) client took the window to $afterIn"
    } else {
        Write-Fail "focus-in from the $($narrow.Size) client left the window at $afterIn. tmux counts focus-in as activity, so psmux must too"
    }
}

# ── teardown ─────────────────────────────────────────────────────────────────
Close-WireClient $wide
Close-WireClient $narrow
Start-Sleep -Milliseconds 400
P kill-session -t $SESS | Out-Null
& $Binary -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
Get-ChildItem (Join-Path $root "$NS`__*") -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed:  $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed:  $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $($script:TestsSkipped)" -ForegroundColor Yellow
exit $script:TestsFailed
