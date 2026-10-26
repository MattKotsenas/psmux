# Format modifier lists that tmux reads differently from psmux.
#
# tmux's format_build_modifiers (format.c:4790 to :4900) abandons the WHOLE
# modifier list at the first character it does not know and then looks the
# complete text up as one name; psmux used to skip the unknown segment and
# apply the rest. A modifier's arguments are wrapped in ASCII punctuation other
# than `-`; anything else after the letter is one bare argument, and `s` with
# fewer than two arguments is skipped (format.c:5857).
#
# The expected values are what tmux 3.4 printed (WSL, `display-message -p`) with
# the session named `s` and @v set to `abcdefgh aA`. When WSL tmux is present
# the suite also asks it again and reports any answer that moved.
#
# Measured on master 822bac1: 17 of the 34 specs below differ from tmux.
#
# Set PSMUX_TEST_BIN to test a binary that is not on PATH.

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$psmuxDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR } else { "$env:USERPROFILE\.psmux" }
$script:TestsPassed = 0; $script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

Write-Host "binary: $PSMUX" -ForegroundColor Cyan
Write-Host ((& $PSMUX -V) -join ' ') -ForegroundColor Cyan

$env:PSMUX_SESSION_NAME = $null; $env:PSMUX_SESSION = $null; $env:PSMUX_PANE = $null
$env:TMUX = $null; $env:TMUX_PANE = $null

$NS = "fmtpar-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$defaultBefore = ((& $PSMUX ls 2>&1) -join "`n")
function P { & $PSMUX -L $NS @args 2>&1 }

$S = [char]0x00A7   # section sign, a non ASCII "separator"
$E = [char]0x00E9   # e acute, a non ASCII "modifier"

# spec, tmux 3.4 answer
$cases = @(
    # an unknown modifier abandons the whole list
    @('#{t;Z:session_name}', ''),
    @("#{t;${E}:session_name}", ''),
    @('#{t;Z;s/s/X/:session_name}', ''),
    @('#{=5;Q:@v}', ''),
    @('#{Z:session_name}', ''),
    @('#{window_name:x}', ''),
    @('#{=#{@n}:@v}', '=3:@v'),
    # a wrapper must be ASCII punctuation other than -
    @('#{sXsXYX:session_name}', 's'),
    @("#{s${S}s${S}X${S}:session_name}", 's'),
    @('#{s0s0X0:session_name}', 's'),
    @('#{s s X :session_name}', 's'),
    @('#{sXaXbX:@v}', 'abcdefgh aA'),
    @('#{s-a-b-:@v}', 'abcdefgh aA'),
    @('#{eXaX:1,2}', ''),
    # s without its arguments is skipped
    @('#{s:session_name}', 's'),
    @('#{s;=1:@v}', 'a'),
    # empty lists
    @('#{:session_name}', 's'),
    @('#{;:session_name}', 's'),
    @('#{;;:session_name}', ''),
    @('#{;l:session_name}', 'session_name'),
    # valid lists keep their answers
    @('#{s/s/X/:session_name}', 'X'),
    @('#{s|s|X|:session_name}', 'X'),
    @('#{=2:session_name}', 's'),
    @('#{e|+|:1,2}', '3'),
    @('#{e|*|:3,4}', '12'),
    @('#{e|+|f|2:1.5,2}', '3.50'),
    @('#{l;:session_name}', 'session_name'),
    @('#{l::session_name}', ':session_name'),
    @('#{s/a/b/;=3:@v}', 'bbc'),
    @('#{q:@v}', 'abcdefgh\ aA'),
    @('#{=/2/...:@v}', 'ab...'),
    @('#{p-5:session_name}', '    s'),
    @('#{m:s*,session_name}', '1'),
    @('#{session_name:}', '')
)

# Ask WSL tmux too, when it is there, so a drift in the recorded answers shows.
$live = @{}
$haveWsl = $false
try { $v = (wsl -e tmux -V 2>$null); if ($LASTEXITCODE -eq 0 -and $v -match 'tmux') { $haveWsl = $true } } catch {}
if ($haveWsl) {
    $sock = "fmtpar_wsl_" + [guid]::NewGuid().ToString('N').Substring(0, 6)
    wsl -e tmux -L $sock -f /dev/null new-session -d -s s -x 80 -y 24 2>$null
    wsl -e tmux -L $sock set -g '@v' 'abcdefgh aA' 2>$null
    wsl -e tmux -L $sock set -g '@n' 3 2>$null
    foreach ($c in $cases) {
        $live[$c[0]] = ((wsl -e env LANG=C.UTF-8 LC_ALL=C.UTF-8 tmux -L $sock display-message -t s -p $c[0] 2>&1) -join "`n")
    }
    wsl -e tmux -L $sock kill-server 2>$null
    Write-Info "WSL $v answered the same specs live"
}

P new-session -d -s s -x 80 -y 24 | Out-Null
Start-Sleep -Milliseconds 1500
P set -g '@v' 'abcdefgh aA' | Out-Null
P set -g '@n' 3 | Out-Null

foreach ($c in $cases) {
    $spec = $c[0]; $want = $c[1]
    if ($haveWsl -and $live.ContainsKey($spec) -and $live[$spec] -cne $want) {
        Write-Info "WSL tmux now prints [$($live[$spec])] for $spec (recorded [$want])"
    }
    $got = ((P display-message -t s -p $spec) -join "`n")
    if ($got -ceq $want) { Write-Pass "$spec -> [$got]" }
    else { Write-Fail "$spec -> psmux [$got], tmux [$want]" }
}

P kill-server | Out-Null
Start-Sleep -Milliseconds 500
Get-ChildItem "$psmuxDir\${NS}__*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
$defaultAfter = ((& $PSMUX ls 2>&1) -join "`n")
if ($defaultAfter -ne $defaultBefore) { Write-Fail "the DEFAULT namespace changed while this ran" }

Write-Host ""
Write-Host "Passed: $script:TestsPassed  Failed: $script:TestsFailed" `
    -ForegroundColor $(if ($script:TestsFailed -eq 0) { 'Green' } else { 'Red' })
exit $(if ($script:TestsFailed -eq 0) { 0 } else { 1 })
