# Does a pane's text land where psmux thinks it does?
#
# RUN THIS INSIDE A PSMUX PANE, in the terminal you want to show. It prints a
# ruler, then one line per emoji sequence holding the sequence followed by a
# marker, and asks psmux itself where it believes the cursor is. On a terminal
# that draws the sequence narrower than psmux counted it, the marker lands to
# the LEFT of the column psmux reports, and the gap is the error. On one that
# draws it wider, the text after it is overwritten instead.
#
#     pwsh -NoProfile -File .\scripts\probe-pane-emoji-shift.ps1
#
# This is the half that `scripts\probe-emoji-width.ps1` cannot see. That one
# measures what the console counts for a raw write; this one measures where
# the text ends up on screen after psmux has drawn its grid, and the two do
# not always agree inside the same terminal. Discussion #749 has the survey
# both of them produced.
#
# The three CJK characters on the first line are the control: six columns in
# every terminal measured so far, so if that line disagrees, the instrument is
# wrong rather than psmux.
#
# Nothing is written outside the pane and nothing is killed.
#
# The output encoding is forced to UTF-8 first. Without that, .NET converts
# anything the console code page cannot hold into a question mark, one per
# UTF-16 code unit, and the run then measures a row of question marks rather
# than an emoji, with numbers that look plausible. The script checks for
# exactly that before trusting a line.
#
# ASCII only: Windows PowerShell 5.1 reads a file with no byte order mark in
# the ANSI code page, so the sequences are built from their code units.

$ErrorActionPreference = "Continue"

if (-not $env:TMUX -and -not $env:PSMUX_SESSION) {
    Write-Host "This has to run inside a psmux pane: it asks psmux where the" -ForegroundColor Red
    Write-Host "cursor is, and outside a pane there is nobody to ask." -ForegroundColor Red
    exit 1
}

$savedOut = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
} catch {
    Write-Host "could not set the output encoding to UTF-8: $_" -ForegroundColor Red
    exit 1
}

function Seq([int[]] $units) {
    $s = ""
    foreach ($u in $units) { $s += [char] $u }
    return $s
}

$cases = @(
    @{ n = "CJK, the control";  u = @(0x3042, 0x3042, 0x3042) },
    @{ n = "heart with VS16";   u = @(0x2764, 0xFE0F) },
    @{ n = "skin tone";         u = @(0xD83D, 0xDC4D, 0xD83C, 0xDFFD) },
    @{ n = "ZWJ family";        u = @(0xD83D, 0xDC68, 0x200D, 0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDC67, 0x200D, 0xD83D, 0xDC66) }
)

# The label is a fixed width so every line starts its sequence at the same
# column, and the ruler above counts from there.
$LABEL = 20

Write-Host ""
Write-Host "Each line: a label, the sequence, then >> and the column psmux"
Write-Host "believes it is at. Read the >> against the ruler. If >> sits to the"
Write-Host "left of that column, the terminal drew the sequence narrower than"
Write-Host "psmux counted, and everything after it on the line is shifted."
Write-Host ""

$tens = " " * $LABEL
$ones = " " * $LABEL
for ($i = 0; $i -lt 30; $i++) {
    $col = $LABEL + $i
    $tens += [string]([math]::Floor($col / 10) % 10)
    $ones += [string]($col % 10)
}
Write-Host $tens
Write-Host $ones

$bad = 0
foreach ($c in $cases) {
    $seq = Seq $c.u
    [Console]::Out.Write(("{0,-$LABEL}" -f $c.n))
    [Console]::Out.Write($seq)
    [Console]::Out.Flush()
    # Ask psmux, from inside the pane, where it thinks the cursor now is.
    # $TMUX points the command at this very session.
    $cx = ((& psmux display-message -p '#{cursor_x}' 2>&1) -join '').Trim()
    [Console]::Out.Write(">> psmux says column " + $cx)
    Write-Host ""
    # Did the sequence actually arrive, or did the encoding turn it into
    # question marks? psmux's own copy of the line is the place to look.
    $line = ((& psmux capture-pane -p 2>&1) -join "`n" -split "`n" |
             Where-Object { $_ -like ($c.n + "*") } | Select-Object -First 1)
    if ($line -and -not $line.Contains($seq)) {
        Write-Host ("  WARNING: the sequence did not reach the pane intact. psmux has: '" + $line + "'") -ForegroundColor Red
        $bad++
    }
}

[Console]::OutputEncoding = $savedOut

Write-Host ""
if ($bad -gt 0) {
    Write-Host "$bad line(s) never carried the real characters, so those rows measure" -ForegroundColor Red
    Write-Host "nothing. Check the shell's output encoding before reading the rest." -ForegroundColor Red
} else {
    Write-Host "The control line should agree: three CJK characters are six columns"
    Write-Host "in every terminal, so its >> sits exactly at the column psmux names."
    Write-Host "A sequence whose >> sits earlier than its number is the bug."
}
