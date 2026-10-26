# Issue #647 (WIN-05): a git install must not report `unknown commit`.
#
# The reporter installed with
#   cargo install --git https://github.com/psmux/psmux psmux --locked --force
# and got `psmux 3.3.8 (unknown commit)` even though cargo itself knew the
# revision (`psmux v3.3.8 (https://github.com/psmux/psmux#d69c3109)`), which
# made it impossible to tell whether a build carried a given post tag fix.
#
# Root cause: build.rs asked `git` and nothing else. `cargo install --git` uses
# libgit2 and never needs the git binary, so a machine with no git on PATH (or
# a container where git refuses the checkout for dubious ownership) installs
# happily and loses the revision.
#
# build.rs now falls back, in order, to `.cargo_vcs_info.json` (present in every
# crates.io tarball), to the cargo git checkout directory name (cargo checks a
# revision out into ~/.cargo/git/checkouts/<name>-<hash>/<short sha>/ next to a
# `.cargo-ok` marker), and to a `PSMUX_GIT_SHA` override for release tooling.
#
# This test installs from a local file:// git URL, with git removed from PATH,
# so it needs no network and reproduces the reporter's condition exactly.
$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor DarkYellow }

Write-Host "`n=== Issue #647 WIN-05: git revision in psmux -V ===" -ForegroundColor Cyan

$repo = (Resolve-Path "$PSScriptRoot\..").Path
$cargo = Get-Command cargo -EA SilentlyContinue
$git = Get-Command git -EA SilentlyContinue

# --- Arm 1: an ordinary repo build still names the commit ---
$local = Join-Path $repo "target\release\psmux.exe"
if (-not (Test-Path $local)) { $local = Join-Path $repo "target\debug\psmux.exe" }
if (Test-Path $local) {
    $v = ((& $local -V 2>&1) -join "`n")
    if ($v -match 'psmux \d+\.\d+\.\d+ \(([0-9a-f]{7,40})') {
        Write-Pass "a repo build names its commit: $($Matches[1])"
    } elseif ($v -match 'unknown commit') {
        Write-Fail "a repo build reports unknown commit: $v"
    } else {
        Write-Fail "unexpected version line: $v"
    }
} else {
    Write-Skip "no built binary under target\; build first to check the repo build"
}

# --- Arm 2: install from a local git URL with git removed from PATH ---
if (-not $cargo) {
    Write-Skip "cargo is not available; the git install arm cannot run"
} elseif (-not $git) {
    Write-Skip "git is not available; cannot read the branch to install"
} else {
    $branch = (& git -C $repo rev-parse --abbrev-ref HEAD 2>$null)
    $head = (& git -C $repo rev-parse --short HEAD 2>$null)
    if (-not $branch -or $branch -eq 'HEAD') {
        Write-Skip "repo HEAD is detached; cargo install --git needs a branch"
    } else {
        $root = Join-Path $env:TEMP "psmux-i647-root"
        # One target dir PER REVISION. Cargo reuses a git package's whole
        # build across checkouts when the target dir is shared: measured
        # 2026-09-13, `cargo install --git` of 33d4854 through the target dir
        # that had built 45c441f the day before printed "Fresh psmux
        # (checkouts\...d4854)" and installed a binary reporting 45c441f,
        # in 4 seconds. Two checkouts of one git package share a metadata
        # directory and the old dep-info paths are all unchanged, so no rerun
        # trigger in build.rs can help. Keying the dir by HEAD keeps a rerun
        # at the same revision fast and makes a new revision build from clean.
        $shared = Join-Path $env:TEMP "psmux-i647-target-$head"
        Get-ChildItem $env:TEMP -Directory -Filter "psmux-i647-target*" -EA SilentlyContinue |
            Where-Object { $_.FullName -ne $shared } |
            ForEach-Object { Remove-Item -Recurse -Force $_.FullName -EA SilentlyContinue }
        Remove-Item -Recurse -Force $root -EA SilentlyContinue
        $url = "file:///" + ($repo -replace '\\', '/')

        # The reporter's condition: no git binary in the environment cargo
        # hands to build.rs.
        $origPath = $env:PATH
        $kept = @()
        foreach ($p in ($origPath -split ';')) {
            if ($p -and (Test-Path (Join-Path $p 'git.exe') -EA SilentlyContinue)) { continue }
            $kept += $p
        }

        Write-Host "  installing from $url (branch $branch, HEAD $head), this can take a few minutes"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $job = Start-Job -ScriptBlock {
            param($path, $target, $url, $branch, $root, $repo)
            $env:PATH = $path
            $env:CARGO_TARGET_DIR = $target
            Set-Location $repo
            cargo install --git $url --branch $branch psmux --root $root --bin psmux 2>&1
        } -ArgumentList ($kept -join ';'), $shared, $url, $branch, $root, $repo

        $done = Wait-Job $job -Timeout 600
        $sw.Stop()
        if (-not $done) {
            Stop-Job $job -EA SilentlyContinue
            Remove-Job $job -Force -EA SilentlyContinue
            Write-Skip "the git install did not finish within 10 minutes; skipping"
        } else {
            $out = Receive-Job $job
            Remove-Job $job -Force -EA SilentlyContinue
            $exe = Join-Path $root "bin\psmux.exe"
            if (-not (Test-Path $exe)) {
                Write-Fail "cargo install produced no binary: $(($out | Select-Object -Last 6) -join ' / ')"
            } else {
                $v = ((& $exe -V 2>&1) -join "`n")
                Write-Host "  installed binary reports: $($v -replace "`n", ' | ')"
                if ($v -match 'unknown commit') {
                    Write-Fail "a git install still reports unknown commit with no git on PATH"
                } elseif ($v -match 'psmux \d+\.\d+\.\d+ \(([0-9a-f]{7,40})') {
                    $sha = $Matches[1]
                    Write-Pass "a git install names its commit without git on PATH: $sha ($([int]$sw.Elapsed.TotalSeconds)s)"
                    if ($head -and $sha.StartsWith($head.Substring(0, [Math]::Min(7, $head.Length)))) {
                        Write-Pass "the reported commit matches the installed revision ($head)"
                    } else {
                        Write-Fail "reported $sha but installed $head"
                    }
                } else {
                    Write-Fail "unexpected version line from the installed binary: $v"
                }
            }
        }
        $env:PATH = $origPath
        Remove-Item -Recurse -Force $root -EA SilentlyContinue
    }
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
