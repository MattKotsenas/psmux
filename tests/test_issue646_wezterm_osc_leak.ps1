# Issue #646: an OSC colour reply fragment ("555\") is typed into the session at
# startup under WezTerm.
#
# Report: "Under WezTerm on Windows, starting psmux intermittently types a fragment of
# the terminal's own OSC colour reply into the pane, usually `555\`.  It lands at the
# shell prompt, where it sits in front of whatever is typed next."
#
# Root cause.  `query_host_terminal_colors_impl` writes OSC 10/11, sixteen OSC 4 queries,
# CSI ?996n and a DA1 sentinel, then drains console input only until the DA1 reply shows
# up.  The sentinel proves the host ANSWERED; it does not prove the host has FINISHED
# answering.  WezTerm replies to DA1 first, so the drain left with sixteen colour replies
# still in flight.  Measured on master, every launch:
#
#   exit: sentinel=true buf_len=28 records_left=0 elapsed_ms=0
#         tail="<ESC>[?61;6;7;22;23;24;28;32;42c"
#   arrivals=[+39ms:8]                   <-- the bytes land after the drain has gone
#
# conhost swallows those replies outright and intermittently passes a torn tail of one
# through verbatim, so the client's input pump reads `555<ESC>\` as the keystrokes
# `5 5 5 Alt+\` and types them into the pane.
#
# Fix: the DA1 sentinel now OPENS a 75ms quiet window instead of ending the drain, and
# the drain refuses to leave part way through a sequence.  The late bytes are kept
# rather than dropped, so a reply that was merely late still reaches the palette.
# Measured 10 of 10 launches leaking before, 0 of 20 after; the drain that used to
# return in 0ms now returns in 75ms to 116ms, holding the very bytes that used to leak.
#
# tmux cannot have this bug: tty_keys_next (tty-keys.c) parses DA and colour replies out
# of the same input stream for the whole life of the tty, so a late reply is consumed by
# the key parser rather than by a bounded startup drain that has already closed.
#
# Layers: real terminal E2E (WezTerm launches + capture-pane), client input-pump trace
#         (PSMUX_SSH_DEBUG emit lines), host palette propagation (PSMUX_HOST_COLORS).

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PSMUX = if ($env:PSMUX_EXE) { $env:PSMUX_EXE } else { (Get-Command psmux -EA SilentlyContinue).Source }
if (-not $PSMUX) { Write-Host "FATAL: no psmux.exe (set PSMUX_EXE)" -ForegroundColor Red; exit 1 }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkGray }

# An attached client launched from an agent shell inherits the caller's routing
# variables and re-enters the wrong session; scrub them before Start-Process.
foreach ($v in @("PSMUX_SESSION_NAME", "PSMUX_SESSION", "PSMUX_PANE", "PSMUX_HOST_COLORS")) {
    Remove-Item "env:$v" -EA SilentlyContinue
}

$wez = $null
foreach ($cand in @(
    (Join-Path $env:ProgramFiles "WezTerm\wezterm-gui.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "WezTerm\wezterm-gui.exe"),
    (Join-Path $env:LOCALAPPDATA "wezterm\wezterm-gui.exe"))) {
    if ($cand -and (Test-Path $cand)) { $wez = $cand; break }
}
if (-not $wez) { $wez = (Get-Command wezterm-gui -EA SilentlyContinue).Source }

if (-not $wez) {
    Write-Host "SKIP: WezTerm is not installed; issue #646 needs a host terminal that answers DA1 before its OSC colour replies." -ForegroundColor Yellow
    Write-Host "`n=== Results ===" -ForegroundColor Cyan
    Write-Host "  Passed: 0  Failed: 0  (skipped)" -ForegroundColor Yellow
    exit 0
}
Write-Info "WezTerm: $wez"

$LAUNCHES = if ($env:PSMUX_I646_LAUNCHES) { [int]$env:PSMUX_I646_LAUNCHES } else { 10 }
$root     = Join-Path $env:TEMP ("psmux_i646_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$savedDataDir = $env:PSMUX_DATA_DIR
$savedSshDbg  = $env:PSMUX_SSH_DEBUG
$script:Opened = @()
$script:Namespaces = @()

function Close-Everything {
    foreach ($ns in $script:Namespaces) {
        & $PSMUX -L $ns kill-server 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 400
    foreach ($procId in $script:Opened) {
        Stop-Process -Id $procId -Force -EA SilentlyContinue
    }
    Start-Sleep -Milliseconds 400
    # Anything still holding this run's data dir is ours and only ours.
    foreach ($pidFile in (Get-ChildItem -Path $root -Filter "*.pid" -Recurse -EA SilentlyContinue)) {
        $val = (Get-Content $pidFile.FullName -EA SilentlyContinue | Select-Object -First 1)
        if ($val -match '^\d+$') {
            $proc = Get-Process -Id ([int]$val) -EA SilentlyContinue
            if ($proc -and $proc.ProcessName -match '^(psmux|pmux|tmux)$') {
                Stop-Process -Id ([int]$val) -Force -EA SilentlyContinue
            }
        }
    }
    if ($savedDataDir) { $env:PSMUX_DATA_DIR = $savedDataDir } else { Remove-Item env:PSMUX_DATA_DIR -EA SilentlyContinue }
    if ($savedSshDbg)  { $env:PSMUX_SSH_DEBUG = $savedSshDbg }  else { Remove-Item env:PSMUX_SSH_DEBUG -EA SilentlyContinue }
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

try {
    New-Item -ItemType Directory -Force $root | Out-Null
    $env:PSMUX_SSH_DEBUG = "1"

    $leaks = @()
    $specs = @()
    Write-Host "`n--- $LAUNCHES WezTerm launches: the pane must come up empty ---" -ForegroundColor Cyan

    for ($i = 1; $i -le $LAUNCHES; $i++) {
        $ns = "i646e$i"
        $dd = Join-Path $root "r$i"
        New-Item -ItemType Directory -Force $dd | Out-Null
        $env:PSMUX_DATA_DIR = $dd
        $script:Namespaces += $ns

        $proc = Start-Process -FilePath $wez -PassThru -ArgumentList @(
            "start", "--always-new-process", "--", $PSMUX, "-L", $ns, "new-session", "-s", "t")
        $script:Opened += $proc.Id
        Start-Sleep -Milliseconds 3500

        $capture = @(& $PSMUX -L $ns capture-pane -p 2>&1 | ForEach-Object { "$_" })
        $typed = @()
        foreach ($line in $capture) {
            # A shell prompt with characters sitting after it is the symptom:
            # nobody has touched the keyboard, so the pane must be empty.
            if ($line.TrimEnd() -match '^PS .*?>\s*(\S.*)$') { $typed += $Matches[1] }
        }

        # The client's own input pump is the second, byte exact witness: on a clean
        # start it emits nothing at all before the user touches the keyboard.
        # Keyboard emits only. A window that opens under the physical pointer
        # makes WezTerm report a motion event the moment any-motion tracking is
        # on (`Mouse(MouseEvent { kind: Moved, column: 50, row: 1 })`, measured
        # 2026-09-23 with the pointer parked at x=516 y=126), and that is the
        # pointer, not a torn colour reply. Sweeps 2026-09-21_18-01-58 and
        # 2026-09-23_13-54-30 failed on exactly that with an empty pane.
        $emitted = @()
        $log = Join-Path $dd "ssh_input.log"
        if (Test-Path $log) {
            $emitted = @(Get-Content $log -EA SilentlyContinue |
                         Where-Object { $_ -match 'emit\(char\)' -and $_ -notmatch 'Mouse\(' } |
                         ForEach-Object { if ($_ -match "Char\('(.*?)'\)") { $Matches[1] } else { "?" } })
        }

        # Whatever the host palette came to, it must be the same on the first
        # launch and every later one: the settle window must not make the answer
        # depend on the race it closes.  Under WezTerm conhost eats the colour
        # replies outright, so this is normally the empty spec, and that is fine.
        & $PSMUX -L $ns split-window -t "t" -d 2>&1 | Out-Null
        Start-Sleep -Milliseconds 700
        $panes = @(& $PSMUX -L $ns list-panes -t "t" -F '#{pane_id}' 2>&1 | ForEach-Object { "$_" })
        if ($panes.Count -ge 2) {
            # Build the marker at runtime so the echoed command line cannot be
            # mistaken for the output it produces.
            & $PSMUX -L $ns send-keys -t $panes[1] 'Write-Output (("HC"+"SPEC") + "=[" + $env:PSMUX_HOST_COLORS + "]")' Enter 2>&1 | Out-Null
            Start-Sleep -Milliseconds 1000
            $p2 = (@(& $PSMUX -L $ns capture-pane -p -t $panes[1] 2>&1 | ForEach-Object { "$_" }) -join "`n")
            if ($p2 -match '(?m)^HCSPEC=\[(.*?)\]\s*$') { $specs += $Matches[1] }
        }

        if ($typed.Count -gt 0 -or $emitted.Count -gt 0) {
            $leaks += ("run {0}: pane=[{1}] emitted=[{2}]" -f $i, ($typed -join "|"), ($emitted -join ""))
            Write-Info ("run {0,2}: LEAK pane=[{1}] emitted=[{2}]" -f $i, ($typed -join "|"), ($emitted -join ""))
        } else {
            Write-Info ("run {0,2}: clean" -f $i)
        }

        & $PSMUX -L $ns kill-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds 400
        Stop-Process -Id $proc.Id -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 400
    }

    if ($leaks.Count -eq 0) {
        Write-Pass "$LAUNCHES WezTerm launches, zero OSC reply fragments typed into the pane"
    } else {
        Write-Fail ("{0} of {1} launches leaked: {2}" -f $leaks.Count, $LAUNCHES, ($leaks -join " ;; "))
    }

    $distinct = @($specs | Sort-Object -Unique)
    if ($specs.Count -eq 0) {
        Write-Info "no pane reported PSMUX_HOST_COLORS; skipping the stability check"
    } elseif ($distinct.Count -eq 1) {
        Write-Pass "the host palette is the same on all $($specs.Count) launches (spec=[$($distinct[0])])"
    } else {
        Write-Fail ("the host palette varied across launches: " + ($distinct -join " | "))
    }
}
finally {
    Close-Everything
}

# Nothing this test opened may outlive it.
$stray = @(Get-Process wezterm-gui -EA SilentlyContinue | Where-Object { $script:Opened -contains $_.Id })
if ($stray.Count -eq 0) {
    Write-Pass "every WezTerm window this test opened is closed"
} else {
    Write-Fail ("{0} WezTerm windows left behind: {1}" -f $stray.Count, (($stray | ForEach-Object { $_.Id }) -join ","))
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
