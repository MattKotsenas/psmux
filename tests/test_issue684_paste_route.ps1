# Issue #684: where a bracketed paste goes, and the two paste-buffer defects
# found alongside it.
#
# On Windows 10 19045 the inbox conhost (10.0.19041.1) silently removes
# ESC[200~ and ESC[201~ from a pane's ConPTY INPUT pipe and hands the child the
# payload alone.  The pipe write reports success, so psmux could not observe the
# loss and the "fall back when the brackets are stripped" strategy in
# input.rs was unreachable.  The same bytes delivered as KEY_EVENT records with
# WriteConsoleInputW arrive intact on that conhost, which is why psmux 0.4.9
# bracketed there and master did not.
#
# The fix decides the channel up front, from the host's build number and the
# pane child's console input mode, and PSMUX_PASTE_INJECT makes the decision
# testable on a host whose pipe works.  That is what this file does: it proves
# the injection route delivers the markers BYTE FOR BYTE the same as the pipe
# route on a modern build, so a 19045 user gets exactly what a 26200 user gets.
#
# Also covered, both reproduced before they were fixed:
#   * prefix + ] sent `paste-buffer` where tmux binds `paste-buffer -p`
#     (key-bindings.c:422), so that one keypress was unbracketed everywhere.
#   * the in server `paste-buffer` dispatch threw every flag away and pasted
#     the top buffer unbracketed, so a binding, a hook or a `:paste-buffer -p
#     -b name` at the command prompt ignored -p, -b, -d, -s and -t.
#
# The recorder is tests\paste_recorder.cs, compiled here, in two shapes:
#   vt       a byte stream reader (ENABLE_VIRTUAL_TERMINAL_INPUT), the node and
#            nvim case, the one the injection route is for.
#   records  an INPUT_RECORD reader, the crossterm / Helix case from issue #98,
#            which must NEVER be handed injected marker bytes because it would
#            show them as the literal characters [200~.

#
# PORTABILITY (gabri-ns ran this on Windows 10 19045 with Windows PowerShell
# 5.1 and reported three ways it misjudged that host):
#
#   * `e is not an escape in Windows PowerShell 5.1, it is the letter e, so
#     every byte exact comparison wanted 65 5b 32 30 30 7e where the child had
#     correctly received 1b 5b 32 30 30 7e.  [char]27 is the portable spelling.
#   * the assertions that pin PSMUX_PASTE_INJECT=0 and then expect markers are
#     asserting the defect this issue is about: below build 22523 that conhost
#     strips them from the pipe BY DESIGN, which is the whole reason the
#     injection route exists.  They are gated on the build now.
#   * the wide payload really is mangled on 19045, on both routes AND without
#     psmux in the chain at all (his measurement: Latin 1 to NUL, each CJK
#     character to one unstable byte, under code page 65001 on the ReadFile
#     side).  That is the platform, so the assertion is strict at 22523 and
#     above and informational below.
#
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i684paste" }
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

# The build that decides whether this host's conhost carries ESC[200~ through a
# pane's ConPTY input pipe.  Same constant as the product's
# PASTE_PIPE_BRACKET_MIN_BUILD, and same one as CONPTY_MOUSE_MIN_BUILD before
# it: the pipe strips the markers below it.
$PIPE_BRACKET_MIN_BUILD = 22523
$OSBuild = [System.Environment]::OSVersion.Version.Build
# The build describes the INBOX conhost.  Under PSMUX_CONPTY_DIR the panes run
# on the console host the user supplied, and OpenConsole 1.24 carries the
# markers on the pipe on 19045 (reporter's measurement on #597: 502 bytes with
# both markers on every arm, wide payload byte exact), so the four build gated
# assertions below are real assertions there, not skips.
$SuppliedHost = [bool]$env:PSMUX_CONPTY_DIR -and (Test-Path (Join-Path $env:PSMUX_CONPTY_DIR 'conpty.dll'))
$PipeCarriesMarkers = ($OSBuild -ge $PIPE_BRACKET_MIN_BUILD) -or $SuppliedHost

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

$repoTests = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($v in 'PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') {
    Remove-Item "env:$v" -EA SilentlyContinue
}

$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$savedInject  = $env:PSMUX_PASTE_INJECT
$savedDebug   = $env:PSMUX_INPUT_DEBUG

$root = Join-Path $env:TEMP "psmux_i684_paste"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"
$env:PSMUX_INPUT_DEBUG = "1"

# --- compile the recorder ---------------------------------------------------
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$recorder = Join-Path $root "paste_recorder.exe"
& $csc /nologo /optimize /platform:x64 /out:$recorder (Join-Path $repoTests "paste_recorder.cs") 2>&1 | Out-Null
if (-not (Test-Path $recorder)) {
    Write-Host "FATAL: could not compile paste_recorder.cs" -ForegroundColor Red
    exit 1
}
$hostInjector = Join-Path $root "paste_host_injector.exe"
& $csc /nologo /optimize /platform:x64 /out:$hostInjector (Join-Path $repoTests "paste_host_injector.cs") 2>&1 | Out-Null

# --- payloads ---------------------------------------------------------------
# 10 lines of 47 characters with CRLF endings: 490 bytes, the reporter's file.
$stdLines = 0..9 | ForEach-Object { ("LINE{0}-ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789" -f $_).PadRight(47, '.') }
$stdText  = ($stdLines -join "`r`n") + "`r`n"
$stdFile  = Join-Path $root "payload_std.txt"
[IO.File]::WriteAllBytes($stdFile, [Text.Encoding]::ASCII.GetBytes($stdText))

# 100 lines of 99 characters: 10100 bytes, well past the 512 byte pipe chunk
# and the 2048 record injection chunk.
$bigText = ((1..100 | ForEach-Object { "X" * 99 }) -join "`r`n") + "`r`n"
$bigFile = Join-Path $root "payload_big.txt"
[IO.File]::WriteAllBytes($bigFile, [Text.Encoding]::ASCII.GetBytes($bigText))

# An ESC byte inside the payload, Latin 1, and CJK: the UTF-16 path in the
# KEY_EVENT records has to carry all of it.
$wideText = "ASCII-start" + [char]0x1b + "ESCBYTE-" + [char]0xe9 + [char]0xfc +
            "-CJK:" + [char]0x4f60 + [char]0x597d + [char]0x4e16 + [char]0x754c + "-end`r`n"
$wideFile = Join-Path $root "payload_wide.txt"
[IO.File]::WriteAllBytes($wideFile, [Text.Encoding]::UTF8.GetBytes($wideText))

# What the pane child must receive: every line break collapsed to a single CR,
# which is what BOTH channels do (write_paste_chunked normalises CRLF to CR and
# send_vt_response does the same on its way into UTF-16).
$ESC = [char]27   # NOT `e: Windows PowerShell 5.1 reads that as the letter e.
function Expected([string]$text, [bool]$bracket) {
    $body = $text -replace "`r`n", "`r"
    if ($bracket) { "$ESC[200~" + $body + "$ESC[201~" } else { $body }
}
function HexOf([string]$s) {
    ([Text.Encoding]::UTF8.GetBytes($s) | ForEach-Object { $_.ToString("x2") }) -join ""
}

# A fixed 3 s after `new -d` was enough on a quiet box and not under a sibling
# cargo build: sweep and agent runs on 2026-09-24 lost whole cases to a session
# that came up in 4 s, and every later assertion of that case failed with it.
# Poll instead: the session answers, then the pane runs what it was asked to.
function Wait-SessionReady([string]$Session, [string]$PaneCommand = "", [int]$TimeoutMs = 20000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        & $PSMUX -L $NS has-session -t $Session 2>$null
        if ($LASTEXITCODE -eq 0) {
            if ($PaneCommand -eq "") { return $true }
            $cmd = (& $PSMUX -L $NS display-message -t $Session -p '#{pane_current_command}' 2>$null | Out-String).Trim()
            if ($cmd -match $PaneCommand) { return $true }
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Info "session $Session not ready after $TimeoutMs ms"
    return $false
}

# --- one measurement --------------------------------------------------------
# Runs the recorder as a pane child, loads a buffer, pastes into it, and returns
# the recorder's parsed block plus the route psmux chose.
function Invoke-Paste {
    param(
        [string]$Tag,
        [string]$PayloadFile,
        [string]$Flags = "-p",
        [string]$RecorderMode = "vt",
        [string]$Inject = "",
        [int]$Seconds = 12
    )
    if ($Inject -ne "") { $env:PSMUX_PASTE_INJECT = $Inject }
    else { Remove-Item env:PSMUX_PASTE_INJECT -EA SilentlyContinue }
    # The route is read by the SERVER, so each arm needs its own cold server.
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $dbg = Join-Path $env:PSMUX_DATA_DIR "input_debug.log"
    Remove-Item $dbg -EA SilentlyContinue

    $log = Join-Path $root "rec_$Tag.log"
    Remove-Item $log -EA SilentlyContinue
    $sess = "i684_$Tag"
    & $PSMUX -L $NS new -d -s $sess -x 100 -y 30 -- $recorder $log $Seconds $RecorderMode 2>&1 | Out-Null
    [void](Wait-SessionReady $sess 'paste_recorder')
    Start-Sleep -Milliseconds 800
    & $PSMUX -L $NS load-buffer $PayloadFile 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $argv = @("-L", $NS, "paste-buffer") + ($Flags -split ' ' | Where-Object { $_ -ne "" }) + @("-t", $sess)
    & $PSMUX @argv 2>&1 | Out-Null
    Start-Sleep -Seconds ($Seconds - 1)

    $res = [ordered]@{ Total = -1; Hex = ""; Has200 = "?"; Has201 = "?"; Text = ""; Route = "none" }
    if (Test-Path $log) {
        foreach ($line in Get-Content $log) {
            if ($line -match '^TOTAL (\d+)$')  { $res.Total  = [int]$Matches[1] }
            elseif ($line -match '^HEX (.*)$') { $res.Hex    = $Matches[1] }
            elseif ($line -match '^HAS200 (\w+)$') { $res.Has200 = $Matches[1] }
            elseif ($line -match '^HAS201 (\w+)$') { $res.Has201 = $Matches[1] }
            elseif ($line -match '^TEXT (.*)$') { $res.Text   = $Matches[1] }
        }
    }
    if (Test-Path $dbg) {
        $r = Get-Content $dbg | Select-String -Pattern 'route=(inject|pipe)' | Select-Object -Last 1
        if ($r) { $res.Route = ([regex]'route=(inject|pipe)').Match($r.Line).Groups[1].Value }
    }
    & $PSMUX -L $NS kill-session -t $sess 2>&1 | Out-Null
    [pscustomobject]$res
}

Write-Host "`n=== Issue #684: paste route ===" -ForegroundColor Yellow
Write-Info "host build $OSBuild, pipe bracket gate $PIPE_BRACKET_MIN_BUILD, pane host $(if ($SuppliedHost) { "supplied via PSMUX_CONPTY_DIR=$env:PSMUX_CONPTY_DIR" } else { 'inbox conhost' }), which $(if ($PipeCarriesMarkers) { 'carries' } else { 'STRIPS' }) ESC[200~ on the input pipe"

# 1. The pipe route, which is what this host does on its own.
$pipe = Invoke-Paste -Tag "pipe" -PayloadFile $stdFile -Inject "0"
$want = HexOf (Expected $stdText $true)
if ($pipe.Route -eq "pipe") { Write-Pass "PSMUX_PASTE_INJECT=0 pins the pipe route" }
else { Write-Fail "PSMUX_PASTE_INJECT=0 chose '$($pipe.Route)'" }
if (-not $PipeCarriesMarkers) {
    # Below the gate this assertion would be asserting the defect: the pipe
    # loses the markers on that conhost, by design, which is why psmux does not
    # use the pipe there unless PSMUX_PASTE_INJECT=0 forces it.
    Write-Skip "pipe route byte exactness: build $OSBuild is below $PIPE_BRACKET_MIN_BUILD, this conhost strips the markers from the pipe (that is the defect, not a regression). Got $($pipe.Total) bytes, markers 200=$($pipe.Has200) 201=$($pipe.Has201)"
} elseif ($pipe.Hex -eq $want) { Write-Pass "pipe route delivers the 490 byte payload byte exact with both markers ($($pipe.Total) bytes)" }
else { Write-Fail "pipe route bytes differ`n    want $want`n    got  $($pipe.Hex)" }

# 2. The injection route, the one a 19045 pane needs, forced on here.
$inj = Invoke-Paste -Tag "inject" -PayloadFile $stdFile -Inject "1"
if ($inj.Route -eq "inject") { Write-Pass "PSMUX_PASTE_INJECT=1 takes the WriteConsoleInputW route" }
else { Write-Fail "PSMUX_PASTE_INJECT=1 chose '$($inj.Route)'" }
if ($inj.Has200 -eq "YES" -and $inj.Has201 -eq "YES") { Write-Pass "the injected paste carries ESC[200~ and ESC[201~" }
else { Write-Fail "the injected paste lost a marker (200=$($inj.Has200) 201=$($inj.Has201))" }
if ($inj.Hex -eq $want) { Write-Pass "injection route delivers the same 490 byte payload byte exact ($($inj.Total) bytes)" }
else { Write-Fail "injection route bytes differ`n    want $want`n    got  $($inj.Hex)" }
if (-not $PipeCarriesMarkers) {
    Write-Skip "route equality: on build $OSBuild the pipe arm is missing the 12 marker bytes the injection arm carries, which is exactly why the injection route exists (inject $($inj.Total) bytes, pipe $($pipe.Total))"
} elseif ($inj.Hex -eq $pipe.Hex) { Write-Pass "both routes hand the child IDENTICAL bytes" }
else { Write-Fail "the two routes disagree, so a 19045 user would not get what a 26200 user gets" }

# 3. Chunking: 10100 bytes crosses both the 512 byte pipe chunk and the 2048
#    record injection chunk.
$bigWant = HexOf (Expected $bigText $true)
$bigInj  = Invoke-Paste -Tag "biginj" -PayloadFile $bigFile -Inject "1" -Seconds 16
if ($bigInj.Hex -eq $bigWant) { Write-Pass "a 10100 byte paste survives injection chunking ($($bigInj.Total) bytes)" }
else { Write-Fail "the chunked injection lost bytes: want $($bigWant.Length/2), got $($bigInj.Total)" }

# 4. An ESC byte and non ASCII through the UTF-16 record encoding.
#
# gabri-ns measured this payload on 19045 four ways: through psmux on the pipe,
# through psmux on the injection route, and through a bare pseudoconsole host
# with NO psmux in the chain on each of those two channels.  The ASCII, the ESC
# byte, the CR and the markers survive every time; only the non ASCII changes,
# and it changes WITHOUT psmux too (Latin 1 to NUL, each CJK character to one
# byte whose value is not stable between runs).  That is the inbox conhost
# converting the console input buffer's UTF-16 under code page 65001 on the
# ReadFile side, a stronger form of the emoji caveat on 26200.  So: strict at
# and above the gate, informational below it.
$wideWant = HexOf (Expected $wideText $true)
$wideInj  = Invoke-Paste -Tag "wideinj" -PayloadFile $wideFile -Inject "1"
$widePipe = Invoke-Paste -Tag "widepipe" -PayloadFile $wideFile -Inject "0"
$wideAsciiOk = $wideInj.Text -match 'ASCII-start' -and $wideInj.Text -match '-end' -and $wideInj.Text -match '<ESC>ESCBYTE-'
if (-not $PipeCarriesMarkers) {
    if ($wideAsciiOk) {
        Write-Skip "wide payload: build $OSBuild mangles non ASCII in the conhost on BOTH routes and without psmux at all (reporter measured it). The ASCII, the ESC byte and the markers did arrive: '$($wideInj.Text)'"
    } else {
        Write-Fail "the wide payload lost its ASCII or its ESC byte, which the platform does NOT explain: '$($wideInj.Text)'"
    }
    Write-Skip "wide payload route equality: not comparable below the gate, the two channels mangle non ASCII differently on that conhost"
} else {
    if ($wideInj.Hex -eq $wideWant) { Write-Pass "an ESC byte, Latin 1 and CJK survive the KEY_EVENT records" }
    else { Write-Fail "the wide payload was mangled by injection`n    want $wideWant`n    got  $($wideInj.Hex)" }
    if ($wideInj.Hex -eq $widePipe.Hex) { Write-Pass "the wide payload is identical on both routes" }
    else { Write-Fail "the wide payload differs between the routes" }
}

# 5. Issue #98: a record reader keeps the pipe even with the override on, and
#    never sees the markers as literal characters.
$rec = Invoke-Paste -Tag "records" -PayloadFile $stdFile -Inject "1" -RecorderMode "records"
if ($rec.Route -eq "pipe") { Write-Pass "a record reader keeps the pipe even with PSMUX_PASTE_INJECT=1 (issue #98)" }
else { Write-Fail "a record reader was sent down the '$($rec.Route)' route" }
if ($rec.Has200 -eq "NO" -and $rec.Has201 -eq "NO" -and $rec.Text -notmatch '\[20[01]~') {
    Write-Pass "the record reader sees no literal [200~ characters"
} else {
    Write-Fail "the record reader saw bracket characters: $($rec.Text)"
}
$recWant = HexOf (Expected $stdText $false)
if ($rec.Hex -eq $recWant) { Write-Pass "the record reader still receives the whole payload ($($rec.Total) bytes)" }
else { Write-Fail "the record reader lost payload bytes ($($rec.Total))" }

# 6. tmux parity: no -p means no markers, whatever the pane asked for
#    (cmd-paste-buffer.c:97 brackets only when -p AND MODE_BRACKETPASTE).
$plain = Invoke-Paste -Tag "noflag" -PayloadFile $stdFile -Flags ""
if ($plain.Has200 -eq "NO" -and $plain.Has201 -eq "NO") { Write-Pass "paste-buffer without -p is unbracketed, as tmux documents" }
else { Write-Fail "paste-buffer without -p emitted markers" }

Write-Host "`n=== Issue #684: the default ] binding ===" -ForegroundColor Yellow

& $PSMUX -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX -L $NS new -d -s i684_keys -x 80 -y 24 2>&1 | Out-Null
[void](Wait-SessionReady 'i684_keys')
$keys = (& $PSMUX -L $NS list-keys) -join "`n"
# tmux key-bindings.c:422: bind -N 'Paste the most recent paste buffer' ] { paste-buffer -p }
if ($keys -match 'bind-key -T prefix \] paste-buffer -p') {
    Write-Pass "list-keys shows ] bound to paste-buffer -p (tmux key-bindings.c:422)"
} else {
    Write-Fail "] is not bound to paste-buffer -p"
}

Write-Host "`n=== Issue #684: paste-buffer flags in the in server dispatch ===" -ForegroundColor Yellow

# A hook runs through commands.rs execute_command_string, the same route a key
# binding and the command prompt take.  Before the fix this pasted buffer 0
# unbracketed whatever the flags said.
# $Inject defaults to "" on purpose: the NATURAL route for this host.  It used
# to default to "0", which pins the pipe, and on a build below the gate that
# made the flag assertions measure the channel instead of the flags: the pane
# did receive NAMEDBUF684, -p was honoured (the server log said
# "route=pipe bracket=true"), and the conhost then ate the twelve marker bytes.
function Invoke-HookPaste([string]$Tag, [string]$Command, [string]$Inject = "") {
    if ($Inject -ne "") { $env:PSMUX_PASTE_INJECT = $Inject }
    else { Remove-Item env:PSMUX_PASTE_INJECT -EA SilentlyContinue }
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $log = Join-Path $root "rec_$Tag.log"
    Remove-Item $log -EA SilentlyContinue
    $sess = "i684_$Tag"
    # The recorder lives in window 1 of a session whose window 0 is a plain
    # shell, so the session survives the recorder's exit.  Without that, the
    # session closes with the recorder and a later list-buffers answers
    # "no server running", which would satisfy a "the buffer is gone"
    # assertion for the wrong reason.
    & $PSMUX -L $NS new -d -s $sess -x 100 -y 30 2>&1 | Out-Null
    [void](Wait-SessionReady $sess)
    & $PSMUX -L $NS new-window -t $sess -- $recorder $log 12 vt 2>&1 | Out-Null
    [void](Wait-SessionReady $sess 'paste_recorder')
    Start-Sleep -Milliseconds 800
    & $PSMUX -L $NS set-buffer -b named684 "NAMEDBUF684" 2>&1 | Out-Null
    & $PSMUX -L $NS set-buffer "DEFAULTBUF684" 2>&1 | Out-Null
    $res = [ordered]@{ Text = ""; Total = -1; Buffers = ""; BuffersBefore = "" }
    $res.BuffersBefore = ((& $PSMUX -L $NS list-buffers) -join "`n")
    & $PSMUX -L $NS set-hook -g before-select-window $Command 2>&1 | Out-Null
    & $PSMUX -L $NS select-window -t "${sess}:1" 2>&1 | Out-Null
    Start-Sleep -Seconds 13
    if (Test-Path $log) {
        foreach ($line in Get-Content $log) {
            if ($line -match '^TEXT (.*)$')  { $res.Text  = $Matches[1] }
            elseif ($line -match '^TOTAL (\d+)$') { $res.Total = [int]$Matches[1] }
        }
    }
    $res.Buffers = ((& $PSMUX -L $NS list-buffers) -join "`n")
    & $PSMUX -L $NS set-hook -gu before-select-window 2>&1 | Out-Null
    & $PSMUX -L $NS kill-session -t $sess 2>&1 | Out-Null
    [pscustomobject]$res
}

$flagged = Invoke-HookPaste -Tag "flags" -Command "paste-buffer -p -b named684"
if ($flagged.Text -eq "<ESC>[200~NAMEDBUF684<ESC>[201~") {
    Write-Pass "a bound `paste-buffer -p -b named684` pastes the NAMED buffer, bracketed"
} else {
    Write-Fail "the flags were ignored, the pane received: '$($flagged.Text)'"
}

$deleted = Invoke-HookPaste -Tag "delete" -Command "paste-buffer -d -b named684"
if ($deleted.Text -eq "NAMEDBUF684") { Write-Pass "-d pastes the named buffer without brackets" }
else { Write-Fail "-d pasted '$($deleted.Text)'" }
if ($deleted.BuffersBefore -match 'named684' -and $deleted.Buffers -notmatch 'named684') {
    Write-Pass "-d deletes the buffer afterwards (cmd-paste-buffer.c:128)"
} elseif ($deleted.BuffersBefore -notmatch 'named684') {
    Write-Fail "the named buffer was never there to delete: $($deleted.BuffersBefore)"
} else {
    Write-Fail "-d left the buffer in place: $($deleted.Buffers)"
}

$sep = Invoke-HookPaste -Tag "sep" -Command "paste-buffer -s @@ -b named684"
if ($sep.Text -eq "NAMEDBUF684") { Write-Pass "-s is accepted (the named buffer has no newline to replace)" }
else { Write-Fail "-s changed a newline free buffer: '$($sep.Text)'" }

$missing = Invoke-HookPaste -Tag "missing" -Command "paste-buffer -p -b nosuchbuffer684"
if ($missing.Total -le 0) { Write-Pass "a missing named buffer pastes nothing (tmux: no buffer <name>)" }
else { Write-Fail "a missing buffer still pasted $($missing.Total) bytes: '$($missing.Text)'" }

Write-Host "`n=== Issue #684 follow up: -t names the pane the text lands in ===" -ForegroundColor Yellow

# gabri-ns: `paste-buffer -t <pane>` on the CLI route pasted into the ACTIVE
# pane.  parse_paste_buffer_args filled `target` and the dispatch never read
# it, and the validated -t focus the dispatcher applies was spent by the
# buffer lookup that ran before the paste.  tmux resolves the pane with
# cmd_find_pane and writes to it (cmd-paste-buffer.c:66 and :124).
#
# Two recorders, one per window, window 0 active: the payload must land in
# window 1 and window 0 must receive NOTHING.
function Invoke-TargetedPaste([string]$Tag, [string]$How) {
    Remove-Item env:PSMUX_PASTE_INJECT -EA SilentlyContinue
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $sess = "i684_$Tag"
    $log0 = Join-Path $root "rec_${Tag}_w0.log"
    $log1 = Join-Path $root "rec_${Tag}_w1.log"
    Remove-Item $log0, $log1 -EA SilentlyContinue
    & $PSMUX -L $NS new -d -s $sess -x 100 -y 30 -- $recorder $log0 16 vt 2>&1 | Out-Null
    [void](Wait-SessionReady $sess 'paste_recorder')
    & $PSMUX -L $NS new-window -t $sess -- $recorder $log1 14 vt 2>&1 | Out-Null
    [void](Wait-SessionReady "${sess}:1" 'paste_recorder')
    Start-Sleep -Milliseconds 800
    & $PSMUX -L $NS set-buffer -b tbuf684 "TARGETED684" 2>&1 | Out-Null
    $err = ""
    if ($How -eq "cli") {
        & $PSMUX -L $NS select-window -t "${sess}:0" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 400
        $err = ((& $PSMUX -L $NS paste-buffer -p -b tbuf684 -t "${sess}:1" 2>&1) -join " ").Trim()
    } else {
        # The in server dispatch: a hook, a key binding and the command prompt
        # all reach paste-buffer through execute_command_string.  The hook runs
        # AFTER the switch to window 0, so the active pane at paste time is
        # window 0's recorder and the target is window 1's.
        & $PSMUX -L $NS set-hook -g after-select-window "paste-buffer -p -b tbuf684 -t ${sess}:1" 2>&1 | Out-Null
        & $PSMUX -L $NS select-window -t "${sess}:0" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        & $PSMUX -L $NS set-hook -gu after-select-window 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 16
    $res = [ordered]@{ W0 = ""; W1 = ""; T0 = -1; T1 = -1; Err = $err }
    if (Test-Path $log0) { foreach ($l in Get-Content $log0) { if ($l -match '^TEXT (.*)$') { $res.W0 = $Matches[1] } elseif ($l -match '^TOTAL (\d+)$') { $res.T0 = [int]$Matches[1] } } }
    if (Test-Path $log1) { foreach ($l in Get-Content $log1) { if ($l -match '^TEXT (.*)$') { $res.W1 = $Matches[1] } elseif ($l -match '^TOTAL (\d+)$') { $res.T1 = [int]$Matches[1] } } }
    & $PSMUX -L $NS kill-session -t $sess 2>&1 | Out-Null
    [pscustomobject]$res
}

$tcli = Invoke-TargetedPaste -Tag "tcli" -How "cli"
if ($tcli.W1 -match 'TARGETED684') { Write-Pass "CLI: paste-buffer -t <window> lands in the TARGET pane ($($tcli.T1) bytes)" }
else { Write-Fail "CLI: the -t target received '$($tcli.W1)' ($($tcli.T1) bytes)" }
if ($tcli.T0 -le 0) { Write-Pass "CLI: the active pane received nothing (it used to receive the whole paste)" }
else { Write-Fail "CLI: the ACTIVE pane received $($tcli.T0) bytes: '$($tcli.W0)'" }

# The byte count on this arm can be a multiple of one paste: psmux fires
# `after-select-window` twice for a single `select-window` (reproduced with a
# hook that only runs `set-buffer`, so it is nothing to do with paste-buffer).
# What this asserts is WHERE the text landed, which is unaffected by that.
$thook = Invoke-TargetedPaste -Tag "thook" -How "hook"
if ($thook.W1 -match 'TARGETED684') { Write-Pass "in server dispatch: a bound paste-buffer -t lands in the TARGET pane ($($thook.T1) bytes)" }
else { Write-Fail "in server dispatch: the -t target received '$($thook.W1)' ($($thook.T1) bytes)" }
if ($thook.T0 -le 0) { Write-Pass "in server dispatch: the active pane received nothing" }
else { Write-Fail "in server dispatch: the ACTIVE pane received $($thook.T0) bytes: '$($thook.W0)'" }

# tmux's error text for a target that does not resolve, and no paste anywhere.
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX -L $NS new -d -s i684_terr -x 80 -y 24 2>&1 | Out-Null
[void](Wait-SessionReady 'i684_terr')
& $PSMUX -L $NS set-buffer -b tbuf684 "TARGETED684" 2>&1 | Out-Null
$errWin  = ((& $PSMUX -L $NS paste-buffer -p -b tbuf684 -t "i684_terr:9" 2>&1) -join " ").Trim()
$rcWin   = $LASTEXITCODE
$errPane = ((& $PSMUX -L $NS paste-buffer -p -b tbuf684 -t "%9999" 2>&1) -join " ").Trim()
$rcPane  = $LASTEXITCODE
if ($errWin -match "can't find window: 9" -and $rcWin -ne 0) { Write-Pass "a -t window that does not exist reports tmux's ""can't find window"" and exits $rcWin" }
else { Write-Fail "bad -t window said '$errWin' rc=$rcWin" }
if ($errPane -match "can't find pane: %9999" -and $rcPane -ne 0) { Write-Pass "a -t pane that does not exist reports tmux's ""can't find pane"" and exits $rcPane" }
else { Write-Fail "bad -t pane said '$errPane' rc=$rcPane" }
& $PSMUX -L $NS kill-session -t i684_terr 2>&1 | Out-Null

# ---------------------------------------------------------------------------
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
$env:PSMUX_DATA_DIR = $savedDataDir
$env:PSMUX_NO_WARM = $savedNoWarm
$env:PSMUX_INPUT_DEBUG = $savedDebug
if ($null -eq $savedInject) { Remove-Item env:PSMUX_PASTE_INJECT -EA SilentlyContinue }
else { $env:PSMUX_PASTE_INJECT = $savedInject }

Write-Host "`n================ SUMMARY ================" -ForegroundColor Yellow
Write-Host "  Host build: $OSBuild (pipe bracket gate $PIPE_BRACKET_MIN_BUILD)" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
if ($script:TestsSkipped -gt 0) {
    Write-Host "  Skipped: $script:TestsSkipped (platform: this conhost strips the markers from the input pipe)" -ForegroundColor Yellow
}
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
