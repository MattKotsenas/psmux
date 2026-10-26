# pipe-pane direct file sink: `cat > file` / `cat >> file` serviced in-process.
#
# The canonical tmux logging idiom could not work on Windows: sink commands run
# under PowerShell, where `cat` is the Get-Content alias - it never reads stdin,
# exits at once, and the redirect left a 0-byte file with rc 0. The server now
# recognizes the idiom and writes the pane's raw ConPTY bytes to the file
# itself. This test proves, end to end, that:
#   1. the docs idiom `cat > file` captures pane output (was 0 bytes forever)
#   2. `cat >> file` appends across re-pipes instead of truncating
#   3. a quoted path with spaces works (quotes survive the #563 wire round-trip)
#   4. toggle-off stops the file sink
#   5. an unopenable path fails LOUD: non-zero exit + ERROR message, and the
#      failed sink is NOT recorded (was: rc 0 and a phantom pipe that a later
#      -o toggled off)
#   6. a UNC path is refused loudly (opening one on the server's event loop
#      could stall every pane on an unreachable host)
#   7. an arbitrary PowerShell sink still runs via the shell (no misfire of the
#      file-sink fast path)
#   8. a DOS reserved device name is refused loudly (`cat > CON` would open
#      the console DEVICE and tee raw VT bytes into the server's own TUI)
#   9. `cat >` truncates an existing file, `cat >>` does not
#
# Isolation (AGENTS.md): runs under New-PsmuxTestEnv (throwaway USERPROFILE/
# HOME, scrubbed PSMUX_*/TMUX vars) plus a dedicated -L namespace, so it cannot
# see or disturb a psmux session the user is running for real.

$ErrorActionPreference = "Continue"

# Same safety gate as test_issue443_cuf_capture.ps1: starting real servers is
# for CI or an explicitly disposable environment.
$isDisposable = $env:PSMUX_ALLOW_DESTRUCTIVE_TESTS -or $env:CI -or $env:GITHUB_ACTIONS
if (-not $isDisposable) {
    Write-Host "[SKIP] test_pipe_pane_cat_file_sink: starts a real server." -ForegroundColor Yellow
    Write-Host "       Set PSMUX_ALLOW_DESTRUCTIVE_TESTS=1 in a disposable environment to run it." -ForegroundColor Yellow
    Write-Host "       Server-free coverage: cargo test --bin psmux tests_pipe_pane_cat_file_sink" -ForegroundColor Yellow
    exit 0
}

. "$PSScriptRoot\psmux_test_helpers.ps1"

$ctx = New-PsmuxTestEnv -Tag 'catsink'
$PSMUX = $ctx.PsmuxExe
$ns = Register-PsmuxNamespace -Ctx $ctx -Namespace "catsink"
$S = "catsink"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Count-Matches($file, $pattern) {
    $c = Get-Content $file -Raw -EA SilentlyContinue
    if ($null -eq $c) { return 0 }
    return ([regex]::Matches($c, $pattern)).Count
}

$work = Join-Path $ctx.Home "sink"
New-Item -ItemType Directory -Force $work | Out-Null

Write-Host "`n=== pipe-pane direct file sink (cat > file) ===" -ForegroundColor Cyan
Write-Host "  psmux: $PSMUX  namespace: $ns" -ForegroundColor DarkGray

try {
    & $PSMUX -L $ns new-session -d -s $S
    Start-Sleep -Seconds 3

    # -----------------------------------------------------------------------
    # TEST 1: the docs idiom `cat > file` captures pane output
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 1] docs idiom: cat > file captures output" -ForegroundColor Yellow
    $log1 = Join-Path $work "t1.log"
    & $PSMUX -L $ns pipe-pane -t $S -o "cat > `"$log1`""
    if ($LASTEXITCODE -eq 0) { Write-Pass "pipe-pane returned exit 0" } else { Write-Fail "pipe-pane exit $LASTEXITCODE" }
    & $PSMUX -L $ns send-keys -t $S "echo CATSINK_MARKER_1" Enter
    Start-Sleep -Seconds 2
    & $PSMUX -L $ns pipe-pane -t $S
    Start-Sleep -Milliseconds 500
    $n1 = Count-Matches $log1 "CATSINK_MARKER_1"
    if ($n1 -gt 0) { Write-Pass "file sink captured $n1 marker match(es) (was 0 bytes before the fix)" }
    else { Write-Fail "file sink captured nothing" }

    # -----------------------------------------------------------------------
    # TEST 2: `cat >> file` appends across re-pipes
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 2] cat >> file appends instead of truncating" -ForegroundColor Yellow
    $log2 = Join-Path $work "t2.log"
    & $PSMUX -L $ns pipe-pane -t $S -o "cat >> `"$log2`""
    & $PSMUX -L $ns send-keys -t $S "echo CATSINK_APPEND_A" Enter
    Start-Sleep -Seconds 2
    & $PSMUX -L $ns pipe-pane -t $S
    Start-Sleep -Milliseconds 500
    & $PSMUX -L $ns pipe-pane -t $S -o "cat >> `"$log2`""
    & $PSMUX -L $ns send-keys -t $S "echo CATSINK_APPEND_B" Enter
    Start-Sleep -Seconds 2
    & $PSMUX -L $ns pipe-pane -t $S
    Start-Sleep -Milliseconds 500
    $a = Count-Matches $log2 "CATSINK_APPEND_A"
    $b = Count-Matches $log2 "CATSINK_APPEND_B"
    if ($a -gt 0 -and $b -gt 0) { Write-Pass "both markers survive re-pipe with >> (A=$a B=$b)" }
    else { Write-Fail "append lost data across re-pipes (A=$a B=$b)" }

    # -----------------------------------------------------------------------
    # TEST 3: quoted path with spaces
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 3] quoted path with spaces" -ForegroundColor Yellow
    $dir3 = Join-Path $work "spaced dir"
    New-Item -ItemType Directory -Force $dir3 | Out-Null
    $log3 = Join-Path $dir3 "pane.log"
    & $PSMUX -L $ns pipe-pane -t $S -o "cat > `"$log3`""
    & $PSMUX -L $ns send-keys -t $S "echo CATSINK_QUOTED" Enter
    Start-Sleep -Seconds 2
    & $PSMUX -L $ns pipe-pane -t $S
    Start-Sleep -Milliseconds 500
    $q = Count-Matches $log3 "CATSINK_QUOTED"
    if ($q -gt 0) { Write-Pass "quoted spaced path captured $q match(es)" }
    else { Write-Fail "quoted spaced path captured nothing" }

    # -----------------------------------------------------------------------
    # TEST 4: toggle-off stops the file sink
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 4] toggle-off stops the file sink" -ForegroundColor Yellow
    $log4 = Join-Path $work "t4.log"
    & $PSMUX -L $ns pipe-pane -t $S -o "cat > `"$log4`""
    & $PSMUX -L $ns send-keys -t $S "echo CATSINK_BEFORE_OFF" Enter
    Start-Sleep -Seconds 2
    & $PSMUX -L $ns pipe-pane -t $S -o "cat > `"$log4`""   # toggle off
    Start-Sleep -Milliseconds 500
    & $PSMUX -L $ns send-keys -t $S "echo CATSINK_AFTER_OFF" Enter
    Start-Sleep -Seconds 2
    $before = Count-Matches $log4 "CATSINK_BEFORE_OFF"
    $after = Count-Matches $log4 "CATSINK_AFTER_OFF"
    if ($before -gt 0) { Write-Pass "captured before toggle-off ($before)" }
    else { Write-Fail "nothing captured before toggle-off" }
    if ($after -eq 0) { Write-Pass "nothing captured after toggle-off" }
    else { Write-Fail "file sink kept running after toggle-off ($after)" }

    # -----------------------------------------------------------------------
    # TEST 5: unopenable path fails loud, and no phantom pipe is recorded
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 5] unopenable path: non-zero exit + ERROR, no phantom pipe" -ForegroundColor Yellow
    $badLog = Join-Path $work ("no_such_dir_" + (Get-Random)) | Join-Path -ChildPath "pane.log"
    $err5 = & $PSMUX -L $ns pipe-pane -t $S -o "cat > `"$badLog`"" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Pass "pipe-pane exited non-zero ($LASTEXITCODE)" }
    else { Write-Fail "pipe-pane exited 0 for an unopenable path" }
    if ($err5 -match "ERROR") { Write-Pass "ERROR message printed" }
    else { Write-Fail "no ERROR message (got: $($err5.Trim()))" }
    # The failed sink must NOT be recorded: a fresh -o on the same pane must
    # start a pipe (not toggle a phantom one off).
    $log5 = Join-Path $work "t5.log"
    & $PSMUX -L $ns pipe-pane -t $S -o "cat > `"$log5`""
    & $PSMUX -L $ns send-keys -t $S "echo CATSINK_AFTER_FAIL" Enter
    Start-Sleep -Seconds 2
    & $PSMUX -L $ns pipe-pane -t $S
    Start-Sleep -Milliseconds 500
    $n5 = Count-Matches $log5 "CATSINK_AFTER_FAIL"
    if ($n5 -gt 0) { Write-Pass "failed sink was not recorded; next -o piped normally ($n5)" }
    else { Write-Fail "phantom dead pipe: -o after failure captured nothing" }

    # -----------------------------------------------------------------------
    # TEST 6: UNC path is refused loudly
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 6] UNC path refused (would stall the event loop)" -ForegroundColor Yellow
    $err6 = & $PSMUX -L $ns pipe-pane -t $S -o "cat > `"\\no-such-host\share\pane.log`"" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and $err6 -match "UNC") { Write-Pass "UNC refused with non-zero exit + message" }
    else { Write-Fail "UNC not refused (exit=$LASTEXITCODE, got: $($err6.Trim()))" }

    # -----------------------------------------------------------------------
    # TEST 7: arbitrary PowerShell sink still runs via the shell
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 7] arbitrary shell sink unaffected by the fast path" -ForegroundColor Yellow
    $log7 = Join-Path $work "t7.log"
    & $PSMUX -L $ns pipe-pane -t $S -o "`$input | Out-File -Encoding utf8 `"$log7`""
    & $PSMUX -L $ns send-keys -t $S "echo CATSINK_SHELL_SINK" Enter
    Start-Sleep -Seconds 3
    & $PSMUX -L $ns pipe-pane -t $S
    Start-Sleep -Seconds 1
    $n7 = Count-Matches $log7 "CATSINK_SHELL_SINK"
    if ($n7 -gt 0) { Write-Pass "shell sink captured $n7 match(es)" }
    else { Write-Fail "shell sink captured nothing" }

    # -----------------------------------------------------------------------
    # TEST 8: DOS reserved device name refused loudly
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 8] reserved device name refused (cat > CON)" -ForegroundColor Yellow
    $err8 = & $PSMUX -L $ns pipe-pane -t $S -o "cat > CON" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and $err8 -match "reserved device") { Write-Pass "CON refused with non-zero exit + message" }
    else { Write-Fail "CON not refused (exit=$LASTEXITCODE, got: $($err8.Trim()))" }
    $err8b = & $PSMUX -L $ns pipe-pane -t $S -o "cat > `"$(Join-Path $work 'CON.log')`"" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and $err8b -match "reserved device") { Write-Pass "CON.log in a directory refused too" }
    else { Write-Fail "CON.log not refused (exit=$LASTEXITCODE, got: $($err8b.Trim()))" }

    # -----------------------------------------------------------------------
    # TEST 9: `>` truncates an existing file, `>>` appends
    # -----------------------------------------------------------------------
    Write-Host "`n[Test 9] > truncates, >> appends" -ForegroundColor Yellow
    $log9 = Join-Path $work "t9.log"
    Set-Content -Path $log9 -Value "CATSINK_STALE_CONTENT"
    & $PSMUX -L $ns pipe-pane -t $S -o "cat > `"$log9`""
    & $PSMUX -L $ns send-keys -t $S "echo CATSINK_FRESH" Enter
    Start-Sleep -Seconds 2
    & $PSMUX -L $ns pipe-pane -t $S
    Start-Sleep -Milliseconds 500
    $stale = Count-Matches $log9 "CATSINK_STALE_CONTENT"
    $fresh = Count-Matches $log9 "CATSINK_FRESH"
    if ($stale -eq 0 -and $fresh -gt 0) { Write-Pass "> truncated stale content and captured fresh ($fresh)" }
    else { Write-Fail "> did not truncate (stale=$stale fresh=$fresh)" }
} finally {
    Remove-PsmuxTestEnv -Ctx $ctx
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed

