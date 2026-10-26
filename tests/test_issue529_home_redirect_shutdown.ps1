# Issue #529: "Server started under a redirected USERPROFILE/HOME silently exits ~7s after startup"
#
# CLAIM UNDER TEST
#   Pointing USERPROFILE and HOME at a fresh throwaway directory makes a detached psmux
#   server terminate on its own roughly 7 seconds after startup, even though its pane runs a
#   long lived process and exit-empty is off. The same command against the real home is said
#   to survive indefinitely.
#
# This suite reproduces the reporter's four variants verbatim and then closes every
# environmental gap between a clean room and the reporter's machine (which their own issue
# #530 documents as carrying ~36 live psmux servers and 6,534 registry files):
#
#   Part 1  the four reported variants, plus a non-psmux decoy process watched over the same
#           window. The decoy is the discriminator: if a redirected-HOME psmux server dies
#           while a plain `ping -t` started at the same instant survives, the killer is psmux.
#           If both die, the killer is environmental and outside psmux.
#   Part 2  is the redirect actually honoured end to end, or does part of the registry still
#           land in the real home? A split would let one subsystem consider the server
#           untracked while another owns it.
#   Part 3  the same repro under a loaded environment with several aged real-home servers
#           running their periodic timers concurrently.
#   Part 4  the repro executed from INSIDE a psmux pane, which is how the reporter's
#           multi-agent workload invokes everything, and a check that an independent nested
#           server is not coupled to its host session's lifetime.
#   Part 5  mandatory layers: the sandbox server answers over raw TCP, and a real visible
#           Win32 TUI session stays functional.
#
# Every death is recorded with its Win32 exit code, which separates a graceful self exit (0)
# from an external TerminateProcess.
#
# tmux parity: tmux's find_home() feeds only cwd, config lookup and prompt history. Nothing
# in tmux ties server lifetime to HOME, so a redirected HOME must not shorten server life.

param(
    [int]$WatchSeconds = 20,
    [int]$LoadedServers = 4,
    [int]$AgeSeconds = 12
)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

# --- Win32 GetExitCodeProcess: tells a self exit from an external kill ---
if (-not ("Issue529Native" -as [type])) {
    Add-Type -Namespace "" -Name Issue529Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(IntPtr h);
'@
}
$PROC_ACCESS = 0x1000 -bor 0x00100000   # PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE

function New-SandboxHome {
    $dir = Join-Path $env:TEMP ("psmux529_" + [Guid]::NewGuid().ToString("N").Substring(0, 10))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# The session .pid anchor holds "<pid>:<creation_filetime>"
function Read-PidAnchor([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { $raw = (Get-Content $Path -Raw -EA Stop).Trim() } catch { return $null }
    if ($raw -match '^(\d+)') { return [int]$Matches[1] }
    return $null
}

function Wait-PidAnchor {
    param([string]$Path, [int]$TimeoutMs = 20000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $p = Read-PidAnchor $Path
        if ($p) { return $p }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Invoke-InHome {
    param([string]$HomeDir, [string[]]$PsmuxArgs)
    $o1 = $env:USERPROFILE; $o2 = $env:HOME
    $env:USERPROFILE = $HomeDir; $env:HOME = $HomeDir
    try { return (& $PSMUX @PsmuxArgs 2>&1 | Out-String) }
    finally { $env:USERPROFILE = $o1; $env:HOME = $o2 }
}

function Clear-StrayPings {
    Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -match '-t 127\.0\.0\.1' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } catch {} }
}

Write-Host "`n=== Issue #529: redirected USERPROFILE/HOME server shutdown ===" -ForegroundColor Cyan
Write-Host "psmux  : $PSMUX" -ForegroundColor DarkGray
Write-Host "version: $((& $PSMUX -V 2>&1 | Select-Object -Last 1))" -ForegroundColor DarkGray

# ==========================================================================================
# PART 1: the four reported variants, plus a non-psmux decoy control
# ==========================================================================================
Write-Host "`n########## PART 1: the four reported variants ##########" -ForegroundColor Magenta

function Invoke-Variant {
    param(
        [string]$Label,
        [string]$HomeDir,
        [switch]$NoWarm,
        [switch]$ClientPolling,
        [int]$Watch = 20
    )

    $ns = "i529" + [Guid]::NewGuid().ToString("N").Substring(0, 6)
    $origUP = $env:USERPROFILE; $origHM = $env:HOME; $origNW = $env:PSMUX_NO_WARM
    $env:USERPROFILE = $HomeDir; $env:HOME = $HomeDir
    if ($NoWarm) { $env:PSMUX_NO_WARM = "1" } else { $env:PSMUX_NO_WARM = $null }

    $result = [ordered]@{ Label = $Label; ServerPid = $null; Died = $false; DiedAtMs = $null; ExitCode = $null; DecoyDied = $false }
    $decoy = $null

    try {
        Write-Host "`n--- $Label ---" -ForegroundColor Yellow
        Write-Info "HOME=$HomeDir  ns=$ns  NoWarm=$([bool]$NoWarm)  ClientPolling=$([bool]$ClientPolling)"

        # Decoy: a plain long lived process started at the same moment, watched identically.
        $decoy = Start-Process -FilePath "ping.exe" -ArgumentList "-t", "127.0.0.1" -WindowStyle Hidden -PassThru

        & $PSMUX -f NUL -L $ns new-session -d -s probe 'ping -t 127.0.0.1' 2>&1 | Out-Null

        $srvPid = Wait-PidAnchor (Join-Path $HomeDir ".psmux\${ns}__probe.pid")
        if (-not $srvPid) {
            Write-Fail "$Label : no .pid anchor within 20s (server never started)"
            return $result
        }
        $result.ServerPid = $srvPid
        Write-Info "server pid=$srvPid, decoy pid=$($decoy.Id)"

        # exit-empty off, exactly as the report specifies (needs a client invocation)
        if ($ClientPolling) { & $PSMUX -f NUL -L $ns set-option -g exit-empty off 2>&1 | Out-Null }

        $handle = [Issue529Native]::OpenProcess($PROC_ACCESS, $false, [uint32]$srvPid)
        $watchSw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastPoll = 0
        while ($watchSw.ElapsedMilliseconds -lt ($Watch * 1000)) {
            if (-not (Get-Process -Id $srvPid -EA SilentlyContinue)) {
                $result.Died = $true
                $result.DiedAtMs = $watchSw.ElapsedMilliseconds
                if ($handle -ne [IntPtr]::Zero) {
                    $c = 0
                    if ([Issue529Native]::GetExitCodeProcess($handle, [ref]$c)) { $result.ExitCode = $c }
                }
                $result.DecoyDied = -not (Get-Process -Id $decoy.Id -EA SilentlyContinue)
                break
            }
            if ($ClientPolling -and ($watchSw.ElapsedMilliseconds - $lastPoll) -ge 1000) {
                $lastPoll = $watchSw.ElapsedMilliseconds
                & $PSMUX -f NUL -L $ns has-session -t probe 2>&1 | Out-Null
            }
            Start-Sleep -Milliseconds 200
        }
        if ($handle -ne [IntPtr]::Zero) { [void][Issue529Native]::CloseHandle($handle) }

        if ($result.Died) {
            $ec = if ($null -ne $result.ExitCode) { "0x{0:X} ({0})" -f $result.ExitCode } else { "unknown" }
            $decoyNote = if ($result.DecoyDied) { "decoy ALSO died (environmental killer)" } else { "decoy survived (psmux specific)" }
            Write-Fail ("$Label : server died at t+{0:N1}s, exit code $ec, $decoyNote" -f ($result.DiedAtMs / 1000.0))
        }
        else {
            Write-Pass "$Label : server survived ${Watch}s"
            # a survivor must also still be a working server, not a husk
            $sess = (& $PSMUX -f NUL -L $ns display-message -t probe -p '#{session_name}' 2>&1 | Out-String).Trim()
            if ($sess -match "probe") { Write-Pass "$Label : session still answers commands after ${Watch}s" }
            else { Write-Fail "$Label : session stopped answering, got '$sess'" }
        }
    }
    finally {
        & $PSMUX -f NUL -L $ns kill-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds 300
        if ($result.ServerPid) { try { Stop-Process -Id $result.ServerPid -Force -EA SilentlyContinue } catch {} }
        if ($decoy) { try { Stop-Process -Id $decoy.Id -Force -EA SilentlyContinue } catch {} }
        $env:USERPROFILE = $origUP; $env:HOME = $origHM; $env:PSMUX_NO_WARM = $origNW
    }
    return $result
}

$sandboxA = New-SandboxHome
$sandboxB = New-SandboxHome
$sandboxC = New-SandboxHome
$results = @()
$results += Invoke-Variant -Label "A: redirected HOME + client polling"  -HomeDir $sandboxA -ClientPolling -Watch $WatchSeconds
$results += Invoke-Variant -Label "B: redirected HOME + PSMUX_NO_WARM=1" -HomeDir $sandboxB -NoWarm -ClientPolling -Watch $WatchSeconds
$results += Invoke-Variant -Label "C: redirected HOME + no client polls" -HomeDir $sandboxC -Watch $WatchSeconds
$results += Invoke-Variant -Label "D: real HOME (control)"               -HomeDir $env:USERPROFILE -ClientPolling -Watch $WatchSeconds
Remove-Item $sandboxA, $sandboxB, $sandboxC -Recurse -Force -EA SilentlyContinue
Clear-StrayPings

# ==========================================================================================
# PART 2: is the redirect honoured end to end (no registry split)?
# ==========================================================================================
Write-Host "`n########## PART 2: registry split check ##########" -ForegroundColor Magenta
$realPsmuxDir = Join-Path $env:USERPROFILE ".psmux"
$snapBefore = @{}
if (Test-Path $realPsmuxDir) {
    Get-ChildItem $realPsmuxDir -Recurse -File -EA SilentlyContinue | ForEach-Object { $snapBefore[$_.FullName] = $true }
}
$sandboxS = New-SandboxHome
$nsS = "S529" + [Guid]::NewGuid().ToString("N").Substring(0, 6)
Invoke-InHome -HomeDir $sandboxS -PsmuxArgs @("-f", "NUL", "-L", $nsS, "new-session", "-d", "-s", "probe", "ping -t 127.0.0.1") | Out-Null
Start-Sleep -Seconds 3

$sandboxFiles = @(Get-ChildItem (Join-Path $sandboxS ".psmux") -Recurse -File -EA SilentlyContinue)
Write-Info "files created under the sandbox home: $($sandboxFiles.Count)"
$newReal = @()
if (Test-Path $realPsmuxDir) {
    $newReal = @(Get-ChildItem $realPsmuxDir -Recurse -File -EA SilentlyContinue | Where-Object { -not $snapBefore.ContainsKey($_.FullName) -and $_.Name -like "*$nsS*" })
}
if ($newReal.Count -gt 0) { Write-Fail "REGISTRY SPLIT: $($newReal.Count) file(s) for namespace $nsS landed under the REAL home despite the redirect" }
else { Write-Pass "no namespace files leaked into the real home: the redirect is honoured" }

foreach ($ext in @(".port", ".key", ".pid", ".sid")) {
    if (@($sandboxFiles | Where-Object { $_.Extension -eq $ext }).Count -gt 0) { Write-Pass "sandbox home holds the $ext registry file" }
    else { Write-Fail "sandbox home is MISSING the $ext registry file" }
}
if (@($sandboxFiles | Where-Object { $_.FullName -match "\\servers\\" }).Count -gt 0) { Write-Pass "sandbox home holds its own servers/ ownership markers" }
else { Write-Fail "sandbox home has no servers/ ownership marker" }

# ==========================================================================================
# PART 5a (uses the part 2 server): raw TCP path
# ==========================================================================================
Write-Host "`n########## PART 5a: raw TCP path against the sandbox server ##########" -ForegroundColor Magenta
$portFile = Join-Path $sandboxS ".psmux\${nsS}__probe.port"
$keyFile = Join-Path $sandboxS ".psmux\${nsS}__probe.key"
$srvPidS = Read-PidAnchor (Join-Path $sandboxS ".psmux\${nsS}__probe.pid")
if ((Test-Path $portFile) -and (Test-Path $keyFile)) {
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content $keyFile -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $stream = $tcp.GetStream(); $stream.ReadTimeout = 10000
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $key`n"); $writer.Flush()
        $auth = $reader.ReadLine()
        if ($auth -eq "OK") { Write-Pass "TCP: AUTH accepted by the redirected-HOME server on port $port" }
        else { Write-Fail "TCP: AUTH returned '$auth'" }
        $writer.Write("list-sessions`n"); $writer.Flush()
        $resp = $reader.ReadLine()
        if ($resp -match "probe") { Write-Pass "TCP: list-sessions returned the probe session" }
        else { Write-Fail "TCP: list-sessions returned '$resp'" }
        $tcp.Close()
    }
    catch { Write-Fail "TCP: could not talk to the sandbox server: $_" }

    Start-Sleep -Seconds 8
    if ($srvPidS -and (Get-Process -Id $srvPidS -EA SilentlyContinue)) { Write-Pass "sandbox server still alive 8s after the TCP exchange" }
    else { Write-Fail "sandbox server died around the TCP exchange" }
}
else {
    Write-Fail "sandbox server produced no .port/.key to test the TCP path"
}
Invoke-InHome -HomeDir $sandboxS -PsmuxArgs @("-f", "NUL", "-L", $nsS, "kill-server") | Out-Null
Start-Sleep -Milliseconds 400
if ($srvPidS) { try { Stop-Process -Id $srvPidS -Force -EA SilentlyContinue } catch {} }
Remove-Item $sandboxS -Recurse -Force -EA SilentlyContinue
Clear-StrayPings

# ==========================================================================================
# PART 3: loaded environment (aged real-home servers running their periodic timers)
# ==========================================================================================
Write-Host "`n########## PART 3: loaded environment ##########" -ForegroundColor Magenta
$loadSessions = @()
for ($i = 0; $i -lt $LoadedServers; $i++) {
    $n = "i529load$i"
    & $PSMUX kill-session -t $n 2>&1 | Out-Null
    & $PSMUX new-session -d -s $n 2>&1 | Out-Null
    $loadSessions += $n
}
Start-Sleep -Seconds 2
Write-Info "live psmux processes: $(@(Get-Process -Name psmux -EA SilentlyContinue).Count); aging them ${AgeSeconds}s"
Start-Sleep -Seconds $AgeSeconds

$sandboxL = New-SandboxHome
$nsL = "L529" + [Guid]::NewGuid().ToString("N").Substring(0, 6)
Invoke-InHome -HomeDir $sandboxL -PsmuxArgs @("-f", "NUL", "-L", $nsL, "new-session", "-d", "-s", "probe", "ping -t 127.0.0.1") | Out-Null
$srvPidL = Wait-PidAnchor (Join-Path $sandboxL ".psmux\${nsL}__probe.pid")
if (-not $srvPidL) {
    Write-Fail "loaded environment: sandbox server never started"
}
else {
    Write-Info "sandbox server pid=$srvPidL under $LoadedServers aged real-home servers"
    $died = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt ($WatchSeconds * 1000)) {
        if (-not (Get-Process -Id $srvPidL -EA SilentlyContinue)) { $died = $sw.ElapsedMilliseconds; break }
        Start-Sleep -Milliseconds 200
    }
    if ($died) { Write-Fail ("loaded environment: sandbox server died at t+{0:N1}s" -f ($died / 1000.0)) }
    else { Write-Pass "loaded environment: sandbox server survived ${WatchSeconds}s" }
    Invoke-InHome -HomeDir $sandboxL -PsmuxArgs @("-f", "NUL", "-L", $nsL, "kill-server") | Out-Null
    Start-Sleep -Milliseconds 300
    try { Stop-Process -Id $srvPidL -Force -EA SilentlyContinue } catch {}
}
foreach ($n in $loadSessions) { & $PSMUX kill-session -t $n 2>&1 | Out-Null }
Remove-Item $sandboxL -Recurse -Force -EA SilentlyContinue
Clear-StrayPings

# ==========================================================================================
# PART 4: repro executed from INSIDE a psmux pane (the reporter's harness shape)
# ==========================================================================================
Write-Host "`n########## PART 4: nested invocation from inside a pane ##########" -ForegroundColor Magenta
$hostSession = "i529host"
& $PSMUX kill-session -t $hostSession 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $hostSession 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t $hostSession 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "could not create the host session for the nested test"
}
else {
    $sandboxN = New-SandboxHome
    $nsN = "N529" + [Guid]::NewGuid().ToString("N").Substring(0, 6)
    & $PSMUX send-keys -t $hostSession "`$env:USERPROFILE='$sandboxN'; `$env:HOME='$sandboxN'" Enter 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $PSMUX send-keys -t $hostSession "& '$PSMUX' -f NUL -L $nsN new-session -d -s probe 'ping -t 127.0.0.1'" Enter 2>&1 | Out-Null

    $srvPidN = Wait-PidAnchor (Join-Path $sandboxN ".psmux\${nsN}__probe.pid") -TimeoutMs 30000
    if (-not $srvPidN) {
        Write-Fail "nested repro produced no .pid anchor"
    }
    else {
        Write-Info "nested sandbox server pid=$srvPidN"
        $died = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt ($WatchSeconds * 1000)) {
            if (-not (Get-Process -Id $srvPidN -EA SilentlyContinue)) { $died = $sw.ElapsedMilliseconds; break }
            Start-Sleep -Milliseconds 200
        }
        if ($died) { Write-Fail ("nested repro: server died at t+{0:N1}s" -f ($died / 1000.0)) }
        else { Write-Pass "nested repro: server survived ${WatchSeconds}s inside a pane" }

        # An independent server must not be coupled to the host session's lifetime.
        $sess = (Invoke-InHome -HomeDir $sandboxN -PsmuxArgs @("-f", "NUL", "-L", $nsN, "display-message", "-t", "probe", "-p", '#{session_name}')).Trim()
        if ($sess -match "probe") { Write-Pass "nested server answers commands before the host kill" }
        else { Write-Fail "nested server did not answer before the host kill: '$sess'" }

        if (Get-Process -Id $srvPidN -EA SilentlyContinue) {
            & $PSMUX kill-session -t $hostSession 2>&1 | Out-Null
            $coupled = $null
            $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw2.ElapsedMilliseconds -lt 10000) {
                if (-not (Get-Process -Id $srvPidN -EA SilentlyContinue)) { $coupled = $sw2.ElapsedMilliseconds; break }
                Start-Sleep -Milliseconds 150
            }
            if ($coupled) { Write-Fail ("COUPLED: independent nested server died {0:N2}s after the host session was killed" -f ($coupled / 1000.0)) }
            else { Write-Pass "independent nested server outlived the host session kill" }
        }
        Invoke-InHome -HomeDir $sandboxN -PsmuxArgs @("-f", "NUL", "-L", $nsN, "kill-server") | Out-Null
        Start-Sleep -Milliseconds 300
        try { Stop-Process -Id $srvPidN -Force -EA SilentlyContinue } catch {}
    }
    Remove-Item $sandboxN -Recurse -Force -EA SilentlyContinue
}
& $PSMUX kill-session -t $hostSession 2>&1 | Out-Null
Clear-StrayPings

# ==========================================================================================
# PART 5b: Win32 TUI visual verification
# ==========================================================================================
Write-Host "`n########## PART 5b: Win32 TUI visual verification ##########" -ForegroundColor Magenta
$SESSION_TUI = "i529tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session", "-s", $SESSION_TUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: visible session is up" } else { Write-Fail "TUI: session did not come up" }

& $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1 | Out-String).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window produced 2 panes" } else { Write-Fail "TUI: expected 2 panes, got '$panes'" }

Start-Sleep -Seconds 10
& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "TUI: session still alive past the reported ~7s shutdown window" }
else { Write-Fail "TUI: session vanished within the reported shutdown window" }

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Clear-StrayPings

# ==========================================================================================
Write-Host "`n=== Part 1 summary ===" -ForegroundColor Cyan
$results | ForEach-Object {
    $verdict = if ($_.Died) { "DIED at t+{0:N1}s (exit 0x{1:X})" -f ($_.DiedAtMs / 1000.0), $_.ExitCode } else { "ALIVE through ${WatchSeconds}s" }
    Write-Host ("  {0,-40} {1}" -f $_.Label, $verdict)
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
