# scripts/probe-terminal-cursor.ps1 - what does this terminal say about its cursor?
#
# Usage:
#   .\scripts\probe-terminal-cursor.ps1          # ask, and print a report
#   .\scripts\probe-terminal-cursor.ps1 -Eye     # also walk through states and
#                                                # ask you what you see
#   .\scripts\probe-terminal-cursor.ps1 -Quiet   # the Markdown block only
#
# -Terminal names the terminal in the report. Without it you are asked, because
# the name is the one thing the machine often cannot supply.
#
# Either PowerShell will do, Windows PowerShell 5.1 as well as pwsh. Which one
# ran is printed with the result, because it has mattered: see the note on the
# escape character further down.
#
# Run it in the terminal you want to measure, NOT inside psmux or tmux: a
# multiplexer answers these queries itself, so what comes back would describe
# it and not the terminal underneath.
#
# WHY THIS EXISTS
#
# psmux has to leave the cursor the way it found it. The shape it can assert
# and reset, but the reset, `ESC [ 0 q`, goes to the TERMINAL's default and not
# to the state the user had. The blink is worse: terminals have no setting for
# it, so it is only ever changed by an escape sequence, and DEC private mode 12
# has just its two states and no "default" to go back to. The only way to put
# either back exactly is to ask the terminal first, and not every terminal
# answers, so what psmux can promise depends on the terminal it is running in.
#
# This asks, and prints the answers as a Markdown table to paste into the
# terminal support discussion. Nothing is left changed: whatever state the
# probe finds is written back before it returns.
#
# WHAT IT ASKS
#
#   ESC [ > q             XTVERSION, which terminal is this
#   ESC [ ? 12 $ p        DECRQM, is the cursor blinking
#   ESC [ ? 25 $ p        DECRQM, is the cursor visible. A control: every
#                         terminal implements mode 25, so a silent 12 beside a
#                         spoken 25 means 12 specifically is unsupported
#   ESC P $ q SP q ESC \  DECRQSS, what is the cursor style
#   ESC [ c               DA1, always answered, so it marks the end
#
# With -Eye it then sends mode 12 both ways, a steady bar and the reset, and
# walks DECSCUSR 0 through 8, asking after each one what you see. That is the
# part no query can answer: whether what the terminal REPORTS matches what it
# DRAWS, and whether anything past DECSCUSR 6 exists.

[CmdletBinding()]
param(
    # What to call this terminal in the report. Asked for at the start when it
    # is not given, because the name is the one thing the machine often cannot
    # supply: Windows Terminal and conhost do not answer XTVERSION, and the
    # version of a terminal installed outside a package is nowhere a script can
    # read it.
    [string]$Terminal,
    [switch]$Eye,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

# When this ran, and which version of the script ran. Both are printed at the
# start and carried in the Markdown block at the end, so a paste that mixes two
# runs together, or drops the tail of one, shows up as two different stamps.
$startedAt = Get-Date
$startedStamp = $startedAt.ToString('yyyy-MM-dd HH:mm:ss zzz')
$scriptStamp = 'unknown'
if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    $scriptStamp = (Get-Item $PSCommandPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class PsmuxCursorProbe
{
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1;
    const uint FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;
    const uint ENABLE_PROCESSED_INPUT = 0x0001;
    const uint ENABLE_LINE_INPUT = 0x0002;
    const uint ENABLE_ECHO_INPUT = 0x0004;
    const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    static extern IntPtr CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr h, byte[] buf, uint len, out uint wrote, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint len, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushConsoleInputBuffer(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr h, out ConsoleInfo info);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleW(IntPtr h, string s, uint len, out uint wrote, IntPtr reserved);

    [StructLayout(LayoutKind.Sequential)] public struct Coord { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public short L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    public struct ConsoleInfo
    {
        public Coord Size;
        public Coord Cursor;
        public ushort Attributes;
        public Rect Window;
        public Coord MaxWindow;
    }

    static IntPtr hIn = IntPtr.Zero, hOut = IntPtr.Zero;
    static uint savedIn, savedOut;

    /// Whether the console agreed to interpret escape sequences on the way
    /// out. Without it everything this probe writes is printed as text, the
    /// terminal never sees a query or a DECSCUSR, and a run says nothing about
    /// the terminal at all. Checked rather than assumed: some console hosts
    /// refuse the mode and the only sign is the escapes appearing on screen.
    public static bool VtOutput = false;
    public static uint ModeIn = 0, ModeOut = 0;

    /// Which handles were taken, for the record: "stdio" or "CONIN$/CONOUT$".
    public static string Path = "";

    /// Take the console, through stdio when stdio is a console.
    ///
    /// The point is to write where psmux writes. psmux sends its queries to
    /// stdout, and Rust's stdout on a console handle goes out through
    /// WriteConsoleW, so that is what this does too: a result measured on some
    /// other handle is a result about that handle. Opening CONOUT$ is the
    /// fallback for a run with the output piped somewhere, where stdio holds
    /// no console to take, and such a run says so in its report.
    public static void Open()
    {
        const int STD_INPUT_HANDLE = -10;
        const int STD_OUTPUT_HANDLE = -11;
        uint probe;
        hIn = GetStdHandle(STD_INPUT_HANDLE);
        hOut = GetStdHandle(STD_OUTPUT_HANDLE);
        bool inOk = hIn != IntPtr.Zero && hIn != (IntPtr)(-1) && GetConsoleMode(hIn, out probe);
        bool outOk = hOut != IntPtr.Zero && hOut != (IntPtr)(-1) && GetConsoleMode(hOut, out probe);
        Path = (inOk && outOk) ? "stdio" : "CONIN$/CONOUT$";
        if (!inOk)
            hIn = CreateFile("CONIN$", GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (!outOk)
            hOut = CreateFile("CONOUT$", GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (hIn == (IntPtr)(-1) || hOut == (IntPtr)(-1))
            throw new Exception("no console: CreateFile failed, error " + Marshal.GetLastWin32Error());
        ConsoleOut = GetConsoleMode(hOut, out probe);
        if (!GetConsoleMode(hIn, out savedIn) || !GetConsoleMode(hOut, out savedOut))
            throw new Exception("no console mode: error " + Marshal.GetLastWin32Error());
        ModeIn = savedIn;
        ModeOut = savedOut;
        if (SetConsoleMode(hOut, savedOut | ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        {
            uint now;
            VtOutput = GetConsoleMode(hOut, out now)
                && (now & ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0;
        }
    }

    public static void Close()
    {
        SetConsoleMode(hIn, savedIn);
        SetConsoleMode(hOut, savedOut);
    }

    static bool ConsoleOut = false;

    /// Write the way psmux does: WriteConsoleW with UTF-16 on a console, and
    /// bytes only when the handle is not one. The two are not interchangeable,
    /// see Open.
    public static void Send(string s)
    {
        uint wrote;
        if (ConsoleOut)
        {
            WriteConsoleW(hOut, s, (uint)s.Length, out wrote, IntPtr.Zero);
            return;
        }
        byte[] b = Encoding.ASCII.GetBytes(s);
        WriteFile(hOut, b, (uint)b.Length, out wrote, IntPtr.Zero);
    }

    static int Column()
    {
        ConsoleInfo info;
        if (!GetConsoleScreenBufferInfo(hOut, out info)) return -1;
        return info.Cursor.X;
    }

    /// How many columns a harmless escape sequence took up on screen.
    ///
    /// The console mode saying yes to VT output is not the same as the screen
    /// acting on it, so write one and look at where the cursor ended up. Zero
    /// means it was acted on, more than zero means it was drawn as text, and
    /// -1 means the position could not be read and the question stays open.
    ///
    /// This only sees the console layer. A console can consume a sequence it
    /// knows, which reads as zero here, and pass one it does not know through
    /// to a window that draws it as text. That case is invisible from this
    /// side and only the eye catches it, which is why there is a question
    /// about it further down.
    public static int EchoWidth()
    {
        Send("\r\n");
        int before = Column();
        if (before < 0) return -1;
        Send("\x1b[0m");
        int after = Column();
        if (after > before) Send("\r" + new string(' ', after) + "\r");
        if (after < 0 || after < before) return -1;
        return after - before;
    }

    /// Send `queries` and read until the terminal has been quiet for a moment.
    ///
    /// A quiet window rather than a sentinel, because terminals answer out of
    /// order: WezTerm replies to DA1 before the rest, so stopping at DA1 would
    /// leave the answers that matter in flight.
    public static string Ask(string queries, int budgetMs)
    {
        uint raw = savedIn & ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT);
        raw |= ENABLE_VIRTUAL_TERMINAL_INPUT;
        SetConsoleMode(hIn, raw);
        FlushConsoleInputBuffer(hIn);
        var acc = new StringBuilder();
        try
        {
            Send(queries);
            var buf = new byte[1024];
            var deadline = DateTime.UtcNow.AddMilliseconds(budgetMs);
            var quiet = DateTime.MinValue;
            while (DateTime.UtcNow < deadline)
            {
                uint avail;
                if (GetNumberOfConsoleInputEvents(hIn, out avail) && avail > 0)
                {
                    uint got;
                    if (ReadFile(hIn, buf, (uint)buf.Length, out got, IntPtr.Zero) && got > 0)
                    {
                        for (int i = 0; i < got; i++)
                        {
                            byte c = buf[i];
                            if (c == 0x1b) acc.Append("<ESC>");
                            else if (c >= 0x20 && c < 0x7f) acc.Append((char)c);
                            else acc.Append("<" + c.ToString("X2") + ">");
                        }
                        quiet = DateTime.UtcNow.AddMilliseconds(120);
                    }
                }
                else if (quiet != DateTime.MinValue && DateTime.UtcNow > quiet) break;
                Thread.Sleep(10);
            }
        }
        finally { SetConsoleMode(hIn, savedIn); }
        return acc.ToString();
    }
}
'@

# -- readers -------------------------------------------------------------

# Every sequence is built from [char]27, never from the backtick e escape.
#
# Windows PowerShell 5.1 does not have that escape: there it is just the letter
# e, so a probe written that way types its queries on the screen instead of
# sending them. Every terminal then looks like it answers nothing, and the
# escapes on screen look like the terminal's doing. Measured: JetBrains
# RustRover, ConEmu and Alacritty were each recorded as silent for this reason
# alone, because each one starts powershell.exe rather than pwsh. The check
# below is what keeps that from coming back.
$ESC = [char]27
$Q_XTVERSION = $ESC + '[>q'
$Q_BLINK     = $ESC + '[?12$p'
$Q_VISIBLE   = $ESC + '[?25$p'
$Q_STYLE     = $ESC + 'P$q q' + $ESC + '\'
$Q_DA1       = $ESC + '[c'
if ([int][char]$Q_DA1[0] -ne 27) {
    throw "the queries do not begin with an escape: this shell mangled them"
}
$ALL_QUERIES = @($Q_XTVERSION, $Q_BLINK, $Q_VISIBLE, $Q_STYLE, $Q_DA1)

# Each query goes out on its own rather than as one burst.
#
# A terminal that does not recognise one of them can fall out of its parse
# state and draw everything after it on screen as text, which then reads as
# "answers nothing" for queries it does in fact answer. Measured in JetBrains
# RustRover 2026.2.2: `ESC [ ? 12 $ p` sent on its own was silent and left
# nothing on screen, while the same sequence sent straight after `ESC [ > q` in
# one burst was drawn along with the rest of the burst. One query at a time
# costs one timeout each on a terminal that stays silent, which is the right
# trade for not having one unknown sequence decide the whole run.
function Ask-Each([string[]]$queries, [int]$eachMs) {
    $acc = ""
    foreach ($q in $queries) { $acc += [PsmuxCursorProbe]::Ask($q, $eachMs) }
    return $acc
}

function Get-Identity([string]$text) {
    # XTVERSION answers in DCS, not CSI: DCS > | <name> ST.
    $m = [regex]::Match($text, '<ESC>P>\|(?<id>[^<]*)<ESC>')
    if ($m.Success) { return $m.Groups['id'].Value }
    return $null
}

function Get-Blink([string]$text) {
    # DECRQM: CSI ? 12 ; Ps $ y. 1 set, 3 permanently set, 2 reset,
    # 4 permanently reset, 0 the mode is not recognised.
    $m = [regex]::Match($text, '<ESC>\[\?12;(?<ps>\d+)\$y')
    if (-not $m.Success) { return $null }
    return $m.Groups['ps'].Value
}

function Get-Mode25([string]$text) {
    $m = [regex]::Match($text, '<ESC>\[\?25;(?<ps>\d+)\$y')
    if (-not $m.Success) { return $null }
    return $m.Groups['ps'].Value
}

function Get-Style([string]$text) {
    # DECRQSS answers in two shapes: a report, DCS 1 $ r Ps SP q ST, and a
    # refusal, DCS 0 $ r ST with no payload. Both are answers; only the first
    # says anything.
    $m = [regex]::Match($text, '<ESC>P1\$r(?<ps>\d*) q<ESC>')
    if ($m.Success) {
        if ($m.Groups['ps'].Value -eq '') { return '0' }
        return $m.Groups['ps'].Value
    }
    if ($text -match '<ESC>P0\$r') { return 'refused' }
    return $null
}

function Get-DA1([string]$text) {
    $m = [regex]::Match($text, '<ESC>\[\?(?<id>[0-9;]*)c')
    if ($m.Success) { return $m.Groups['id'].Value }
    return $null
}

# No [string] on these: a typed parameter turns $null into the empty string,
# and then "no answer" cannot be told from an answer nobody understood.
function Format-Blink($ps) {
    if ([string]::IsNullOrEmpty($ps)) { return 'no answer' }
    switch ($ps) {
        '1' { 'blinking' }
        '2' { 'steady' }
        '3' { 'blinking (permanent)' }
        '4' { 'steady (permanent)' }
        '0' { 'mode not recognised' }
        default { "unexpected Ps $ps" }
    }
}

$STYLE_NAMES = @{
    '0' = 'the terminal default'; '1' = 'blinking block'; '2' = 'steady block'
    '3' = 'blinking underline';   '4' = 'steady underline'
    '5' = 'blinking bar';         '6' = 'steady bar'
}

function Format-Style($ps) {
    if ([string]::IsNullOrEmpty($ps)) { return 'no answer' }
    if ($ps -eq 'refused') { return 'refused' }
    if ($STYLE_NAMES.ContainsKey($ps)) { return "$ps ($($STYLE_NAMES[$ps]))" }
    return $ps
}

function Ask-Eye([string]$what) {
    while ($true) {
        Write-Host ""
        Write-Host "  $what" -ForegroundColor Cyan
        $a = Read-Host "  Is the cursor blinking? (y/n)"
        if ($a -match '^[yY]') { return 'blinking' }
        if ($a -match '^[nN]') { return 'steady' }
    }
}

# -- who is being measured -----------------------------------------------

function Get-DetectedName {
    if ($env:WT_SESSION) {
        try {
            $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($pkg) { return "Windows Terminal $($pkg.Version)" }
        } catch { }
        return 'Windows Terminal'
    }
    if ($env:TERM_PROGRAM) {
        if ($env:TERM_PROGRAM_VERSION) { return "$env:TERM_PROGRAM $env:TERM_PROGRAM_VERSION" }
        return $env:TERM_PROGRAM
    }
    return $null
}

$detected = Get-DetectedName

# -- refuse to measure a multiplexer -------------------------------------

if ($env:TMUX -or $env:PSMUX_SESSION -or $env:PSMUX_PANE) {
    Write-Host "This is a psmux or tmux pane (TMUX=$env:TMUX PSMUX_SESSION=$env:PSMUX_SESSION)." -ForegroundColor Red
    Write-Host "The multiplexer answers these queries itself, so the result would describe" -ForegroundColor Red
    Write-Host "it and not the terminal. Run this in a plain terminal window." -ForegroundColor Red
    exit 1
}

if (-not $Quiet) {
    Write-Host "=== psmux terminal cursor probe ===" -ForegroundColor Cyan
    Write-Host ("  started $startedStamp, script of $scriptStamp") -ForegroundColor DarkGray
    Write-Host ("  shell " + $PSVersionTable.PSEdition + " " + $PSVersionTable.PSVersion) -ForegroundColor DarkGray
    Write-Host ""
}

if (-not $Terminal -and -not $Quiet) {
    Write-Host "Which terminal is this, and which version?" -ForegroundColor Cyan
    Write-Host "  name the TERMINAL, not the shell or the OS, as in" -ForegroundColor DarkGray
    Write-Host "  conhost (Windows 11 26200), Alacritty 0.13.2, VS Code terminal 1.95" -ForegroundColor DarkGray
    if ($detected) {
        Write-Host "  detected: $detected" -ForegroundColor DarkGray
        Write-Host "  press Enter to use that, or what the terminal reports for itself" -ForegroundColor DarkGray
    } else {
        Write-Host "  nothing detected from the environment" -ForegroundColor DarkGray
        Write-Host "  press Enter to use whatever the terminal reports for itself" -ForegroundColor DarkGray
    }
    $typed = Read-Host "  terminal"
    if ($typed.Trim()) { $Terminal = $typed.Trim() }
}

# -- ask -----------------------------------------------------------------

[PsmuxCursorProbe]::Open()

# A run with no VT output measures nothing: every sequence below would be
# printed as text instead of reaching the terminal, and the empty replies that
# follow would look exactly like a terminal that answers nothing.
if (-not [PsmuxCursorProbe]::VtOutput) {
    [PsmuxCursorProbe]::Close()
    Write-Host ""
    Write-Host "STOP: this console will not interpret escape sequences." -ForegroundColor Red
    Write-Host ("  console mode out = 0x{0:X}, and ENABLE_VIRTUAL_TERMINAL_PROCESSING could not be set" -f [PsmuxCursorProbe]::ModeOut) -ForegroundColor Red
    Write-Host "  Everything this probe writes would be printed as text rather than acted on," -ForegroundColor Red
    Write-Host "  so the result would describe nothing. If you saw raw escapes on screen in an" -ForegroundColor Red
    Write-Host "  earlier run, that run measured this, not the terminal." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Try a newer shell in the same terminal (pwsh rather than cmd), or report the" -ForegroundColor Red
    Write-Host "  console mode above: a terminal that cannot be put into VT output mode is" -ForegroundColor Red
    Write-Host "  itself worth recording." -ForegroundColor Red
    exit 2
}

# The mode saying yes is not proof. Write one harmless sequence and look at
# where the cursor ended up: in some terminals the console accepts the mode and
# the window still draws the escapes as text.
$echo = [PsmuxCursorProbe]::EchoWidth()
if ($echo -gt 0) {
    [PsmuxCursorProbe]::Close()
    Write-Host ""
    Write-Host "STOP: escape sequences are being printed, not acted on." -ForegroundColor Red
    Write-Host "  ESC [ 0 m took up $echo columns on screen, so it was drawn as text." -ForegroundColor Red
    Write-Host "  The console accepted VT output mode, so this is not the console refusing:" -ForegroundColor Red
    Write-Host "  whatever draws this window does not read escape sequences." -ForegroundColor Red
    Write-Host "  Nothing below would describe the terminal's cursor, so the run stops here." -ForegroundColor Red
    exit 2
}

$eyeBlink = @()
$eyeShapes = @()
# Which queries this terminal draws on screen instead of acting on. Only
# filled in when nothing answered, which is when the question arises.
$drawn = @()
try {
    $raw = Ask-Each $ALL_QUERIES 400
    $identity = Get-Identity $raw
    $blink = Get-Blink $raw
    $mode25 = Get-Mode25 $raw
    $style = Get-Style $raw
    $da1 = Get-DA1 $raw

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "raw reply: [$raw]" -ForegroundColor DarkGray
        if ([PsmuxCursorProbe]::Path -eq 'stdio') {
            Write-Host "written on: stdio, the same path psmux writes its queries on" -ForegroundColor DarkGray
        } else {
            Write-Host "written on: CONOUT$, because stdio here is not a console." -ForegroundColor Yellow
            Write-Host "  psmux writes its queries on stdout, so this is not quite the same path." -ForegroundColor Yellow
            Write-Host "  Run it again without redirecting the output to measure the one psmux uses." -ForegroundColor Yellow
        }
        Write-Host ""
        @(
            [PSCustomObject]@{ Query = 'XTVERSION  ESC[>q';     Answer = $(if ($identity) { $identity } else { 'no answer' }) }
            [PSCustomObject]@{ Query = 'DECRQM 12  blink';      Answer = (Format-Blink $blink) }
            [PSCustomObject]@{ Query = 'DECRQM 25  visible';    Answer = $(if ($mode25) { "answered ($mode25)" } else { 'no answer' }) }
            [PSCustomObject]@{ Query = 'DECRQSS    cursor style'; Answer = (Format-Style $style) }
            [PSCustomObject]@{ Query = 'DA1        ESC[c';      Answer = $(if ($da1) { $da1 } else { 'no answer: the probe never got through' }) }
        ) | Format-Table -AutoSize | Out-String | Write-Host
    }

    # Nothing answered, DA1 included, and DA1 is the one query almost every
    # terminal answers. Two different terminals look like this: one where the
    # writes arrive and only the replies are lost, and one where nothing is
    # read at all and the sequences are landing somewhere as text. The queries
    # cannot tell them apart, so ask the screen.
    if (-not $da1 -and -not $Quiet) {
        Write-Host "Nothing answered, DA1 included, and almost every terminal answers DA1." -ForegroundColor Yellow
        Write-Host "Either the writes arrive and the replies are lost, or nothing arrives at all," -ForegroundColor Yellow
        Write-Host "and the queries cannot tell those apart. So one at a time, with the screen as" -ForegroundColor Yellow
        Write-Host "the witness. Answer y if anything at all appeared, even a single character." -ForegroundColor Yellow
        Write-Host ""
        $named = @(
            @{ N = 'XTVERSION  ESC [ > q';         Q = $Q_XTVERSION }
            @{ N = 'DECRQM 12  ESC [ ? 12 $ p';    Q = $Q_BLINK }
            @{ N = 'DECRQM 25  ESC [ ? 25 $ p';    Q = $Q_VISIBLE }
            @{ N = 'DECRQSS    ESC P $ q SP q ST'; Q = $Q_STYLE }
            @{ N = 'DA1        ESC [ c';           Q = $Q_DA1 }
        )
        foreach ($one in $named) {
            [PsmuxCursorProbe]::Send($one.Q)
            Start-Sleep -Milliseconds 250
            $a = Read-Host ("  sent " + $one.N + ", anything on screen (y/n)")
            $drawn += [PSCustomObject]@{
                Query = $one.N
                Result = $(if ($a.Trim().ToLower().StartsWith('y')) { 'drawn as text' } else { 'silent' })
            }
        }
        Write-Host ""
        $allDrawn = (($drawn | Where-Object { $_.Result -eq 'silent' }).Count -eq 0)
        if ($allDrawn) {
            Write-Host "STOP: every one of them was drawn instead of acted on." -ForegroundColor Red
            Write-Host "  Nothing this probe writes reaches the terminal, so a table of no answer" -ForegroundColor Red
            Write-Host "  rows would read as a property of the terminal when it is a property of" -ForegroundColor Red
            Write-Host "  this path to it. Worth recording as that, with the shell named, but not" -ForegroundColor Red
            Write-Host "  as a measurement of the cursor." -ForegroundColor Red
            exit 2
        }
        Write-Host "  Some were silent, so those reach the terminal and only the replies are" -ForegroundColor Green
        Write-Host "  lost. Worth measuring: psmux can still change this cursor, it just cannot" -ForegroundColor Green
        Write-Host "  read it. The table of which ones are drawn goes in the report." -ForegroundColor Green
        Write-Host ""
    }

    if ($Eye) {
        Write-Host "Now a few states, to see whether what the terminal REPORTS is what it DRAWS." -ForegroundColor Cyan
        $steps = @(
            @{ Label = 'as found';      Send = '' }
            @{ Label = 'mode 12 reset'; Send = $ESC + '[?12l' }
            @{ Label = 'mode 12 set';   Send = $ESC + '[?12h' }
            @{ Label = 'steady bar';    Send = $ESC + '[6 q' }
            @{ Label = 'shape reset';   Send = $ESC + '[0 q' }
        )
        foreach ($step in $steps) {
            if ($step.Send -ne '') { [PsmuxCursorProbe]::Send($step.Send); Start-Sleep -Milliseconds 250 }
            $r = Ask-Each @($Q_BLINK, $Q_STYLE, $Q_DA1) 300
            $prompt = if ($step.Send -eq '') { "as found, nothing sent yet" } else { "after " + $step.Label + ", sent " + ($step.Send -replace $ESC, "ESC ") }
            $seen = Ask-Eye $prompt
            $eyeBlink += [PSCustomObject]@{
                Step = $step.Label
                Reported = (Format-Blink (Get-Blink $r))
                Seen = $seen
            }
        }

        Write-Host ""
        Write-Host "And the shapes. DECSCUSR defines 0 to 6; 7 and 8 are past the end, to see" -ForegroundColor Cyan
        Write-Host "whether this terminal has quietly extended it." -ForegroundColor Cyan
        Write-Host "Answer with a word: block / empty / under / dunder / bar / vintage / unchanged" -ForegroundColor Cyan
        foreach ($ps in 0..8) {
            [PsmuxCursorProbe]::Send($ESC + "[$ps q")
            Start-Sleep -Milliseconds 250
            $r = Ask-Each @($Q_STYLE, $Q_DA1) 300
            Write-Host ""
            Write-Host ("  sent ESC [ $ps q, reported " + (Format-Style (Get-Style $r))) -ForegroundColor Cyan
            $seen = Read-Host "  What does it look like"
            $eyeShapes += [PSCustomObject]@{ Sent = "ESC[$ps q"; Reported = (Format-Style (Get-Style $r)); Seen = $seen }
        }
    }
}
finally {
    # Put back what was found, as well as these two controls can say it.
    if ($style -and $style -match '^\d+$') { [PsmuxCursorProbe]::Send($ESC + "[$style q") }
    elseif ($Eye) { [PsmuxCursorProbe]::Send($ESC + '[0 q') }
    if ($blink -eq '1' -or $blink -eq '3') { [PsmuxCursorProbe]::Send($ESC + '[?12h') }
    elseif ($blink -eq '2' -or $blink -eq '4') { [PsmuxCursorProbe]::Send($ESC + '[?12l') }
    [PsmuxCursorProbe]::Close()
}

# -- what it means for psmux ---------------------------------------------

$canBlink = ($blink -eq '1' -or $blink -eq '2' -or $blink -eq '3' -or $blink -eq '4')
$canShape = ($style -match '^\d+$')

# Does mode 12 describe what is drawn? A terminal can track the mode faithfully
# and still not use it: the blink of a DECSCUSR shape is the other way to say
# the same thing, and some terminals only honour that one.
$mode12Drawn = $null
if ($Eye -and $eyeBlink.Count -ge 3) {
    $off = $eyeBlink[1]   # after mode 12 reset
    $on  = $eyeBlink[2]   # after mode 12 set
    $mode12Drawn = ($off.Seen -eq 'steady' -and $on.Seen -eq 'blinking')
}

# Does the report match the cursor that was there before anything was sent?
#
# This is the one a restore stands on. psmux reads the blink at attach and
# writes that value back on the way out, so a terminal which reports a state it
# is not drawing hands the user a cursor they never had. The later steps cannot
# answer it: a report that tracks what was just written to it still says
# nothing about whether it described the state it was found in. Measured in
# Alacritty 0.17.0: DECRQM answered mode 12 set over a cursor that was steady,
# and tracked both writes afterwards faithfully.
$reportTrue = $null
if ($Eye -and $eyeBlink.Count -ge 1 -and $eyeBlink[0].Reported -match '^(blinking|steady)$') {
    $reportTrue = ($eyeBlink[0].Reported -eq $eyeBlink[0].Seen)
}

# Is the blink carried in a DECSCUSR code drawn? `ESC [ 6 q` names a STEADY
# bar, so a cursor still blinking after it says the code's blink bit is ignored
# too. This only has an answer when the cursor was seen blinking somewhere in
# the run: a steady cursor after a steady shape proves nothing if it was never
# blinking to begin with. Measured in mintty 3.8.3: neither mode 12 nor the
# code moves the blink, and the terminal's own setting decides, which means
# naming a blinking shape does not help there either.
$shapeBlinkDrawn = $null
if ($Eye -and $eyeBlink.Count -ge 4) {
    if (($eyeBlink | Where-Object { $_.Seen -eq 'blinking' }).Count -gt 0) {
        $shapeBlinkDrawn = ($eyeBlink[3].Seen -eq 'steady')
    }
}

# And whether a shape is drawn at all. A terminal that ignores DECSCUSR as well
# ignores everything psmux could say about the cursor, which is a different
# answer from "name a shape instead of asking for the blink".
$shapeDrawn = $null
if ($Eye -and $eyeShapes.Count -ge 7) {
    $shapeDrawn = (($eyeShapes.Seen | Sort-Object -Unique).Count -gt 1)
}

if (-not $Quiet) {
    Write-Host "What psmux can do here:" -ForegroundColor Cyan
    if ($canBlink) { Write-Host "  the blink can be put back exactly when psmux exits" -ForegroundColor Green }
    else { Write-Host "  the blink cannot be read, so psmux can only undo its own write" -ForegroundColor Yellow }
    if ($canShape) { Write-Host "  the shape can be put back exactly when psmux exits" -ForegroundColor Green }
    if ($false -eq $reportTrue) {
        Write-Host ("  but the blink report did not match the cursor it was found with: " + $eyeBlink[0].Reported) -ForegroundColor Yellow
        Write-Host ("  was reported over a cursor that was " + $eyeBlink[0].Seen + ", so a restore from it") -ForegroundColor Yellow
        Write-Host "  hands back a cursor the user did not have" -ForegroundColor Yellow
    }
    else { Write-Host "  the shape cannot be read, so psmux falls back to ESC [ 0 q, as tmux does" -ForegroundColor Yellow }
    if ($false -eq $shapeDrawn) {
        Write-Host "  DECSCUSR is not drawn either: nothing psmux can send changes the cursor" -ForegroundColor Yellow
        Write-Host "  here, so neither cursor-style nor cursor-blink has any visible effect" -ForegroundColor Yellow
    }
    elseif ($null -ne $mode12Drawn) {
        if ($mode12Drawn) {
            Write-Host "  mode 12 is drawn, so cursor-blink works on its own here" -ForegroundColor Green
        } elseif ($false -eq $shapeBlinkDrawn) {
            Write-Host "  neither mode 12 nor the blink in a DECSCUSR code is drawn: nothing psmux" -ForegroundColor Yellow
            Write-Host "  sends moves the blink here, the terminal's own setting decides it" -ForegroundColor Yellow
        } else {
            Write-Host "  mode 12 is tracked but NOT drawn: cursor-blink on its own has no visible" -ForegroundColor Yellow
            Write-Host "  effect, and a shape has to be named (cursor-style blinking-bar)" -ForegroundColor Yellow
        }
    }
    Write-Host ""
}

# -- the block to paste into the discussion ------------------------------

# What was typed wins, then what the terminal says about itself, then what the
# environment betrays. Whether XTVERSION answered is a row in the table below,
# so the heading does not have to carry it.
$name = $Terminal
if (-not $name) { $name = $identity }
if (-not $name) { $name = $detected }
if (-not $name) { $name = 'unknown terminal' }

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("### $name")
[void]$md.AppendLine()
[void]$md.AppendLine("Measured $startedStamp, with the probe as it stood on $scriptStamp,")
[void]$md.AppendLine("from PowerShell $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion).")
[void]$md.AppendLine()
[void]$md.AppendLine("| question | answer |")
[void]$md.AppendLine("|---|---|")
if ([PsmuxCursorProbe]::Path -ne 'stdio') {
    [void]$md.AppendLine("| how this was measured | not on stdio, so not the path psmux uses |")
}
[void]$md.AppendLine("| XTVERSION | $(if ($identity) { '`' + $identity + '`' } else { 'no answer' }) |")
[void]$md.AppendLine("| DA1 | $(if ($da1) { '`' + $da1 + '`' } else { 'no answer' }) |")
[void]$md.AppendLine("| DECRQM mode 12, the blink | $(Format-Blink $blink) |")
[void]$md.AppendLine("| DECRQM mode 25, a control | $(if ($mode25) { "answered, Ps $mode25" } else { 'no answer' }) |")
[void]$md.AppendLine("| DECRQSS, the cursor style | $(Format-Style $style) |")
if ($null -ne $reportTrue) {
    $rt = if ($reportTrue) { 'yes' }
          else { 'NO, it reported ' + $eyeBlink[0].Reported + ' over a cursor that was ' + $eyeBlink[0].Seen }
    [void]$md.AppendLine("| the blink report matched the cursor as found | $rt |")
}
[void]$md.AppendLine("| psmux can restore the blink | $(if ($canBlink) { 'yes' } else { 'no, it can only undo its own write' }) |")
[void]$md.AppendLine("| psmux can restore the shape | $(if ($canShape) { 'yes' } else { 'no, it falls back to the reset tmux sends' }) |")
if ($null -ne $shapeDrawn) {
    [void]$md.AppendLine("| DECSCUSR changes the cursor | $(if ($shapeDrawn) { 'yes' } else { 'no, the shape never changed' }) |")
}
if ($null -ne $shapeBlinkDrawn) {
    $sb = if ($shapeBlinkDrawn) { 'yes, so cursor-style blinking-bar blinks' }
          else { "no, the terminal's own setting decides the blink" }
    [void]$md.AppendLine("| the blink in a DECSCUSR code is drawn | $sb |")
}

if ($null -ne $mode12Drawn) {
    $m12 = if ($mode12Drawn) { 'yes, so cursor-blink works on its own' }
           elseif ($false -eq $shapeDrawn) { 'no, and nor is anything else' }
           elseif ($false -eq $shapeBlinkDrawn) { 'no, and nor is the blink in a shape code' }
           else { 'no, so a shape has to be named' }
    [void]$md.AppendLine("| mode 12 is drawn, not just tracked | $m12 |")
}

if (-not $da1) {
    [void]$md.AppendLine()
    [void]$md.AppendLine("No query was answered here, DA1 included, so every restore row above is")
    [void]$md.AppendLine("a no by default: psmux cannot read this cursor, only write it. The escapes")
    [void]$md.AppendLine("were not drawn on screen, so the writes do arrive and the seen column below")
    [void]$md.AppendLine("is what this terminal has to be judged on.")
}

if ($drawn.Count -gt 0) {
    [void]$md.AppendLine()
    [void]$md.AppendLine("Sent one at a time, with the screen as the witness:")
    [void]$md.AppendLine()
    [void]$md.AppendLine("| query | what the terminal did with it |")
    [void]$md.AppendLine("|---|---|")
    foreach ($r in $drawn) { [void]$md.AppendLine("| ``$($r.Query)`` | $($r.Result) |") }
}

if ($Eye) {
    [void]$md.AppendLine()
    [void]$md.AppendLine("Reported beside what was on screen:")
    [void]$md.AppendLine()
    [void]$md.AppendLine("| step | reported | seen |")
    [void]$md.AppendLine("|---|---|---|")
    foreach ($r in $eyeBlink) { [void]$md.AppendLine("| $($r.Step) | $($r.Reported) | $($r.Seen) |") }
    [void]$md.AppendLine()
    [void]$md.AppendLine("| sent | reported | seen |")
    [void]$md.AppendLine("|---|---|---|")
    foreach ($r in $eyeShapes) { [void]$md.AppendLine("| ``$($r.Sent)`` | $($r.Reported) | $($r.Seen) |") }
}

if (-not $Quiet) {
    Write-Host "Paste this into the discussion:" -ForegroundColor Cyan
    Write-Host ""
}
Write-Host $md.ToString()
