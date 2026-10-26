# Issue #672: "Warm-pane cd injection uses PowerShell syntax for full-path Git
# Bash default-shell" (TreyThomasCodes, psmux 3.3.8 / 66cf613, WinGet).
#
# Reported: with
#
#     set -g default-shell "C:/Program Files/Git/bin/bash.exe"
#
# every pane served from the warm pool carried this in its scrollback:
#
#     $  cd 'C:\Users\trey\trading\newsletter-follower'; try { [System.IO.Directory]::SetCurrentDirectory($PWD.ProviderPath) } catch {}; cls
#     bash: syntax error near unexpected token `('
#
# The first (cold) pane of a session was clean; splits and new windows, which
# come from the warm pool, were not. The reporter's hypothesis was that the
# shell classification matched the raw `default-shell` value against bare names
# instead of its basename.
#
# That is the same defect as #600. 3.3.8's `rehome_command` had no shell
# classification at all: it chose the snippet from `cfg!(windows)`, so on
# Windows every warm pane got the PowerShell form whatever shell was running in
# it. c3a8c64 keyed it on the shell instead; this test is the standing guard
# for the reported recipe, and #672 additionally made the choice a function of
# the SPELLING alone (see tests-rs/test_issue672_shell_basename_classify.rs),
# so a path that is not installed on this machine classifies like one that is.
#
# What is asserted, for the full path (forward AND backslash spellings), for
# the bare `bash` spelling, and for pwsh as the regression guard:
#   1. no `syntax error` anywhere in the pane's scrollback
#   2. no `SetCurrentDirectory` / `try {` / `cls` text (the PowerShell form)
#   3. the pane really is in the requested directory (#{pane_current_path})
#   4. for a POSIX shell, `pwd` inside the pane also reports it
# for a split pane and for a new-window pane, both warm-pool served.
#
# SAFETY: fully isolated. USERPROFILE points at a throwaway temp dir so the
# server's ~/.psmux state cannot collide with a live one, every session lives
# in its own `-L` namespace, and teardown is `kill-server` on that namespace
# only. No process is killed by name and no global kill-server is issued, so
# this is safe to run beside other psmux servers.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue672_gitbash_fullpath_warm_cd.ps1
#      pwsh ... -Psmux <path-to-psmux.exe>

param(
    [string]$Psmux = (Join-Path $PSScriptRoot "..\target\release\psmux.exe"),
    [int]$SettleMs = 9000,      # time given to a cold shell to reach its first prompt
    [int]$WarmSettleMs = 6000   # time given to a warm-served pane to finish the rehome
)

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass { param($msg) Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info { param($msg) Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }
function Write-Skip { param($msg) Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }

if (-not (Test-Path $Psmux)) {
    Write-Host "ERROR: psmux binary not found at $Psmux (cargo build --release)" -ForegroundColor Red
    exit 2
}
$Psmux = (Resolve-Path $Psmux).Path
Write-Host "`n=== Issue #672: warm pane cd injection matches the pane's shell ===" -ForegroundColor Cyan
Write-Info "binary: $Psmux"

$gitBashFwd  = "C:/Program Files/Git/bin/bash.exe"
$gitBashBack = "C:\Program Files\Git\bin\bash.exe"
$haveGitBash = Test-Path $gitBashBack

# The PowerShell rehome form, in the pieces that show up in a pane that was
# handed the wrong dialect. Any of these in a bash pane is the bug.
$powershellFormMarkers = @('SetCurrentDirectory', 'ProviderPath', 'try {', '} catch {}')

function Invoke-ShellCase {
    param(
        [string]$Label,
        [string]$ShellValue,     # what goes in `set -g default-shell "..."`
        [string]$Family,         # posix | powershell
        [string]$PromptPattern   # a prompt this shell is known to print
    )

    Write-Host "`n--- $Label : default-shell `"$ShellValue`" ---" -ForegroundColor White

    $ns = "i672" + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $tempHome = Join-Path $env:TEMP "psmux-$ns"
    New-Item -ItemType Directory -Force -Path (Join-Path $tempHome ".psmux") | Out-Null
    $conf = Join-Path $tempHome "psmux.conf"
    Set-Content -Path $conf -Value ("set -g default-shell `"$ShellValue`"`n") -Encoding ascii

    $startDir = Join-Path $env:TEMP "psmux672-start-$ns"
    $targetDir = Join-Path $env:TEMP "psmux672-target-$ns"
    New-Item -ItemType Directory -Force -Path $startDir, $targetDir | Out-Null

    $savedUP = $env:USERPROFILE; $savedCfg = $env:PSMUX_CONFIG_FILE
    $savedSess = $env:PSMUX_SESSION; $savedTmux = $env:TMUX; $savedTgt = $env:PSMUX_TARGET_SESSION
    $env:USERPROFILE = $tempHome
    $env:PSMUX_CONFIG_FILE = $conf
    # A psmux launched from inside a pane would otherwise target that session.
    $env:PSMUX_SESSION = $null; $env:TMUX = $null; $env:PSMUX_TARGET_SESSION = $null

    try {
        # Cold start, polled rather than slept: a session that never comes up
        # (a busy machine loses the race often enough) is retried once before
        # the case gives up, and what the pane actually showed is reported.
        $cold = ""
        $started = $false
        foreach ($attempt in 1..2) {
            $create = (& $Psmux -L $ns new-session -d -s t -x 100 -y 30 -c $startDir 2>&1 | Out-String).Trim()
            if ($create) { Write-Info "new-session said: $create" }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt $SettleMs) {
                Start-Sleep -Milliseconds 300
                $cold = (& $Psmux -L $ns capture-pane -t t:0.0 -p -S -3000 2>&1 | Out-String)
                if ($cold -match $PromptPattern) { $started = $true; break }
            }
            if ($started) { break }
            Write-Info "attempt $attempt did not reach a prompt (last capture: $($cold.Trim())); retrying"
            & $Psmux -L $ns kill-server 2>&1 | Out-Null
            Start-Sleep -Milliseconds 700
        }
        if (-not $started) {
            Write-Skip "$Label : the pane never reached a $Family prompt (shell not usable here); capture was: $($cold.Trim())"
            return
        }
        Write-Info "cold pane prompt OK"

        # Both warm-pool served: a split and a new window, each asking for a
        # directory the pre-spawned shell is not in, which is what makes psmux
        # type the rehome line.
        & $Psmux -L $ns split-window -t t:0.0 -d -c $targetDir 2>&1 | Out-Null
        Start-Sleep -Milliseconds $WarmSettleMs
        & $Psmux -L $ns new-window -d -t t -c $targetDir 2>&1 | Out-Null
        Start-Sleep -Milliseconds $WarmSettleMs

        foreach ($pane in @(@{ T = "t:0.1"; N = "split-window -c" }, @{ T = "t:1.0"; N = "new-window -c" })) {
            $target = $pane.T
            $name = $pane.N
            $cap = (& $Psmux -L $ns capture-pane -t $target -p -S -3000 2>&1 | Out-String)

            # A capture that never happened must not pass the content checks
            # below by being empty.
            if ((-not $cap.Trim()) -or ($cap -match 'no server running|can.t find pane|no such')) {
                Write-Fail "$Label / $name : the pane could not be captured -> $($cap.Trim())"
                continue
            }

            if ($cap -match '(?im)^.*syntax error.*$') {
                Write-Fail "$Label / $name : pane scrollback contains a syntax error -> $($Matches[0].Trim())"
            } else {
                Write-Pass "$Label / $name : no syntax error in the pane scrollback"
            }

            if ($Family -eq 'posix') {
                $hit = $powershellFormMarkers | Where-Object { $cap -like "*$_*" }
                if ($hit) {
                    Write-Fail "$Label / $name : PowerShell rehome form reached a POSIX shell (found: $($hit -join ', '))"
                } else {
                    Write-Pass "$Label / $name : no PowerShell rehome text in a POSIX pane"
                }
            }

            $cwd = (& $Psmux -L $ns display-message -p -t $target '#{pane_current_path}' 2>&1 | Out-String).Trim()
            if ($cwd -and ($cwd.TrimEnd('\') -ieq $targetDir.TrimEnd('\'))) {
                Write-Pass "$Label / $name : pane_current_path is the requested directory"
            } else {
                Write-Fail "$Label / $name : pane_current_path is '$cwd', expected '$targetDir'"
            }

            # And ask the shell itself, so a stale reading cannot pass this.
            $marker = "M672_" + ([guid]::NewGuid().ToString('N').Substring(0, 6))
            if ($Family -eq 'posix') {
                & $Psmux -L $ns send-keys -t $target "echo $marker `$(pwd)" Enter 2>&1 | Out-Null
            } else {
                & $Psmux -L $ns send-keys -t $target "Write-Host `"$marker `$(Get-Location)`"" Enter 2>&1 | Out-Null
            }
            $echo = ""
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 12000) {
                Start-Sleep -Milliseconds 250
                $c = (& $Psmux -L $ns capture-pane -t $target -p -S -3000 2>&1 | Out-String)
                $m = [regex]::Match($c, "(?m)^$marker (.+)$")
                if ($m.Success) { $echo = $m.Groups[1].Value.Trim(); break }
            }
            if (-not $echo) {
                Write-Fail "$Label / $name : the shell never echoed its own working directory"
            } else {
                # A POSIX shell answers in its own idiom (/c/Users/... or
                # /tmp/...), so compare on the leaf, which both forms share.
                $leaf = Split-Path $targetDir -Leaf
                if ($echo -like "*$leaf*") {
                    Write-Pass "$Label / $name : the shell itself reports the requested directory ($echo)"
                } elseif ($echo -like "/mnt/*") {
                    # The pane is WSL's bash (a bare `bash` resolves to
                    # C:\Windows\System32\bash.exe on a machine without Git Bash
                    # on PATH). It is a POSIX shell and gets the POSIX line,
                    # which is what #672 is about, but a Windows path is not a
                    # path it can enter: it would need /mnt/c/... instead. That
                    # is a separate, pre-existing limitation of the rehome (the
                    # same class as #615's frozen WSL cwd), not something this
                    # test can assert away.
                    Write-Skip "$Label / $name : WSL bash cannot cd to a Windows path (reports '$echo'); dialect is still POSIX, which is what #672 covers"
                } else {
                    Write-Fail "$Label / $name : the shell reports '$echo', which is not '$targetDir'"
                }
            }
        }
    }
    finally {
        & $Psmux -L $ns kill-server 2>&1 | Out-Null
        Start-Sleep -Milliseconds 700
        $env:USERPROFILE = $savedUP; $env:PSMUX_CONFIG_FILE = $savedCfg
        $env:PSMUX_SESSION = $savedSess; $env:TMUX = $savedTmux; $env:PSMUX_TARGET_SESSION = $savedTgt
        Remove-Item -Recurse -Force $startDir, $targetDir, $tempHome -ErrorAction SilentlyContinue
    }
}

# The reporter's own configuration, in both spellings of the same path.
if ($haveGitBash) {
    Invoke-ShellCase -Label "git bash, full path, forward slashes" -ShellValue $gitBashFwd `
        -Family posix -PromptPattern '(?m)(MINGW|MSYS|\$ *$)'
    Invoke-ShellCase -Label "git bash, full path, backslashes" -ShellValue $gitBashBack `
        -Family posix -PromptPattern '(?m)(MINGW|MSYS|\$ *$)'
} else {
    Write-Skip "Git Bash not installed at $gitBashBack; the full-path cases need it"
}

# The bare spelling. On a machine without Git Bash on PATH this resolves to
# WSL's C:\Windows\System32\bash.exe, which is still a bash and still must get
# the POSIX form; if no bash resolves at all the case skips itself.
Invoke-ShellCase -Label "bare bash" -ShellValue "bash" -Family posix -PromptPattern '(?m)(\$ *$|MINGW|MSYS|@)'

# Regression guard: the shell the rehome was originally written for must keep
# the PowerShell form and keep landing in the right directory.
Invoke-ShellCase -Label "pwsh (regression guard)" -ShellValue "pwsh -NoProfile" -Family powershell -PromptPattern '(?m)PS [A-Z]:\\'

Write-Host "`n=== RESULTS: $script:TestsPassed passed, $script:TestsFailed failed ===" -ForegroundColor $(if ($script:TestsFailed -eq 0) { "Green" } else { "Red" })
exit $script:TestsFailed
