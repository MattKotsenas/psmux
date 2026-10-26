# Issue #641: "Psmux Memory Scaling Issue Compared To Tmux".
#
# Reported as: headless panes created with `new-session -x 500` and
# `history-limit 200000`, then fed the output of a build or an agent, and the
# psmux server climbs into the gigabytes until it dies and takes the pane with
# it. The reporter measured ~1,158 MB for 60,000 lines at that geometry and
# matched it to the model `min(lines, history_limit) * cols * 44`.
#
# The cause was that a row leaving the visible grid was pushed into the
# scrollback verbatim, dense at the pane's full width, so every retained line
# cost `cols * 44` bytes no matter how few characters it held. A 500 column pane
# paid ~22 KB for a 40 character line, about 95% of it trailing blank cells.
#
# Rows are now compacted to their used width on the way into history, which is
# what tmux does: `grid_expand_line` (grid.c:564) only ever grows a line as far
# as the column actually written, `grid_scroll_history` compacts the line as it
# becomes history (grid.c:508), and `grid_get_cell` serves `grid_default_cell`
# for any column past the stored data (grid.c:650).
#
# This script proves it end to end, against the real server, by watching the
# server process's working set while it is flooded.
#
# WHAT IS ASSERTED
#   1. WIDE geometry (-x 500, history-limit 200000, 60,000 lines): peak server
#      RSS stays under MAX_WIDE_MB. The bound is derived from text actually
#      retained, not from the pane width. Each line here is about 156 characters
#      ("NNNNN " plus 150 x's), so the floor is 60000 * 156 * 44 = 412 MB of
#      genuine cell data. Measured: 1,278 MB before the fix, 420 MB after. The
#      bound is set at 700 MB, which is comfortably above the 420 MB the fix
#      produces (1.67x headroom for allocator behaviour and machine noise) and
#      comfortably below the 1,278 MB the old build reaches, so it cannot pass
#      on an unfixed binary.
#   2. SHORT LINE geometry (-x 500, 34 character lines): this is the reporter's
#      real workload, short build output in a wide pane, and it is where width
#      independence shows up most. Measured: 1,278 MB before, 107 MB after, so
#      the bound is 300 MB.
#   3. NARROW control (-x 80, history-limit 2000): must stay flat, under 60 MB,
#      proving the change did not cost anything on the ordinary geometry.
#   4. The history is still correct and complete after all that flooding:
#      `capture-pane -p -S -N` returns the expected number of lines, the line
#      bodies are intact at full width, and the line numbering is contiguous.
#   5. A compacted history row still renders with its attributes (`-e`), still
#      joins wrapped lines (`-J`), still holds CJK glyphs, and survives a resize
#      in both directions.
#
# Run this against a pre-fix binary and tests 1 and 2 FAIL on the RSS bound
# while 4 and 5 pass, which is the shape of the bug: no wrong output, just an
# unbounded memory cost per retained line.

$ErrorActionPreference = "Continue"

# Required so the CJK assertion below compares real Han characters rather than
# the "?" a CP437 console would hand back.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# The agent/CI shell may export NO_COLOR, which makes pwsh inside the pane strip
# every SGR sequence and would fake a `capture-pane -e` failure.
Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue

$SOCK = "i641"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Test($m) { Write-Host "`n[$m]" -ForegroundColor Cyan }

$PSMUX = $env:PSMUX_TEST_EXE
if (-not $PSMUX) { $PSMUX = (Get-Command psmux -EA SilentlyContinue).Source }
if (-not $PSMUX) { Write-Host "psmux not found"; exit 1 }
$PSMUX = (Resolve-Path $PSMUX).Path
$IMAGE = [System.IO.Path]::GetFileName($PSMUX)

$work = Join-Path $env:TEMP "psmux_i641"
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Pmux { & $PSMUX -L $SOCK @args 2>&1 }
function Kill-Sess([string]$n) { Pmux kill-session -t $n | Out-Null }

$script:Metrics = [ordered]@{
    timestamp = (Get-Date).ToString("o")
    exe       = $PSMUX
    runs      = @()
}

# --- the flood ---------------------------------------------------------------
# Returns the peak working set of THIS binary's server process, in MB, after
# pushing $Lines lines of $LineLen x's through a $Cols by $Rows pane.
function Invoke-Flood {
    param(
        [string]$Session,
        [int]$Cols,
        [int]$Rows,
        [int]$HistoryLimit,
        [int]$Lines,
        [int]$LineLen,
        [int]$TimeoutSec = 420
    )

    Kill-Sess $Session
    Start-Sleep -Milliseconds 300
    Pmux new-session -d -s $Session -x $Cols -y $Rows | Out-Null
    Start-Sleep -Milliseconds 900
    Pmux set-option -t $Session history-limit $HistoryLimit | Out-Null

    # Sample the largest working set among the server processes started from
    # THIS executable path. Scoping by path and never by image name keeps other
    # psmux builds and the developer's own sessions out of the measurement.
    #
    # It has to be the maximum over all of them rather than one chosen pid: a
    # psmux server under test is usually accompanied by the `-s __warm__`
    # standby, a claimed warm server keeps `__warm__` in its command line
    # forever, and picking the first match silently measured the idle standby
    # instead of the pane's server.
    $sample = {
        $ws = @(Get-CimInstance Win32_Process -Filter "Name='$IMAGE'" |
            Where-Object { $_.ExecutablePath -eq $PSMUX -and $_.CommandLine -match 'server' } |
            ForEach-Object { $_.WorkingSetSize })
        if ($ws.Count -eq 0) { return $null }
        ($ws | Measure-Object -Maximum).Maximum
    }

    $base = $null
    for ($t = 0; $t -lt 40; $t++) {
        $base = & $sample
        if ($null -ne $base) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($null -eq $base) { return $null }
    $baseMb = $base / 1MB

    # Split so the literal never appears in the command line the shell echoes
    # back into the pane, which would match on the very first sample and end the
    # wait before any flooding happened.
    $sentinel = "ZZ641DONEZZ"
    $cmd = 'for ($i=0;$i -lt ' + $Lines + ';$i++){ "$i " + (''x''*' + $LineLen + ') }; "ZZ641" + "DONEZZ"'
    Pmux send-keys -t $Session $cmd Enter | Out-Null

    $peak = $base
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $died = $false
    $done = $false
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Milliseconds 500
        $now = & $sample
        if ($null -eq $now) { $died = $true; break }
        if ($now -gt $peak) { $peak = $now }
        $view = (Pmux capture-pane -p -t $Session) -join "`n"
        if ($view -match [regex]::Escape($sentinel)) { $done = $true; break }
    }
    # A couple of trailing samples: the last frame can land after the sentinel.
    for ($k = 0; $k -lt 4 -and -not $died; $k++) {
        Start-Sleep -Milliseconds 500
        $now = & $sample
        if ($null -eq $now) { break }
        if ($now -gt $peak) { $peak = $now }
    }

    $peakMb = $peak / 1MB
    $retained = [Math]::Min($Lines, $HistoryLimit)
    $row = [ordered]@{
        session       = $Session
        cols          = $Cols
        rows          = $Rows
        history_limit = $HistoryLimit
        lines         = $Lines
        line_len      = $LineLen
        baseline_mb   = [Math]::Round($baseMb, 1)
        peak_mb       = [Math]::Round($peakMb, 1)
        bytes_per_line = [Math]::Round((($peak - $base) / $retained), 0)
        model_cols_x_44 = $Cols * 44
        server_died   = $died
        flood_done    = $done
        seconds       = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        history_size  = (Pmux display-message -p -t $Session '#{history_size}')
        history_bytes = (Pmux display-message -p -t $Session '#{history_bytes}')
    }
    $script:Metrics.runs += $row
    Write-Host ("       baseline {0:N1} MB, peak {1:N1} MB, {2:N0} bytes per line (old model was {3})" -f `
        $baseMb, $peakMb, $row.bytes_per_line, $row.model_cols_x_44)
    return $row
}

# === TEST 1: wide pane, deep history ========================================
# Where the reporter measured 1,158 MB. Bound justified in the header.
$MAX_WIDE_MB = 700
Write-Test "TEST 1: 500 col pane, history-limit 200000, 60000 lines of ~156 chars"
$wide = Invoke-Flood -Session "i641_wide" -Cols 500 -Rows 50 -HistoryLimit 200000 -Lines 60000 -LineLen 150
if (-not $wide) {
    Write-Fail "could not locate the server process for $PSMUX"
} elseif ($wide.server_died) {
    Write-Fail "the server DIED during the flood (this is the reported crash)"
} elseif (-not $wide.flood_done) {
    Write-Fail "flood did not finish within the timeout, RSS reading is not comparable"
} elseif ($wide.peak_mb -lt $MAX_WIDE_MB) {
    Write-Pass ("peak server RSS {0:N1} MB is under the {1} MB bound (was ~1278 MB before the fix)" -f $wide.peak_mb, $MAX_WIDE_MB)
} else {
    Write-Fail ("peak server RSS {0:N1} MB exceeds the {1} MB bound: scrollback rows are not being compacted" -f $wide.peak_mb, $MAX_WIDE_MB)
}
if ($wide) {
    # Per line cost must track the text, not the pane width.
    if ($wide.bytes_per_line -lt ($wide.model_cols_x_44 * 0.6)) {
        Write-Pass ("{0:N0} bytes per retained line is well below the old cols*44 = {1}" -f $wide.bytes_per_line, $wide.model_cols_x_44)
    } else {
        Write-Fail ("{0:N0} bytes per retained line still matches the old cols*44 = {1} model" -f $wide.bytes_per_line, $wide.model_cols_x_44)
    }
}

# === TEST 2: scrollback content is intact after all that flooding ============
Write-Test "TEST 2: capture-pane -p -S -N still returns the right history"
if ($wide -and -not $wide.server_died) {
    $cap = Pmux capture-pane -p -t "i641_wide" -S -50000
    $count = @($cap).Count
    if ($count -ge 50000) {
        Write-Pass "capture-pane -S -50000 returned $count lines"
    } else {
        Write-Fail "capture-pane -S -50000 returned only $count lines, history was lost"
    }
    # Bodies intact: 150 x's, not truncated by the compaction.
    $full = @($cap | Where-Object { $_ -match '^\d+ x{150}$' }).Count
    if ($full -ge 40000) {
        Write-Pass "$full history lines carry all 150 payload characters"
    } else {
        Write-Fail "only $full history lines carry all 150 characters, compaction truncated text"
    }
    # Numbering contiguous: nothing silently dropped in the middle.
    $nums = @($cap | Where-Object { $_ -match '^(\d+) x{150}$' } | ForEach-Object { [int]($_ -replace ' x+$', '') })
    if ($nums.Count -gt 100) {
        $gaps = 0
        for ($i = 1; $i -lt $nums.Count; $i++) { if ($nums[$i] -ne $nums[$i - 1] + 1) { $gaps++ } }
        if ($gaps -eq 0) {
            Write-Pass "the $($nums.Count) captured line numbers are contiguous, no row was dropped"
        } else {
            Write-Fail "$gaps discontinuities in the captured line numbers"
        }
    } else {
        Write-Skip "too few numbered lines captured to check contiguity"
    }
    $hb = $wide.history_bytes
    if ($hb -match '^\d+$' -and [long]$hb -gt 0) {
        Write-Pass "#{history_bytes} reports $hb (it was hardcoded to 0 before, which hid this issue)"
    } else {
        Write-Fail "#{history_bytes} reported '$hb'"
    }
}
Kill-Sess "i641_wide"
Start-Sleep -Milliseconds 500

# === TEST 3: the reporter's real workload, short lines in a wide pane ========
$MAX_SHORT_MB = 300
Write-Test "TEST 3: 500 col pane, 60000 lines of only ~34 chars (short build output)"
$short = Invoke-Flood -Session "i641_short" -Cols 500 -Rows 50 -HistoryLimit 200000 -Lines 60000 -LineLen 28
if (-not $short) {
    Write-Fail "could not locate the server process"
} elseif ($short.server_died) {
    Write-Fail "the server DIED during the flood"
} elseif (-not $short.flood_done) {
    Write-Fail "flood did not finish within the timeout"
} elseif ($short.peak_mb -lt $MAX_SHORT_MB) {
    Write-Pass ("peak server RSS {0:N1} MB is under the {1} MB bound (was ~1278 MB before the fix)" -f $short.peak_mb, $MAX_SHORT_MB)
} else {
    Write-Fail ("peak server RSS {0:N1} MB exceeds the {1} MB bound: history still costs the pane's full width" -f $short.peak_mb, $MAX_SHORT_MB)
}
# Short lines must cost proportionally less than long ones. This is the actual
# scaling property, and it is what the old build could not satisfy at all.
if ($wide -and $short -and -not $short.server_died) {
    if ($short.bytes_per_line -lt ($wide.bytes_per_line * 0.6)) {
        Write-Pass ("34 char lines cost {0:N0} bytes each against {1:N0} for 156 char lines: cost tracks text" -f $short.bytes_per_line, $wide.bytes_per_line)
    } else {
        Write-Fail ("34 char lines cost {0:N0} bytes and 156 char lines {1:N0}: cost does not track text" -f $short.bytes_per_line, $wide.bytes_per_line)
    }
}
Kill-Sess "i641_short"
Start-Sleep -Milliseconds 500

# === TEST 4: narrow control must stay flat ==================================
$MAX_NARROW_MB = 60
Write-Test "TEST 4: control, 80 col pane, history-limit 2000, 30000 lines"
$narrow = Invoke-Flood -Session "i641_narrow" -Cols 80 -Rows 24 -HistoryLimit 2000 -Lines 30000 -LineLen 150
if (-not $narrow) {
    Write-Fail "could not locate the server process"
} elseif ($narrow.server_died) {
    Write-Fail "the server DIED on the control geometry"
} elseif ($narrow.peak_mb -lt $MAX_NARROW_MB) {
    Write-Pass ("control peak RSS {0:N1} MB stays flat, under the {1} MB bound" -f $narrow.peak_mb, $MAX_NARROW_MB)
} else {
    Write-Fail ("control peak RSS {0:N1} MB regressed past the {1} MB bound" -f $narrow.peak_mb, $MAX_NARROW_MB)
}
Kill-Sess "i641_narrow"
Start-Sleep -Milliseconds 500

# === TEST 5: compacted history rows still read back correctly ===============
Write-Test "TEST 5: attributes, joined wrapping, CJK and resize over compacted history"
$payload = Join-Path $work "i641_payload.ps1"
$body = @'
1..40 | ForEach-Object { "plain line $_" }
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$e = [char]27
[Console]::Out.Write("$e[31mREDTEXT$e[1;44mBOLDBLUE$e[0m tail`n")
[Console]::Out.Write("CJK: <C1><C2><C1><C2> done`n")
[Console]::Out.Write("L" + ("ab" * 120) + "R`n")
1..30 | ForEach-Object { "filler $_" }
"ZZ641MARKZZ"
'@
$body = $body.Replace('<C1>', [string][char]0x4F60).Replace('<C2>', [string][char]0x597D)
Set-Content -Path $payload -Value $body -Encoding UTF8

Kill-Sess "i641_read"
Start-Sleep -Milliseconds 300
Pmux new-session -d -s "i641_read" -x 120 -y 10 | Out-Null
Start-Sleep -Milliseconds 900
Pmux set-option -t "i641_read" history-limit 5000 | Out-Null
Pmux send-keys -t "i641_read" "& '$payload'" Enter | Out-Null
$ready = $false
for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 300
    if (((Pmux capture-pane -p -t "i641_read") -join "`n") -match 'ZZ641MARKZZ') { $ready = $true; break }
}
if (-not $ready) {
    Write-Skip "payload never reached the pane, read-path checks not comparable"
} else {
    Start-Sleep -Milliseconds 600
    $plain = (Pmux capture-pane -p -t "i641_read" -S -200) -join "`n"
    $esc   = (Pmux capture-pane -p -e -t "i641_read" -S -200) -join "`n"
    $joinc = (Pmux capture-pane -p -J -t "i641_read" -S -200) -join "`n"

    $seen = @(1..40 | Where-Object { $plain -match "plain line $_`$" -or $plain -match "plain line $_\s" }).Count
    if ($seen -eq 40) { Write-Pass "all 40 compacted history lines captured verbatim" }
    else { Write-Fail "only $seen of 40 compacted history lines captured" }

    if ($esc -match '44m') { Write-Pass "capture-pane -e still emits the SGR attributes of a compacted row" }
    else { Write-Fail "capture-pane -e lost the attributes of a compacted row" }

    $cjk = "CJK: " + [string][char]0x4F60 + [string][char]0x597D + [string][char]0x4F60 + [string][char]0x597D + " done"
    if ($plain -match [regex]::Escape($cjk)) { Write-Pass "CJK glyphs survive compaction with both halves intact" }
    else { Write-Fail "CJK glyphs were damaged by compaction" }

    if ($joinc -match ("L" + ("ab" * 55))) { Write-Pass "capture-pane -J rejoins a wrapped compacted row" }
    else { Write-Fail "capture-pane -J did not rejoin the wrapped compacted row" }

    Pmux resize-window -t "i641_read" -x 40 -y 10 | Out-Null
    Start-Sleep -Milliseconds 600
    $nar = (Pmux capture-pane -p -t "i641_read" -S -200) -join "`n"
    Pmux resize-window -t "i641_read" -x 200 -y 10 | Out-Null
    Start-Sleep -Milliseconds 600
    $wid = (Pmux capture-pane -p -t "i641_read" -S -200) -join "`n"
    if (($nar -match 'plain line') -and ($wid -match 'plain line')) {
        Write-Pass "history still readable after resizing narrower then wider"
    } else {
        Write-Fail "resize lost the compacted history"
    }

    # Copy mode reads by absolute column and must not fault past a short row.
    Pmux copy-mode -t "i641_read" | Out-Null
    Pmux send-keys -t "i641_read" -X history-top | Out-Null
    # Since PR #671 copy mode scrolls a snapshot and a plain capture-pane answers
    # with the LIVE screen (tmux reads wp->base), so the view is read through its
    # own offset: the region that starts scroll_position lines above the bottom.
    $cmPos = [int]((Pmux display-message -p -t "i641_read" '#{scroll_position}') -join '').Trim()
    $cmView = (Pmux capture-pane -p -t "i641_read" -S "-$cmPos" -E "-$([Math]::Max(0, $cmPos - 9))") -join "`n"
    # history-top homes the cursor to row 0 col 0 of the oldest line, as tmux
    # does, and that row is the prompt that launched the payload. Search down
    # to a known compacted row so select-line copies it (tmux 3.4 does the same
    # flow and yields exactly 'plain line 7').
    Pmux send-keys -t "i641_read" -X search-forward 'plain line 7' | Out-Null
    Pmux send-keys -t "i641_read" -X select-line | Out-Null
    Pmux send-keys -t "i641_read" -X copy-selection-and-cancel | Out-Null
    Start-Sleep -Milliseconds 400
    $buf = ((Pmux show-buffer) -join '') -replace '\s+$', ''
    if ($cmView -match 'plain line' -and $buf -eq 'plain line 7') {
        Write-Pass "copy mode reads a compacted history row and yields '$buf'"
    } else {
        Write-Fail "copy mode over a compacted history row failed (view match=$($cmView -match 'plain line'), buffer='$buf')"
    }
    if (((Pmux list-sessions) -join '') -match 'i641_read') {
        Write-Pass "server still alive after every read path"
    } else {
        Write-Fail "server died during the read-path checks"
    }
}
Kill-Sess "i641_read"

# === METRICS ================================================================
# Written outside the repository, by repo convention.
$metricsDir = "$env:USERPROFILE\.psmux-test-data\metrics"
New-Item -ItemType Directory -Force -Path $metricsDir | Out-Null
$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$metricsFile = Join-Path $metricsDir "issue641-$stamp.json"
$script:Metrics.passed = $script:TestsPassed
$script:Metrics.failed = $script:TestsFailed
$script:Metrics.skipped = $script:TestsSkipped
$script:Metrics | ConvertTo-Json -Depth 5 | Set-Content -Path $metricsFile -Encoding UTF8
Write-Host "`nmetrics written to $metricsFile" -ForegroundColor DarkGray

# === TEARDOWN ================================================================
foreach ($s in @("i641_wide", "i641_short", "i641_narrow", "i641_read")) { Kill-Sess $s }
Pmux kill-server | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item $work -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results: $script:TestsPassed passed, $script:TestsFailed failed, $script:TestsSkipped skipped ===" -ForegroundColor Cyan
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
