# Shared helpers for the psmux docker-exec (non-SSH) interactive tests
# (dot-source this file).
#
# Unlike test_docker_ssh_lib.ps1 (which reaches the container over sshd),
# everything here goes through `docker exec` ONLY. The interactive attach
# path is a ConPTY host harness (tests\docker_conpty_attach_host.cs) that is
# compiled INSIDE the container with the .NET Framework csc and runs INSIDE
# the container: it hosts `psmux attach` under a real container-side
# pseudoconsole (conhost build 20348), which is exactly how `docker exec -it`
# hosts an interactive process. A file-based control protocol feeds it raw
# keystroke / mouse-report bytes and the raw VT output stream is captured to
# a file, so tests can assert on the exact bytes a user's terminal would get.
#
# HARD-WON GOTCHA captured in the harness itself: a ConPTY child spawned by a
# process whose std handles are docker-exec pipes inherits those (invalid)
# handle VALUES - interactive children read instant stdin EOF and their
# stdout writes vanish. The harness NULLs its std handles before
# CreateProcess (see docker_conpty_attach_host.cs).
#
# KNOWN ENV ISSUE (2026-07): pwsh 7.5 crashes with 0xc0000005 when spawned
# under a ConPTY inside this hyperv container, so panes must use Windows
# PowerShell 5.1 or cmd (same note as the SSH lib).

$script:ContainerName = "psmux-dev"
$script:PaneShell     = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$script:CPs51         = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$script:CCsc          = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$script:HarnessDir    = "C:\psmux_test"
$script:DockerExe     = $null

# Docker Desktop's Windows-engine proxy has been seen returning 500s on this
# class of host; a manually started dockerd on a private npipe is a valid
# fallback. Probe the candidates and pick whichever can see the container.
function Resolve-DockerEnv {
    $cmd = Get-Command docker -EA SilentlyContinue
    $script:DockerExe = if ($cmd) { $cmd.Source } else { "C:\Program Files\Docker\Docker\resources\bin\docker.exe" }
    # An absent docker environment is a missing PREREQUISITE, not a psmux
    # failure: skip the suite (exit 0) so unattended sweeps count only real
    # defects. Mid-test docker errors below still throw/fail as before.
    if (-not (Test-Path $script:DockerExe)) {
        Write-Host "[SKIP] docker CLI not found - docker suites need docker\Run-PsmuxDev.ps1 environment" -ForegroundColor Yellow
        exit 0
    }
    $candidates = @(
        $env:DOCKER_HOST,
        "npipe:////./pipe/docker_engine",
        "npipe:////./pipe/dockerDesktopWindowsEngine",
        "npipe:////./pipe/test_dockerd_manual"
    ) | Where-Object { $_ }
    foreach ($h in $candidates) {
        $env:DOCKER_HOST = $h
        $names = & $script:DockerExe ps --format "{{.Names}}" 2>$null
        if ($LASTEXITCODE -eq 0 -and ($names -contains $script:ContainerName)) {
            Write-Host "  docker endpoint: $h" -ForegroundColor DarkGray
            return
        }
    }
    Write-Host "[SKIP] container '$($script:ContainerName)' not running on any docker endpoint - run docker\Run-PsmuxDev.ps1 first (and build/install psmux inside)" -ForegroundColor Yellow
    exit 0
}

# Run a cmd.exe one-liner inside the container. Exit code in $script:CExecExit.
function Invoke-CExec {
    param([string]$Command)
    $out = & $script:DockerExe exec -i $script:ContainerName cmd /c $Command 2>&1 | Out-String
    $script:CExecExit = $LASTEXITCODE
    return $out
}

# Run a Windows PowerShell 5.1 command inside the container (reliable there,
# unlike pwsh 7 - see header). Single-quote remote paths inside $Command.
function Invoke-CPs {
    param([string]$Command)
    $out = & $script:DockerExe exec -i $script:ContainerName $script:CPs51 -NoProfile -Command $Command 2>&1 | Out-String
    $script:CExecExit = $LASTEXITCODE
    return $out
}

# Copy a local text file into the container over docker exec stdin (docker cp
# does not work against a RUNNING hyperv container).
function Write-ContainerTextFile {
    param([string]$LocalPath, [string]$RemotePath)
    Get-Content -Raw $LocalPath | & $script:DockerExe exec -i $script:ContainerName `
        $script:CPs51 -NoProfile -Command "[IO.File]::WriteAllText('$RemotePath', [Console]::In.ReadToEnd())"
    return ($LASTEXITCODE -eq 0)
}

# Compile the attach harness inside the container (idempotent, ~3s).
function Install-AttachHarness {
    param([string]$SourcePath = (Join-Path $PSScriptRoot "docker_conpty_attach_host.cs"))
    Invoke-CExec "if not exist $($script:HarnessDir) mkdir $($script:HarnessDir)" | Out-Null
    if (-not (Write-ContainerTextFile $SourcePath "$($script:HarnessDir)\docker_conpty_attach_host.cs")) {
        throw "failed to copy harness source into container"
    }
    $out = Invoke-CExec "$($script:CCsc) /nologo /optimize /out:$($script:HarnessDir)\docker_conpty_attach_host.exe $($script:HarnessDir)\docker_conpty_attach_host.cs & echo CSC_RC=%errorlevel%"
    if ($out -notmatch "CSC_RC=0") { throw "harness compile failed inside container: $out" }
}

# ------------- interactive attach harness (docker exec, no SSH) -------------

# Start `psmux attach ...` (or any command) under a container-side ConPTY.
# Returns a handle object for the Send-/Get-/Stop- helpers below.
function Start-AttachHarness {
    param(
        [string]$Name,
        [string]$Command,          # e.g. "psmux attach -t dkrms"
        [int]$Cols = 120,
        [int]$Rows = 30,
        [hashtable]$EnvVars = @{}
    )
    $h = @{
        Name = $Name
        Ctrl = "$($script:HarnessDir)\ctrl_$Name.txt"
        Out  = "$($script:HarnessDir)\out_$Name.bin"
        Log  = "$($script:HarnessDir)\log_$Name.txt"
    }
    Invoke-CPs "[IO.File]::WriteAllText('$($h.Ctrl)',''); [IO.File]::WriteAllText('$($h.Out)',''); [IO.File]::WriteAllText('$($h.Log)','')" | Out-Null
    $args = @("exec", "-d")
    foreach ($k in $EnvVars.Keys) { $args += @("-e", "$k=$($EnvVars[$k])") }
    $args += @($script:ContainerName, "$($script:HarnessDir)\docker_conpty_attach_host.exe",
               $h.Ctrl, $h.Out, $h.Log, "$Cols", "$Rows")
    $args += ($Command -split ' ')
    & $script:DockerExe @args 2>&1 | Out-Null
    return $h
}

# Append a control line (TEXT/TYPE/CR/HEX/QUIT) - this IS the keystroke path.
function Send-HarnessCtrl {
    param($H, [string]$Line)
    $safe = $Line -replace "'", "''"
    Invoke-CPs "Add-Content -Path '$($H.Ctrl)' -Value '$safe'" | Out-Null
}

# Convenience: send raw bytes given as a hex string (mouse reports, prefix...).
function Send-HarnessHex { param($H, [string]$Hex) Send-HarnessCtrl $H "HEX $Hex" }

# Raw VT stream the "terminal" has received so far.
function Get-HarnessStream {
    param($H)
    $b64 = Invoke-CPs "`$fs=[IO.File]::Open('$($H.Out)','Open','Read','ReadWrite'); `$b=New-Object byte[] `$fs.Length; [void]`$fs.Read(`$b,0,`$b.Length); `$fs.Close(); [Convert]::ToBase64String(`$b)"
    try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($b64.Trim()))) } catch { return "" }
}

function Get-HarnessLog { param($H) return (Invoke-CExec "type $($H.Log)") }

function Wait-HarnessMatch {
    param($H, [string]$Pattern, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-HarnessStream $H) -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# First TUI frame can lag; nudge a redraw with a harmless CR like the SSH lib.
function Wait-TuiRender {
    param($H, [string]$Pattern, [int]$TimeoutSec = 40)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Wait-HarnessMatch $H $Pattern 8) { return $true }
        Send-HarnessCtrl $H "CR"
    }
    return $false
}

# True while the hosted client is still running (no CHILD_EXIT in the log).
function Test-HarnessClientAlive { param($H) return ((Get-HarnessLog $H) -notmatch "CHILD_EXIT") }

function Stop-AttachHarness {
    param($H)
    try { Send-HarnessCtrl $H "QUIT" } catch {}
}

# has-session by docker exec exit-code propagation. NEVER check this with
# `cmd /c "psmux has-session ... & echo RC=%errorlevel%"`: %errorlevel% is
# expanded at cmd parse time (before has-session runs) and always shows the
# stale pre-command value (0), so sessions look permanently alive.
function Test-ContainerSession {
    param([string]$Name)
    Invoke-CExec "psmux has-session -t $Name" | Out-Null
    return ($script:CExecExit -eq 0)
}

# Create a detached session inside the container with a pane shell that
# survives this environment, and wait for its prompt.
function New-ContainerSession {
    param([string]$Name)
    Invoke-CExec "psmux kill-session -t $Name" | Out-Null
    Start-Sleep -Milliseconds 500
    Invoke-CExec "psmux new-session -d -s $Name -- $($script:PaneShell)" | Out-Null
    Start-Sleep -Seconds 3
    Invoke-CExec "psmux set-option -g default-shell $($script:PaneShell)" | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ((Invoke-CExec "psmux capture-pane -t $Name -p") -match "PS C:") { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}
