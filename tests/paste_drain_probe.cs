// paste_drain_probe.exe <logfile> <bp:on|off> <stopfile> [mode]
// Used by tests\test_large_paste_no_server_stall.ps1.
//
// A pane program that counts what it reads and proves it intact without
// slowing the paste down: no per chunk hex dump (paste_probe719 rewrites the
// whole log in hex on every chunk, which is quadratic on a 1.3 MB paste and
// would make the probe the bottleneck it is meant to measure).
//
// It puts stdin in raw VT input mode (so ESC[200~ arrives as bytes), optionally
// enables DECSET 2004, and keeps a running FNV-1a 64 over every byte read.
// The log is rewritten at most every 100 ms and once more at stop:
//   TOTAL <bytes>          bytes read so far
//   FNV <hex16>            FNV-1a 64 of those bytes, in order
//   CHUNKS <n>
//   FIRST <qpc> / LAST <qpc>  Stopwatch.GetTimestamp() of the first/last read
//   FREQ <qpc ticks per second>
//   KEYS <qpc>:<hex> ...   for reads of at most 8 bytes (typed keys), so a
//                          caller can time a send-keys against its own QPC
// On stop the raw bytes are also written to <logfile>.bin.
//
// mode: read (default) reads promptly; noread never reads; late<ms> reads
// only after <ms> milliseconds (the child that has not drained yet, which is
// what the 512 B / 5 ms paste pacing in src/input.rs was added for).
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Diagnostics;

static class PasteDrainProbe
{
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll")] static extern bool WriteFile(IntPtr h, byte[] b, uint n, out uint w, IntPtr o);
    [DllImport("kernel32.dll")] static extern bool ReadFile(IntPtr h, byte[] b, uint n, out uint r, IntPtr o);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCP(uint cp);
    [DllImport("kernel32.dll")] static extern bool SetConsoleOutputCP(uint cp);

    static readonly object gate = new object();
    static MemoryStream all = new MemoryStream();
    static ulong fnv = 14695981039346656037UL;
    static long chunks = 0, first = 0, last = 0;
    static StringBuilder keys = new StringBuilder();
    static bool dirty = true;

    static int Main(string[] a)
    {
        string log = a[0];
        bool bp = a.Length > 1 && a[1] == "on";
        string stop = a.Length > 2 ? a[2] : null;
        string mode = a.Length > 3 ? a[3] : "read";
        SetConsoleCP(65001); SetConsoleOutputCP(65001);
        IntPtr hin = GetStdHandle(-10), hout = GetStdHandle(-11);
        uint im, om; GetConsoleMode(hin, out im); GetConsoleMode(hout, out om);
        SetConsoleMode(hin, (im & ~0x7u) | 0x200u);
        SetConsoleMode(hout, om | 0x4u);
        string hello = (bp ? "\x1b[?2004h" : "\x1b[?2004l") + "\x1b[2J\x1b[Hpaste_drain_probe bp=" + (bp ? "on" : "off") + " mode=" + mode + " ready\r\n";
        uint w; var hb = Encoding.ASCII.GetBytes(hello); WriteFile(hout, hb, (uint)hb.Length, out w, IntPtr.Zero);
        Flush(log);
        int delay = 0;
        if (mode.StartsWith("late")) int.TryParse(mode.Substring(4), out delay);
        var t = new Thread(() => {
            if (delay > 0) Thread.Sleep(delay);
            var buf = new byte[65536];
            for (;;) {
                uint n;
                if (!ReadFile(hin, buf, (uint)buf.Length, out n, IntPtr.Zero)) { Thread.Sleep(20); continue; }
                if (n == 0) continue;
                long now = Stopwatch.GetTimestamp();
                lock (gate) {
                    all.Write(buf, 0, (int)n);
                    for (int i = 0; i < n; i++) { fnv ^= buf[i]; fnv *= 1099511628211UL; }
                    if (chunks == 0) first = now;
                    last = now; chunks++;
                    if (n <= 8) {
                        keys.Append(now).Append(':');
                        for (int i = 0; i < n; i++) keys.Append(buf[i].ToString("x2"));
                        keys.Append(' ');
                    }
                    dirty = true;
                }
            }
        });
        t.IsBackground = true;
        if (mode != "noread") t.Start();
        while (stop == null || !File.Exists(stop)) {
            Thread.Sleep(25);
            lock (gate) { if (dirty) { Flush(log); dirty = false; } }
        }
        lock (gate) {
            Flush(log);
            try { File.WriteAllBytes(log + ".bin", all.ToArray()); } catch { }
            try { File.AppendAllText(log, "DONE\n"); } catch { }
        }
        return 0;
    }

    static void Flush(string log)
    {
        var sb = new StringBuilder();
        sb.Append("TOTAL ").Append(all.Length).Append('\n');
        sb.Append("FNV ").Append(fnv.ToString("x16")).Append('\n');
        sb.Append("CHUNKS ").Append(chunks).Append('\n');
        sb.Append("FIRST ").Append(first).Append('\n');
        sb.Append("LAST ").Append(last).Append('\n');
        sb.Append("FREQ ").Append(Stopwatch.Frequency).Append('\n');
        sb.Append("KEYS ").Append(keys).Append('\n');
        string tmp = log + ".tmp";
        try { File.WriteAllText(tmp, sb.ToString()); File.Copy(tmp, log, true); } catch { }
    }
}
