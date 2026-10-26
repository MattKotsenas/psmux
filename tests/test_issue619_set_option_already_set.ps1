# Issue #619, the two residual set-option parity gaps found while fixing item 2.
#
# GAP A: `set-option -o <opt> <val>` on an option that is ALREADY set was
# refused in complete silence: exit code 0, empty stdout, empty stderr, value
# untouched, on the CLI route, the raw TCP route, the config-file route and the
# in-TUI command prompt alike. Measured on the unfixed tree (eb627b4):
#
#     $ psmux set-option -g  -t S escape-time 11
#     $ psmux set-option -go -t S escape-time 22
#     rc=0 stdout=[] stderr=[]   escape-time still 11
#
# tmux fails it and names the option (cmd-set-option.c):
#
#     if (!args_has(args, 'u') && args_has(args, 'o')) {
#             if (array_key == NULL)
#                     already = (o != NULL);
#             ...
#             if (already) {
#                     if (args_has(args, 'q'))
#                             goto out;
#                     cmdq_error(item, "already set: %s", argument);
#                     goto fail;
#             }
#     }
#
# so it is `already set: <name>` on stderr at exit 1, and a silent exit 0 only
# under `-q`. Being silent in BOTH cases makes `-o` useless for the one job it
# exists to do: a caller seeding a default it does not want to clobber cannot
# tell "I set it" from "the user already had it".
#
# GAP B: `set-option -u` did not restore the table default. tmux funnels every
# unset through options_remove_or_default (options.c ~1457), which restores the
# options-table default for a table option at a global scope and removes a user
# option outright. psmux open coded the unset in three places, each wrong in its
# own way, and on the unfixed tree 37 of 42 probed options did not come back to
# the value a freshly started server reports. `set -s default-terminal
# xterm-256color` then `set -su default-terminal` still read xterm-256color, and
# `set -gu status-left` restored `psmux:#I` where a fresh server reports `[#S] `.
#
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue619_set_option_already_set.ps1

$ErrorActionPreference = "Continue"

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -EA SilentlyContinue).Path }
if (-not $PSMUX) { $c = Get-Command psmux -EA SilentlyContinue; if ($c) { $PSMUX = $c.Source } }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$SESSION   = "test_i619b"
$FRESH     = "test_i619bfresh"
$CFGSESS   = "test_i619bcfg"
$TUISESS   = "test_i619btui"
$PSMUX_DIR = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor Gray }

# Run psmux with an exact argv (no shell re-tokenizing) and capture rc/out/err.
$script:OutFile = Join-Path $env:TEMP "t619b_out.txt"
$script:ErrFile = Join-Path $env:TEMP "t619b_err.txt"
function Invoke-Psmux([string[]]$ArgList) {
    $proc = Start-Process -FilePath $PSMUX -ArgumentList $ArgList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $script:OutFile -RedirectStandardError $script:ErrFile
    [pscustomobject]@{
        rc  = $proc.ExitCode
        out = "$(Get-Content $script:OutFile -Raw -ErrorAction SilentlyContinue)".Trim()
        err = "$(Get-Content $script:ErrFile -Raw -ErrorAction SilentlyContinue)".Trim()
    }
}
# Session-creating calls run WITHOUT redirection: the detached server inherits
# the redirected handles and the next redirected call then fights it for them.
function New-PsmuxSession($name) { & $PSMUX new-session -d -s $name 2>&1 | Out-Null }
function Remove-PsmuxSession($name) { & $PSMUX kill-session -t $name 2>&1 | Out-Null }

function Read-Opt($sess, $name) { (Invoke-Psmux @('show-options','-qv','-t',$sess,$name)).out }

# Raw TCP straight to the server, bypassing the CLI guard entirely, so the
# server-side request handler is measured on its own.
function Send-TcpCommand {
    param([string]$Session, [string]$Command, [int]$TimeoutMs = 5000)
    try {
        $port = (Get-Content "$PSMUX_DIR\$Session.port" -Raw).Trim()
        $key  = (Get-Content "$PSMUX_DIR\$Session.key" -Raw).Trim()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.NoDelay = $true
        $tcp.Connect("127.0.0.1", [int]$port)
        $ns = $tcp.GetStream()
        $ns.ReadTimeout = $TimeoutMs
        $wr = New-Object System.IO.StreamWriter($ns); $wr.AutoFlush = $true
        $rd = New-Object System.IO.StreamReader($ns)
        $wr.WriteLine("AUTH $key")
        $auth = $rd.ReadLine()
        if ($auth -ne "OK") { $tcp.Close(); return @{ ok=$false; err="AUTH_FAIL" } }
        $wr.WriteLine($Command)
        $lines = @()
        try {
            while ($true) {
                $line = $rd.ReadLine()
                if ($null -eq $line) { break }
                $lines += $line
                # Read to EOF: a one-shot reply ends when the server closes the
                # connection (ReadLine returns null), bounded by ReadTimeout. A quiet
                # socket is not the end of a reply.
            }
        } catch {}
        $tcp.Close()
        return @{ ok=$true; resp=($lines -join "`n"); lines=$lines }
    } catch { return @{ ok=$false; err=$_.Exception.Message } }
}

function Wait-SessionReady([string]$Name, [int]$TimeoutMs = 25000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Invoke-Psmux @('has-session','-t',$Name)).rc -eq 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

$env:PSMUX_NO_WARM = "1"
$env:PSMUX_SESSION_NAME = $null

Write-Host "`n=== Issue #619: set-option -o refusal and -u default restore ===" -ForegroundColor Cyan
Write-Info "Binary: $PSMUX"

foreach ($s in @($SESSION, $FRESH, $CFGSESS, $TUISESS)) { Remove-PsmuxSession $s }
Start-Sleep -Milliseconds 800

New-PsmuxSession $SESSION
New-PsmuxSession $FRESH
if (-not (Wait-SessionReady $SESSION)) { Write-Fail "session creation failed"; exit 1 }
if (-not (Wait-SessionReady $FRESH))   { Write-Fail "reference session creation failed"; exit 1 }

# Every "what should -u restore" assertion below is measured against a session
# that was never touched, so the expected value is literally "what a fresh
# server reports" rather than a hand transcribed default that can drift. The
# snapshot is taken ONCE and the reference session is then closed: holding it
# open for the whole run made the suite depend on nothing else on the machine
# reaping it.
$OptionNames = @(
    'escape-time','history-limit','display-time','display-panes-time','repeat-time',
    'status-interval','status-left-length','status-right-length','base-index',
    'pane-base-index','main-pane-width','main-pane-height','monitor-silence','mouse',
    'focus-events','visual-bell','allow-rename','monitor-activity','aggressive-resize',
    'synchronize-panes','set-titles','renumber-windows','mode-keys','status-justify',
    'status-position','bell-action','activity-action','silence-action','set-clipboard',
    'window-size','pane-border-lines','copy-mode-line-numbers','status-left',
    'word-separators','set-titles-string','status-style','message-style','mode-style',
    'window-status-style','window-status-current-style','window-status-activity-style',
    'pane-active-border-style','window-status-separator','default-terminal'
)
$FreshValues = @{}
foreach ($n in $OptionNames) { $FreshValues[$n] = Read-Opt $FRESH $n }
Remove-PsmuxSession $FRESH

# A snapshot that came back blank means the reference session was already gone,
# and every comparison below would be meaningless rather than failing honestly.
# window-status-separator is the one option here whose real default is a single
# space, which Read-Opt trims to nothing, so it is not evidence of a loss.
$blank = $OptionNames |
         Where-Object { $_ -ne 'window-status-separator' } |
         Where-Object { $FreshValues[$_] -eq '' }
if ($blank.Count -gt 0) {
    Write-Fail "the fresh-server snapshot is empty for: $($blank -join ', ') (reference session lost)"
    exit 1
}
Write-Info "fresh-server snapshot taken for $($OptionNames.Count) options (escape-time=$($FreshValues['escape-time']), status-left=[$($FreshValues['status-left'])])"

# ---------------------------------------------------------------------------
# Arm 1 (GAP A, CLI): -o on an option that is already set must FAIL and say so.
# ---------------------------------------------------------------------------
Write-Host "[Arm 1] GAP A, CLI: already set is an error" -ForegroundColor Yellow

function Test-AlreadySet {
    param([string]$Label, [string]$Verb, [string]$SetFlag, [string]$Option,
          [string]$First, [string]$Second)
    Invoke-Psmux @($Verb, $SetFlag, '-t', $SESSION, $Option, $First) | Out-Null
    $before = Read-Opt $SESSION $Option
    $r = Invoke-Psmux @($Verb, ($SetFlag + 'o'), '-t', $SESSION, $Option, $Second)
    $after = Read-Opt $SESSION $Option
    Write-Info "$Label : rc=$($r.rc) stderr=[$($r.err)] value [$before] -> [$after]"
    if ($r.rc -eq 1 -and $r.err -eq "already set: $Option") {
        Write-Pass "$Label : rc 1 with the tmux message 'already set: $Option'"
    } else {
        Write-Fail "$Label : expected rc 1 and 'already set: $Option', got rc=$($r.rc) stderr=[$($r.err)]"
    }
    if ($after -eq $before) {
        Write-Pass "$Label : the refused -o left the value at [$after]"
    } else {
        Write-Fail "$Label : the refused -o changed the value to [$after]"
    }
}

Test-AlreadySet -Label "int escape-time"    -Verb 'set-option'        -SetFlag '-g' -Option 'escape-time'   -First '11'     -Second '22'
Test-AlreadySet -Label "string status-left" -Verb 'set-option'        -SetFlag '-g' -Option 'status-left'   -First 'AAA'    -Second 'ZZZ'
Test-AlreadySet -Label "style status-style" -Verb 'set-option'        -SetFlag '-g' -Option 'status-style'  -First 'fg=red' -Second 'fg=blue'
Test-AlreadySet -Label "@user option"       -Verb 'set-option'        -SetFlag '-g' -Option '@i619bu'       -First 'one'    -Second 'two'
Test-AlreadySet -Label "setw window option" -Verb 'setw'              -SetFlag '-g' -Option 'window-status-separator' -First 'XX' -Second 'YY'
Test-AlreadySet -Label "set-window-option"  -Verb 'set-window-option' -SetFlag '-g' -Option 'window-status-format'    -First 'PP' -Second 'QQ'
Test-AlreadySet -Label "server scope -s"    -Verb 'set-option'        -SetFlag '-s' -Option 'default-terminal' -First 'screen-256color' -Second 'tmux-256color'

# -q keeps tmux's silent exit 0.
Invoke-Psmux @('set-option','-g','-t',$SESSION,'escape-time','11') | Out-Null
$r = Invoke-Psmux @('set-option','-goq','-t',$SESSION,'escape-time','33')
$v = Read-Opt $SESSION 'escape-time'
if ($r.rc -eq 0 -and $r.err -eq '' -and $r.out -eq '' -and $v -eq '11') {
    Write-Pass "-q keeps the refusal silent at rc 0 and leaves escape-time at 11"
} else {
    Write-Fail "-goq: rc=$($r.rc) stdout=[$($r.out)] stderr=[$($r.err)] value=[$v]"
}

# -o on a never-set option still applies, at rc 0 with no output.
$r = Invoke-Psmux @('set-option','-go','-t',$SESSION,'@i619bfresh','freshvalue')
$v = Read-Opt $SESSION '@i619bfresh'
if ($r.rc -eq 0 -and $r.err -eq '' -and $v -eq 'freshvalue') {
    Write-Pass "-o on a never-set option applies at rc 0 with no output"
} else {
    Write-Fail "-o on a fresh option: rc=$($r.rc) stderr=[$($r.err)] value=[$v]"
}

# -u disarms the guard: tmux skips the -o check whenever -u is present, so this
# is an unset, never an "already set" failure.
Invoke-Psmux @('set-option','-g','-t',$SESSION,'status-left','PRE') | Out-Null
$r = Invoke-Psmux @('set-option','-guo','-t',$SESSION,'status-left','NEVER')
$v = Read-Opt $SESSION 'status-left'
if ($r.rc -eq 0 -and $r.err -eq '' -and $v -ne 'NEVER') {
    Write-Pass "-u in the same token disarms the -o guard: rc 0, no error, value [$v]"
} else {
    Write-Fail "-guo: rc=$($r.rc) stderr=[$($r.err)] value=[$v]"
}

# ---------------------------------------------------------------------------
# Arm 2 (GAP A, raw TCP): the server request handler answers on its own.
# ---------------------------------------------------------------------------
Write-Host "[Arm 2] GAP A, raw TCP to the server" -ForegroundColor Yellow

$t = Send-TcpCommand $SESSION 'set-option -g @i619btcp one'
if (-not $t.ok) {
    Write-Fail "TCP connect failed: $($t.err)"
} else {
    Start-Sleep -Milliseconds 300
    $t = Send-TcpCommand $SESSION 'set-option -go @i619btcp two'
    Start-Sleep -Milliseconds 300
    $v = "$((Send-TcpCommand $SESSION 'show-options -qv @i619btcp').resp)".Trim()
    if ("$($t.resp)".Trim() -eq 'ERROR: already set: @i619btcp') {
        Write-Pass "TCP: the server replies 'ERROR: already set: @i619btcp'"
    } else {
        Write-Fail "TCP: reply was [$("$($t.resp)".Trim())]"
    }
    if ($v -eq 'one') { Write-Pass "TCP: the refused -o left the value at one" }
    else { Write-Fail "TCP: value is [$v], expected one" }

    Send-TcpCommand $SESSION 'set-option -g escape-time 44' | Out-Null
    Start-Sleep -Milliseconds 300
    $t = Send-TcpCommand $SESSION 'set-option -goq escape-time 55'
    Start-Sleep -Milliseconds 300
    $v = "$((Send-TcpCommand $SESSION 'show-options -qv escape-time').resp)".Trim()
    if ("$($t.resp)".Trim() -eq '' -and $v -eq '44') {
        Write-Pass "TCP: -q refusal is silent and the value stayed 44"
    } else {
        Write-Fail "TCP -goq: reply=[$("$($t.resp)".Trim())] value=[$v]"
    }
}

# ---------------------------------------------------------------------------
# Arm 3 (GAP B, CLI): -u restores the value a fresh server reports.
# ---------------------------------------------------------------------------
Write-Host "[Arm 3] GAP B, CLI: -u restores the fresh-server default" -ForegroundColor Yellow

# One probe value per option, spanning int, bool, choice, string, style, window
# options and the server-scope options #618 added. Each expected result comes
# from the fresh-server snapshot above.
$unsetCases = @(
    @{ o='escape-time';                  v='5'      },
    @{ o='history-limit';                v='1234'   },
    @{ o='display-time';                 v='222'    },
    @{ o='display-panes-time';           v='4321'   },
    @{ o='repeat-time';                  v='321'    },
    @{ o='status-interval';              v='42'     },
    @{ o='status-left-length';           v='99'     },
    @{ o='status-right-length';          v='98'     },
    @{ o='base-index';                   v='7'      },
    @{ o='pane-base-index';              v='7'      },
    @{ o='main-pane-width';              v='55'     },
    @{ o='main-pane-height';             v='44'     },
    @{ o='monitor-silence';              v='9'      },
    @{ o='mouse';                        v='off'    },
    @{ o='focus-events';                 v='on'     },
    @{ o='visual-bell';                  v='on'     },
    @{ o='allow-rename';                 v='off'    },
    @{ o='monitor-activity';             v='on'     },
    @{ o='aggressive-resize';            v='on'     },
    @{ o='synchronize-panes';            v='on'     },
    @{ o='set-titles';                   v='on'     },
    @{ o='renumber-windows';             v='on'     },
    @{ o='mode-keys';                    v='vi'     },
    @{ o='status-justify';               v='centre' },
    @{ o='status-position';              v='top'    },
    @{ o='bell-action';                  v='none'   },
    @{ o='activity-action';              v='none'   },
    @{ o='silence-action';               v='none'   },
    @{ o='set-clipboard';                v='off'    },
    @{ o='window-size';                  v='manual' },
    @{ o='pane-border-lines';            v='double' },
    @{ o='copy-mode-line-numbers';       v='absolute' },
    @{ o='status-left';                  v='AAA'    },
    @{ o='word-separators';              v='xyz'    },
    @{ o='set-titles-string';            v='ZZZ'    },
    @{ o='status-style';                 v='fg=red' },
    @{ o='message-style';                v='fg=red' },
    @{ o='mode-style';                   v='fg=red' },
    @{ o='window-status-style';          v='fg=red' },
    @{ o='window-status-current-style';  v='fg=red' },
    @{ o='window-status-activity-style'; v='fg=red' },
    @{ o='pane-active-border-style';     v='fg=red' },
    @{ o='window-status-separator';      v='XX'     },
    @{ o='default-terminal';             v='screen-256color' }
)

$restoreBad = 0
foreach ($c in $unsetCases) {
    $fresh = $FreshValues[$c.o]
    Invoke-Psmux @('set-option','-g','-t',$SESSION,$c.o,$c.v) | Out-Null
    $set = Read-Opt $SESSION $c.o
    Invoke-Psmux @('set-option','-gu','-t',$SESSION,$c.o) | Out-Null
    $after = Read-Opt $SESSION $c.o
    if ($after -eq $fresh) {
        $restoreBad += 0
    } else {
        $restoreBad++
        Write-Info "  MISMATCH $($c.o): fresh=[$fresh] set=[$set] after-u=[$after]"
    }
}
if ($restoreBad -eq 0) {
    Write-Pass "all $($unsetCases.Count) options come back to the fresh-server value after -u"
} else {
    Write-Fail "$restoreBad of $($unsetCases.Count) options did not come back to the fresh-server value"
}

# The two options this used to get outright wrong, named so a regression points
# at itself rather than at a count.
Invoke-Psmux @('set-option','-g','-t',$SESSION,'status-left','AAA') | Out-Null
Invoke-Psmux @('set-option','-gu','-t',$SESSION,'status-left') | Out-Null
$v = Read-Opt $SESSION 'status-left'
$f = $FreshValues['status-left']
if ($v -eq $f) { Write-Pass "status-left restores to the fresh value [$v], not psmux:#I" }
else { Write-Fail "status-left restored to [$v], a fresh server reports [$f]" }

Invoke-Psmux @('set-option','-s','-t',$SESSION,'default-terminal','screen-256color') | Out-Null
Invoke-Psmux @('set-option','-su','-t',$SESSION,'default-terminal') | Out-Null
$v = Read-Opt $SESSION 'default-terminal'
if ($v -eq 'xterm-256color') { Write-Pass "server scope: set -su default-terminal restores xterm-256color" }
else { Write-Fail "set -su default-terminal left [$v]" }

# A @user option is REMOVED, not defaulted (it has no table entry in tmux).
Invoke-Psmux @('set-option','-g','-t',$SESSION,'@i619brm','x') | Out-Null
Invoke-Psmux @('set-option','-gu','-t',$SESSION,'@i619brm') | Out-Null
$r = Invoke-Psmux @('set-option','-go','-t',$SESSION,'@i619brm','y')
$v = Read-Opt $SESSION '@i619brm'
if ($r.rc -eq 0 -and $v -eq 'y') { Write-Pass "a @user option is removed by -u, so a later -o applies" }
else { Write-Fail "@user option after -u then -o: rc=$($r.rc) value=[$v]" }

# ---------------------------------------------------------------------------
# Arm 4 (GAP B, raw TCP): the server request loop restores too.
# ---------------------------------------------------------------------------
Write-Host "[Arm 4] GAP B, raw TCP" -ForegroundColor Yellow

Send-TcpCommand $SESSION 'set-option -g status-style fg=magenta' | Out-Null
Start-Sleep -Milliseconds 300
Send-TcpCommand $SESSION 'set-option -gu status-style' | Out-Null
Start-Sleep -Milliseconds 400
$v = "$((Send-TcpCommand $SESSION 'show-options -qv status-style').resp)".Trim()
$f = $FreshValues['status-style']
if ($v -eq $f) { Write-Pass "TCP: -gu status-style restores [$v]" }
else { Write-Fail "TCP: status-style after -gu is [$v], a fresh server reports [$f]" }

Send-TcpCommand $SESSION 'set-option -g base-index 7' | Out-Null
Start-Sleep -Milliseconds 300
Send-TcpCommand $SESSION 'set-option -gu base-index' | Out-Null
Start-Sleep -Milliseconds 400
$v = "$((Send-TcpCommand $SESSION 'show-options -qv base-index').resp)".Trim()
if ($v -eq '0') { Write-Pass "TCP: -gu base-index restores 0" }
else { Write-Fail "TCP: base-index after -gu is [$v], expected 0" }

# ---------------------------------------------------------------------------
# Arm 5: the config-file route, which is a separate parser
# (src/config.rs parse_set_option).
# ---------------------------------------------------------------------------
Write-Host "[Arm 5] config file route" -ForegroundColor Yellow

$conf = Join-Path $env:TEMP "psmux_619b.conf"
@"
set -g escape-time 5
set -gu escape-time
set -g status-left AAA
set -gu status-left
set -g status-style fg=red
set -gu status-style
set -g history-limit 1234
set -gu history-limit
set -s default-terminal screen-256color
set -su default-terminal
set -g display-panes-time 4321
set -gu display-panes-time
set -g word-separators xyz
set -gu word-separators
set -g base-index 7
set -gu base-index
set -g repeat-time 11
set -go repeat-time 22
set -g @i619bc keep
set -go @i619bc clobber
set -g mouse off
set -goq mouse on
"@ | Set-Content -Path $conf -Encoding ASCII

Remove-PsmuxSession $CFGSESS
$env:PSMUX_CONFIG_FILE = $conf
New-PsmuxSession $CFGSESS
$ready = Wait-SessionReady $CFGSESS
Remove-Item env:PSMUX_CONFIG_FILE -ErrorAction SilentlyContinue

if (-not $ready) {
    Write-Fail "config-file session did not start"
} else {
    Start-Sleep -Milliseconds 900
    # GAP B through the config parser: every -u lands the fresh-server value.
    foreach ($n in @('escape-time','status-left','status-style','history-limit',
                     'default-terminal','display-panes-time','word-separators','base-index')) {
        $got = Read-Opt $CFGSESS $n
        $want = $FreshValues[$n]
        if ($got -eq $want) { Write-Pass "config: -gu $n restored [$got]" }
        else { Write-Fail "config: $n after -gu is [$got], a fresh server reports [$want]" }
    }
    # GAP A through the config parser: the -o is refused and the value stands.
    $v = Read-Opt $CFGSESS 'repeat-time'
    if ($v -eq '11') { Write-Pass "config: -go on a set option kept repeat-time at 11" }
    else { Write-Fail "config: repeat-time is [$v], expected 11" }
    $v = Read-Opt $CFGSESS '@i619bc'
    if ($v -eq 'keep') { Write-Pass "config: -go on a set @user option kept it at keep" }
    else { Write-Fail "config: @i619bc is [$v], expected keep" }
    $v = Read-Opt $CFGSESS 'mouse'
    if ($v -eq 'off') { Write-Pass "config: -goq on a set option kept mouse off" }
    else { Write-Fail "config: mouse is [$v], expected off" }

    # ...and it is LOGGED, the way "unknown option" is (#606, #370).
    $logs = @("$PSMUX_DIR\config-warnings.log", "$env:USERPROFILE\.psmux\config-warnings.log") |
            Sort-Object -Unique
    $found = $false
    $seen = @()
    foreach ($lp in $logs) {
        if (Test-Path $lp) {
            $txt = "$(Get-Content $lp -Raw -ErrorAction SilentlyContinue)"
            $seen += $lp
            if ($txt -match 'already set: repeat-time') { $found = $true }
        }
    }
    if ($found) {
        Write-Pass "config-warnings.log records 'already set: repeat-time'"
    } else {
        Write-Fail "no 'already set: repeat-time' in config-warnings.log (looked at: $($seen -join ', '))"
    }
    # -q must NOT be logged.
    $quietLogged = $false
    foreach ($lp in $seen) {
        if ("$(Get-Content $lp -Raw -ErrorAction SilentlyContinue)" -match 'already set: mouse') { $quietLogged = $true }
    }
    if (-not $quietLogged) { Write-Pass "the -goq refusal is not logged, matching tmux's -q" }
    else { Write-Fail "the -goq refusal was logged; -q asked for silence" }
}
Remove-PsmuxSession $CFGSESS

# ---------------------------------------------------------------------------
# Arm 6 (Layer 2, Win32 TUI): the same behaviour against a REAL attached client
# in its own console window, driven by CLI and read back through
# display-message so the value is proven live in the server that client is
# talking to, not just in a one-shot CLI round trip.
# ---------------------------------------------------------------------------
Write-Host "[Arm 6] attached client (Win32 TUI visual verification)" -ForegroundColor Yellow

# A .cmd wrapper, because the agent shell exports PSMUX_SESSION_NAME and the
# launched client would otherwise route into the wrong session.
$launcher = Join-Path $env:TEMP "psmux_619b_launch.cmd"
@"
@echo off
set PSMUX_SESSION_NAME=
set PSMUX_NO_WARM=1
"$PSMUX" new-session -s %1 -x 120 -y 30
"@ | Set-Content -Path $launcher -Encoding ASCII

$client = Start-Process -FilePath $launcher -ArgumentList @($TUISESS) -PassThru
if (-not (Wait-SessionReady $TUISESS 30000)) {
    Write-Fail "attached client never came up"
} else {
    Start-Sleep -Seconds 3

    # GAP A on the live client: -o on a set option fails and the live server
    # still reports the original value through the format engine.
    Invoke-Psmux @('set-option','-g','-t',$TUISESS,'@i619btui','one') | Out-Null
    Start-Sleep -Milliseconds 500
    $r = Invoke-Psmux @('set-option','-go','-t',$TUISESS,'@i619btui','two')
    Start-Sleep -Milliseconds 700
    $dm = Invoke-Psmux @('display-message','-t',$TUISESS,'-p','#{@i619btui}')
    if ($r.rc -eq 1 -and $r.err -eq 'already set: @i619btui' -and $dm.out -eq 'one') {
        Write-Pass "attached client: -o refused with rc 1, display-message still reports one"
    } else {
        Write-Fail "TUI -o refusal: rc=$($r.rc) stderr=[$($r.err)] display-message=[$($dm.out)]"
    }

    # A built-in option, read back the same way.
    Invoke-Psmux @('set-option','-g','-t',$TUISESS,'status-left','LIVE') | Out-Null
    Start-Sleep -Milliseconds 500
    $r = Invoke-Psmux @('set-option','-go','-t',$TUISESS,'status-left','CLOBBER')
    Start-Sleep -Milliseconds 700
    $dm = Invoke-Psmux @('display-message','-t',$TUISESS,'-p','#{status-left}')
    if ($r.rc -eq 1 -and $r.err -eq 'already set: status-left' -and $dm.out -eq 'LIVE') {
        Write-Pass "attached client: status-left survived the refused -o (display-message: [$($dm.out)])"
    } else {
        Write-Fail "TUI status-left: rc=$($r.rc) stderr=[$($r.err)] display-message=[$($dm.out)]"
    }

    # GAP B on the live client: -u restores the fresh-server value, and the
    # live client agrees through display-message.
    Invoke-Psmux @('set-option','-g','-t',$TUISESS,'status-left','TEMP') | Out-Null
    Start-Sleep -Milliseconds 400
    Invoke-Psmux @('set-option','-gu','-t',$TUISESS,'status-left') | Out-Null
    Start-Sleep -Milliseconds 700
    $dm = Invoke-Psmux @('display-message','-t',$TUISESS,'-p','#{status-left}')
    $f = $FreshValues['status-left']
    if ($dm.out -eq $f) {
        Write-Pass "attached client: -u restored status-left to the fresh value, live (display-message: [$($dm.out)])"
    } else {
        Write-Fail "TUI status-left after -u: display-message=[$($dm.out)], fresh server reports [$f]"
    }

    Invoke-Psmux @('set-option','-g','-t',$TUISESS,'status-style','fg=magenta') | Out-Null
    Start-Sleep -Milliseconds 400
    Invoke-Psmux @('set-option','-gu','-t',$TUISESS,'status-style') | Out-Null
    Start-Sleep -Milliseconds 700
    $v = Read-Opt $TUISESS 'status-style'
    $f = $FreshValues['status-style']
    if ($v -eq $f) {
        Write-Pass "attached client: -u restored the status bar style to [$v], the bar is repainted stock"
    } else {
        Write-Fail "TUI status-style after -u: [$v], fresh server reports [$f]"
    }

    # And the #619 item 2 contract still holds on the live client: -u then -o
    # applies, at rc 0 with no error.
    Invoke-Psmux @('set-option','-g','-t',$TUISESS,'@i619btui2','one') | Out-Null
    Invoke-Psmux @('set-option','-gu','-t',$TUISESS,'@i619btui2') | Out-Null
    $r = Invoke-Psmux @('set-option','-go','-t',$TUISESS,'@i619btui2','two')
    Start-Sleep -Milliseconds 700
    $dm = Invoke-Psmux @('display-message','-t',$TUISESS,'-p','#{@i619btui2}')
    if ($r.rc -eq 0 -and $r.err -eq '' -and $dm.out -eq 'two') {
        Write-Pass "attached client: -u then -o applies at rc 0, display-message reports two"
    } else {
        Write-Fail "TUI -u then -o: rc=$($r.rc) stderr=[$($r.err)] display-message=[$($dm.out)]"
    }
}

Remove-PsmuxSession $TUISESS
Start-Sleep -Milliseconds 500
# Stop only the client we launched, by PID. Never a blanket kill by name.
if ($client -and -not $client.HasExited) {
    try { Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue } catch {}
}

Remove-PsmuxSession $SESSION

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
