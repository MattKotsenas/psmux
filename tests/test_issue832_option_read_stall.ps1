# Issue #832: a named user option read while the server's command loop is
# busy must never answer "not set" for a key that is set.
#
# The one shot route waited 2 s for the loop and turned the timeout into the
# same None as an unset key: `show-options -qv @k` printed nothing at exit 0
# and `show-options -v @k` said "invalid option: @k" at exit 1. A busy server
# now answers the client's timeout error ("no response from server (timed
# out)", exit 1), as 3.4.0 did when its client limit ended the read.
#
# The stall is made the way the reporter made it: only the server's main
# thread (the command loop) is suspended, the connection threads keep running.
# Private data dir and empty config, so no other session is touched.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$saved = @{ DATA = $env:PSMUX_DATA_DIR; CONF = $env:PSMUX_CONFIG_FILE; WARM = $env:PSMUX_NO_WARM }
$dataDir = Join-Path $env:TEMP "psmux-i832-$(Get-Random)"
$conf = Join-Path $env:TEMP "psmux-i832-$(Get-Random).conf"
Set-Content $conf ''
$env:PSMUX_DATA_DIR = $dataDir
$env:PSMUX_CONFIG_FILE = $conf
$env:PSMUX_NO_WARM = '1'
$NS = "i832_$(Get-Random)"
function P { & $PSMUX -L $NS @args }

Add-Type -Namespace I832 -Name T -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr OpenThread(int a, bool i, int id);
[DllImport("kernel32.dll")] public static extern int SuspendThread(IntPtr h);
[DllImport("kernel32.dll")] public static extern int ResumeThread(IntPtr h);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
'@

Write-Host "`n=== Issue #832: option read during a busy command loop ===" -ForegroundColor Cyan
Write-Host "  binary: $PSMUX  namespace: $NS"
try {
    P new-session -d -s s 2>&1 | Out-Null
    P set-option -t s '@k' v 2>&1 | Out-Null

    $v = (P show-options -qv -t s '@k' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $v -eq 'v') { Write-Pass "unloaded: show-options -qv @k answers v at rc 0" } else { Write-Fail "unloaded read: rc=$LASTEXITCODE out=[$v]" }
    $v = (P show-options -qv -t s '@unset' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $v -eq '') { Write-Pass "unloaded: -qv of an unset key is empty at rc 0 (unchanged)" } else { Write-Fail "unset -qv: rc=$LASTEXITCODE out=[$v]" }
    $v = (P show-options -v -t s '@unset' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -and $v -match 'invalid option') { Write-Pass "unloaded: -v of an unset key is 'invalid option' at rc 1 (unchanged)" } else { Write-Fail "unset -v: rc=$LASTEXITCODE out=[$v]" }

    $pidFile = Get-ChildItem $dataDir -Filter "${NS}__s.pid" | Select-Object -First 1
    $srv = [int]((Get-Content $pidFile.FullName -Raw).Trim() -split ':')[0]
    $main = (Get-Process -Id $srv).Threads | Sort-Object StartTime | Select-Object -First 1
    $h = [I832.T]::OpenThread(0x0002, $false, $main.Id)
    try {
        [void][I832.T]::SuspendThread($h)
        $q = (P show-options -qv -t s '@k' 2>&1 | Out-String).Trim(); $qrc = $LASTEXITCODE
        $n = (P show-options -v -t s '@k' 2>&1 | Out-String).Trim(); $nrc = $LASTEXITCODE
    } finally { [void][I832.T]::ResumeThread($h); [void][I832.T]::CloseHandle($h) }

    Write-Host "  [INFO] stalled -qv: rc=$qrc out=[$q]   stalled -v: rc=$nrc out=[$n]" -ForegroundColor DarkGray
    if (($qrc -eq 0 -and $q -eq 'v') -or ($qrc -ne 0 -and $q -match 'timed out')) { Write-Pass "stalled -qv @k: the value or a timeout error, never empty at rc 0" }
    else { Write-Fail "stalled -qv @k answered rc=$qrc out=[$q] for a key that is set" }
    if ($n -notmatch 'invalid option') { Write-Pass "stalled -v @k never says 'invalid option' for a set key" }
    else { Write-Fail "stalled -v @k said: $n" }
    if ($nrc -ne 0 -and $n -match 'timed out') { Write-Pass "stalled -v @k reports the timeout at rc 1" }
    elseif ($nrc -eq 0 -and $n -eq 'v') { Write-Pass "stalled -v @k answered v" }
    else { Write-Fail "stalled -v @k: rc=$nrc out=[$n]" }

    $v = (P show-options -qv -t s '@k' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $v -eq 'v') { Write-Pass "after the stall the key answers v again" } else { Write-Fail "after the stall: rc=$LASTEXITCODE out=[$v]" }
} finally {
    P kill-server 2>&1 | Out-Null
    $env:PSMUX_DATA_DIR = $saved.DATA; $env:PSMUX_CONFIG_FILE = $saved.CONF; $env:PSMUX_NO_WARM = $saved.WARM
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $dataDir -EA SilentlyContinue
    Remove-Item -Force $conf -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)"
Write-Host "  Failed: $($script:TestsFailed)"
exit $script:TestsFailed
