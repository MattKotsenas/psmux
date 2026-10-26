# Issue #683: "Path to profile.ps1 is different inside and outside of psmux".
#
# WHAT WAS REPRODUCED (installed 0bcc421, Windows 11 26200)
#
#   The reporter's Windows Terminal tab runs Windows PowerShell 5.1, so outside
#   psmux `$PROFILE` is `...\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`.
#   A pane inside psmux runs PowerShell 7, whose `$PROFILE` is
#   `...\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`, a file that does
#   not exist for them, so none of their PSReadLine bindings load. Measured here:
#
#     powershell.exe -NoProfile -Command 'psmux new-session -d -s p683a'
#       outer PSVersion=5.1.26100.9444  PROFILE=...\Documents\WindowsPowerShell\...
#       inner PSVersion=7.6.6           PROFILE=...\Documents\PowerShell\...
#       show-options -g -v default-shell -> ...\WindowsApps\pwsh.exe
#
#   The pwsh preference is deliberate and documented (default-shell defaults to
#   pwsh, then powershell, then cmd). What was NOT tmux parity: psmux ignored the
#   SHELL environment variable entirely.
#
#     $env:SHELL = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
#     psmux new-session -d -s p683s     -> inner PSVersion=7.6.6 (SHELL ignored)
#
# tmux PARITY
#
#   tmux.c getshell(): the initial value of `default-shell` is $SHELL when
#   checkshell() accepts it (absolute path, executable, not tmux itself), else
#   the passwd shell, else /bin/sh. tmux never looks at which shell the client
#   was typed into; the environment decides. psmux now does the same on Windows:
#   SHELL wins when it names an executable that exists and is not psmux, and the
#   pwsh > powershell > cmd walk stays the fallback. A bare name (`powershell`)
#   is accepted when it resolves on PATH, a Git Bash style `/usr/bin/bash` or a
#   missing path is ignored exactly like checkshell() would ignore it.
#
# WHAT THIS SUITE PINS
#   T1  no SHELL, launched from Windows PowerShell 5.1: the pane is still pwsh 7
#       (the documented default, the reporter's observation, not a bug)
#   T2  SHELL = full path to powershell.exe: default-shell reports it, the pane
#       is 5.1 and $PROFILE is under WindowsPowerShell (THE fix; fails on 0bcc421)
#   T3  SHELL = /usr/bin/bash (Git Bash's value): ignored, pane is pwsh 7
#   T4  SHELL = a path that does not exist: ignored
#   T5  SHELL = psmux.exe itself: ignored (tmux areshell())
#   T6  `set -g default-shell powershell` in the config with no SHELL: pane is
#       5.1 (the workaround recommended to the reporter, proven)
#   T7  SHELL = bare `powershell`: resolved on PATH, pane is 5.1
#   T8  SHELL honoured on the warm claim path too (no PSMUX_NO_WARM)
#   T9  launched from a real LOGIN Git Bash (`bash -l`, the Windows Terminal
#       profile form): MSYS hands Windows children
#       SHELL=C:\Program Files\Git\usr\bin\bash.exe, so the pane is bash, exactly
#       what tmux does with $SHELL (a deliberate, documented change for people
#       who start psmux from Git Bash and want pwsh: set default-shell pwsh)
#
# Set PSMUX_TEST_BIN to test a non-installed binary.
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue683_shell_env_default_shell.ps1

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else {
    $local = Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue
    if ($local) { $local.Path } else { (Get-Command psmux -EA Stop).Source }
}
$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX_TARGET_SESSION','SHELL','PSMUX_CONFIG_FILE') {
    Set-Item -Path "env:$v" -Value $null -EA SilentlyContinue
}

$POWERSHELL51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $POWERSHELL51)) { Write-Host "Windows PowerShell 5.1 not found at $POWERSHELL51"; exit 1 }
$PWSH7 = (Get-Command pwsh -EA Stop).Source

$rig = Join-Path $env:TEMP ("psmux683-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $rig | Out-Null

# Every case gets its own data root and namespace so the server it spawns
# carries exactly the environment the case set and nothing from a neighbour.
$script:CaseNo = 0
function New-Case {
    param([string]$Name)
    $script:CaseNo++
    $data = Join-Path $rig ("data" + $script:CaseNo)
    New-Item -ItemType Directory -Force -Path $data | Out-Null
    return @{ Name = $Name; Data = $data; NS = ("e683c" + $script:CaseNo); Session = ("i683_" + $script:CaseNo) }
}

# Start a detached session with the given environment and read back what the
# pane's shell actually is. Returns @{ Version; Profile; DefaultShell; Screen }.
function Start-AndProbe {
    param($Case, [hashtable]$Env, [switch]$FromPowerShell51, [switch]$AllowWarm)
    $envPrefix = ""
    foreach ($k in $Env.Keys) { $envPrefix += "`$env:$k = '$($Env[$k])'; " }
    $noWarm = if ($AllowWarm) { "" } else { "`$env:PSMUX_NO_WARM = '1'; " }
    $launch = "$noWarm`$env:PSMUX_DATA_DIR = '$($Case.Data)'; $envPrefix& '$PSMUX' -L $($Case.NS) new-session -d -s $($Case.Session) -x 100 -y 30"
    if ($FromPowerShell51) {
        & $POWERSHELL51 -NoProfile -NonInteractive -Command $launch 2>&1 | Out-Null
    } else {
        & $PWSH7 -NoProfile -NonInteractive -Command $launch 2>&1 | Out-Null
    }
    $env:PSMUX_DATA_DIR = $Case.Data
    $alive = $false
    for ($i = 0; $i -lt 60; $i++) {
        & $PSMUX -L $Case.NS has-session -t $Case.Session 2>$null
        if ($LASTEXITCODE -eq 0) { $alive = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $alive) { return @{ Version = "NO_SESSION"; Profile = ""; DefaultShell = ""; Screen = "" } }
    $defaultShell = (& $PSMUX -L $Case.NS show-options -g -v default-shell 2>&1 | Out-String).Trim()
    # Wait for a prompt before typing so the probe line is not eaten by startup.
    for ($i = 0; $i -lt 80; $i++) {
        $cap = & $PSMUX -L $Case.NS capture-pane -t $Case.Session -p 2>&1 | Out-String
        if ($cap -match '(?m)^PS [A-Za-z]:\\') { break }
        Start-Sleep -Milliseconds 250
    }
    & $PSMUX -L $Case.NS send-keys -t $Case.Session 'Write-Host ("I683 v=" + $PSVersionTable.PSVersion.Major + " p=" + $PROFILE)' Enter 2>&1 | Out-Null
    $version = ""; $profile = ""; $screen = ""
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        $screen = & $PSMUX -L $Case.NS capture-pane -t $Case.Session -p -S -200 2>&1 | Out-String
        $m = [regex]::Match($screen, 'I683 v=(\d+) p=(\S+)')
        if ($m.Success -and $m.Groups[2].Value -notmatch '\$PROFILE') { $version = $m.Groups[1].Value; $profile = $m.Groups[2].Value; break }
    }
    return @{ Version = $version; Profile = $profile; DefaultShell = $defaultShell; Screen = $screen }
}

function Stop-Case {
    param($Case)
    $env:PSMUX_DATA_DIR = $Case.Data
    & $PSMUX -L $Case.NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
}

Write-Host "`n=== Issue #683: SHELL seeds default-shell like tmux ===" -ForegroundColor Cyan

# T1: the reporter's exact shape, no SHELL, launched from Windows PowerShell 5.1.
Write-Host "`n[T1] no SHELL, launched from powershell.exe 5.1: pane is pwsh 7 (documented default)" -ForegroundColor Yellow
$c = New-Case "T1"
$r = Start-AndProbe $c @{} -FromPowerShell51
Write-Info "version=$($r.Version) profile=$($r.Profile) default-shell=$($r.DefaultShell)"
if ($r.Version -eq "7" -and $r.Profile -match '\\PowerShell\\') { Write-Pass "T1 pane is PowerShell 7 with the PowerShell profile path" }
else { Write-Fail "T1 expected pwsh 7, got version=$($r.Version) profile=$($r.Profile)" }
if ($r.DefaultShell -match 'pwsh') { Write-Pass "T1 default-shell reports pwsh" } else { Write-Fail "T1 default-shell '$($r.DefaultShell)' should be pwsh" }
Stop-Case $c

# T2: THE fix. SHELL names Windows PowerShell 5.1 by full path.
Write-Host "`n[T2] SHELL = full path to powershell.exe: pane is 5.1, profile under WindowsPowerShell" -ForegroundColor Yellow
$c = New-Case "T2"
$r = Start-AndProbe $c @{ SHELL = $POWERSHELL51 } -FromPowerShell51
Write-Info "version=$($r.Version) profile=$($r.Profile) default-shell=$($r.DefaultShell)"
if ($r.DefaultShell -ieq $POWERSHELL51) { Write-Pass "T2 default-shell is the SHELL value" } else { Write-Fail "T2 default-shell '$($r.DefaultShell)' should be '$POWERSHELL51'" }
if ($r.Version -eq "5" -and $r.Profile -match '\\WindowsPowerShell\\') { Write-Pass "T2 pane is Windows PowerShell 5.1 with the WindowsPowerShell profile path" }
else { Write-Fail "T2 expected 5.1 pane, got version=$($r.Version) profile=$($r.Profile)" }
Stop-Case $c

# T3: Git Bash exports SHELL=/usr/bin/bash, which is not a Windows path. Ignored.
Write-Host "`n[T3] SHELL = /usr/bin/bash (Git Bash value): ignored, pane is pwsh 7" -ForegroundColor Yellow
$c = New-Case "T3"
$r = Start-AndProbe $c @{ SHELL = '/usr/bin/bash' }
Write-Info "version=$($r.Version) default-shell=$($r.DefaultShell)"
if ($r.Version -eq "7" -and $r.DefaultShell -match 'pwsh') { Write-Pass "T3 POSIX style SHELL ignored, pwsh 7 pane" }
else { Write-Fail "T3 expected pwsh 7 fallback, got version=$($r.Version) default-shell=$($r.DefaultShell)" }
Stop-Case $c

# T4: a path that does not exist is ignored (checkshell access(X_OK)).
Write-Host "`n[T4] SHELL = missing path: ignored" -ForegroundColor Yellow
$c = New-Case "T4"
$r = Start-AndProbe $c @{ SHELL = 'C:\definitely\missing\i683shell.exe' }
Write-Info "version=$($r.Version) default-shell=$($r.DefaultShell)"
if ($r.Version -eq "7" -and $r.DefaultShell -match 'pwsh') { Write-Pass "T4 missing SHELL ignored, pwsh 7 pane" }
else { Write-Fail "T4 expected pwsh 7 fallback, got version=$($r.Version) default-shell=$($r.DefaultShell)" }
Stop-Case $c

# T5: SHELL pointing at psmux itself is ignored (tmux areshell()).
Write-Host "`n[T5] SHELL = psmux.exe itself: ignored" -ForegroundColor Yellow
$c = New-Case "T5"
$r = Start-AndProbe $c @{ SHELL = $PSMUX }
Write-Info "version=$($r.Version) default-shell=$($r.DefaultShell)"
if ($r.Version -eq "7" -and $r.DefaultShell -match 'pwsh') { Write-Pass "T5 SHELL=psmux ignored, pwsh 7 pane" }
else { Write-Fail "T5 expected pwsh 7 fallback, got version=$($r.Version) default-shell=$($r.DefaultShell)" }
Stop-Case $c

# T6: the config workaround: set -g default-shell powershell.
Write-Host "`n[T6] config 'set -g default-shell powershell', no SHELL: pane is 5.1" -ForegroundColor Yellow
$c = New-Case "T6"
$conf = Join-Path $rig 'i683.conf'
"set -g default-shell powershell`n" | Set-Content -Path $conf -Encoding UTF8
$r = Start-AndProbe $c @{ PSMUX_CONFIG_FILE = $conf } -FromPowerShell51
Write-Info "version=$($r.Version) profile=$($r.Profile) default-shell=$($r.DefaultShell)"
if ($r.Version -eq "5" -and $r.Profile -match '\\WindowsPowerShell\\') { Write-Pass "T6 default-shell powershell from config gives a 5.1 pane with the WindowsPowerShell profile" }
else { Write-Fail "T6 expected 5.1 pane, got version=$($r.Version) profile=$($r.Profile)" }
Stop-Case $c

# T7: a bare name resolves on PATH.
Write-Host "`n[T7] SHELL = bare 'powershell': resolved on PATH, pane is 5.1" -ForegroundColor Yellow
$c = New-Case "T7"
$r = Start-AndProbe $c @{ SHELL = 'powershell' }
Write-Info "version=$($r.Version) default-shell=$($r.DefaultShell)"
if ($r.Version -eq "5" -and $r.DefaultShell -match 'powershell\.exe$') { Write-Pass "T7 bare SHELL name resolved to powershell.exe, 5.1 pane" }
else { Write-Fail "T7 expected 5.1 pane, got version=$($r.Version) default-shell=$($r.DefaultShell)" }
Stop-Case $c

# T8: the warm claim path (standby pool allowed) honours SHELL as well.
Write-Host "`n[T8] SHELL honoured on the warm claim path (PSMUX_NO_WARM unset)" -ForegroundColor Yellow
$c = New-Case "T8"
$r = Start-AndProbe $c @{ SHELL = $POWERSHELL51 } -AllowWarm
Write-Info "version=$($r.Version) profile=$($r.Profile) default-shell=$($r.DefaultShell)"
if ($r.Version -eq "5" -and $r.DefaultShell -ieq $POWERSHELL51) { Write-Pass "T8 warm path pane is 5.1 with default-shell = SHELL" }
else { Write-Fail "T8 expected 5.1 pane on the warm path, got version=$($r.Version) default-shell=$($r.DefaultShell)" }
Stop-Case $c
# The standby pool may have spawned extra servers under this data root; reap them by pid file.
Get-ChildItem -Path $c.Data -Filter '*.pid' -Recurse -EA SilentlyContinue | ForEach-Object {
    $pid_ = (Get-Content $_.FullName -Raw -EA SilentlyContinue).Trim()
    if ($pid_ -match '^\d+$') { $p = Get-Process -Id ([int]$pid_) -EA SilentlyContinue; if ($p -and $p.ProcessName -eq 'psmux') { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } }
}

# T9: launched from a REAL Git Bash. MSYS rewrites SHELL for Windows children
# to `C:\Program Files\Git\bin\bash.exe` (measured: `cmd //c echo %SHELL%` from
# bash prints the Windows path), so like tmux the pane becomes bash.
Write-Host "`n[T9] launched from Git Bash: SHELL is rewritten to a Windows path, pane is bash (tmux parity)" -ForegroundColor Yellow
$gitBash = @("C:\Program Files\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe") | ? { Test-Path $_ } | Select -First 1
if (-not $gitBash) {
    Write-Host "  [SKIP] Git Bash not installed" -ForegroundColor Yellow
} else {
    $c = New-Case "T9"
    $env:PSMUX_DATA_DIR = $c.Data
    $env:PSMUX_NO_WARM = '1'
    $psmuxPosix = ($PSMUX -replace '\\', '/')
    # A Windows Terminal Git Bash profile runs `bash.exe -i -l`; only a LOGIN
    # bash exports SHELL to Windows children (measured: `bash -c` leaves it
    # unset, `bash -l -c` hands them C:\Program Files\Git\usr\bin\bash.exe).
    & $gitBash -l -c "'$psmuxPosix' -L $($c.NS) new-session -d -s $($c.Session) -x 100 -y 30" 2>&1 | Out-Null
    $alive = $false
    for ($i = 0; $i -lt 60; $i++) { & $PSMUX -L $c.NS has-session -t $c.Session 2>$null; if ($LASTEXITCODE -eq 0) { $alive = $true; break }; Start-Sleep -Milliseconds 250 }
    if (-not $alive) { Write-Fail "T9 session did not start from Git Bash" }
    else {
        $ds = (& $PSMUX -L $c.NS show-options -g -v default-shell 2>&1 | Out-String).Trim()
        Write-Info "default-shell=$ds"
        if ($ds -match 'bash\.exe$') { Write-Pass "T9 default-shell is Git Bash's bash.exe (SHELL honoured)" } else { Write-Fail "T9 default-shell '$ds' should be bash.exe" }
        for ($i = 0; $i -lt 60; $i++) { $cap = & $PSMUX -L $c.NS capture-pane -t $c.Session -p 2>&1 | Out-String; if ($cap -match '\$\s*$') { break }; Start-Sleep -Milliseconds 250 }
        & $PSMUX -L $c.NS send-keys -t $c.Session 'echo I683 bash=$BASH_VERSION' Enter 2>&1 | Out-Null
        $ok = $false
        for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 250; $cap = & $PSMUX -L $c.NS capture-pane -t $c.Session -p -S -200 2>&1 | Out-String; if ($cap -match 'I683 bash=\d') { $ok = $true; break } }
        if ($ok) { Write-Pass "T9 pane runs bash ($([regex]::Match($cap, 'I683 bash=(\d\S*)').Groups[1].Value))" } else { Write-Fail "T9 pane is not bash; screen:`n$cap" }
    }
    Stop-Case $c
    Remove-Item env:PSMUX_NO_WARM -EA SilentlyContinue
}

Remove-Item env:PSMUX_DATA_DIR -EA SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item -Recurse -Force $rig -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if ($script:Fail -gt 0) { "Red" } else { "Green" })
exit $script:Fail
