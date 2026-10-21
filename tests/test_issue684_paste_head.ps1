# Issue #684 follow up: the FIRST character of a Ctrl+V burst must not go out
# as typing.
#
# gabri-ns, on Windows 10 19045 with a real Windows Terminal Ctrl+V into a
# recorder pane, on master and on the build before the #684 fix alike:
#
#   [paste] zero-latency flush 1 char(s) as typing
#   [send] -> send-text "M"
#   [paste] stage2: 71 chars in 20ms, waiting for Ctrl+V Release
#   [paste] paste CONFIRMED (post-event), sending 90 chars as send-paste
#   child:  M ESC[200~ icrosoft Windows [Version 10.0.19045.7725] ...
#
# The head of the paste was on the wrong side of the marker.  An earlier run
# with a 490 byte clipboard leaked 32 characters the same way.  The client's
# "zero-latency typing flush" assumed the console host injects a clipboard
# atomically, so paste_pend would already hold three or more characters by the
# time the event batch was drained; on his host the first batch held one.
#
# This box (26200) does inject atomically, so the 19045 shape is emulated with
# tests/paste_host_injector.cs `drip`: one WriteConsoleInputW per character,
# PSMUX_INJECT_GAP_MS apart (a spin, not Thread.Sleep, which would round up to
# the 15.6 ms tick).  Measured on the fix's parent, a 2 ms drip put ALL 43
# characters outside the brackets, one send-text at a time.
#
# tmux never has this problem: its host brackets the paste in the byte stream
# and tty_keys_paste (tty-keys.c:838) returns 1 for "partial" until the closing
# ESC[201~ arrives, so nothing of a paste is ever dispatched as keys.  The
# console input buffer carries no such marker, so the client recognises the
# head of a paste from the clipboard (a paste IS the clipboard) or from a
# Ctrl+V press still in flight.
#
# The third case is the control: a hand typing must still take the zero latency
# path, character by character, with no brackets and no hold.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue684_paste_head.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i684head" }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$savedDebug   = $env:PSMUX_INPUT_DEBUG
$savedGap     = $env:PSMUX_INJECT_GAP_MS
$savedClip    = try { Get-Clipboard -Raw -EA SilentlyContinue } catch { $null }
# Everything below runs inside try/finally so the user's clipboard comes back
# even when the run dies or is stopped halfway (it sets several test texts).
try {

$root = Join-Path $env:TEMP "psmux_i684_head"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"
$env:PSMUX_INPUT_DEBUG = "1"

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$recorder = Join-Path $root "paste_recorder.exe"
$inj = Join-Path $root "paste_host_injector.exe"
& $csc /nologo /optimize /platform:x64 /out:$recorder (Join-Path $PSScriptRoot "paste_recorder.cs") 2>&1 | Out-Null
& $csc /nologo /optimize /out:$inj (Join-Path $PSScriptRoot "paste_host_injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $recorder) -or -not (Test-Path $inj)) {
    Write-Host "FATAL: could not compile the recorder or the injector" -ForegroundColor Red
    exit 1
}

$ESC = [char]27   # NOT `e: Windows PowerShell 5.1 reads that as the letter e.

# Set-Clipboard does not report a clipboard another window is holding open: the
# old contents stay and the client, correctly, finds the typed text is not the
# clipboard's head and flushes every character as typing.  That is the shape of
# a split paste, so the gesture must not start until the clipboard really holds
# what the test is about to inject.
function Set-ClipboardVerified([string]$Value) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 5000) {
        try { Set-Clipboard -Value $Value -EA Stop } catch {}
        Start-Sleep -Milliseconds 100
        $now = try { (Get-Clipboard -Raw -EA Stop) } catch { $null }
        if ($null -ne $now -and $now.TrimEnd("`r", "`n") -eq $Value) { return $true }
    }
    return $false
}

# One gesture against a REAL attached client, with the recorder as the pane
# child so the assertion is on the bytes, not on the screen.
function Invoke-Gesture {
    param([string]$Tag, [string]$Mode, [int]$Gap, [string]$Text, [string]$Clip = "")
    if ($Clip -eq "") { $Clip = $Text }
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $dbg = Join-Path $env:PSMUX_DATA_DIR "input_debug.log"
    Remove-Item $dbg -EA SilentlyContinue
    $log = Join-Path $root "rec_$Tag.log"
    Remove-Item $log -EA SilentlyContinue
    $sess = "i684h_$Tag"
    $res = [ordered]@{ Text = ""; Total = -1; Has200 = "?"; Has201 = "?"; Flush = 0; Hold = 0; Rc = -1; Attached = $false; ClipSet = $false }

    & $PSMUX -L $NS new -d -s $sess -x 100 -y 30 -- $recorder $log 22 vt 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $client = Start-Process -FilePath $PSMUX -ArgumentList "-L", $NS, "attach-session", "-t", $sess -PassThru -WindowStyle Normal
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        if (((& $PSMUX -L $NS display-message -t $sess -p '#{session_attached}') -join '').Trim() -eq '1') { $res.Attached = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if ($res.Attached) {
        Start-Sleep -Seconds 2
        $res.ClipSet = Set-ClipboardVerified $Clip
        if (-not $res.ClipSet) { Write-Info "[$Tag] the clipboard never took the test text in 5 s; it holds '$(try { Get-Clipboard -Raw } catch { '?' })'" }
        Start-Sleep -Milliseconds 250
        $env:PSMUX_INJECT_GAP_MS = "$Gap"
        & $inj $client.Id $Mode 150 $Text
        $res.Rc = $LASTEXITCODE
        Start-Sleep -Seconds 4
    }
    try { if (-not $client.HasExited) { Stop-Process -Id $client.Id -Force -EA SilentlyContinue } } catch {}
    Start-Sleep -Seconds 17

    if (Test-Path $log) {
        foreach ($l in Get-Content $log) {
            if ($l -match '^TEXT (.*)$') { $res.Text = $Matches[1] }
            elseif ($l -match '^TOTAL (\d+)$') { $res.Total = [int]$Matches[1] }
            elseif ($l -match '^HAS200 (\w+)$') { $res.Has200 = $Matches[1] }
            elseif ($l -match '^HAS201 (\w+)$') { $res.Has201 = $Matches[1] }
        }
    }
    if (Test-Path $dbg) {
        $lines = Get-Content $dbg
        $res.Flush = @($lines | Where-Object { $_ -match 'zero-latency flush' }).Count
        $res.Hold  = @($lines | Where-Object { $_ -match 'holding .* head of a paste' }).Count
    }
    & $PSMUX -L $NS kill-session -t $sess 2>&1 | Out-Null
    [pscustomobject]$res
}

$payload = "Microsoft Windows [Version 10.0.19045.7725]"
$wantBracketed = "<ESC>[200~" + $payload + "<ESC>[201~"

Write-Host "`n=== #684 follow up: a dripped Ctrl+V burst (the 19045 shape) ===" -ForegroundColor Yellow
$drip = Invoke-Gesture -Tag "drip" -Mode "drip" -Gap 2 -Text $payload
if (-not $drip.Attached) {
    Write-Skip "no client attached, nothing measurable"
} elseif ($drip.Rc -eq 2) {
    Write-Skip "AttachConsole refused from this shell (run the suite from a real console)"
} elseif (-not $drip.ClipSet) {
    Write-Skip "the clipboard never held the payload, so the burst was not a paste of it"
} else {
    if ($drip.Text -eq $wantBracketed) {
        Write-Pass "all $($payload.Length) characters arrived INSIDE the brackets ($($drip.Total) bytes)"
    } else {
        Write-Fail "the burst was split: '$($drip.Text)'"
    }
    # Starts WITH the marker, not merely "no characters before one": a burst
    # that lost its brackets entirely must not satisfy this.
    if ($drip.Text.StartsWith("<ESC>[200~")) {
        Write-Pass "the child's very first byte is ESC, so no character of the paste was typed"
    } else {
        Write-Fail "the paste did not begin with ESC[200~: '$($drip.Text)'"
    }
    if ($drip.Flush -eq 0) { Write-Pass "the client made no zero-latency typing flush during the burst" }
    else { Write-Fail "$($drip.Flush) zero-latency flush(es) during a paste" }
    if ($drip.Hold -ge 1) { Write-Pass "the client logged the hold: the head of the burst was recognised" }
    else { Write-Info "no hold line (the burst never presented a 1 to 2 character batch on this run)" }
}

Write-Host "`n=== the atomic shape this host's terminal uses is unchanged ===" -ForegroundColor Yellow
$atomic = Invoke-Gesture -Tag "host" -Mode "host" -Gap 0 -Text $payload
if (-not $atomic.Attached -or $atomic.Rc -eq 2) {
    Write-Skip "atomic arm not measurable on this host"
} elseif ($atomic.Text -eq $wantBracketed) {
    Write-Pass "an atomically injected clipboard still arrives whole and bracketed ($($atomic.Total) bytes)"
} else {
    Write-Fail "the atomic paste changed shape: '$($atomic.Text)'"
}

Write-Host "`n=== the control: typing must still take the zero latency path ===" -ForegroundColor Yellow
# The clipboard deliberately does NOT begin with the typed text, which is the
# ordinary case: nothing may be held.
$typed = Invoke-Gesture -Tag "type" -Mode "type" -Gap 120 -Text "hello" -Clip "ZZZ not what is being typed"
if (-not $typed.Attached -or $typed.Rc -eq 2) {
    Write-Skip "typing arm not measurable on this host"
} else {
    if ($typed.Text -eq "hello") { Write-Pass "the typed characters arrived verbatim and unbracketed" }
    else { Write-Fail "typing arrived as '$($typed.Text)'" }
    if ($typed.Has200 -eq "NO" -and $typed.Has201 -eq "NO") { Write-Pass "typing is never wrapped in bracketed paste" }
    else { Write-Fail "typing was bracketed (200=$($typed.Has200) 201=$($typed.Has201))" }
    if ($typed.Flush -ge 5) { Write-Pass "all 5 keystrokes took the zero latency flush ($($typed.Flush) flushes)" }
    else { Write-Fail "only $($typed.Flush) of 5 keystrokes took the zero latency path" }
    if ($typed.Hold -eq 0) { Write-Pass "nothing was held: the clipboard did not match what was typed" }
    else { Write-Fail "$($typed.Hold) keystroke(s) were held although the clipboard does not begin with them" }
}

Write-Host "`n=== the cost case: typing the clipboard's first character ===" -ForegroundColor Yellow
# The one case where the hold costs anything: the character typed IS the first
# character of the clipboard.  It must still arrive, through the ordinary 20 ms
# window, which is the path every character took before the zero latency flush
# existed.
$cost = Invoke-Gesture -Tag "cost" -Mode "type" -Gap 120 -Text "hello" -Clip "hello world, this is on the clipboard"
if (-not $cost.Attached -or $cost.Rc -eq 2) {
    Write-Skip "cost arm not measurable on this host"
} else {
    if ($cost.Text -eq "hello") { Write-Pass "the held character still arrives, in order, as typing" }
    else { Write-Fail "the held character changed the text: '$($cost.Text)'" }
    if ($cost.Has200 -eq "NO") { Write-Pass "a held keystroke is not promoted to a paste" }
    else { Write-Fail "a held keystroke was bracketed" }
    if ($cost.Hold -le 1) { Write-Pass "only the matching character was held ($($cost.Hold))" }
    else { Write-Fail "$($cost.Hold) characters were held, expected at most 1" }
}

Write-Host "`n=== a moment of clipboard contention must not poison later pastes ===" -ForegroundColor Yellow
# One attached client.  Paste 1 is dripped while another window holds the
# clipboard open, so the client cannot read its head.  The holder lets go and
# paste 2 of the SAME clipboard (same sequence number) is dripped.  Before the
# fix the refused read was cached as "no text" for that sequence number and
# paste 2 arrived as 43 typed characters with no brackets.
#
# The holder must open the clipboard with a real window: OpenClipboard(NULL)
# does not stop another process opening it, so it would hold nothing.
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$dbg = Join-Path $env:PSMUX_DATA_DIR "input_debug.log"
Remove-Item $dbg -EA SilentlyContinue
$clog = Join-Path $root "rec_contend.log"
$flag = Join-Path $root "holding.flag"
$holder = Join-Path $root "clip_holder.ps1"
@'
param([string]$Flag, [int]$HoldMs)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace H684 -Name C -MemberDefinition '[DllImport("user32.dll")] public static extern bool OpenClipboard(System.IntPtr h); [DllImport("user32.dll")] public static extern bool CloseClipboard();'
$form = New-Object System.Windows.Forms.Form
if ([H684.C]::OpenClipboard($form.Handle)) { Set-Content $Flag 'held'; Start-Sleep -Milliseconds $HoldMs; [H684.C]::CloseClipboard() | Out-Null; Set-Content $Flag 'released' }
else { Set-Content $Flag 'openfailed' }
$form.Dispose()
'@ | Set-Content $holder
$csess = "i684h_contend"
& $PSMUX -L $NS new -d -s $csess -x 100 -y 30 -- $recorder $clog 40 vt 2>&1 | Out-Null
Start-Sleep -Seconds 3
$cclient = Start-Process -FilePath $PSMUX -ArgumentList "-L", $NS, "attach-session", "-t", $csess -PassThru -WindowStyle Normal
$sw = [Diagnostics.Stopwatch]::StartNew(); $catt = $false
while ($sw.ElapsedMilliseconds -lt 15000) {
    if (((& $PSMUX -L $NS display-message -t $csess -p '#{session_attached}') -join '').Trim() -eq '1') { $catt = $true; break }
    Start-Sleep -Milliseconds 100
}
$cclipOk = $false; $held = ""; $rc2 = -1
if ($catt) {
    Start-Sleep -Seconds 2
    $cclipOk = Set-ClipboardVerified $payload
    Start-Sleep -Milliseconds 250
    $shellExe = (Get-Process -Id $PID).Path
    $hp = Start-Process $shellExe -ArgumentList '-NoProfile', '-File', $holder, '-Flag', $flag, '-HoldMs', 1500 -PassThru -WindowStyle Hidden
    $sw.Restart(); while (-not (Test-Path $flag) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 20 }
    $held = (Get-Content $flag -EA SilentlyContinue) -join ''
    $env:PSMUX_INJECT_GAP_MS = "2"
    & $inj $cclient.Id drip 150 $payload | Out-Null
    $hp.WaitForExit(15000) | Out-Null
    $held = (Get-Content $flag -EA SilentlyContinue) -join ''
    Start-Sleep -Seconds 2
    & $inj $cclient.Id type 150 "|" | Out-Null
    Start-Sleep -Seconds 1
    & $inj $cclient.Id drip 150 $payload | Out-Null
    $rc2 = $LASTEXITCODE
    Start-Sleep -Seconds 4
}
try { if (-not $cclient.HasExited) { Stop-Process -Id $cclient.Id -Force -EA SilentlyContinue } } catch {}
# The recorder writes its log when its 40 s window closes.
$sw.Restart(); while (-not ((Test-Path $clog) -and (Select-String -Path $clog -Pattern '^TEXT ' -Quiet)) -and $sw.ElapsedMilliseconds -lt 45000) { Start-Sleep -Milliseconds 500 }
$ctext = ""
foreach ($l in Get-Content $clog -EA SilentlyContinue) { if ($l -match '^TEXT (.*)$') { $ctext = $Matches[1] } }
$busy = if (Test-Path $dbg) { @(Get-Content $dbg | Where-Object { $_ -match 'clipboard busy' }).Count } else { 0 }
& $PSMUX -L $NS kill-session -t $csess 2>&1 | Out-Null
if (-not $catt -or $rc2 -eq 2) {
    Write-Skip "contention arm not measurable on this host"
} elseif (-not $cclipOk -or $held -ne 'released') {
    Write-Skip "could not stage the contention (clipboard set: $cclipOk, holder: '$held')"
} else {
    if ($busy -ge 1) { Write-Pass "the client met the held clipboard and did not cache the refusal ($busy busy read(s))" }
    else { Write-Info "the client never read the clipboard while it was held (no busy line); paste 1 did not exercise the refusal" }
    $second = ($ctext -split '\|', 2)[1]
    if ($second -eq $wantBracketed) { Write-Pass "the paste after the contention arrived whole and bracketed" }
    else { Write-Fail "the paste after the contention was split: '$second' (whole record: '$ctext')" }
}

} finally {
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
$env:PSMUX_DATA_DIR = $savedDataDir
$env:PSMUX_NO_WARM = $savedNoWarm
$env:PSMUX_INPUT_DEBUG = $savedDebug
if ($null -eq $savedGap) { Remove-Item env:PSMUX_INJECT_GAP_MS -EA SilentlyContinue } else { $env:PSMUX_INJECT_GAP_MS = $savedGap }
if ($savedClip) {
    # Retried and verified: a clipboard another window holds open refuses
    # the write silently.
    $back = $false
    for ($i = 0; $i -lt 50 -and -not $back; $i++) {
        try { Set-Clipboard -Value $savedClip -EA Stop } catch {}
        $back = ((try { Get-Clipboard -Raw -EA Stop } catch { $null }) -eq $savedClip)
        if (-not $back) { Start-Sleep -Milliseconds 100 }
    }
    if ($back) { Write-Info "the clipboard was restored" } else { Write-Host "  [WARN] the clipboard could not be restored" -ForegroundColor Yellow }
}
}

Write-Host "`n================ SUMMARY ================" -ForegroundColor Yellow
Write-Host "  Passed: $script:Pass" -ForegroundColor Green
Write-Host "  Failed: $script:Fail" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
if ($script:Skip -gt 0) { Write-Host "  Skipped: $script:Skip" -ForegroundColor Yellow }
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
