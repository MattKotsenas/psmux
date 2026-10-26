# Issue #651: prefix + `.` had no binding, and command-prompt dropped a
# value-taking flag's value into the template.
#
# tmux binds `.` by default. Measured on the tmux tree at
# C:\Users\godwin\Documents\workspace\tmux, key-bindings.c, every release from
# 3.4 through 3.7b:
#
#     bind -N 'Move the current window' . { command-prompt -T target { move-window -t '%%' } }
#
# psmux has no `{}` command blocks, so PREFIX_DEFAULTS spells the same command
# in the quoting psmux's parser reads. Two separate defects stood between the
# key and move-window, and this suite pins both.
#
#   1. `.` was absent from PREFIX_DEFAULTS. `list-keys -T prefix` printed 63
#      bindings on 3.3.8 (cebc8cf) and none of them was `.`, so the key did
#      nothing at all: no prompt, no message.
#
#   2. Adding the line would not have helped. The client's command-prompt
#      parser consumed a value for -I and -p only; every other flag was skipped
#      WITHOUT its value, so `-T target "move-window -t '%%'"` built the
#      template `target move-window -t '%%'` and Enter sent
#      `target move-window -t '5'`, which is not a command.
#
#      Measured on cebc8cf with a real attached client and WriteConsoleInput
#      keystrokes (prefix, `.`, `5`, Enter), 3 runs each:
#
#        bind . command-prompt -T target "move-window -t '%%'"  ->  0 1 2*  (nothing moved) 3/3
#        bind . command-prompt -p index  "move-window -t '%%'"  ->  0 1 5*  (moved)         3/3
#
#      and with the leak made visible by naming a real command as the prompt
#      type, `bind . command-prompt -T display-message "move-window -t '%%'"`,
#      the client's status line printed `move-window` after Enter: the -T value
#      had become the command and the template its arguments.
#
# What move-window itself does with a resolved target is pinned by
# tests/test_issue601_602_move_swap_window.ps1. This suite covers the path from
# the key to the command line that one already covers.
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0; $script:TestsFailed = 0
$script:Opened = @()

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Head($msg) { Write-Host "`n--- $msg ---" -ForegroundColor Yellow }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan

# Inherited routing would aim every call at whatever session owns this shell.
$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION      = $null
$env:PSMUX_PANE         = $null
$env:TMUX               = $null
$env:TMUX_PANE          = $null

$NS   = "i651-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$SESS = "dot"
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_i651_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TMP | Out-Null

function P { & $PSMUX -L $NS @args 2>&1 }

# ---------------------------------------------------------------------------
# Tooling: the keystroke injector and the screen reader, both already in tests\.
# ---------------------------------------------------------------------------
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
$INJ = Join-Path $TMP "injector.exe"
$RD  = Join-Path $TMP "conread.exe"
$haveTools = $false
if ($csc -and (Test-Path $csc)) {
    & $csc /nologo /optimize /out:$INJ (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
    & $csc /nologo /optimize /out:$RD  (Join-Path $PSScriptRoot "conread.cs")  2>&1 | Out-Null
    $haveTools = (Test-Path $INJ) -and (Test-Path $RD)
}
if (-not $haveTools) { Write-Info "csc.exe or a build of injector.cs/conread.cs is unavailable; the injected key layers will be skipped" }

# ---------------------------------------------------------------------------
# Rig
# ---------------------------------------------------------------------------
function Stop-Opened {
    foreach ($id in $script:Opened) { try { Stop-Process -Id $id -Force -EA SilentlyContinue } catch {} }
    $script:Opened = @()
}

function Kill-Rig {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    Stop-Opened
    Get-ChildItem "$psmuxDir\${NS}__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}

# Launch a REAL attached client in its own console, which is the only thing the
# injector can write keys into, and wait for its socket.
function Start-Attached($configPath) {
    $env:PSMUX_CONFIG_FILE = $configPath
    $p = Start-Process -FilePath $PSMUX -ArgumentList "-L",$NS,"new-session","-s",$SESS -PassThru
    $script:Opened += $p.Id
    $portFile = Join-Path $psmuxDir "${NS}__${SESS}.port"
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path $portFile) {
            $port = (Get-Content $portFile -Raw).Trim()
            try {
                $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $t.Close()
                Start-Sleep -Milliseconds 1500
                return $p
            } catch {}
        }
    }
    return $null
}

function Invoke-Inject($procId, $keys) {
    $o = Join-Path $TMP "inj_out.txt"; $e = Join-Path $TMP "inj_err.txt"
    $ip = Start-Process -FilePath $INJ -ArgumentList "$procId",$keys -Wait -PassThru -WindowStyle Hidden `
          -RedirectStandardOutput $o -RedirectStandardError $e
    return $ip.ExitCode
}

# The status line, the prompt box and every border are drawn by the CLIENT, so
# capture-pane cannot see them. Read the client's own screen instead.
function Get-ClientScreen($procId) {
    $o = Join-Path $TMP "screen.txt"; $e = Join-Path $TMP "screen_err.txt"
    Start-Process -FilePath $RD -ArgumentList "$procId" -Wait -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
    if (Test-Path $o) { return (Get-Content $o -Raw) }
    return ""
}

function Get-Windows {
    $o = P list-windows -t $SESS -F '#{window_index}:#{window_name}#{?window_active,*,}'
    return ((($o | Out-String) -replace '\s+', ' ').Trim())
}

function Write-Conf($name, $line) {
    $f = Join-Path $TMP $name
    $line | Set-Content -Path $f -Encoding ascii
    return $f
}

# One injected run: stand up `0 1 2*`, press prefix + `.`, type $typed, Enter.
# Returns the layout before and after plus the screen while the prompt is open
# and the screen right after Enter, where the server's reply is still up.
function Invoke-DotPrompt($configPath, $typed, $finish = "{ENTER}", $selectIdx = $null) {
    Kill-Rig
    $proc = Start-Attached $configPath
    if (-not $proc) { return $null }
    P new-window -t $SESS | Out-Null
    Start-Sleep -Milliseconds 400
    P new-window -t $SESS | Out-Null
    Start-Sleep -Milliseconds 700
    if ($null -ne $selectIdx) {
        P select-window -t ("{0}:{1}" -f $SESS, $selectIdx) | Out-Null
        Start-Sleep -Milliseconds 500
    }
    $before = Get-Windows
    $keys = P list-keys -T prefix
    $dot = (@(($keys | Out-String) -split "`r?`n" | Where-Object { $_ -match '^bind-key -T prefix \. ' }) -join '')
    $rc1 = Invoke-Inject $proc.Id ("^b{SLEEP:500}.{SLEEP:600}" + $typed)
    Start-Sleep -Milliseconds 250
    $promptScreen = Get-ClientScreen $proc.Id
    $rc2 = Invoke-Inject $proc.Id $finish
    Start-Sleep -Milliseconds 250
    $afterScreen = Get-ClientScreen $proc.Id
    Start-Sleep -Milliseconds 1500
    $after = Get-Windows
    $r = @{
        before = $before; after = $after; dot = $dot
        promptScreen = $promptScreen; afterScreen = $afterScreen
        rc = "$rc1/$rc2"
    }
    Kill-Rig
    return $r
}

function Test-Moves($name, $configPath, $typed, $expectAfter) {
    Write-Head $name
    if (-not $haveTools) { Write-Info "skipped (no injector)"; return }
    $r = Invoke-DotPrompt $configPath $typed
    if (-not $r) { Write-Fail "$name : the attached client never came up"; return }
    Write-Info "list-keys: $($r.dot)"
    Write-Info "before: $($r.before)   after: $($r.after)"
    if ($r.after -eq $expectAfter) { Write-Pass "$name : $expectAfter" }
    else { Write-Fail "$name : expected '$expectAfter' but got '$($r.after)'" }
}

$EMPTY = Write-Conf "empty.conf" "# no bindings, stock defaults only"
$CT    = Write-Conf "t_target.conf"   "bind . command-prompt -T target `"move-window -t '%%'`""
$CP    = Write-Conf "p_index.conf"    "bind . command-prompt -p index `"move-window -t '%%'`""
$CTGT  = Write-Conf "t_client.conf"   "bind . command-prompt -t %1 `"move-window -t '%%'`""
$CBOOL = Write-Conf "booleans.conf"   "bind . command-prompt -1 -N -W -k `"move-window -t '%%'`""
$CINIT = Write-Conf "initial.conf"    "bind . command-prompt -p idx -I 7 `"move-window -t '%%'`""

try {
    # =======================================================================
    # 1. The default binding exists and reads like tmux's
    # =======================================================================
    Write-Head "the `.` default reaches list-keys"
    Kill-Rig
    P new-session -d -s $SESS | Out-Null
    Start-Sleep -Seconds 2
    $keys = (P list-keys -T prefix | Out-String)
    $dotLines = @($keys -split "`r?`n" | Where-Object { $_ -match '^bind-key -T prefix \. ' })
    if ($dotLines.Count -eq 1) { Write-Pass "list-keys carries one `.` binding: $($dotLines[0].Trim())" }
    else { Write-Fail "expected exactly one `.` binding in list-keys, found $($dotLines.Count)" }
    $dotLine = ($dotLines -join '')
    if ($dotLine -match 'command-prompt')  { Write-Pass "`.` runs command-prompt, as in tmux" }
    else { Write-Fail "`.` does not run command-prompt: $dotLine" }
    if ($dotLine -match '-T target')       { Write-Pass "`.` carries tmux's -T target prompt type" }
    else { Write-Fail "`.` is missing -T target: $dotLine" }
    if ($dotLine -match "move-window -t '%%'") { Write-Pass "`.`'s template is move-window -t '%%'" }
    else { Write-Fail "`.` does not template move-window: $dotLine" }
    Kill-Rig

    # =======================================================================
    # 2. The key itself, injected into a real attached client
    # =======================================================================
    Test-Moves "default binding, no config: prefix . 5 Enter" $EMPTY "5" "0:pwsh 1:pwsh 5:pwsh*"
    Test-Moves "user binding, tmux's -T target form"          $CT    "5" "0:pwsh 1:pwsh 5:pwsh*"
    Test-Moves "user binding, -p index form (worked before)"  $CP    "5" "0:pwsh 1:pwsh 5:pwsh*"

    # -t is command-prompt's other value-taking flag and sat in the same hole.
    Test-Moves "-t <client> no longer swallows the template"  $CTGT  "5" "0:pwsh 1:pwsh 5:pwsh*"

    # Booleans must not eat the template either.
    Test-Moves "-1 -N -W -k leave the template alone"         $CBOOL "5" "0:pwsh 1:pwsh 5:pwsh*"

    # =======================================================================
    # 3. Symbolic targets survive the substitution (#601/#602's resolver)
    # =======================================================================
    Test-Moves "a relative target: +1 from window 2"          $EMPTY "+1" "0:pwsh 1:pwsh 3:pwsh*"

    # =======================================================================
    # 4. An occupied index is refused, with tmux's message
    # =======================================================================
    Write-Head "an occupied index is refused and nothing moves"
    if ($haveTools) {
        $r = Invoke-DotPrompt $EMPTY "1"
        if (-not $r) { Write-Fail "the attached client never came up" }
        else {
            Write-Info "before: $($r.before)   after: $($r.after)"
            if ($r.after -eq $r.before) { Write-Pass "layout unchanged: $($r.after)" }
            else { Write-Fail "expected the layout to stay '$($r.before)' but it became '$($r.after)'" }
            if ($r.afterScreen -match 'index in use: 1') { Write-Pass "the client showed tmux's 'index in use: 1'" }
            else { Write-Fail "the client did not show 'index in use: 1'" }
        }
    } else { Write-Info "skipped (no injector)" }

    # `$` is the last window index. Standing on window 0 of `0* 1 2` that is 2,
    # which another window holds, so the refusal NAMES 2: proof that `$` reached
    # resolve_window_spec intact rather than arriving as a literal. (From window
    # 2 the same target would be the window's own slot, which is not a move and
    # not an error, so the run has to stand somewhere else.)
    Write-Head "a symbolic target reaches the resolver: `$ becomes the last index"
    if ($haveTools) {
        $r = Invoke-DotPrompt $EMPTY "`$" "{ENTER}" 0
        if (-not $r) { Write-Fail "the attached client never came up" }
        else {
            Write-Info "before: $($r.before)   after: $($r.after)"
            if ($r.after -eq $r.before) { Write-Pass "layout unchanged: $($r.after)" }
            else { Write-Fail "expected the layout to stay '$($r.before)' but it became '$($r.after)'" }
            if ($r.afterScreen -match 'index in use: 2') { Write-Pass "`$ resolved to the last index, 2" }
            else { Write-Fail "the client did not report 'index in use: 2' for `$" }
        }
    } else { Write-Info "skipped (no injector)" }

    # =======================================================================
    # 5. Escape closes the prompt without running anything
    # =======================================================================
    Write-Head "Escape closes the prompt and runs nothing"
    if ($haveTools) {
        $r = Invoke-DotPrompt $EMPTY "5" "{ESC}"
        if (-not $r) { Write-Fail "the attached client never came up" }
        else {
            Write-Info "before: $($r.before)   after: $($r.after)"
            if ($r.after -eq $r.before) { Write-Pass "Escape left the layout at $($r.after)" }
            else { Write-Fail "Escape moved a window: '$($r.before)' -> '$($r.after)'" }
        }
    } else { Write-Info "skipped (no injector)" }

    # =======================================================================
    # 6. The heading: with no -p, tmux names the command the prompt will run
    #    (cmd-command-prompt.c: xstrndup(template, strcspn(template, " ,")))
    # =======================================================================
    Write-Head "the prompt names the command it is about to run"
    if ($haveTools) {
        $r = Invoke-DotPrompt $EMPTY "5"
        if ($r -and $r.promptScreen -match '\(move-window\)') { Write-Pass "the open prompt is headed (move-window)" }
        elseif ($r) { Write-Fail "the open prompt was not headed (move-window)" }
        else { Write-Fail "the attached client never came up" }

        $r = Invoke-DotPrompt $CP "5"
        if ($r -and $r.promptScreen -match 'index') { Write-Pass "an explicit -p wins: the heading is 'index'" }
        elseif ($r) { Write-Fail "-p index did not reach the heading" }
        else { Write-Fail "the attached client never came up" }
    } else { Write-Info "skipped (no injector)" }

    # =======================================================================
    # 7. -I still preloads the prompt, and the rest of prefix still works
    # =======================================================================
    Write-Head "-I preloads the prompt (and Enter runs the preloaded value)"
    if ($haveTools) {
        # Typing nothing: the initial value 7 is what Enter substitutes.
        $r = Invoke-DotPrompt $CINIT ""
        if (-not $r) { Write-Fail "the attached client never came up" }
        else {
            Write-Info "before: $($r.before)   after: $($r.after)"
            if ($r.after -eq "0:pwsh 1:pwsh 7:pwsh*") { Write-Pass "-I 7 preloaded the prompt and moved the window to 7" }
            else { Write-Fail "expected '0:pwsh 1:pwsh 7:pwsh*' but got '$($r.after)'" }
        }
    } else { Write-Info "skipped (no injector)" }

    Write-Head "prefix + : still opens a bare prompt and runs what is typed"
    if ($haveTools) {
        Kill-Rig
        $proc = Start-Attached $EMPTY
        if (-not $proc) { Write-Fail "the attached client never came up" }
        else {
            Start-Sleep -Milliseconds 500
            $winsBefore = (P display-message -t $SESS -p '#{session_windows}' | Out-String).Trim()
            Invoke-Inject $proc.Id "^b{SLEEP:400}:{SLEEP:500}new-window{SLEEP:200}{ENTER}" | Out-Null
            Start-Sleep -Seconds 2
            $winsAfter = (P display-message -t $SESS -p '#{session_windows}' | Out-String).Trim()
            if ([int]$winsAfter -gt [int]$winsBefore) { Write-Pass "prefix + : ran new-window ($winsBefore -> $winsAfter)" }
            else { Write-Fail "prefix + : did not run the typed command ($winsBefore -> $winsAfter)" }
        }
        Kill-Rig
    } else { Write-Info "skipped (no injector)" }
}
finally {
    Kill-Rig
    Stop-Opened
    Remove-Item $TMP -Recurse -Force -EA SilentlyContinue
}

Write-Host ""
Write-Host "Passed: $script:TestsPassed  Failed: $script:TestsFailed" -ForegroundColor Cyan
exit $script:TestsFailed
