# Issue #623 (second report): Ctrl+1 in Far Manager's drives menu opened the
# Temporary panel instead of toggling the disk type column.
#
# Measured before anything was changed, with real keystrokes injected into an
# attached client's console and a pane child configured in Far's own console
# input mode (0x01B8), logging every INPUT_RECORD it read:
#
#   injected Ctrl+1  ->  KEY down vk=0x31 sc=0x02 ch=0x0031 ctrl=0x0000
#   injected Ctrl+0  ->  KEY down vk=0x30 sc=0x0B ch=0x0030 ctrl=0x0000
#   injected Ctrl+2  ->  KEY down vk=0x20 sc=0x39 ch=0x0020 ctrl=0x0000
#
# An unmodified '1', an unmodified '0', and a literal SPACE.  Far's drives menu
# gives the Temporary panel plugin the hotkey '1', so a bare '1' opens it.  The
# same keys injected into a Far running OUTSIDE psmux dropped the word "fixed"
# from "C: fixed | 924 G | 32.7 G", which is what the reporter expected.
#
# Cause: psmux ports tmux's input-keys.c `standard_map` verbatim, and a terminal
# has no code for Ctrl + a digit, so tmux sends the bare character.  A pane that
# reads bytes is fine with that; a pane that reads records cannot recover the
# modifier.  ConPTY parses neither xterm extended key form (CSI 27;5;49~ and
# CSI 49;5u both produced NO record at all under a bare pseudoconsole), so the
# fix encodes those keys in win32 input mode, and only for a pane that
# `detect_record_reader` classifies as a record reader.
#
# Test 1 runs everywhere, using tests/record_key_child.cs as the Far stand-in.
# Test 2 needs a real Far Manager install and SKIPS with a clear message when
# there is none.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_BIN) { $env:PSMUX_BIN } else { (Get-Command psmux -EA Stop).Source }
$SOCK = "i623cd"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($msg) { Write-Host "  [SKIP] $msg" -ForegroundColor DarkGray }

$emptyConf = "$env:TEMP\psmux_623cd_empty.conf"
"" | Set-Content -Path $emptyConf -Encoding ASCII

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}

$injector = "$env:TEMP\psmux_623cd_injector.exe"
$recChild = "$env:TEMP\psmux_623cd_reckey.exe"
& $csc /nologo /platform:x64 /out:$injector "$PSScriptRoot\injector.cs"          2>&1 | Out-Null
& $csc /nologo /platform:x64 /out:$recChild "$PSScriptRoot\record_key_child.cs"  2>&1 | Out-Null
foreach ($exe in @($injector, $recChild)) {
    if (-not (Test-Path $exe)) {
        Write-Host "  [FAIL] could not build the C# harnesses (csc at $csc): missing $exe" -ForegroundColor Red
        exit 1
    }
}

$dataRoot = "$env:TEMP\psmux_623cd_root"
if (-not (Test-Path $dataRoot)) { New-Item -ItemType Directory -Path $dataRoot | Out-Null }
$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$savedRecLog  = $env:PSMUX_RECORD_LOG
$env:PSMUX_DATA_DIR = $dataRoot
$env:PSMUX_NO_WARM = "1"

function Cleanup-Session($name) {
    & $PSMUX -L $SOCK kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
}

Write-Host "`n=== Issue #623 Tests: Ctrl+digit must keep its modifier ===" -ForegroundColor Cyan

# =============================================================================
# TEST 1: a record-reading pane receives VK + LEFT_CTRL_PRESSED, not a digit
# =============================================================================
Write-Host "`n[Test 1] Ctrl+digit reaches a record reader as a modified key record" -ForegroundColor Yellow

$sess = "i623cd_rec"
$recLog = "$dataRoot\record_key.txt"
if (Test-Path $recLog) { Remove-Item -LiteralPath $recLog -Force }
$env:PSMUX_RECORD_LOG = $recLog
Cleanup-Session $sess

$client = Start-Process -FilePath $PSMUX -PassThru `
    -ArgumentList "-L",$SOCK,"-f",$emptyConf,"new-session","-s",$sess,"-x","100","-y","30","--",$recChild
Start-Sleep -Seconds 5

& $PSMUX -L $SOCK has-session -t $sess 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "attached session '$sess' never came up"
} elseif (-not (Test-Path $recLog)) {
    Write-Skip "the record-reading pane child never started (no $recLog)"
} else {
    $mode = (Get-Content $recLog | Where-Object { $_ -match '^mode ' }) -join ''
    if ($mode -match '-> 0x01B8') {
        Write-Pass "the pane child runs in Far's console mode ($mode)"
    } else {
        Write-Skip "the pane child could not take Far's console mode ($mode)"
    }

    # One injected keystroke per case, then read the record it produced.
    #
    # A real chord starts with the modifier's own key-down (VK_SHIFT 0x10,
    # VK_CONTROL 0x11, VK_MENU 0x12) and those records are skipped here: the
    # assertion is about the KEY, and taking the first record instead made
    # Shift+1 look like a changed key when only the prologue was being read.
    function Inject-And-Read($keys, $label) {
        $before = @(Get-Content $recLog -EA SilentlyContinue).Count
        & $injector $client.Id $keys 2>&1 | Out-Null
        Start-Sleep -Milliseconds 700
        $all = @(Get-Content $recLog -EA SilentlyContinue)
        $new = @($all | Select-Object -Skip $before | Where-Object {
            $_ -match '^KEY down' -and $_ -notmatch 'vk=0x1[012] '
        })
        if ($new.Count -eq 0) { return $null }
        return $new[0]
    }

    # Ctrl+digit: VK of the digit, LEFT_CTRL_PRESSED (0x0008), no character.
    $digits = @(
        @('0', '0x30'), @('1', '0x31'), @('3', '0x33'), @('4', '0x34'),
        @('5', '0x35'), @('6', '0x36'), @('7', '0x37'), @('8', '0x38'), @('9', '0x39')
    )
    $bad = @()
    foreach ($d in $digits) {
        $vkHex = $d[1].Substring(2)
        $rec = Inject-And-Read "{RAW:$vkHex`:0000:0008}" "Ctrl+$($d[0])"
        if ($null -eq $rec) { $bad += "Ctrl+$($d[0]): no record at all"; continue }
        if ($rec -notmatch "vk=$($d[1])") { $bad += "Ctrl+$($d[0]): wrong vk -> $rec"; continue }
        if ($rec -notmatch 'ctrl=0x0008') { $bad += "Ctrl+$($d[0]): modifier lost -> $rec"; continue }
    }
    if ($bad.Count -eq 0) {
        Write-Pass "all nine Ctrl+digit keys arrived with their own VK and LEFT_CTRL_PRESSED"
    } else {
        Write-Fail "#623 regression: $($bad -join ' | ')"
    }

    # Ctrl+2 folds onto Ctrl+Space on Windows (fold_nul_to_ctrl_space, tmux
    # tty-keys.c "C-Space is special"), so it must arrive as VK_SPACE WITH the
    # modifier -- before the fix it arrived as a literal space, ctrl=0x0000.
    $rec = Inject-And-Read "{RAW:32:0000:0008}" "Ctrl+2"
    if ($null -eq $rec) {
        Write-Fail "Ctrl+2 produced no record at all"
    } elseif ($rec -match 'vk=0x20' -and $rec -match 'ctrl=0x0008' -and $rec -match 'ch=0x0000') {
        Write-Pass "Ctrl+2 arrived as Ctrl+Space with the modifier intact ($rec)"
    } else {
        Write-Fail "#623 regression: Ctrl+2 arrived as $rec (a bare space means the modifier was dropped)"
    }

    # The keys that were already right must not move.
    $rec = Inject-And-Read "1" "plain 1"
    if ($rec -match 'vk=0x31' -and $rec -match 'ch=0x0031' -and $rec -match 'ctrl=0x0000') {
        Write-Pass "a plain 1 is still a plain 1 ($rec)"
    } else {
        Write-Fail "plain 1 changed: $rec"
    }
    $rec = Inject-And-Read "!" "Shift+1"
    if ($rec -match 'ch=0x0021') {
        Write-Pass "Shift+1 still produces '!' ($rec)"
    } else {
        Write-Fail "Shift+1 changed: $rec"
    }
    $rec = Inject-And-Read "{MOD:31:0031:0002}" "Alt+1"
    if ($rec -match 'vk=0x31' -and $rec -match 'ctrl=0x0002') {
        Write-Pass "Alt+1 still carries LEFT_ALT_PRESSED ($rec)"
    } else {
        Write-Fail "Alt+1 changed: $rec"
    }
    $rec = Inject-And-Read "{RAW:70:0000:0008}" "Ctrl+F1"
    if ($rec -match 'vk=0x70' -and $rec -match 'ctrl=0x0008') {
        Write-Pass "Ctrl+F1 still arrives as a modified function key ($rec)"
    } else {
        Write-Fail "Ctrl+F1 changed: $rec"
    }
    $rec = Inject-And-Read "^w" "Ctrl+w"
    if ($rec -match 'vk=0x57' -and $rec -match 'ctrl=0x0008') {
        Write-Pass "Ctrl+<letter> still travels as its C0 byte ($rec)"
    } else {
        Write-Fail "Ctrl+w changed: $rec"
    }
    $rec = Inject-And-Read " " "plain space"
    if ($rec -match 'vk=0x20' -and $rec -match 'ch=0x0020' -and $rec -match 'ctrl=0x0000') {
        Write-Pass "the space bar is untouched ($rec)"
    } else {
        Write-Fail "the space bar changed: $rec"
    }

    # A win32 sequence latches the ConPTY, so a bare ESC afterwards would
    # vanish without the #588 repair.  Far leans on Escape to close its menus.
    $rec = Inject-And-Read "{ESC}" "Escape"
    if ($rec -match 'vk=0x1B') {
        Write-Pass "Escape still arrives after a win32 sequence latched the pane (#588)"
    } else {
        Write-Fail "Escape was swallowed after the Ctrl+digit writes: $rec"
    }
}
if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force -EA SilentlyContinue }
Cleanup-Session $sess

# =============================================================================
# TEST 2: Ctrl+1 toggles the disk type column in Far's drives menu
# =============================================================================
Write-Host "`n[Test 2] Ctrl+1 toggles the disk type in Far Manager's drives menu" -ForegroundColor Yellow

$farCandidates = @(
    "$env:ProgramFiles\Far Manager\Far.exe",
    "${env:ProgramFiles(x86)}\Far Manager\Far.exe",
    "$env:LOCALAPPDATA\Programs\Far Manager\Far.exe"
)
$far = $farCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $far) {
    $cmd = Get-Command far.exe -EA SilentlyContinue
    if ($cmd) { $far = $cmd.Source }
}

if (-not $far) {
    Write-Skip "Far Manager is not installed - install it with 'winget install --id FarManager.FarManager' to run this test"
} else {
    $sess2 = "i623cd_far"
    Cleanup-Session $sess2
    $client2 = Start-Process -FilePath $PSMUX -PassThru `
        -ArgumentList "-L",$SOCK,"-f",$emptyConf,"new-session","-s",$sess2,"-x","120","-y","40","--","`"$far`""
    Start-Sleep -Seconds 9

    $screen = (& $PSMUX -L $SOCK capture-pane -p -t $sess2 2>&1 | Out-String)
    if ($screen -notmatch '1Help') {
        Write-Fail "Far did not start in the pane (no function key bar on screen)"
    } else {
        Write-Pass "Far is running in the pane"

        # Alt+F1 opens the drives menu on the left panel.
        & $injector $client2.Id "{MOD:70:0000:0002}" 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $menu = (& $PSMUX -L $SOCK capture-pane -p -t $sess2 2>&1 | Out-String)
        if ($menu -notmatch 'Change drive') {
            Write-Skip "the drives menu did not open, nothing to toggle"
        } else {
            $typeShown = ($menu -match 'fixed')
            if (-not $typeShown) {
                Write-Skip "this Far already hides the disk type, so there is nothing to toggle off"
            } else {
                Write-Pass "the drives menu is open and shows the disk type ('fixed')"

                & $injector $client2.Id "{RAW:31:0000:0008}" 2>&1 | Out-Null
                Start-Sleep -Seconds 2
                $after = (& $PSMUX -L $SOCK capture-pane -p -t $sess2 2>&1 | Out-String)
                if ($after -match 'Temporary panel \[') {
                    Write-Fail "#623: Ctrl+1 opened the Temporary panel, so Far saw a bare '1'"
                } elseif ($after -notmatch 'Change drive') {
                    Write-Fail "#623: the drives menu closed on Ctrl+1, so Far saw something else"
                } elseif ($after -match 'fixed') {
                    Write-Fail "#623: the disk type is still shown, so Ctrl+1 did nothing"
                } else {
                    Write-Pass "ONE Ctrl+1 removed the disk type column, the menu stayed open"
                }

                & $injector $client2.Id "{RAW:31:0000:0008}" 2>&1 | Out-Null
                Start-Sleep -Seconds 2
                $back = (& $PSMUX -L $SOCK capture-pane -p -t $sess2 2>&1 | Out-String)
                if ($back -match 'fixed') {
                    Write-Pass "a second Ctrl+1 brought the disk type back"
                } else {
                    Write-Fail "Ctrl+1 does not toggle: the disk type did not come back"
                }
            }

            # Escape must still close the menu on a pane now latched into win32
            # input mode, and one F1 must still open the help (the first half of
            # #623, dc6ff84 / 36bbaf7).
            & $injector $client2.Id "{ESC}" 2>&1 | Out-Null
            Start-Sleep -Milliseconds 1500
            $closed = (& $PSMUX -L $SOCK capture-pane -p -t $sess2 2>&1 | Out-String)
            if ($closed -notmatch 'Change drive') {
                Write-Pass "Escape still closes the menu after the win32 latch (#588)"
            } else {
                Write-Fail "Escape no longer reaches Far: the menu is still open"
            }

            & $injector $client2.Id "{F1}" 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            $help = (& $PSMUX -L $SOCK capture-pane -p -t $sess2 2>&1 | Out-String)
            if ($help -match 'How to use help' -or $help -match 'Help file index') {
                Write-Pass "ONE F1 still opens Far's help"
            } else {
                Write-Fail "F1 stopped opening Far's help"
            }
            & $injector $client2.Id "{ESC}" 2>&1 | Out-Null
            Start-Sleep -Milliseconds 700
        }
    }
    if ($client2 -and -not $client2.HasExited) { Stop-Process -Id $client2.Id -Force -EA SilentlyContinue }
    Cleanup-Session $sess2
}

# =============================================================================
# TEST 3: a shell pane keeps tmux's byte
# =============================================================================
Write-Host "`n[Test 3] a cooked-mode shell pane still gets tmux's standard_map byte" -ForegroundColor Yellow

$sess3 = "i623cd_sh"
Cleanup-Session $sess3
$client3 = Start-Process -FilePath $PSMUX -PassThru `
    -ArgumentList "-L",$SOCK,"-f",$emptyConf,"new-session","-s",$sess3,"-x","100","-y","30","--","cmd.exe","/k","prompt","PROBE`$G"
Start-Sleep -Seconds 5

& $PSMUX -L $SOCK has-session -t $sess3 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "shell session '$sess3' never came up"
} else {
    & $injector $client3.Id "echo A" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    & $injector $client3.Id "{RAW:31:0000:0008}" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    & $injector $client3.Id "B" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    $line = (& $PSMUX -L $SOCK capture-pane -p -t $sess3 2>&1 | Out-String)
    if ($line -match 'echo A1B') {
        Write-Pass "Ctrl+1 still types a literal 1 in a shell (tmux input-keys.c standard_map parity)"
    } else {
        Write-Fail "the shell pane changed: expected 'echo A1B' on screen"
    }
}
if ($client3 -and -not $client3.HasExited) { Stop-Process -Id $client3.Id -Force -EA SilentlyContinue }
Cleanup-Session $sess3

& $PSMUX -L $SOCK kill-server 2>&1 | Out-Null
$env:PSMUX_DATA_DIR = $savedDataDir
$env:PSMUX_NO_WARM = $savedNoWarm
$env:PSMUX_RECORD_LOG = $savedRecLog

Write-Host "`n=== Issue #623 Ctrl+digit summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
