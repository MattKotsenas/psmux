# Issue #598 (larroy, 2026-09-28): iTerm2 over plain ssh into psmux, pwsh pane,
# bracketed paste on.  The first paste after attach lands; every later paste
# does nothing.  The reporter's input_debug.log:
#
#   [event] Paste (203 bytes)
#   [send] -> send-paste ...
#   [event] Key code=Char('c') mods=CONTROL -> send-key C-c
#   5x Backspace
#   [event] Paste (31 bytes)
#   [paste] Event::Paste: dropping duplicate of 31 char(s) already sent as characters
#   ... the same for 25, 16, 9, 9 and 9 bytes, no send-paste after any of them
#
# ROOT CAUSE: the Event::Paste arm recorded its own send-paste in PasteGesture,
# which set the "already forwarded as characters" latch.  Only a Ctrl+V press or
# release cleared it, and a client behind ssh never sees that keystroke, so the
# latch outlived the first paste and every later Event::Paste was "a duplicate".
# Every typed key sets the same latch, so a paste right after a keystroke was
# dropped too.
#
# This test drives the path the reporter uses, end to end: a REAL Unix ssh
# client (WSL) under a REAL pty writes ESC[200~ text ESC[201~ into Windows sshd,
# whose ConPTY hosts the attached psmux client.  The assertion is on the pane
# (capture-pane), not on a log line.
#
#   1. the reporter's sequence: paste 203 bytes, C-c, 5 backspaces, then three
#      small distinct pastes seconds apart.  All of them must land.
#   2. a key typed 120 ms before each paste (`git commit -m ` then Cmd+V).
#      The paste must land.
#   3. the client log holds no "dropping duplicate" line for any of it.
#
# Skips cleanly, exit 0, when WSL, a WSL python3, sshd on localhost or key auth
# for the current user is missing.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = "i598after_" + (Get-Random -Maximum 999999)
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "[SKIP] $msg" -ForegroundColor Yellow }

Write-Host "=== Issue #598: every paste of an ssh client reaches the pane ===" -ForegroundColor Cyan
Write-Info "binary: $PSMUX"

# --- preflight -----------------------------------------------------------------
if (-not (Get-Command wsl.exe -EA SilentlyContinue)) { Write-Skip "wsl.exe not present"; exit 0 }
$distro = if ($env:PSMUX_TEST_WSL_DISTRO) { $env:PSMUX_TEST_WSL_DISTRO } else { "Ubuntu" }
$probe = & wsl -d $distro -e bash -lc "command -v python3 >/dev/null && echo PY_OK" 2>&1 | Out-String
if ($probe -notmatch "PY_OK") { Write-Skip "WSL distro '$distro' or its python3 is unavailable"; exit 0 }
$sshd = Get-Service sshd -EA SilentlyContinue
if (-not $sshd -or $sshd.Status -ne "Running") { Write-Skip "Windows sshd service is not running"; exit 0 }
$sshUser = if ($env:PSMUX_TEST_SSH_USER) { $env:PSMUX_TEST_SSH_USER } else { $env:USERNAME }
$keyWin = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
if (-not (Test-Path $keyWin)) { Write-Skip "no $keyWin to give the WSL ssh client"; exit 0 }
$selfProbe = & ssh -o ConnectTimeout=5 -o BatchMode=yes "$sshUser@localhost" "echo PSMUX_SSH_OK" 2>$null
if ("$selfProbe" -notmatch "PSMUX_SSH_OK") { Write-Skip "key auth to $sshUser@localhost is not configured"; exit 0 }
$hostIp = (& wsl -d $distro -e bash -lc "ip route show default | awk '{print `$3}'" 2>&1 | Out-String).Trim()
if (-not $hostIp) { Write-Skip "could not determine the Windows host address from WSL"; exit 0 }

foreach ($v in 'PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') { Remove-Item "env:$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedInputDebug = $env:PSMUX_INPUT_DEBUG

$root = Join-Path $env:TEMP "psmux_i598_after"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$dataDir = Join-Path $root "data"
New-Item -ItemType Directory -Force $dataDir | Out-Null
$env:PSMUX_DATA_DIR = $dataDir
$env:PSMUX_INPUT_DEBUG = "1"

# The sshd side gets its own environment, so the data dir travels in the command.
$attachCmd = Join-Path $root "attach.cmd"
@(
  '@echo off'
  "set PSMUX_DATA_DIR=$dataDir"
  'set PSMUX_INPUT_DEBUG=1'
  '"%~1" -L %~2 attach -t %~3'
) -join "`r`n" | Set-Content -Encoding ASCII $attachCmd

# --- the pty driver: runs a list of "<wait seconds> <hex bytes>" steps ----------
$driver = @'
import os, sys, pty, select, time, fcntl, termios, struct, signal, subprocess
hostip, keyfile, remote, outlog, stepsfile, user = sys.argv[1:7]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
env = dict(os.environ); env['TERM'] = 'xterm-256color'
args = ['ssh', '-tt', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-i', keyfile, user + '@' + hostip, remote]
p = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave, preexec_fn=os.setsid, env=env, close_fds=True)
os.close(slave)
out = open(outlog, 'wb')
def pump(sec):
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.05)
        if master in r:
            try: d = os.read(master, 65536)
            except OSError: return
            if not d: return
            out.write(d); out.flush()
for line in open(stepsfile).read().split('\n'):
    line = line.strip()
    if not line: continue
    parts = line.split(' ', 1)
    pump(float(parts[0]))
    if len(parts) > 1 and parts[1]:
        os.write(master, bytes.fromhex(parts[1]))
pump(2.0)
try: os.killpg(os.getpgid(p.pid), signal.SIGTERM)
except Exception: pass
try: p.wait(timeout=5)
except Exception:
    try: os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except Exception: pass
out.close()
print("DRIVER_DONE")
'@
$driverWin = Join-Path $root "drv.py"
Set-Content -Encoding ASCII -Path $driverWin -Value $driver

function To-WslPath([string]$p) { "/mnt/" + $p.Substring(0,1).ToLower() + $p.Substring(2).Replace('\','/') }
$keyWsl = "/tmp/psmux_i598after_key"
$prep = @"
cp '$(To-WslPath $keyWin)' $keyWsl && sed -i 's/\r`$//' $keyWsl && chmod 600 $keyWsl
sed 's/\r`$//' '$(To-WslPath $driverWin)' > /tmp/psmux_i598after_drv.py
echo PREP_OK
"@
$prep = $prep -replace "`r`n", "`n"
$prepOut = & wsl -d $distro -e bash -lc $prep 2>&1 | Out-String
if ($prepOut -notmatch "PREP_OK") { Write-Skip "could not stage the ssh key inside WSL: $prepOut"; exit 0 }

$ESC = [char]0x1b
function Hx([string]$s) { ([Text.Encoding]::UTF8.GetBytes($s) | ForEach-Object { $_.ToString("x2") }) -join "" }
function Bracket([string]$s) { Hx "$ESC[200~$s$ESC[201~" }

# One attached client, one pwsh pane, the given steps; returns the pane text.
function Invoke-Scenario([string]$tag, [string[]]$steps) {
    $sess = "s_$tag"
    & $PSMUX -L $NS new-session -d -s $sess -x 120 -y 40 "pwsh -NoProfile -NoLogo" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $stepsFile = Join-Path $root "$tag.steps"
    ($steps -join "`n") | Set-Content -Encoding ASCII -NoNewline $stepsFile
    $outLog = Join-Path $root "$tag.ssh.bin"
    $remote = "$attachCmd `"$PSMUX`" $NS $sess"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
    $cmd = "R=`$(echo $b64 | base64 -d); python3 /tmp/psmux_i598after_drv.py '$hostIp' '$keyWsl' `"`$R`" " +
           "'$(To-WslPath $outLog)' '$(To-WslPath $stepsFile)' '$sshUser'"
    $drv = & wsl -d $distro -e bash -lc $cmd 2>&1 | Out-String
    if ($drv -notmatch "DRIVER_DONE") { Write-Info "driver output: $drv" }
    $cap = & $PSMUX -L $NS capture-pane -p -J -t $sess 2>&1 | Out-String
    & $PSMUX -L $NS kill-session -t $sess 2>&1 | Out-Null
    return ($cap -replace "`r?`n", "")
}

try {
    # --- 1. the reporter's sequence ---------------------------------------------
    Write-Host "`n[Test 1] paste 203 bytes, C-c, 5 backspaces, then three more pastes" -ForegroundColor Yellow
    $first = "FIRST598" + ("x" * 195)
    $later = @("SECOND598_padpadpadpadpadpadpad", "THIRD598_padpadpadpadpad", "FOURTH598_pad")
    $steps = @(("6 " + (Bracket $first)), "1.6 03")
    for ($i = 0; $i -lt 5; $i++) { $steps += "0.3 7f" }
    foreach ($t in $later) { $steps += ("4 " + (Bracket $t)) }
    $steps += "3"
    $pane = Invoke-Scenario "report" $steps
    if ($pane.Contains($first)) { Write-Pass "the first paste (203 bytes) landed" }
    else { Write-Fail "the first paste did not land" }
    $n = 2
    foreach ($t in $later) {
        if ($pane.Contains($t)) { Write-Pass "paste $n ($($t.Length) bytes) landed after the first one" }
        else { Write-Fail "paste $n ($($t.Length) bytes) never reached the pane (the #598 symptom)" }
        $n++
    }

    # --- 2. a key typed just before each paste ------------------------------------
    Write-Host "`n[Test 2] a space typed 120 ms before each paste" -ForegroundColor Yellow
    $typed = @("TYPEDA598_padpadpad", "TYPEDB598_pad", "TYPEDC598")
    $steps = @()
    foreach ($t in $typed) { $steps += "3.5 20"; $steps += ("0.12 " + (Bracket $t)) }
    $steps += "3"
    $pane = Invoke-Scenario "typed" $steps
    foreach ($t in $typed) {
        if ($pane.Contains($t)) { Write-Pass "'$t' landed right after a keystroke" }
        else { Write-Fail "'$t' was swallowed by the keystroke before it" }
    }

    # --- 3. the client log -------------------------------------------------------
    Write-Host "`n[Test 3] no paste was classified as a duplicate" -ForegroundColor Yellow
    $log = Join-Path $dataDir "input_debug.log"
    if (Test-Path $log) {
        $events = @(Select-String -Path $log -Pattern "\] Paste \(").Count
        $dropped = @(Select-String -Path $log -Pattern "dropping duplicate")
        if ($events -ge 7 -and $dropped.Count -eq 0) { Write-Pass "$events paste events, none dropped" }
        elseif ($events -lt 7) { Write-Fail "only $events Event::Paste lines: the markers did not reach the client as a paste" }
        else { Write-Fail "$($dropped.Count) of $events paste events dropped, first: $($dropped[0].Line)" }
    } else {
        Write-Fail "no input_debug.log in $dataDir"
    }
}
finally {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    if ($null -eq $savedDataDir) { Remove-Item env:PSMUX_DATA_DIR -EA SilentlyContinue } else { $env:PSMUX_DATA_DIR = $savedDataDir }
    if ($null -eq $savedInputDebug) { Remove-Item env:PSMUX_INPUT_DEBUG -EA SilentlyContinue } else { $env:PSMUX_INPUT_DEBUG = $savedInputDebug }
    & wsl -d $distro -e bash -lc "rm -f $keyWsl /tmp/psmux_i598after_drv.py" 2>&1 | Out-Null
}

Write-Host "`n=== Results: $script:TestsPassed passed, $script:TestsFailed failed ===" -ForegroundColor $(if ($script:TestsFailed -eq 0) { "Green" } else { "Red" })
exit $(if ($script:TestsFailed -eq 0) { 0 } else { 1 })
