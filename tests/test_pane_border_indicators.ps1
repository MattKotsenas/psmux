$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()
$psmux = (Get-Command psmux -ErrorAction Stop).Source
$runId = [guid]::NewGuid().ToString("N")
$namespace = "borderind_$($runId.Substring(0, 12))"
$session = "borderind"
$targetSession = "borderindtarget"
$artifactRoot = Join-Path $env:TEMP "psmux-border-indicators-$runId"
$hostExe = Join-Path $artifactRoot "conpty_host.exe"
$outputFile = Join-Path $artifactRoot "conpty_out.bin"
$controlFile = Join-Path $artifactRoot "conpty_ctrl.txt"
$logFile = Join-Path $artifactRoot "conpty_host.log"
$pidFile = Join-Path $artifactRoot "conpty_childpid.txt"
$rightArrow = "<E2><86><92>"
$failed = 0

function Read-BinEscaped([long]$Start = 0) {
    if (-not (Test-Path $outputFile)) { return "" }
    $stream = [System.IO.File]::Open($outputFile, "Open", "Read", "ReadWrite")
    $length = [Math]::Max(0, $stream.Length - $Start)
    [void]$stream.Seek($Start, [System.IO.SeekOrigin]::Begin)
    $buffer = New-Object byte[] $length
    [void]$stream.Read($buffer, 0, $length)
    $stream.Close()
    $builder = [System.Text.StringBuilder]::new()
    foreach ($byte in $buffer) {
        if ($byte -eq 0x1b) { [void]$builder.Append("<ESC>") }
        elseif ($byte -ge 32 -and $byte -lt 127) { [void]$builder.Append([char]$byte) }
        elseif ($byte -eq 0x0a) { [void]$builder.Append("\n") }
        else { [void]$builder.Append(("<{0:X2}>" -f $byte)) }
    }
    return $builder.ToString()
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSeconds, [string]$Failure) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw $Failure
}

function Get-DefaultSessions {
    $previousPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        return @(& $psmux list-sessions -F '#{session_name}' 2>$null) |
            Sort-Object
    } finally {
        $PSNativeCommandUseErrorActionPreference = $previousPreference
    }
}

function Assert-RejectedIndicator([string]$Label, [string[]]$CommandArguments) {
    $slug = $Label -replace "[^a-z0-9]+", "-"
    $stdoutPath = Join-Path $artifactRoot "$slug.out"
    $stderrPath = Join-Path $artifactRoot "$slug.err"
    $process = Start-Process `
        -FilePath $psmux `
        -ArgumentList $CommandArguments `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -Wait `
        -PassThru `
        -WindowStyle Hidden
    $value = (& $psmux -L $namespace show-options -t $session -g -v pane-border-indicators).Trim()
    if ($process.ExitCode -eq 0 -or $value -ne "colour") {
        $stdout = Get-Content $stdoutPath -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content $stderrPath -Raw -ErrorAction SilentlyContinue
        throw "Expected indicator rejection without mutation for $Label (exit=$($process.ExitCode), value='$value', stdout='$stdout', stderr='$stderr')"
    }
}

function Invoke-RawPsmux([string]$SessionBase, [string]$Command) {
    $port = [int](Get-Content (Join-Path $env:USERPROFILE ".psmux\$SessionBase.port"))
    $key = (Get-Content (Join-Path $env:USERPROFILE ".psmux\$SessionBase.key") -Raw).Trim()
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect("127.0.0.1", $port)
        $stream = $client.GetStream()
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $writer = [System.IO.StreamWriter]::new($stream, $utf8, 1024, $true)
        $reader = [System.IO.StreamReader]::new($stream, $utf8, $false, 1024, $true)
        $writer.NewLine = "`n"
        $writer.WriteLine("AUTH $key")
        $writer.WriteLine($Command)
        $writer.Flush()
        $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
        return $reader.ReadToEnd()
    } finally {
        $client.Dispose()
    }
}

New-Item -ItemType Directory -Path $artifactRoot | Out-Null
$defaultSessionsBefore = @(Get-DefaultSessions)
$variables = @(
    "PSMUX_CONPTY_OUT",
    "PSMUX_CONPTY_CTRL",
    "PSMUX_CONPTY_LOG",
    "PSMUX_CONPTY_PID"
)
$previous = @{}
foreach ($name in $variables) {
    $previous[$name] = if (Test-Path "Env:\$name") { (Get-Item "Env:\$name").Value } else { $null }
}
$client = $null

try {
    $compiler = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $compilerOutput = & $compiler /nologo /optimize /out:$hostExe tests\conpty_host_0xE.cs 2>&1
    if (-not (Test-Path $hostExe)) {
        throw "ConPTY host compilation failed: $($compilerOutput -join [Environment]::NewLine)"
    }

    $env:PSMUX_CONPTY_OUT = $outputFile
    $env:PSMUX_CONPTY_CTRL = $controlFile
    $env:PSMUX_CONPTY_LOG = $logFile
    $env:PSMUX_CONPTY_PID = $pidFile
    & $psmux -L $namespace kill-server 2>$null | Out-Null
    $client = Start-Process `
        -FilePath $hostExe `
        -ArgumentList "`"$psmux`" -L $namespace new-session -s $session" `
        -PassThru `
        -WindowStyle Hidden

    $portFile = Join-Path $env:USERPROFILE ".psmux\${namespace}__${session}.port"
    Wait-Until { Test-Path $portFile } 10 "Session port file was not created"
    Wait-Until { (Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 0 } 10 "Initial render was not captured"

    $default = (& $psmux -L $namespace show-options -g -v pane-border-indicators).Trim()
    if ($default -ne "colour") { throw "Default indicator was '$default', expected 'colour'" }

    $splitOffset = (Get-Item $outputFile).Length
    & $psmux -L $namespace split-window -h -t $session 2>&1 | Out-Null
    Wait-Until {
        $paneCount = (& $psmux -L $namespace display-message -t $session -p '#{window_panes}' 2>$null).Trim()
        $paneCount -eq "2" -and (Get-Item $outputFile).Length -gt $splitOffset
    } 10 "Two-pane render was not observed"

    $before = Read-BinEscaped
    if ($before -match $rightArrow) { throw "Arrow appeared in default colour mode" }

    $arrowOffset = (Get-Item $outputFile).Length
    & $psmux -L $namespace set-option -g pane-border-indicators arrows 2>&1 | Out-Null
    Wait-Until {
        (Read-BinEscaped -Start $arrowOffset) -match $rightArrow
    } 10 "Right arrow was not emitted after selecting arrows mode"

    $resetOffset = (Get-Item $outputFile).Length
    & $psmux -L $namespace set-option -gu pane-border-indicators 2>&1 | Out-Null
    Wait-Until {
        (Get-Item $outputFile).Length -gt $resetOffset
    } 10 "No repaint followed indicator reset"
    $afterReset = Read-BinEscaped -Start $resetOffset
    $resetValue = (& $psmux -L $namespace show-options -g -v pane-border-indicators).Trim()
    if ($resetValue -ne "colour" -or $afterReset -match $rightArrow) {
        throw "Reset failed (value='$resetValue', arrow=$($afterReset -match $rightArrow))"
    }

    & $psmux -L $namespace new-window -d -t $session -n focus-probe 2>&1 | Out-Null
    $sourceBase = "${namespace}__${session}"
    foreach ($rawCommand in @(
        "set-option -gt :1 pane-border-indicators arrows -junk",
        "set-option -gat :1 pane-border-indicators arrows",
        "set-option -gt :1 pane-border-indicators",
        "set-option -gqt :1 pane-border-indicators sideways"
    )) {
        $rejection = Invoke-RawPsmux $sourceBase $rawCommand
        if ($rejection -notmatch "ERROR:") {
            throw "Raw targeted rejection returned no error: $rawCommand"
        }
        $focusResponse = Invoke-RawPsmux $sourceBase 'display-message -p "#{window_index}"'
        $windowIndices = @($focusResponse -split "\r?\n" | Where-Object { $_ -match "^\d+$" })
        if ($windowIndices.Count -eq 0 -or $windowIndices[-1] -ne "0") {
            throw "Rejected targeted set leaked focus after '$rawCommand': $focusResponse"
        }
    }

    & $psmux -L $namespace new-session -d -s $targetSession 2>&1 | Out-Null
    $targetPortFile = Join-Path $env:USERPROFILE ".psmux\${namespace}__${targetSession}.port"
    Wait-Until { Test-Path $targetPortFile } 10 "Target session port file was not created"
    & $psmux -L $namespace set-option -gt $targetSession pane-border-indicators arrows 2>&1 | Out-Null
    $sourceValue = (& $psmux -L $namespace show-options -t $session -g -v pane-border-indicators).Trim()
    $targetValue = (& $psmux -L $namespace show-options -t $targetSession -g -v pane-border-indicators).Trim()
    if ($sourceValue -ne "colour" -or $targetValue -ne "arrows") {
        throw "Combined target routed incorrectly (source='$sourceValue', target='$targetValue')"
    }

    foreach ($case in @(
        @{
            Label = "invalid value"
            Arguments = @("-L", $namespace, "set-option", "-g", "pane-border-indicators", "sideways")
        },
        @{
            Label = "multi-token invalid value"
            Arguments = @("-L", $namespace, "set-option", "-g", "pane-border-indicators", "arrows", "junk")
        },
        @{
            Label = "append"
            Arguments = @("-L", $namespace, "set-option", "-ga", "pane-border-indicators", "arrows")
        },
        @{
            Label = "window command"
            Arguments = @("-L", $namespace, "set-window-option", "pane-border-indicators", "arrows")
        },
        @{
            Label = "window flag"
            Arguments = @("-L", $namespace, "set-option", "-w", "pane-border-indicators", "arrows")
        }
    )) {
        Assert-RejectedIndicator $case.Label $case.Arguments
    }

    Write-Host "[PASS] pane-border-indicators colour -> arrows -> colour" -ForegroundColor Green
}
catch {
    $failed++
    Write-Host "[FAIL] $($_.InvocationInfo.PositionMessage) $_" -ForegroundColor Red
}
finally {
    if ($null -ne $client -and -not $client.HasExited) {
        Set-Content -Path $controlFile -Value "QUIT`n" -NoNewline -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
    }
    & $psmux -L $namespace kill-server 2>$null | Out-Null
    $defaultSessionsAfter = @(Get-DefaultSessions)
    if (Compare-Object $defaultSessionsBefore $defaultSessionsAfter) {
        $failed++
        Write-Host "[FAIL] Default namespace changed during isolated test" -ForegroundColor Red
    }
    foreach ($name in $variables) {
        if ($null -eq $previous[$name]) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:\$name" $previous[$name] }
    }
    Remove-Item $artifactRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $failed
