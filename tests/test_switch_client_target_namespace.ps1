# `switch-client` target resolution: three defects found while reviewing the
# #640 follow-up, all in the same command.
#
# 1. A KEYBINDING of `switch-client -t <session>` was executed as session
#    cycling. The attached client classified any switch-client without -T as
#    navigation, so the named destination never reached the server. The CLI
#    route was already correct, which is what pinned the fault to the client.
#
#      [route 1] CLI: psmux switch-client -t p2   -> session now: p2
#      [route 2] keybinding: prefix + g           -> session now: p3   WRONG
#
# 2. `switch-client -t <session>` failed outright under a -L socket namespace.
#    The server resolved the target against the UNSCOPED session listing,
#    which deliberately skips every namespaced base, so the list came back
#    empty and a session sitting in `list-sessions` could not be switched to:
#
#      psmux -L ns switch-client -t p2  ->  can't find session: p2   rc=1
#
# 3. `switch-client -n` / `-p` cycled ACROSS namespaces. The enumeration of
#    <base>.port files filtered only warm sessions, so cycling off the last
#    session of nsA wrapped into nsB's first session and the client attached
#    to another server's session:
#
#      nsA after: a1 ... | a2 ...
#      nsB after: b1 ... (attached)     <- the client left its own namespace
#
#    tmux treats a -L socket as a separate server; psmux applied that rule to
#    the choosers in ed52715 but not to the session cycle.
#
# Physical keystrokes are required for parts A and C: `send-keys` does not go
# through the attached client's key dispatch, which is where defects 1 and 3
# live.
#
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"

$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0
$script:TestsFailed = 0
$scratch = if ($env:TEMP) { $env:TEMP } else { "." }
$inj = Join-Path $scratch "psmux_swtarget_inj.exe"
$started = @()

function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

function Ensure-Injector {
    if (Test-Path $inj) { return $true }
    $src = Join-Path (Split-Path $PSScriptRoot -Parent) "tests\injector.cs"
    if (-not (Test-Path $src)) { $src = Join-Path $PSScriptRoot "injector.cs" }
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }
    if (-not (Test-Path $csc)) { return $false }
    & $csc /nologo /optimize /out:$inj $src 2>&1 | Out-Null
    return (Test-Path $inj)
}

function Kill-Started {
    foreach ($p in $script:started) {
        try { Stop-Process -Id $p -Force -EA SilentlyContinue } catch {}
    }
    $script:started = @()
}

function Sessions-Of($ns) {
    if ($ns) { (& $PSMUX -L $ns list-sessions 2>&1 | Out-String).Trim() }
    else     { (& $PSMUX list-sessions 2>&1 | Out-String).Trim() }
}

function Attached-In($ns) {
    # The session carrying the "(attached)" marker, or "" if none.
    $lines = if ($ns) { & $PSMUX -L $ns list-sessions 2>&1 } else { & $PSMUX list-sessions 2>&1 }
    foreach ($l in $lines) {
        if ("$l" -match '^([^:]+):.*\(attached\)') { return $Matches[1] }
    }
    return ""
}

Write-Host "`nbinary:  $PSMUX"
Write-Host "dataDir: $($env:PSMUX_DATA_DIR)"

if (-not (Ensure-Injector)) {
    Write-Host "`n  [SKIP] could not compile the keystroke injector; parts A and C need it" -ForegroundColor Yellow
    exit 0
}

# ===========================================================================
# Part A: a keybinding of `switch-client -t` switches to the NAMED session
# ===========================================================================
Write-Host "`n=== Part A: a binding of switch-client -t names a destination ===" -ForegroundColor Cyan

foreach ($s in @("swt1","swt2","swt3")) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 500

$confA = Join-Path $scratch "psmux_swtarget_a.conf"
@"
set -g prefix C-a
unbind C-b
bind-key g switch-client -t swt2
"@ | Set-Content -Path $confA -Encoding UTF8
$env:PSMUX_CONFIG_FILE = $confA

& $PSMUX new-session -d -s swt2 2>&1 | Out-Null
& $PSMUX new-session -d -s swt3 2>&1 | Out-Null
Start-Sleep -Seconds 2
$procA = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","swt1" -PassThru
$started += $procA.Id
Start-Sleep -Seconds 5

# swt1 is attached. Sorted order is swt1, swt2, swt3, so "previous session"
# wraps to swt3 while the correct answer is swt2: the two outcomes differ.
$startA = Attached-In $null
if ($startA -eq "swt1") { Write-Pass "the client starts attached to swt1" }
else { Write-Fail "expected to start on swt1, got '$startA'"; Write-Info (Sessions-Of $null) }

& $inj $procA.Id "^a{SLEEP:400}g" | Out-Null
Start-Sleep -Seconds 4
$afterA = Attached-In $null
Write-Info "after prefix+g the attached session is '$afterA'"
if ($afterA -eq "swt2") {
    Write-Pass "prefix+g switched to the named target swt2"
} elseif ($afterA -eq "swt3") {
    Write-Fail "prefix+g cycled to the previous session swt3 instead of the named target swt2"
} else {
    Write-Fail "prefix+g left the client on '$afterA', expected swt2"
}

# The CLI route must agree, and did even before the fix.
& $PSMUX switch-client -t swt3 2>&1 | Out-Null
Start-Sleep -Seconds 3
if ((Attached-In $null) -eq "swt3") { Write-Pass "the CLI route switches to the named target too" }
else { Write-Fail "CLI switch-client -t swt3 did not take effect" }

Kill-Started
foreach ($s in @("swt1","swt2","swt3")) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 500

# ===========================================================================
# Part B: `switch-client -t` resolves inside a -L socket namespace
# ===========================================================================
Write-Host "`n=== Part B: switch-client -t resolves under a -L namespace ===" -ForegroundColor Cyan

$NS = "swtns"
foreach ($s in @("q1","q2")) { & $PSMUX -L $NS kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 500

$env:PSMUX_CONFIG_FILE = $null
& $PSMUX -L $NS new-session -d -s q1 2>&1 | Out-Null
& $PSMUX -L $NS new-session -d -s q2 2>&1 | Out-Null
Start-Sleep -Seconds 2

$lsB = Sessions-Of $NS
Write-Info "namespace $NS holds: $($lsB -replace "`r`n", ' | ')"
if ($lsB -match "q2") { Write-Pass "q2 is listed in namespace $NS" }
else { Write-Fail "q2 is missing from list-sessions in $NS" }

# Attach a client so there is something to switch.
$procB = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"attach","-t","q1" -PassThru
$started += $procB.Id
Start-Sleep -Seconds 5

$outB = (& $PSMUX -L $NS switch-client -t q2 2>&1 | Out-String).Trim()
$rcB = $LASTEXITCODE
Write-Info "switch-client -t q2 said '$outB' rc=$rcB"
if ($rcB -eq 0 -and $outB -notmatch "can't find session") {
    Write-Pass "switch-client -t q2 was accepted inside the namespace"
} else {
    Write-Fail "switch-client -t q2 failed in namespace ${NS}: '$outB' rc=$rcB"
}
Start-Sleep -Seconds 3
if ((Attached-In $NS) -eq "q2") { Write-Pass "the client landed on q2" }
else { Write-Fail "the client did not land on q2 (attached: '$(Attached-In $NS)')" }

# A genuinely absent target must still be an error, with the bare name.
$outMissing = (& $PSMUX -L $NS switch-client -t nosuchsess 2>&1 | Out-String).Trim()
$rcMissing = $LASTEXITCODE
if ($rcMissing -ne 0 -and $outMissing -match "can't find session: nosuchsess") {
    Write-Pass "an absent target still errors, naming the session the user typed"
} else {
    Write-Fail "absent target gave '$outMissing' rc=$rcMissing"
}

Kill-Started
foreach ($s in @("q1","q2")) { & $PSMUX -L $NS kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 500

# ===========================================================================
# Part C: the session cycle never leaves its own -L namespace
# ===========================================================================
Write-Host "`n=== Part C: switch-client -n stays inside the namespace ===" -ForegroundColor Cyan

foreach ($s in @("a1","a2")) { & $PSMUX -L swtA kill-session -t $s 2>&1 | Out-Null }
foreach ($s in @("b1","b2","b3")) { & $PSMUX -L swtB kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 500

$confC = Join-Path $scratch "psmux_swtarget_c.conf"
@"
set -g prefix C-a
unbind C-b
bind-key n switch-client -n
"@ | Set-Content -Path $confC -Encoding UTF8
$env:PSMUX_CONFIG_FILE = $confC

# swtA sorts before swtB, so cycling forward off swtA's LAST session is the
# case that used to escape: it must wrap to a1, not fall into swtB's b1.
& $PSMUX -L swtA new-session -d -s a1 2>&1 | Out-Null
foreach ($s in @("b1","b2","b3")) { & $PSMUX -L swtB new-session -d -s $s 2>&1 | Out-Null }
Start-Sleep -Seconds 3

$procC = Start-Process -FilePath $PSMUX -ArgumentList "-L","swtA","new-session","-s","a2" -PassThru
$started += $procC.Id
Start-Sleep -Seconds 5

Write-Info "swtA: $((Sessions-Of 'swtA') -replace "`r`n", ' | ')"
Write-Info "swtB: $((Sessions-Of 'swtB') -replace "`r`n", ' | ')"

if ((Attached-In "swtA") -eq "a2") { Write-Pass "the client starts on swtA's last session a2" }
else { Write-Fail "expected to start on a2, attached is '$(Attached-In 'swtA')'" }

& $inj $procC.Id "^a{SLEEP:400}n" | Out-Null
Start-Sleep -Seconds 4

$inA = Attached-In "swtA"
$inB = Attached-In "swtB"
Write-Info "after prefix+n, swtA attached='$inA' swtB attached='$inB'"

if ($inB -ne "") {
    Write-Fail "the cycle escaped into namespace swtB and attached to '$inB'"
} else {
    Write-Pass "the cycle did not attach to any session in swtB"
}
if ($inA -eq "a1") {
    Write-Pass "the cycle wrapped inside swtA from a2 to a1"
} else {
    Write-Fail "expected to wrap to a1 inside swtA, attached is '$inA'"
}

# ===========================================================================
Kill-Started
foreach ($s in @("a1","a2")) { & $PSMUX -L swtA kill-session -t $s 2>&1 | Out-Null }
foreach ($s in @("b1","b2","b3")) { & $PSMUX -L swtB kill-session -t $s 2>&1 | Out-Null }
Remove-Item $confA,$confC -Force -EA SilentlyContinue
$env:PSMUX_CONFIG_FILE = $null

Write-Host "`n=== switch-client target and namespace results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" -ForegroundColor Cyan
exit $script:TestsFailed
