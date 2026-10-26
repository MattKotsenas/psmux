# How many columns does THIS terminal give each emoji sequence?
#
# Run it in the terminal you want measured, from a normal prompt, not inside
# psmux or tmux: a multiplexer would answer for itself and the result would
# describe the multiplexer. Either PowerShell will do.
#
#     .\scripts\probe-emoji-width.ps1
#
# The measurement is the console's own cursor: write the sequence with
# WriteConsoleW, which is the call psmux writes with, and read the cursor
# column before and after. The difference is the number of columns the host
# gave the sequence. Nothing is guessed from a width table here, and each line
# is erased after it is measured, so the screen is left as it was found.
#
# It ends with a block that draws every sequence with a bar at the column the
# console counted. A glyph that reaches past its own bar was drawn wider than
# it was counted, and a gap before the bar is the opposite; a screenshot of
# that block says more than the table does. This is how the eight terminal
# survey in discussion #749 was made.
#
# What the console counts and what the terminal draws are two different
# things, and `scripts\probe-pane-emoji-shift.ps1` is the other half: it
# measures where text actually lands inside a psmux pane.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads a file with no byte
# order mark in the ANSI code page, so every character above ASCII is built
# from its code units below.

param(
    # Name for the terminal when it sets no environment variable this knows.
    [string] $Terminal
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class EmojiWidth
{
    [StructLayout(LayoutKind.Sequential)] public struct Coord { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SmallRect { public short L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct ConsoleInfo {
        public Coord Size; public Coord Cursor; public ushort Attrs;
        public SmallRect Window; public Coord MaxWindow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr h, out ConsoleInfo info);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleW(IntPtr h, string s, uint len, out uint wrote, IntPtr reserved);

    static IntPtr hOut = GetStdHandle(-11);

    public static bool IsConsole()
    {
        ConsoleInfo info;
        return GetConsoleScreenBufferInfo(hOut, out info);
    }

    static void Send(string s)
    {
        uint wrote;
        WriteConsoleW(hOut, s, (uint)s.Length, out wrote, IntPtr.Zero);
    }

    /// Draw text with the same call the measurement uses, so what the picture
    /// shows is what was measured and not whatever PowerShell's own output
    /// encoding would have made of it.
    public static void Write(string s) { Send(s); }

    static int Column()
    {
        ConsoleInfo info;
        if (!GetConsoleScreenBufferInfo(hOut, out info)) return -1;
        return info.Cursor.X;
    }

    /// Columns the host gave `s`, or -1 when the cursor could not be read.
    /// The line is wiped afterwards so the screen is left as it was found.
    public static int Width(string s)
    {
        Send("\r\n");
        int before = Column();
        if (before < 0) return -1;
        Send(s);
        int after = Column();
        if (after < 0 || after < before) return -1;
        Send("\r" + new string(' ', after + 2) + "\r");
        return after - before;
    }
}
"@

function Seq([int[]] $units) {
    $s = ""
    foreach ($u in $units) { $s += [char] $u }
    return $s
}

if (-not [EmojiWidth]::IsConsole()) {
    Write-Host "stdout is not a console here, so the cursor cannot be read." -ForegroundColor Red
    Write-Host "Run this from a terminal window rather than through a pipe."
    exit 1
}
if ($env:PSMUX -or $env:TMUX) {
    Write-Host "This is running inside a multiplexer, which would measure the" -ForegroundColor Red
    Write-Host "multiplexer and not the terminal. Detach and run it again."
    exit 1
}

# name and the UTF-16 code units. Nothing here says what any width table or
# any program thinks: the only number this script produces is the one the
# console itself reports.
$cases = @(
    @{ n = "U+0041 letter A";                         u = @(0x0041) },
    @{ n = "U+3042 hiragana A";                       u = @(0x3042) },
    @{ n = "U+2764 heart, no selector";               u = @(0x2764) },
    @{ n = "U+2764 U+FE0F heart with VS16";           u = @(0x2764, 0xFE0F) },
    @{ n = "U+2733 U+FE0F eight spoked asterisk";     u = @(0x2733, 0xFE0F) },
    @{ n = "U+1F44D thumbs up";                       u = @(0xD83D, 0xDC4D) },
    @{ n = "U+1F44D U+1F3FD with skin tone";          u = @(0xD83D, 0xDC4D, 0xD83C, 0xDFFD) },
    @{ n = "U+1F1EF U+1F1F5 flag of Japan";           u = @(0xD83C, 0xDDEF, 0xD83C, 0xDDF5) },
    @{ n = "U+1F3F3 U+FE0F ZWJ U+1F308 rainbow flag"; u = @(0xD83C, 0xDFF3, 0xFE0F, 0x200D, 0xD83C, 0xDF08) },
    @{ n = "man ZWJ woman ZWJ girl ZWJ boy family";   u = @(0xD83D, 0xDC68, 0x200D, 0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDC67, 0x200D, 0xD83D, 0xDC66) }
)

$rows = @()
$widths = @{}
foreach ($c in $cases) {
    $w = [EmojiWidth]::Width((Seq $c.u))
    $widths[$c.n] = $w
    $rows += [pscustomobject]@{
        sequence = $c.n
        columns  = $w
    }
}

# Who is being measured. A terminal that sets none of these is reported as
# unknown rather than guessed at, and the name typed by hand is what counts.
function Get-TerminalName {
    if ($env:WT_SESSION) {
        try {
            $pkg = Get-AppxPackage -Name "Microsoft.WindowsTerminal*" -EA SilentlyContinue | Select-Object -First 1
            if ($pkg) { return "Windows Terminal $($pkg.Version)" }
        } catch { }
        return "Windows Terminal"
    }
    if ($env:WEZTERM_EXECUTABLE -or $env:WEZTERM_PANE) {
        if ($env:WEZTERM_VERSION) { return "WezTerm $env:WEZTERM_VERSION" }
        return "WezTerm"
    }
    if ($env:TERM_PROGRAM) {
        if ($env:TERM_PROGRAM_VERSION) { return "$env:TERM_PROGRAM $env:TERM_PROGRAM_VERSION" }
        return $env:TERM_PROGRAM
    }
    if ($env:TERMINAL_EMULATOR) { return $env:TERMINAL_EMULATOR }
    if ($env:ConEmuPID) { return "ConEmu" }
    if ($env:ALACRITTY_WINDOW_ID -or $env:ALACRITTY_SOCKET) { return "Alacritty" }
    if ($env:SESSIONNAME -eq "Console" -and -not $env:TERM) { return "conhost (probably)" }
    return "unknown"
}

$name = if ($Terminal) { $Terminal } else { Get-TerminalName }

Write-Host ""
Write-Host "terminal: $name"
Write-Host "env:      WT_SESSION=$([bool]$env:WT_SESSION) WEZTERM_PANE=$([bool]$env:WEZTERM_PANE) TERM_PROGRAM=$env:TERM_PROGRAM TERM=$env:TERM"
Write-Host "shell:    PowerShell $($PSVersionTable.PSVersion)"
Write-Host "measured: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""
$rows | Format-Table -AutoSize
Write-Host "columns = how far this console's own cursor advanced, which is the"
Write-Host "          number of columns it gave the sequence. A -1 means the"
Write-Host "          position could not be read for that one."
Write-Host ""
Write-Host "For the survey: paste the whole block above, and name the terminal"
Write-Host "yourself if the line says unknown."

# -- the picture ---------------------------------------------------------
#
# A screenshot of this block says more than the table does, because two
# different things can disagree here: how many columns the console COUNTED
# (where the bar lands) and how wide the terminal DREW the glyph. A glyph that
# reaches past its bar was drawn wider than it was counted, and everything to
# its right on a real screen would be pushed along; a gap before the bar is
# the opposite.

$LABEL = 44
Write-Host ""
Write-Host "--- what this terminal draws ---"
Write-Host ""
Write-Host "The bar is where the console said the cursor ended up. A glyph that"
Write-Host "reaches past its own bar is drawn wider than the console counted."
Write-Host ""

$ruler = ""
for ($i = 1; $i -le 14; $i++) { $ruler += [string]($i % 10) }
Write-Host ((" " * $LABEL) + $ruler)

foreach ($c in $cases) {
    $w = $widths[$c.n]
    [EmojiWidth]::Write(("{0,-$LABEL}" -f $c.n))
    [EmojiWidth]::Write((Seq $c.u))
    [EmojiWidth]::Write("|")
    [EmojiWidth]::Write(("  counted {0}" -f $w))
    [EmojiWidth]::Write("`r`n")
}

Write-Host ""
Write-Host "A screenshot of the block above is the clearest way to show this to"
Write-Host "someone who cannot run the script."
