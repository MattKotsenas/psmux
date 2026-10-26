# Session picker and tree chooser list only the client's own -L namespace.
#
# tmux parity: a -L socket is a separate server, so a client on one socket
# never sees another socket's sessions. psmux keeps every namespace in one
# registry directory as <ns>__<name>. `ls` already hides other namespaces;
# the interactive choosers (prefix+s, prefix+w) enumerated every .port file.
#
# Found by the full sweep of 2026-08-30 (run 2026-08-30_21-24-30): an external
# daemon kept `amx-6c9b6ad63d__main` alive in the default registry while
# tests/test_issue259_picker_hjkl.ps1 ran. Sorted by name it sat between
# a_issue259 and b_issue259, so every j/k/h/l step in the picker landed on the
# wrong session while g/G still reached the ends (50P/8F, 58/0 before).
#
# This suite rebuilds that exact registry: a_pns, b_pns in the default
# namespace plus a foreign `-L amxpns` session whose stored name
# (`amxpns__main`) sorts between them, then drives a real attached client
# through the picker with WriteConsoleInput and proves j lands on b_pns.

$ErrorActionPreference = "Continue"
$script:pass = 0
$script:fail = 0
function Write-Test($msg) { Write-Host "  TEST: $msg" -ForegroundColor Yellow }
function Add-Result($name, $ok, $detail) {
    if ($ok) { Write-Host "  PASS: $name $detail" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  FAIL: $name $detail" -ForegroundColor Red;   $script:fail++ }
}

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path
if (-not $PSMUX) { $cmd = Get-Command psmux -EA SilentlyContinue; if ($cmd) { $PSMUX = $cmd.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$env:PSMUX_SESSION = ""
$env:PSMUX_SESSION_NAME = $null

Write-Host "`n=== picker namespace filter (tmux -L socket isolation) ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"

# Names chosen so the foreign entry sorts between the two default ones,
# exactly where amx-6c9b6ad63d__main landed in the sweep:
#   a_pns  <  amxpns__main  <  b_pns     ('_' is 0x5F, 'm' is 0x6D, 'a' < 'b')
$S1 = "a_pns"; $S2 = "b_pns"; $S3 = "c_pns"
$NS = "amxpns"; $FOREIGN = "main"; $FOREIGN_FULL = "${NS}__${FOREIGN}"

foreach ($s in @($S1,$S2,$S3)) { & $PSMUX kill-session -t $s 2>$null | Out-Null }
& $PSMUX -L $NS kill-session -t $FOREIGN 2>$null | Out-Null
Start-Sleep -Milliseconds 500

foreach ($s in @($S1,$S2,$S3)) { & $PSMUX new-session -d -s $s 2>&1 | Out-Null; Start-Sleep -Milliseconds 300 }
& $PSMUX -L $NS new-session -d -s $FOREIGN 2>&1 | Out-Null

function Wait-Session($name, [string[]]$Pre = @(), [int]$timeoutSec = 8) {
    for ($i = 0; $i -lt ($timeoutSec * 4); $i++) {
        & $PSMUX @Pre has-session -t $name 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}
$alive = (Wait-Session $S1) -and (Wait-Session $S2) -and (Wait-Session $S3) -and (Wait-Session $FOREIGN @('-L', $NS))
Add-Result "three default sessions and one -L $NS session started" $alive ""
$foreignFile = Test-Path "$psmuxDir\$FOREIGN_FULL.port"
Add-Result "foreign session is stored as $FOREIGN_FULL.port in the shared registry" $foreignFile ""

# --- Part A: CLI listings already honour the namespace (control) ---
Write-Test "ls in the default namespace hides $FOREIGN_FULL"
$ls = (& $PSMUX ls 2>&1 | Out-String)
Add-Result "default ls lists a_pns, b_pns, c_pns" (($ls -match "a_pns") -and ($ls -match "b_pns") -and ($ls -match "c_pns")) ""
Add-Result "default ls hides the foreign namespace" (-not ($ls -match $NS)) "ls=$($ls -replace "`r?`n",' | ')"
$lsNs = (& $PSMUX -L $NS ls 2>&1 | Out-String)
Add-Result "-L $NS ls lists main only" (($lsNs -match "main") -and -not ($lsNs -match "_pns")) "ls=$($lsNs -replace "`r?`n",' | ')"

# --- Part B: live picker through a real attached client ---
$injectorSrc = Join-Path $PSScriptRoot "injector.cs"
$injectorExe = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injectorExe) -or ((Get-Item $injectorSrc).LastWriteTime -gt (Get-Item $injectorExe).LastWriteTime)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
    & $csc /nologo /optimize /out:$injectorExe $injectorSrc 2>&1 | Out-Null
}
$haveInjector = Test-Path $injectorExe
Add-Result "injector compiled" $haveInjector $injectorExe

function Query-Attached($full) {
    $pf = "$psmuxDir\$full.port"; $kf = "$psmuxDir\$full.key"
    if (-not (Test-Path $pf)) { return $null }
    try {
        $port = [int]((Get-Content $pf -Raw).Trim())
        $key  = if (Test-Path $kf) { (Get-Content $kf -Raw).Trim() } else { "" }
        $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
        $st   = $tcp.GetStream(); $st.ReadTimeout = 2000
        $w    = [System.IO.StreamWriter]::new($st); $w.AutoFlush = $true
        $r    = [System.IO.StreamReader]::new($st)
        $w.WriteLine("AUTH $key"); $null = $r.ReadLine()
        $w.WriteLine("session-info")
        $line = $r.ReadLine()
        $tcp.Close()
        return $line
    } catch { return $null }
}

# Attach to $StartFull (registry name), press prefix+s, $NavKey, Enter, then
# report which of the candidate registry names carries "(attached)".
function Drive-Picker([string[]]$AttachArgs, [string]$StartFull, [string]$NavKey, [string[]]$Candidates) {
    $proc = Start-Process -FilePath $PSMUX -ArgumentList $AttachArgs -PassThru
    Start-Sleep -Seconds 4
    $pre = Query-Attached $StartFull
    if (-not ($pre -match "\(attached\)")) {
        try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
        return @{ Ok = $false; Landed = "PRECONDITION: $StartFull not attached ($pre)" }
    }
    & $injectorExe $proc.Id "^b{SLEEP:400}s{SLEEP:600}$NavKey{SLEEP:300}{ENTER}" | Out-Null
    $landed = $null
    for ($i = 0; $i -lt 16; $i++) {
        Start-Sleep -Milliseconds 500
        $attached = @()
        foreach ($c in $Candidates) { if ((Query-Attached $c) -match "\(attached\)") { $attached += $c } }
        if ($attached.Count -eq 1 -and $attached[0] -ne $StartFull) { $landed = $attached[0]; break }
    }
    if (-not $landed) {
        $attached = @()
        foreach ($c in $Candidates) { if ((Query-Attached $c) -match "\(attached\)") { $attached += $c } }
        $landed = "none of the candidates (attached now: $($attached -join ','))"
    }
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    Start-Sleep -Seconds 1
    return @{ Ok = $true; Landed = $landed }
}

$all = @($S1, $S2, $S3, $FOREIGN_FULL)
if ($haveInjector -and $alive) {
    Write-Test "default client on a_pns: prefix+s, j, Enter must land on b_pns, not $FOREIGN_FULL"
    $r = Drive-Picker @("attach","-t",$S1) $S1 'j' $all
    Add-Result "j from a_pns lands on b_pns" ($r.Landed -eq $S2) "landed=$($r.Landed)"

    Write-Test "default client on b_pns: prefix+s, k, Enter must land on a_pns"
    $r = Drive-Picker @("attach","-t",$S2) $S2 'k' $all
    Add-Result "k from b_pns lands on a_pns" ($r.Landed -eq $S1) "landed=$($r.Landed)"

    Write-Test "default client on a_pns: G must land on c_pns (the foreign session is not the last row)"
    $r = Drive-Picker @("attach","-t",$S1) $S1 'G' $all
    Add-Result "G from a_pns lands on c_pns" ($r.Landed -eq $S3) "landed=$($r.Landed)"

    Write-Test "-L $NS client on main: the picker holds only main, so j must stay on main"
    $proc = Start-Process -FilePath $PSMUX -ArgumentList @("-L",$NS,"attach","-t",$FOREIGN) -PassThru
    Start-Sleep -Seconds 4
    $pre = Query-Attached $FOREIGN_FULL
    if ($pre -match "\(attached\)") {
        & $injectorExe $proc.Id "^b{SLEEP:400}s{SLEEP:600}j{SLEEP:300}{ENTER}" | Out-Null
        Start-Sleep -Seconds 3
        $moved = @(); foreach ($c in @($S1,$S2,$S3)) { if ((Query-Attached $c) -match "\(attached\)") { $moved += $c } }
        $still = (Query-Attached $FOREIGN_FULL) -match "\(attached\)"
        Add-Result "-L client never crosses into the default namespace" (($moved.Count -eq 0) -and $still) "default attached=$($moved -join ','), main attached=$still"
    } else {
        Add-Result "-L client precondition (main attached)" $false "info=$pre"
    }
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
} else {
    Add-Result "live picker arms" $false "skipped (injector or sessions missing)"
}

foreach ($s in @($S1,$S2,$S3)) { & $PSMUX kill-session -t $s 2>$null | Out-Null }
& $PSMUX -L $NS kill-session -t $FOREIGN 2>$null | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass / $($pass + $fail)" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
exit $fail
