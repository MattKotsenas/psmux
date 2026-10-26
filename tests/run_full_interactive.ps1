# Run the FULL psmux test suite in a dedicated console.
#
# WHY A SEPARATE CONSOLE: many suites launch an ATTACHED psmux client and some
# drive it with real keystrokes (WriteConsoleInput via AttachConsole). Those need
# a real console of their own, and they will happily kill whatever console they
# are attached to. Running them inside an agent/tool shell both breaks the tests
# (no window to find, see test_config_exhaustive_tui) and can take the caller's
# terminal down with it.
#
# WHY THE ENVIRONMENT IS SCRUBBED: 22 suites shell out to claude.exe. Launched
# from inside a Claude Code session the child inherits CLAUDE_CODE_CHILD_SESSION
# and is treated as a nested child with its teammate toolset suppressed, which is
# the harness leaking its identity into the product under test. NO_COLOR is worse:
# it silently fakes a machine wide colour regression across a dozen suites and
# defeats bisection, because every side of every A/B inherits it equally.
#
# Test discovery is a glob over tests\test_*.ps1, so any NEW test file is picked
# up automatically with no registration step and nothing is filtered out.
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Forward)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$lockFile = Join-Path $env:TEMP 'psmux-testrun.lock'

# ---------------------------------------------------------------------------
# Single instance guard.
#
# The runner kills ALL psmux processes and wipes ~/.psmux between every test, so
# two concurrent runs destroy each other's sessions mid test and emit a stream of
# bogus failures that look exactly like product bugs. That happened once here and
# cost a full triage cycle, so a second run is refused rather than allowed to
# corrupt both.
#
# The guard is a pid anchor, NOT a command line search. Searching for pwsh
# processes whose command line mentions run_all_tests matches any shell that
# merely NAMES the runner, including the monitoring commands used to watch a run
# in progress, and a false positive here refuses every future run permanently.
# Anchoring on pid plus process start time is exactly how psmux validates its own
# .pid files, and it cannot be fooled by a recycled pid.
# ---------------------------------------------------------------------------
function Test-RunActive {
    if (-not (Test-Path $lockFile)) { return $null }
    $raw = (Get-Content $lockFile -Raw -EA SilentlyContinue)
    if (-not $raw) { return $null }
    $parts = $raw.Trim() -split ':'
    if ($parts.Count -ne 2) { return $null }
    $pidVal = 0; $ticks = 0L
    if (-not [int]::TryParse($parts[0], [ref]$pidVal))   { return $null }
    if (-not [long]::TryParse($parts[1], [ref]$ticks))   { return $null }
    $p = Get-Process -Id $pidVal -EA SilentlyContinue
    if (-not $p) { return $null }                        # dead: stale lock
    if ($p.StartTime.Ticks -ne $ticks) { return $null }  # pid recycled: stale lock
    return $p
}

$active = Test-RunActive
if ($active) {
    Write-Host ''
    Write-Host 'REFUSING TO START: a psmux test run is already active.' -ForegroundColor Red
    Write-Host ("  existing run pid {0}, started {1}" -f $active.Id, $active.StartTime) -ForegroundColor Yellow
    Write-Host "Two concurrent runs wipe each other's sessions and produce bogus failures." -ForegroundColor Yellow
    Write-Host 'Stop the existing run first, then relaunch.' -ForegroundColor Yellow
    exit 99
}

$me = Get-Process -Id $PID
"{0}:{1}" -f $PID, $me.StartTime.Ticks | Set-Content $lockFile -Encoding ASCII

# ---------------------------------------------------------------------------
# Turn OFF QuickEdit on this console before anything long starts.
#
# With QuickEdit on, a single stray click or drag in the runner window puts the
# console into selection mode, and selection mode BLOCKS the next write. The
# runner writes a heartbeat every ten seconds, so it freezes on the first one
# after the click and never comes back: no heartbeat, no timeout, no summary,
# and the process sits in a UserRequest wait looking alive.
#
# Measured 2026-08-28: run 2026-08-28_03-45-22 stopped dead at suite 470 of 657
# with the suite process already exited, the runner pwsh idle across all 14
# threads, and progress.log frozen at the exact second the next suite started.
# Roughly four hours of a sweep were lost to a mouse click.
#
# ENABLE_EXTENDED_FLAGS must be set in the same call, otherwise clearing the
# QuickEdit bit alone is ignored. Insert mode is preserved. This only touches
# THIS console, and only for the life of the run.
try {
    if (-not ('PsmuxRunnerConsole' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PsmuxRunnerConsole {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    const int  STD_INPUT_HANDLE          = -10;
    const uint ENABLE_QUICK_EDIT_MODE    = 0x0040;
    const uint ENABLE_INSERT_MODE        = 0x0020;
    const uint ENABLE_EXTENDED_FLAGS     = 0x0080;

    // Returns true when QuickEdit was on and is now off.
    public static bool DisableQuickEdit() {
        IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
        uint mode;
        if (!GetConsoleMode(h, out mode)) { return false; }
        if ((mode & ENABLE_QUICK_EDIT_MODE) == 0) { return false; }
        uint want = (mode & ~ENABLE_QUICK_EDIT_MODE) | ENABLE_EXTENDED_FLAGS | ENABLE_INSERT_MODE;
        return SetConsoleMode(h, want);
    }
}
'@ -ErrorAction Stop
    }
    if ([PsmuxRunnerConsole]::DisableQuickEdit()) {
        Write-Host '  QuickEdit disabled on this console: a stray click can no longer freeze the run.' -ForegroundColor DarkGray
    }
} catch {
    # Never fatal. A run in a host without a real console still works, it just
    # keeps whatever selection behaviour that host has.
    Write-Host "  (could not adjust console mode: $_)" -ForegroundColor DarkGray
}

# Drop any abort flag left over from a previous run before this one starts, so a
# stale file cannot stop the new run on its first poll. run_all_tests.ps1 clears
# it too; doing it here as well closes the window between the lock being taken
# and the runner starting.
Remove-Item (Join-Path $env:TEMP 'psmux-teststop.flag') -Force -EA SilentlyContinue

try {
    Get-ChildItem env: |
        Where-Object { $_.Name -like 'CLAUDE*' -or $_.Name -like 'ANTHROPIC*' -or $_.Name -eq 'NO_COLOR' } |
        ForEach-Object {
            Write-Host ('  scrubbed env: ' + $_.Name) -ForegroundColor DarkGray
            Remove-Item ('env:' + $_.Name) -EA SilentlyContinue
        }

    $env:PSMUX_TEST_SANDBOX = '1'
    Set-Location $repoRoot

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  psmux FULL TEST SUITE (interactive, dedicated window)' -ForegroundColor Cyan
    Write-Host ('  Started: ' + (Get-Date)) -ForegroundColor Cyan
    Write-Host ('  psmux:   ' + (Get-Command psmux -EA SilentlyContinue).Source) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  TO STOP THIS RUN: run  tests\stop_tests.cmd  from any other window.' -ForegroundColor Yellow
    Write-Host '  (Ctrl+C works here too, but test suites steal the foreground within' -ForegroundColor DarkGray
    Write-Host '   seconds, so this window is usually not reachable from the keyboard.)' -ForegroundColor DarkGray
    Write-Host ''

    # -IncludeInteractive : run the TUI suites instead of skipping them
    # -IncludeWSL         : run the tmux parity suites (WSL tmux present)
    # (no -SkipPerf)      : perf/stress suites run too
    #
    # Splat a HASHTABLE, not an array. Array splatting binds every element
    # POSITIONALLY, so '-IncludeInteractive' was handed to the first positional
    # parameter ([int]$DefaultTimeoutSec), the runner died on the type conversion,
    # and the launcher still reported exit code 0. A full run appeared to start
    # and vanished silently.
    $params = @{ IncludeInteractive = $true; IncludeWSL = $true }

    # Fold forwarded arguments (-Resume, -Only <regex>, -SkipPerf, ...) into the
    # same hashtable: a token taking a non-dash token after it is a name/value
    # pair, anything else is a switch.
    $fwd = @($Forward | Where-Object { $_ })
    for ($i = 0; $i -lt $fwd.Count; $i++) {
        $tok = $fwd[$i]
        if ($tok -notmatch '^-') {
            Write-Host "  ignoring stray argument: $tok" -ForegroundColor Yellow
            continue
        }
        $name = $tok.TrimStart('-')
        if ($i + 1 -lt $fwd.Count -and $fwd[$i + 1] -notmatch '^-') {
            $params[$name] = $fwd[$i + 1]
            $i++
        } else {
            $params[$name] = $true
        }
    }

    & (Join-Path $PSScriptRoot 'run_all_tests.ps1') @params
    $rc = $LASTEXITCODE
} finally {
    # Only clear the lock if it is still ours; a later run must not lose its lock
    # to this one's cleanup.
    $cur = (Get-Content $lockFile -Raw -EA SilentlyContinue)
    if ($cur -and $cur.Trim().StartsWith("$PID`:")) { Remove-Item $lockFile -Force -EA SilentlyContinue }
}

exit $rc
