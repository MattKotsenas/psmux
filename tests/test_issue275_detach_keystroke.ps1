# Issue #275: keystroke regression guard for prefix+d (detach-client)
# Uses WriteConsoleInput injector to drive REAL keystrokes into the attached
# psmux client and verify:
#   1. prefix+d still detaches (default keybinding preserved)
#   2. prefix+:detach-client<Enter> from the command prompt also detaches
# Both must complete WITHOUT killing the server (panes/shells preserved).

$ErrorActionPreference = "Continue"
$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe").Path
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$script:Passed = 0
$script:Failed = 0

function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }

# Compile the injector once.
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }
    & $csc /nologo /optimize /out:$injectorExe tests\injector.cs 2>&1 | Out-Null
}
if (-not (Test-Path $injectorExe)) {
    Write-Host "[SKIP] no csc.exe; cannot run keystroke test" -ForegroundColor Yellow
    exit 0
}

function Cleanup {
    param([string]$Name)
    & $PSMUX kill-session -t $Name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$Name.*" -Force -EA SilentlyContinue
}

function Wait-Session {
    param([string]$Name, [int]$Timeout = 12000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Timeout) {
        if (Test-Path "$psmuxDir\$Name.port") { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Run-Scenario {
    param(
        [string]$Label,
        [string]$Session,
        [string]$KeySeq
    )
    Write-Host "`n[$Label] $Session" -ForegroundColor Yellow
    Cleanup $Session

    # Launch attached psmux in a real visible window
    $proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$Session -PassThru
    $ok = Wait-Session $Session
    if (-not $ok) { Write-Fail "session never started"; return }
    Start-Sleep -Seconds 4

    # Verify a client is registered (sanity check)
    $pre = (& $PSMUX list-clients -t $Session 2>&1 | Out-String).Trim()
    if ($pre -eq "" -or $pre -match "no client") {
        Write-Fail "no client registered before keystrokes"
        try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
        return
    }

    # Inject the keystrokes that should detach the client
    & $injectorExe $proc.Id $KeySeq | Out-Null

    # Poll for client process exit (proves detach happened)
    $exited = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 12000) {
        Start-Sleep -Milliseconds 200
        $alive = Get-Process -Id $proc.Id -EA SilentlyContinue
        if ($null -eq $alive -or $alive.HasExited) { $exited = $true; break }
    }
    if ($exited) {
        Write-Pass ("client exited via keystrokes (~{0}ms)" -f $sw.ElapsedMilliseconds)
    } else {
        Write-Fail "client did not exit after keystrokes"
        try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
        Cleanup $Session
        return
    }

    # Server must survive (the entire feature contract)
    & $PSMUX has-session -t $Session 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "server preserved after detach (panes intact)"
    } else {
        Write-Fail "server died — detach is supposed to leave it alive"
    }
    Cleanup $Session
}

Write-Host "`n=== Issue #275 keystroke regression guards ===" -ForegroundColor Cyan

# Scenario A: prefix+d (default detach binding)
# Ctrl+B then 'd' — must trigger Action::Detach
Run-Scenario -Label "K1" -Session "ks275_prefixd" -KeySeq "^b{SLEEP:300}d"

# Scenario B: prefix+:detach-client<Enter>  (command prompt path)
Run-Scenario -Label "K2" -Session "ks275_cmdprompt" -KeySeq "^b{SLEEP:300}:{SLEEP:400}detach-client{ENTER}"

# Scenario C: prefix+:detach<Enter> (alias)
Run-Scenario -Label "K3" -Session "ks275_alias" -KeySeq "^b{SLEEP:300}:{SLEEP:400}detach{ENTER}"

# Scenario D: prefix+:detach-client -a<Enter>
# -a from inside an attached client detaches OTHER clients only — current client stays.
Write-Host "`n[K4] prefix+:detach-client -a<Enter> (current client should NOT exit)" -ForegroundColor Yellow
$session = "ks275_dashA"
Cleanup $session
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$session -PassThru
$ok = Wait-Session $session
if ($ok) {
    Start-Sleep -Seconds 4
    & $injectorExe $proc.Id "^b{SLEEP:300}:{SLEEP:400}detach-client -a{ENTER}" | Out-Null
    Start-Sleep -Seconds 3
    $alive = Get-Process -Id $proc.Id -EA SilentlyContinue
    if ($alive -and -not $alive.HasExited) {
        Write-Pass "current client correctly STAYS attached when running 'detach-client -a'"
    } else {
        Write-Fail "current client wrongly detached on 'detach-client -a'"
    }
    & $PSMUX detach-client -s $session 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    Cleanup $session
} else {
    Write-Fail "K4 session never started"
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Passed)" -ForegroundColor Green
$failColor = if ($script:Failed -gt 0) { "Red" } else { "Green" }
Write-Host "  Failed: $($script:Failed)" -ForegroundColor $failColor
exit $script:Failed
