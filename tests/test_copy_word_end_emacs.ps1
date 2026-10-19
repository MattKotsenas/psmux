# Copy mode: an emacs word end copies the whole word, as tmux does.
#
# tmux window_copy_cursor_next_word_end starts at the cursor and, with emacs
# mode-keys, stops one cell PAST the word; vi stops on the last letter. The
# emacs copy leaves the cursor cell out and vi keeps it, so both copy the
# whole word. psmux stopped on the last letter in both modes, and once the
# emacs copy dropped the cursor cell (tmux 3.8 parity), select-word, a double
# click and begin-selection + next-word-end all lost the last letter:
# "beta1" copied as "beta".

$ErrorActionPreference = 'Continue'
$PSMUX = (Get-Command psmux -EA Stop).Source
$NS = "cwe" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$env:PSMUX_DATA_DIR = Join-Path $env:TEMP "psmux_cwe_$NS"
New-Item -ItemType Directory $env:PSMUX_DATA_DIR -Force | Out-Null
$env:PSMUX_NO_WARM = '1'

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function P { & $PSMUX -L $NS @args 2>&1 }

Write-Host "`n=== Copy mode: emacs word end copies the whole word ===" -ForegroundColor Cyan
P new-session -d -s s -x 80 -y 24 | Out-Null
$up = $false
for ($i = 0; $i -lt 40; $i++) { P has-session -t s | Out-Null; if ($LASTEXITCODE -eq 0) { $up = $true; break }; Start-Sleep -Milliseconds 250 }
if (-not $up) { Write-Fail "no session"; exit 1 }
Start-Sleep -Milliseconds 1500
P send-keys -t s 'cls; "alpha1 beta1 gam.ma1 x-y-z end"' Enter | Out-Null

$row = -1
for ($i = 0; $i -lt 40 -and $row -lt 0; $i++) {
    Start-Sleep -Milliseconds 250
    $cap = (P capture-pane -t s -p) -split "`r?`n"
    for ($j = 0; $j -lt $cap.Count; $j++) { if ($cap[$j] -match '^alpha1 beta1 gam') { $row = $j } }
}
if ($row -lt 0) { Write-Fail "the text row never appeared"; P kill-server | Out-Null; exit 1 }

# Put the copy cursor on (row, col) and run the verbs, then read the buffer.
function Copy-From($col, [string[]]$verbs) {
    P set-buffer -b marker MARKER | Out-Null
    P copy-mode -t s | Out-Null
    P send-keys -t s -X top-line | Out-Null
    P send-keys -t s -X start-of-line | Out-Null
    for ($k = 0; $k -lt $row; $k++) { P send-keys -t s -X cursor-down | Out-Null }
    for ($k = 0; $k -lt $col; $k++) { P send-keys -t s -X cursor-right | Out-Null }
    foreach ($v in $verbs) { P send-keys -t s -X $v | Out-Null }
    P send-keys -t s -X copy-selection-and-cancel | Out-Null
    Start-Sleep -Milliseconds 250
    return ((P show-buffer) -join "`n")
}

# Each case: the cursor column, the verbs, and what tmux copies (both modes).
$cases = @(
    @{ col = 8;  verbs = @('select-word');                        want = 'beta1';  what = 'select-word in the middle of a word' },
    @{ col = 7;  verbs = @('select-word');                        want = 'beta1';  what = 'select-word on the first letter' },
    @{ col = 11; verbs = @('select-word');                        want = 'beta1';  what = 'select-word on the last letter' },
    @{ col = 7;  verbs = @('begin-selection', 'next-word-end');   want = 'beta1';  what = 'begin-selection + next-word-end' },
    @{ col = 13; verbs = @('begin-selection', 'next-word-end');   want = 'gam';    what = 'next-word-end stops at a separator' },
    @{ col = 21; verbs = @('begin-selection', 'next-space-end');  want = 'x-y-z';  what = 'begin-selection + next-space-end' }
)
foreach ($mk in 'emacs', 'vi') {
    P set -g mode-keys $mk | Out-Null
    Write-Host "`n[mode-keys $mk]" -ForegroundColor Yellow
    foreach ($c in $cases) {
        $got = Copy-From $c.col $c.verbs
        if ($got -eq $c.want) { Write-Pass "$mk : $($c.what) copied [$got]" }
        else { Write-Fail "$mk : $($c.what) copied [$got], want [$($c.want)]" }
    }
}

# Two next-word-end in a row walk word by word in both modes.
foreach ($mk in 'emacs', 'vi') {
    P set -g mode-keys $mk | Out-Null
    $got = Copy-From 0 @('begin-selection', 'next-word-end', 'next-word-end')
    if ($got -eq 'alpha1 beta1') { Write-Pass "$mk : two next-word-end copied [$got]" }
    else { Write-Fail "$mk : two next-word-end copied [$got], want [alpha1 beta1]" }
}

# The emacs cursor sits one past the word, where tmux puts it.
P set -g mode-keys emacs | Out-Null
P copy-mode -t s | Out-Null
P send-keys -t s -X top-line | Out-Null
P send-keys -t s -X start-of-line | Out-Null
for ($k = 0; $k -lt $row; $k++) { P send-keys -t s -X cursor-down | Out-Null }
for ($k = 0; $k -lt 7; $k++) { P send-keys -t s -X cursor-right | Out-Null }
P send-keys -t s -X next-word-end | Out-Null
$x = ((P display -p -t s '#{copy_cursor_x}') -join '').Trim()
if ($x -eq '12') { Write-Pass "emacs next-word-end from b of beta1 puts the cursor on column 12" }
else { Write-Fail "emacs next-word-end put the cursor on column [$x], want 12" }
P set -g mode-keys vi | Out-Null
P send-keys -t s -X start-of-line | Out-Null
for ($k = 0; $k -lt 7; $k++) { P send-keys -t s -X cursor-right | Out-Null }
P send-keys -t s -X next-word-end | Out-Null
$x = ((P display -p -t s '#{copy_cursor_x}') -join '').Trim()
if ($x -eq '11') { Write-Pass "vi next-word-end from b of beta1 puts the cursor on column 11" }
else { Write-Fail "vi next-word-end put the cursor on column [$x], want 11" }
P send-keys -t s -X cancel | Out-Null

# TUI: a real attached client window, and the server answers it.
Write-Host "`n[TUI] an attached client" -ForegroundColor Yellow
$proc = Start-Process -FilePath $PSMUX -ArgumentList '-L', $NS, 'attach', '-t', 's' -PassThru
Start-Sleep -Seconds 3
$clients = (P list-clients -t s) -join "`n"
if ($clients -match 's') { Write-Pass "the attached client is listed" } else { Write-Fail "no attached client: [$clients]" }
P set -g mode-keys emacs | Out-Null
$got = Copy-From 8 @('select-word')
if ($got -eq 'beta1') { Write-Pass "with a client attached, emacs select-word copied [$got]" }
else { Write-Fail "with a client attached, emacs select-word copied [$got], want [beta1]" }

P kill-server | Out-Null
Start-Sleep -Milliseconds 500
if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue }
Remove-Item $env:PSMUX_DATA_DIR -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed ===" `
    -ForegroundColor $(if ($script:TestsFailed) { 'Red' } else { 'Green' })
exit $script:TestsFailed
