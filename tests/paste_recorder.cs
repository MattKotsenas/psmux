// paste_recorder.cs - stdin byte recorder for the psmux paste route tests (issue #684).
//
// Compiled at test time by tests\test_issue684_paste_route.ps1 with the
// in-box csc.exe, so the E2E test needs no toolchain beyond .NET Framework.
//
// It is the C# equivalent of the dump.c recorder gabri-ns attached to #684:
// a pane child that announces bracketed paste, paints one line so the inbox
// conhost flushes its output, then records every byte that reaches it.
//
//   paste_recorder.exe <logfile> <seconds> [vt|records] [stopfile]
//
//     stopfile (optional) the recorder also ends, and writes its log, as soon
//              as this file exists.  A caller whose schedule is not fixed (the
//              ssh suite, whose start up time varies by seconds) passes a long
//              <seconds> as a ceiling and ends the recording when it is done,
//              so the pane never dies in the middle of the thing measured.
//
//     vt       (default) ENABLE_VIRTUAL_TERMINAL_INPUT on, cooked bits off,
//              reads raw bytes with ReadFile.  This is the node / nvim shape:
//              a byte stream reader that reassembles ESC[200~ itself.
//     records  ENABLE_MOUSE_INPUT on, cooked bits off, VIRTUAL_TERMINAL_INPUT
//              off, reads INPUT_RECORDs with ReadConsoleInputW.  This is the
//              crossterm / Helix shape from issue #98, the child that must
//              never be handed injected marker bytes because it would show
//              them as the literal characters [ 2 0 0 ~.
//
// The log ends with a machine readable block the PowerShell test parses:
//   TOTAL <n>
//   HEX <lowercase hex, no separators>
//   HAS200 YES|NO
//   HAS201 YES|NO
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class PasteRecorder
{
    const int STD_INPUT_HANDLE = -10;
    const int STD_OUTPUT_HANDLE = -11;

    const uint ENABLE_PROCESSED_INPUT = 0x0001;
    const uint ENABLE_LINE_INPUT = 0x0002;
    const uint ENABLE_ECHO_INPUT = 0x0004;
    const uint ENABLE_WINDOW_INPUT = 0x0008;
    const uint ENABLE_MOUSE_INPUT = 0x0010;
    const uint ENABLE_EXTENDED_FLAGS = 0x0080;
    const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr h, byte[] buf, uint n, out uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushFileBuffers(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleCP(uint codePage);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleOutputCP(uint codePage);

    [StructLayout(LayoutKind.Explicit)]
    struct InputRecord
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort RepeatCount;
        [FieldOffset(10)] public ushort VirtualKeyCode;
        [FieldOffset(12)] public ushort VirtualScanCode;
        [FieldOffset(14)] public ushort UnicodeChar;
        [FieldOffset(16)] public uint ControlKeyState;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ReadConsoleInputW(IntPtr h, [Out] InputRecord[] buf, uint len, out uint read);

    static readonly MemoryStream Collected = new MemoryStream();
    static readonly object Gate = new object();

    static int Main(string[] argv)
    {
        string path = argv.Length > 0 ? argv[0] : "paste_recorder.log";
        int seconds = argv.Length > 1 ? int.Parse(argv[1]) : 10;
        string mode = argv.Length > 2 ? argv[2] : "vt";
        string stopFile = argv.Length > 3 ? argv[3] : null;

        // Read stdin as UTF-8, the way node and nvim do.  Without this conhost
        // converts the UTF-16 it holds down to the console's ANSI code page on
        // the way out of ReadFile and a pasted emoji arrives as '?'.  That is a
        // property of the recorder, not of the paste: measured, both routes
        // delivered the same mangled bytes before this call was added.
        SetConsoleCP(65001);
        SetConsoleOutputCP(65001);

        IntPtr hin = GetStdHandle(STD_INPUT_HANDLE);
        IntPtr hout = GetStdHandle(STD_OUTPUT_HANDLE);

        uint inMode, outMode;
        GetConsoleMode(hin, out inMode);
        GetConsoleMode(hout, out outMode);

        uint raw = inMode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
        if (mode == "records")
        {
            // A deliberate INPUT_RECORD reader: mouse on, virtual terminal
            // input off.  psmux's mode_is_deliberate_record_reader keys on
            // exactly this shape.
            raw &= ~ENABLE_VIRTUAL_TERMINAL_INPUT;
            raw |= ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS | ENABLE_WINDOW_INPUT;
        }
        else
        {
            raw |= ENABLE_VIRTUAL_TERMINAL_INPUT;
        }
        SetConsoleMode(hin, raw);
        SetConsoleMode(hout, outMode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);

        uint nowIn;
        GetConsoleMode(hin, out nowIn);

        // Announce bracketed paste, then PAINT.  A child that enables a mode
        // and prints nothing has its output held by the inbox conhost until
        // its next paint, so psmux would never see the ?2004h (issue #684,
        // "a child that enables a mode and prints nothing is invisible").
        Emit(hout, Encoding.ASCII.GetBytes("\x1b[?2004h"));
        Emit(hout, Encoding.ASCII.GetBytes(
            "\x1b[2J\x1b[Hpaste_recorder " + mode + ": bracketed paste ON, recording " + seconds + "s\r\n"));

        var reader = new Thread(mode == "records" ? (ThreadStart)(() => ReadRecords(hin))
                                                  : (ThreadStart)(() => ReadBytes(hin)));
        reader.IsBackground = true;
        reader.Start();

        if (string.IsNullOrEmpty(stopFile)) {
            Thread.Sleep(seconds * 1000);
        } else {
            var until = DateTime.UtcNow.AddSeconds(seconds);
            while (DateTime.UtcNow < until && !File.Exists(stopFile)) Thread.Sleep(100);
        }

        byte[] got;
        lock (Gate) { got = Collected.ToArray(); }

        var sb = new StringBuilder();
        sb.Append("mode=").Append(mode)
          .Append(" initialIn=0x").Append(inMode.ToString("x8"))
          .Append(" rawIn=0x").Append(nowIn.ToString("x8"))
          .Append(" initialOut=0x").Append(outMode.ToString("x8")).Append('\n');
        sb.Append("TEXT ").Append(Printable(got)).Append('\n');
        sb.Append("TOTAL ").Append(got.Length).Append('\n');
        sb.Append("HEX ").Append(Hex(got)).Append('\n');
        sb.Append("HAS200 ").Append(Contains(got, "\x1b[200~") ? "YES" : "NO").Append('\n');
        sb.Append("HAS201 ").Append(Contains(got, "\x1b[201~") ? "YES" : "NO").Append('\n');

        SetConsoleMode(hin, inMode);
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
        return 0;
    }

    static void Emit(IntPtr hout, byte[] bytes)
    {
        uint written;
        WriteFile(hout, bytes, (uint)bytes.Length, out written, IntPtr.Zero);
        FlushFileBuffers(hout);
    }

    static void ReadBytes(IntPtr hin)
    {
        var buf = new byte[4096];
        for (;;)
        {
            uint n;
            if (!ReadFile(hin, buf, (uint)buf.Length, out n, IntPtr.Zero)) return;
            if (n == 0) continue;
            lock (Gate) { Collected.Write(buf, 0, (int)n); }
        }
    }

    // An INPUT_RECORD reader records the UTF-16 characters conhost hands it,
    // re-encoded as UTF-8 so the byte level assertions read the same way for
    // both recorder shapes.
    static void ReadRecords(IntPtr hin)
    {
        var buf = new InputRecord[128];
        for (;;)
        {
            uint n;
            if (!ReadConsoleInputW(hin, buf, (uint)buf.Length, out n)) return;
            var chunk = new StringBuilder();
            for (uint i = 0; i < n; i++)
            {
                if (buf[i].EventType != 1) continue;   // KEY_EVENT
                if (buf[i].KeyDown == 0) continue;
                if (buf[i].UnicodeChar == 0) continue;
                chunk.Append((char)buf[i].UnicodeChar);
            }
            if (chunk.Length == 0) continue;
            var bytes = Encoding.UTF8.GetBytes(chunk.ToString());
            lock (Gate) { Collected.Write(bytes, 0, bytes.Length); }
        }
    }

    static bool Contains(byte[] hay, string needle)
    {
        var n = Encoding.ASCII.GetBytes(needle);
        for (int i = 0; i + n.Length <= hay.Length; i++)
        {
            bool ok = true;
            for (int j = 0; j < n.Length; j++) if (hay[i + j] != n[j]) { ok = false; break; }
            if (ok) return true;
        }
        return false;
    }

    static string Hex(byte[] b)
    {
        var sb = new StringBuilder(b.Length * 2);
        foreach (var x in b) sb.Append(x.ToString("x2"));
        return sb.ToString();
    }

    static string Printable(byte[] b)
    {
        var sb = new StringBuilder();
        foreach (var c in b)
        {
            if (c == 0x1b) sb.Append("<ESC>");
            else if (c == 0x0d) sb.Append("<CR>");
            else if (c == 0x0a) sb.Append("<LF>");
            else if (c >= 32 && c < 127) sb.Append((char)c);
            else sb.Append('<').Append(c.ToString("x2")).Append('>');
        }
        return sb.ToString();
    }
}
