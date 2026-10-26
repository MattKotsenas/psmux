# Issue #598 (larroy, 2026-09-22): "not able to paste anymore with iterm2 on mac".
#
# Everything under tests\ that exercises paste over SSH before this file drove
# the connection with the Windows ssh.exe and a REDIRECTED PIPE for stdin
# (tests\test_vt_paste_ssh_real.ps1).  A pipe is not a terminal, so that shape
# can never show what a Mac user sees: iTerm2 is not a Windows console, it holds
# a real pty, and the psmux client on the far side reads whatever Windows sshd's
# ConPTY makes of those bytes.
#
# This file closes that gap.  It drives a REAL Unix ssh client, the one inside
# WSL, under a REAL pty opened with python's pty module, with TERM set and a
# 120x40 winsize, and then writes the exact byte sequence iTerm2 writes on
# Cmd+V into the pty master:
#
#     ESC[200~ <text> ESC[201~
#
# which is what iTerm2 sends once the attached psmux client has turned bracketed
# paste on with ESC[?2004h on the outer terminal.  The pane child is
# tests\paste_recorder.cs, so the assertion is on the exact bytes the pane's
# program received, not on a rendered screen.
#
# Covered shapes, each asserted byte for byte:
#   1. single line paste
#   2. multi line paste with CRLF line endings, which must stay ONE bracketed
#      gesture: if it split, a shell with bracketed paste on would submit each
#      fragment as its own command line, which is what "pasting is broken"
#      looks like from the Mac.
#   3. 17 KB multi line paste, past every internal chunk boundary
#   4. a pane child that reads INPUT_RECORDs instead of bytes, which must get
#      the payload with the markers STRIPPED (issue #98)
#   5. the outer terminal keeps bracketed paste ON for the whole attachment,
#      i.e. ESC[?2004l is never sent before detach.  If it were, iTerm2 would
#      stop wrapping pastes and the user would see unbracketed text.
#   6. THE FRAGMENTED SHAPES, which is where the reported regression lives.
#      The payload is written to the pty in small pieces with a gap between
#      them, the way a paste reaches the Windows side when sshd's ConPTY hands
#      the client its records in separate reads.
#
#      Below about ten bytes per piece, sshd's ConPTY mangles the ESC[200~ open
#      marker itself, measured as ESC[0n ESC[0n ~ reaching the client, so psmux
#      never sees a bracketed paste and falls back to its text-burst heuristic.
#      That part is a ConPTY defect and is out of psmux's reach.  What psmux
#      MUST still do is deliver the clipboard as ONE gesture, because a decoded
#      key in the middle of the run ends it: before the fix a three line paste
#      arrived as THREE separately bracketed pastes with a literal LF between
#      them, and a shell with bracketed paste on ran each one as a command.
#
#      The regression was 5e16dcf (#642), which made a bare 0x0a decode as C-j.
#      That is right for a keypress and wrong for the LF of a pasted CRLF.
#
# Skips cleanly, exit 0, when WSL, a WSL python3, sshd on localhost or key auth
# for the current user is missing.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS   = "i598ssh"
$SESS = "i598_s"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "[SKIP] $msg" -ForegroundColor Yellow }

$repoTests = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== Issue #598: bracketed paste from a real Unix ssh client ===" -ForegroundColor Cyan

# --- preflight: everything this test needs, or skip -------------------------
$wsl = Get-Command wsl.exe -EA SilentlyContinue
if (-not $wsl) { Write-Skip "wsl.exe not present"; exit 0 }

$distro = if ($env:PSMUX_TEST_WSL_DISTRO) { $env:PSMUX_TEST_WSL_DISTRO } else { "Ubuntu" }
$probe = & wsl -d $distro -e bash -lc "command -v python3 >/dev/null && echo PY_OK" 2>&1 | Out-String
if ($probe -notmatch "PY_OK") { Write-Skip "WSL distro '$distro' or its python3 is unavailable"; exit 0 }

$sshd = Get-Service sshd -EA SilentlyContinue
if (-not $sshd -or $sshd.Status -ne "Running") { Write-Skip "Windows sshd service is not running"; exit 0 }

$sshUser = if ($env:PSMUX_TEST_SSH_USER) { $env:PSMUX_TEST_SSH_USER } else { $env:USERNAME }
$keyWin  = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
if (-not (Test-Path $keyWin)) { Write-Skip "no $keyWin to give the WSL ssh client"; exit 0 }

$selfProbe = & ssh -o ConnectTimeout=5 -o BatchMode=yes "$sshUser@localhost" "echo PSMUX_SSH_OK" 2>$null
if ("$selfProbe" -notmatch "PSMUX_SSH_OK") { Write-Skip "key auth to $sshUser@localhost is not configured"; exit 0 }

# WSL2 cannot reach the Windows host on 'localhost'; the host is the default route.
$hostIp = (& wsl -d $distro -e bash -lc "ip route show default | awk '{print `$3}'" 2>&1 | Out-String).Trim()
if (-not $hostIp) { Write-Skip "could not determine the Windows host address from WSL"; exit 0 }

foreach ($v in 'PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') {
    Remove-Item "env:$v" -EA SilentlyContinue
}
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM

$root = Join-Path $env:TEMP "psmux_i598_ssh"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$dataDir = Join-Path $root "data"
New-Item -ItemType Directory -Force $dataDir | Out-Null
$env:PSMUX_DATA_DIR = $dataDir
$env:PSMUX_NO_WARM  = "1"

# The ssh side gets its own process with its own environment, so the data dir
# has to travel in the command sshd runs, not in this shell's environment.
$attachCmd = Join-Path $root "attach.cmd"
@(
  '@echo off'
  "set PSMUX_DATA_DIR=$dataDir"
  'set PSMUX_NO_WARM=1'
  '"%~1" -L %~2 attach -t %~3'
) -join "`r`n" | Set-Content -Encoding ASCII $attachCmd

# --- compile the byte recorder ----------------------------------------------
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$recorder = Join-Path $root "paste_recorder.exe"
& $csc /nologo /optimize /platform:x64 /out:$recorder (Join-Path $repoTests "paste_recorder.cs") 2>&1 | Out-Null
if (-not (Test-Path $recorder)) { Write-Host "FATAL: could not compile paste_recorder.cs" -ForegroundColor Red; exit 1 }

# --- the pty driver, written out so the test stays self contained -----------
$driver = @'
import os, sys, pty, select, time, fcntl, termios, struct, signal, subprocess
hostip, keyfile, remote, outlog, payfile = sys.argv[1:6]
attach_wait = float(sys.argv[6]); post_wait = float(sys.argv[7])
chunk_size  = int(sys.argv[8]) if len(sys.argv) > 8 else 0
chunk_delay = float(sys.argv[9]) if len(sys.argv) > 9 else 0.0
payload = open(payfile, 'rb').read()
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
env = dict(os.environ); env['TERM'] = 'xterm-256color'
args = ['ssh', '-tt', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-i', keyfile,
        os.environ.get('PSMUX_SSH_USER', 'x') + '@' + hostip, remote]
p = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave,
                     preexec_fn=os.setsid, env=env, close_fds=True)
os.close(slave)
out = open(outlog, 'wb')
def pump(sec):
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.2)
        if master in r:
            try: d = os.read(master, 65536)
            except OSError: return
            if not d: return
            out.write(d); out.flush()
pump(attach_wait)
out.write(b"\n<<<MARK:PASTE>>>\n"); out.flush()
if chunk_size > 0:
    for i in range(0, len(payload), chunk_size):
        os.write(master, payload[i:i+chunk_size])
        end = time.time() + chunk_delay
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 0.01)
            if master in r:
                try: d = os.read(master, 65536)
                except OSError: break
                if d: out.write(d); out.flush()
else:
    os.write(master, payload)
pump(post_wait)
out.write(b"\n<<<MARK:DETACH>>>\n"); out.flush()
os.write(master, b'\x02'); time.sleep(0.4); os.write(master, b'd')
pump(3.0)
try: os.killpg(os.getpgid(p.pid), signal.SIGTERM)
except Exception: pass
try: p.wait(timeout=5)
except Exception:
    try: os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except Exception: pass
out.close()
print("DRIVER_DONE")
'@
$driverWin = Join-Path $root "pastedrv.py"
Set-Content -Encoding ASCII -Path $driverWin -Value $driver

function To-WslPath([string]$p) { "/mnt/" + $p.Substring(0,1).ToLower() + $p.Substring(2).Replace('\','/') }

# Stage the key and the driver inside WSL once.
$keyWsl = "/tmp/psmux_i598_key"
$prep = @"
cp '$(To-WslPath $keyWin)' $keyWsl && sed -i 's/\r`$//' $keyWsl && chmod 600 $keyWsl
sed 's/\r`$//' '$(To-WslPath $driverWin)' > /tmp/psmux_i598_drv.py
echo PREP_OK
"@
# A CRLF checkout puts a \r at the end of every line of that here string, and
# bash then runs `chmod 600 /tmp/psmux_i598_key\r` and writes the driver to a
# file literally named `psmux_i598_drv.py\r`, while `echo PREP_OK\r` still
# prints PREP_OK. Hand bash LF only, whatever the checkout did to this file.
$prep = $prep -replace "`r`n", "`n"
$prepOut = & wsl -d $distro -e bash -lc $prep 2>&1 | Out-String
if ($prepOut -notmatch "PREP_OK") { Write-Skip "could not stage the ssh key inside WSL: $prepOut"; exit 0 }

$ESC = [char]0x1b
function New-Payload([string]$name, [string]$text) {
    $f = Join-Path $root "$name.bin"
    [IO.File]::WriteAllBytes($f, [Text.Encoding]::UTF8.GetBytes("$ESC[200~$text$ESC[201~"))
    return $f
}

# Run one shape: start a detached session whose pane child is the recorder,
# drive the Unix ssh client through the paste, return the recorder's bytes.
function Invoke-SshPaste([string]$tag, [string]$payloadFile, [string]$recMode,
                         [int]$chunkSize = 0, [double]$chunkDelay = 0.0) {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    $recLog = Join-Path $root "$tag.rec.log"
    Remove-Item $recLog -EA SilentlyContinue
    $outLog = Join-Path $root "$tag.ssh.bin"
    Remove-Item $outLog -EA SilentlyContinue
    $stopFile = Join-Path $root "$tag.stop"
    Remove-Item $stopFile -EA SilentlyContinue

    # The recorder used to live a fixed 20 s, while the driver detaches at
    # 3 s + wsl/ssh start up + 16 s.  When start up took more than about a
    # second the pane exited first, the session ended, and the client's own
    # teardown (ESC[?2004l among it) landed before MARK:DETACH, which [5] then
    # reported as "bracketed paste turned off before detach" (sweep
    # 2026-10-01_01-53-14; 2 s more before attach failed it 2 of 2).  The
    # recording now ends on a stop file written after the driver has
    # detached, with 90 s only as a ceiling.
    & $PSMUX -L $NS new-session -d -s $SESS "$recorder `"$recLog`" 90 $recMode `"$stopFile`"" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    if ((& $PSMUX -L $NS list-sessions 2>&1 | Out-String) -notmatch [regex]::Escape($SESS)) {
        return @{ ok = $false; why = "session did not start" }
    }

    $remote = "$attachCmd `"$PSMUX`" $NS $SESS"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
    $cmd = "export PSMUX_SSH_USER='$sshUser'; R=`$(echo $b64 | base64 -d); " +
           "python3 /tmp/psmux_i598_drv.py '$hostIp' '$keyWsl' `"`$R`" '$(To-WslPath $outLog)' '$(To-WslPath $payloadFile)' 7 9 $chunkSize $chunkDelay"
    & wsl -d $distro -e bash -lc $cmd 2>&1 | Out-Null

    # The driver has detached.  The pane must still be alive here, or the
    # stream's teardown came from the session ending and not from the detach.
    & $PSMUX -L $NS has-session -t $SESS 2>&1 | Out-Null
    $aliveAtDetach = ($LASTEXITCODE -eq 0)
    Set-Content -Path $stopFile -Value "stop"

    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path $recLog) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    Start-Sleep -Milliseconds 800
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null

    if (-not (Test-Path $recLog)) { return @{ ok = $false; why = "the recorder never wrote its log" } }
    $rl = Get-Content $recLog
    $hexLine = $rl | Where-Object { $_ -like "HEX *" } | Select-Object -First 1
    $totLine = $rl | Where-Object { $_ -like "TOTAL *" } | Select-Object -First 1
    return @{
        ok    = $true
        alive = $aliveAtDetach
        hex   = if ($hexLine) { $hexLine.Substring(4).Trim() } else { "" }
        total = if ($totLine) { [int]$totLine.Split(' ')[1] } else { -1 }
        ssh   = if (Test-Path $outLog) { [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($outLog)) } else { "" }
    }
}

function To-Hex([byte[]]$b) { ($b | ForEach-Object { $_.ToString("x2") }) -join "" }

# The pane's ConPTY normalises CRLF to CR on the way in, the same on every
# route, so the expectation is built the same way.
function Expected-Hex([string]$text, [bool]$bracketed) {
    $t = $text.Replace("`r`n", "`r")
    $s = if ($bracketed) { "$ESC[200~$t$ESC[201~" } else { $t }
    return To-Hex ([Text.Encoding]::UTF8.GetBytes($s))
}

# ---------------------------------------------------------------------------
Write-Host "`n[1] single line paste into a byte stream pane" -ForegroundColor Yellow
$t1 = "PSMUX_598_SINGLE_LINE_PAYLOAD"
$r1 = Invoke-SshPaste "single" (New-Payload "p_single" $t1) "vt"
if (-not $r1.ok) { Write-Fail "single line: $($r1.why)" }
else {
    $exp = Expected-Hex $t1 $true
    if ($r1.hex -eq $exp) { Write-Pass "single line arrived byte for byte ($($r1.total) bytes, markers intact)" }
    else { Write-Fail "single line mismatch`n    expected $exp`n    got      $($r1.hex)" }
}

Write-Host "`n[2] multi line CRLF paste into a byte stream pane" -ForegroundColor Yellow
$t2 = "line one`r`nline two`r`nline three"
$r2 = Invoke-SshPaste "multi" (New-Payload "p_multi" $t2) "vt"
if (-not $r2.ok) { Write-Fail "multi line: $($r2.why)" }
else {
    $exp = Expected-Hex $t2 $true
    if ($r2.hex -eq $exp) { Write-Pass "multi line arrived byte for byte ($($r2.total) bytes)" }
    else { Write-Fail "multi line mismatch`n    expected $exp`n    got      $($r2.hex)" }
    # One gesture must stay ONE bracketed paste.  If it split, a shell with
    # bracketed paste would submit each fragment as its own command line.
    $opens  = ([regex]::Matches($r2.hex, "1b5b3230307e")).Count
    $closes = ([regex]::Matches($r2.hex, "1b5b3230317e")).Count
    if ($opens -eq 1 -and $closes -eq 1) { Write-Pass "the paste stayed a single bracketed gesture (1 open, 1 close)" }
    else { Write-Fail "the paste was split into $opens open and $closes close markers" }
}

Write-Host "`n[3] 17 KB multi line paste, past every internal chunk boundary" -ForegroundColor Yellow
$t3 = ((1..200 | ForEach-Object { "L{0:D3}_the_quick_brown_fox_jumps_over_the_lazy_dog_0123456789_abcdefghijklmnopqrstuvwxyz" -f $_ }) -join "`r`n")
$r3 = Invoke-SshPaste "big" (New-Payload "p_big" $t3) "vt"
if (-not $r3.ok) { Write-Fail "17 KB: $($r3.why)" }
else {
    $exp = Expected-Hex $t3 $true
    if ($r3.hex -eq $exp) { Write-Pass "17 KB paste arrived byte for byte ($($r3.total) bytes)" }
    else { Write-Fail "17 KB mismatch: expected $($exp.Length / 2) bytes, got $($r3.total)" }
}

Write-Host "`n[4] a pane child that reads INPUT_RECORDs must NOT see the markers (issue #98)" -ForegroundColor Yellow
$r4 = Invoke-SshPaste "records" (New-Payload "p_rec" $t2) "records"
if (-not $r4.ok) { Write-Fail "record reader: $($r4.why)" }
else {
    $exp = Expected-Hex $t2 $false
    if ($r4.hex -eq $exp) { Write-Pass "record reader got the payload with the markers stripped ($($r4.total) bytes)" }
    else { Write-Fail "record reader mismatch`n    expected $exp`n    got      $($r4.hex)" }
}

Write-Host "`n[5] bracketed paste stays ON for the whole attachment" -ForegroundColor Yellow
# iTerm2 only wraps a paste while the app has ESC[?2004h in force.  If psmux
# turned it off mid session the Mac would send raw text and the user would say
# pasting stopped working, so the disable must come only after detach.
if (-not $r2.ok -or -not $r2.ssh) { Write-Fail "no ssh output stream was captured" }
elseif (-not $r2.alive) {
    # Without a live pane at detach the client exited because its session
    # ended, and its teardown says nothing about what a detach sends.
    Write-Fail "the multi line shape's session was gone before the driver detached, so [5] cannot be judged from this stream"
}
else {
    $enable  = $r2.ssh.IndexOf("[?2004h")
    $disable = $r2.ssh.IndexOf("[?2004l")
    $detach  = $r2.ssh.IndexOf("MARK:DETACH")
    if ($enable -lt 0) { Write-Fail "the client never sent ESC[?2004h to the outer terminal" }
    else { Write-Pass "the client enabled bracketed paste on the outer terminal" }
    if ($disable -ge 0 -and $detach -ge 0 -and $disable -lt $detach) {
        Write-Fail "bracketed paste was turned off at offset $disable, before the detach at $detach"
    } else { Write-Pass "bracketed paste was never turned off before detach" }
}

Write-Host "`n[6] the reported regression: a FRAGMENTED multi line paste" -ForegroundColor Yellow
# 5 bytes at a time, 20 ms apart.  Below about ten bytes per piece sshd's ConPTY
# destroys the ESC[200~ marker before psmux sees it, so a little marker residue
# reaching the pane is expected and is NOT what this asserts.  What it asserts
# is that the clipboard still arrives as ONE gesture and that no line ending
# terminates it, because that is what makes a bracketed paste shell execute
# each line as a command.
#
# Before the fix, on 0af98f6: three ESC[200~ openers, three ESC[201~ closers and
# a literal LF between them.  After: one opener, one closer.
$r6 = Invoke-SshPaste "frag" (New-Payload "p_frag" $t2) "vt" 5 0.02
if (-not $r6.ok) { Write-Fail "fragmented: $($r6.why)" }
else {
    $opens  = ([regex]::Matches($r6.hex, "1b5b3230307e")).Count
    $closes = ([regex]::Matches($r6.hex, "1b5b3230317e")).Count
    Write-Info "fragmented recorder bytes: $($r6.total), openers $opens, closers $closes"
    if ($opens -eq 1 -and $closes -eq 1) {
        Write-Pass "a fragmented paste is still ONE bracketed gesture (was 3 before the #642 fix)"
    } else {
        Write-Fail "a fragmented paste was split into $opens openers and $closes closers, so a bracketed paste shell would run each fragment as its own command"
    }
    # The three line payload must produce exactly two line endings, not four.
    # Before 5e16dcf a CRLF reached the pane as CR CR; 5e16dcf turned the LF
    # into C-j, which ended the run instead.  One CR per line is correct.
    $crs = ([regex]::Matches($r6.hex, "0d")).Count
    if ($crs -eq 2) { Write-Pass "each CRLF collapsed to exactly one CR ($crs for three lines)" }
    else { Write-Fail "expected 2 line endings for three lines, got $crs" }
    # No line of the payload may be missing.
    $txt = ""
    try { $txt = -join ( ($r6.hex -split '(..)' | Where-Object { $_ }) | ForEach-Object { [char][Convert]::ToInt32($_,16) } ) } catch {}
    $missing = @("line one","line two","line three") | Where-Object { $txt -notlike "*$_*" }
    if (-not $missing) { Write-Pass "all three lines survived the fragmented delivery" }
    else { Write-Fail "lines lost in a fragmented paste: $($missing -join ', ')" }
}

Write-Host "`n[7] a real C-j keypress still decodes as C-j (issue #642 must survive)" -ForegroundColor Yellow
# The fix folds an LF into the text run only when a CR came immediately before
# it, or when ordinary text arrived within the same 20 ms burst.  A bare 0x0a
# that opens its own burst is a keypress and must still reach the pane as C-j,
# which is what made a `C-j` prefix work over SSH in the first place.
$lonePay = Join-Path $root "p_ctrlj.bin"
[IO.File]::WriteAllBytes($lonePay, [byte[]](0x0a))
$r7 = Invoke-SshPaste "ctrlj" $lonePay "vt"
if (-not $r7.ok) { Write-Fail "lone 0x0a: $($r7.why)" }
else {
    Write-Info "lone 0x0a recorder bytes: $($r7.total) hex=$($r7.hex)"
    # C-j reaches a VT reading child as the byte 0x0a.  An Enter would be 0x0d.
    if ($r7.hex -match "0a" -and $r7.hex -notmatch "0d") {
        Write-Pass "a lone 0x0a still reaches the pane as 0x0a (C-j), not as 0x0d (Enter)"
    } else {
        Write-Fail "a lone 0x0a reached the pane as '$($r7.hex)'; #642 expects 0a and not 0d"
    }
}

# --- cleanup ----------------------------------------------------------------
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
& wsl -d $distro -e bash -lc "rm -f $keyWsl /tmp/psmux_i598_drv.py" 2>&1 | Out-Null
$env:PSMUX_DATA_DIR = $savedDataDir
$env:PSMUX_NO_WARM  = $savedNoWarm
Remove-Item -Recurse -Force $root -EA SilentlyContinue

Write-Host ""
Write-Host "=== Results: $script:TestsPassed passed, $script:TestsFailed failed ===" -ForegroundColor Cyan
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
