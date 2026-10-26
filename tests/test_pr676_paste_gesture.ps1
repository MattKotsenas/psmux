# PR #667 / PR #676: a clipboard paste into a psmux pane must land ONCE.
#
# Windows Terminal binds Ctrl+V: the press never reaches the client, the
# clipboard text is injected as character key events, and only the V key
# release is forwarded. The psmux client also has a Release fallback that reads
# the clipboard itself (for hosts that do not inject), and that fallback used to
# deliver the text a second time. PR #667 compared the forwarded text with the
# clipboard, which covered pure CJK and pure ASCII pastes but not a paste the
# host splits into several bursts ('C2' as typing, then the CJK part through
# the IME heuristic), which is what PR #676 fixes by tracking the gesture.
#
# This suite emulates the host at the console input buffer with
# tests/paste_host_injector.cs against a REAL attached client, so both read
# back sites are exercised the way a user's Ctrl+V exercises them.
#
# Measured on the pre #676 build (fabfd2d) on this machine: every string already
# landed once through both routes, so the reporter's duplicate needs a host that
# splits the paste differently from this Windows Terminal. The suite therefore
# guards the contract rather than reproducing the report: one paste lands once,
# a deliberate second paste lands too, and a host that does not inject still
# pastes once through the read back.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_pr676_paste_gesture.ps1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = "pr676_$PID"
$S = "paste"
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }
function P { & $PSMUX -L $NS @args 2>&1 }

# The client must not think it is nested inside another psmux.
foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','TMUX','TMUX_PANE') { Remove-Item "Env:\$v" -EA SilentlyContinue }

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$inj = Join-Path $env:TEMP "psmux_paste_host_injector.exe"
& $csc /nologo /optimize /out:$inj (Join-Path $PSScriptRoot "paste_host_injector.cs") 2>&1 | Out-Null
if (-not (Test-Path $inj)) { Write-Fail "could not compile paste_host_injector.cs"; exit 1 }

Write-Host "`n=== PR #676: clipboard paste lands once ($PSMUX) ===" -ForegroundColor Cyan
$client = $null
# The cells below put their own text on the clipboard; the user's goes back in
# the finally block, verified.
$savedClip = try { Get-Clipboard -Raw -EA Stop } catch { $null }
try {
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 400
    P new-session -d -s $S -x 100 -y 30 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 20000) {
        if (((P capture-pane -t $S -p) -join "`n") -match 'PS [A-Z]:\\') { break }
        Start-Sleep -Milliseconds 100
    }
    $client = Start-Process -FilePath $PSMUX -ArgumentList "-L", $NS, "attach-session", "-t", $S -PassThru -WindowStyle Normal
    $sw.Restart()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        if (((P display-message -t $S -p '#{session_attached}') -join '').Trim() -eq '1') { break }
        Start-Sleep -Milliseconds 100
    }
    if (((P display-message -t $S -p '#{session_attached}') -join '').Trim() -ne '1') {
        Write-Fail "the attached client never registered"
        throw "no client"
    }
    Write-Info "attached client pid=$($client.Id)"
    Start-Sleep -Seconds 2

    function Count-OnPane([string]$text) {
        $cap = (P capture-pane -t $S -p) -join "`n"
        return ([regex]::Matches($cap, [regex]::Escape($text))).Count
    }
    function Reset-Prompt {
        # The pasted text sits on PSReadLine's input line; revert it first
        # (Escape is RevertLine) or 'clear' is appended to it and never runs.
        P send-keys -t $S Escape | Out-Null
        Start-Sleep -Milliseconds 250
        P send-keys -t $S "clear" Enter | Out-Null
        Start-Sleep -Milliseconds 800
    }
    function Paste-Once([string]$mode, [string]$text) {
        Set-Clipboard -Value $text
        Start-Sleep -Milliseconds 150
        # 150 ms between the injected characters and the V release: a hand
        # releases the key well after the host has finished injecting.
        & $inj $client.Id $mode 150 $text
        $rc = $LASTEXITCODE
        Start-Sleep -Milliseconds 1500
        return $rc
    }

    $cases = @(
        @{ text = '恭喜通关';       why = 'pure CJK, the #667 report' },
        @{ text = 'C2单元格应显示'; why = 'ASCII prefix then CJK, split into two bursts (#676)' },
        @{ text = '=(B3-B2)/B2';   why = 'formula, leading = flushed as typing (#676)' },
        @{ text = 'ZQ7';           why = 'pure ASCII' }
    )
    foreach ($c in $cases) {
        Write-Host "`n[host paste] '$($c.text)' : $($c.why)" -ForegroundColor Yellow
        Reset-Prompt
        $rc = Paste-Once 'host' $c.text
        if ($rc -eq 2) { Write-Skip "AttachConsole refused for '$($c.text)' (no console access from this shell)"; continue }
        if ($rc -ne 0) { Write-Fail "injector rc=$rc for '$($c.text)'"; continue }
        $n = Count-OnPane $c.text
        if ($n -eq 1) { Write-Pass "'$($c.text)' landed exactly once" }
        else { Write-Fail "'$($c.text)' landed $n time(s), expected 1" }

        # A deliberate second paste of the same text is a new gesture and must land.
        $rc = Paste-Once 'host' $c.text
        if ($rc -eq 0) {
            $n2 = Count-OnPane $c.text
            if ($n2 -eq 2) { Write-Pass "a second deliberate paste of '$($c.text)' landed too (2 total)" }
            else { Write-Fail "after a second paste '$($c.text)' appears $n2 time(s), expected 2" }
        }
    }

    Write-Host "`n[plain Ctrl+V] a host that does not inject: the client reads the clipboard itself" -ForegroundColor Yellow
    Reset-Prompt
    $rc = Paste-Once 'plain' 'C2单元格应显示'
    if ($rc -eq 2) { Write-Skip "AttachConsole refused for the plain case" }
    elseif ($rc -ne 0) { Write-Fail "injector rc=$rc for the plain case" }
    else {
        $n = Count-OnPane 'C2单元格应显示'
        if ($n -eq 1) { Write-Pass "plain Ctrl+V still pastes once through the read back" }
        else { Write-Fail "plain Ctrl+V pasted $n time(s), expected 1" }
    }

    Write-Host "`n[TUI] the attached client is still healthy" -ForegroundColor Yellow
    P split-window -v -t $S | Out-Null
    Start-Sleep -Milliseconds 600
    $panes = ((P display-message -t $S -p '#{window_panes}') -join '').Trim()
    if ($panes -eq '2') { Write-Pass "split-window created 2 panes under the live client" } else { Write-Fail "expected 2 panes, got '$panes'" }
    $att = ((P display-message -t $S -p '#{session_attached}') -join '').Trim()
    if ($att -eq '1') { Write-Pass "the client is still attached" } else { Write-Fail "session_attached=$att" }
}
catch { if ($_.Exception.Message -ne 'no client') { Write-Fail "unexpected: $_" } }
finally {
    if ($client) { Stop-Process -Id $client.Id -Force -EA SilentlyContinue }
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 300
    Get-ChildItem "$env:USERPROFILE\.psmux" -Filter "${NS}__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    if ($null -ne $savedClip) {
        $back = $false
        for ($i = 0; $i -lt 50 -and -not $back; $i++) {
            try { Set-Clipboard -Value $savedClip -EA Stop } catch {}
            $back = ((try { Get-Clipboard -Raw -EA Stop } catch { $null }) -eq $savedClip)
            if (-not $back) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $back) { Write-Host "  [WARN] the clipboard could not be restored" -ForegroundColor Yellow }
    }
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass  Failed: $script:Fail  Skipped: $script:Skip"
exit $script:Fail
