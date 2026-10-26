// key_chunk_probe729.exe <logfile> <stopfile> [w32][,ckm]
// Used by tests\test_issue729_key_chunks.ps1 (issue #729).
// Pane program: puts stdin in raw virtual terminal input mode and logs every
// ReadFile chunk as "CHUNK t=<ms with 3 decimals> n=<len> <hex>" so the caller
// can tell whether one key's sequence (ESC [ A) reached the pane in one read or
// in several, and how far apart.  `w32` asks the console for win32 input mode
// (CSI ?9001h) the way dsh-TUI and other Ink based TUIs do on Windows, `ckm`
// turns on DECCKM application cursor keys (CSI ?1h).
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class Probe729
{
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll")] static extern bool WriteFile(IntPtr h, byte[] b, uint n, out uint w, IntPtr o);
    [DllImport("kernel32.dll")] static extern bool ReadFile(IntPtr h, byte[] b, uint n, out uint r, IntPtr o);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCP(uint cp);
    [DllImport("kernel32.dll")] static extern bool SetConsoleOutputCP(uint cp);

    static int Main(string[] a)
    {
        string log = a[0];
        string stop = a.Length > 1 ? a[1] : null;
        string opts = a.Length > 2 ? a[2] : "";
        SetConsoleCP(65001); SetConsoleOutputCP(65001);
        IntPtr hin = GetStdHandle(-10), hout = GetStdHandle(-11);
        uint im, om; GetConsoleMode(hin, out im); GetConsoleMode(hout, out om);
        SetConsoleMode(hin, (im & ~0x7u) | 0x200u);
        SetConsoleMode(hout, om | 0x4u);
        File.WriteAllText(log, "");
        var hb = Encoding.ASCII.GetBytes((opts.Contains("w32") ? "\x1b[?9001h" : "") + (opts.Contains("ckm") ? "\x1b[?1h" : "") + "\x1b[2J\x1b[Hkey_chunk_probe729 ready\r\n");
        uint w; WriteFile(hout, hb, (uint)hb.Length, out w, IntPtr.Zero);
        var sw = Stopwatch.StartNew();
        var t = new Thread(() => {
            var buf = new byte[65536];
            for (;;) {
                uint n;
                if (!ReadFile(hin, buf, (uint)buf.Length, out n, IntPtr.Zero)) { Thread.Sleep(20); continue; }
                if (n == 0) continue;
                double ms = sw.Elapsed.TotalMilliseconds;
                var sb = new StringBuilder();
                sb.Append("CHUNK t=").Append(ms.ToString("F3", System.Globalization.CultureInfo.InvariantCulture))
                  .Append(" n=").Append(n).Append(' ');
                for (int i = 0; i < n; i++) sb.Append(buf[i].ToString("x2"));
                sb.Append('\n');
                try { File.AppendAllText(log, sb.ToString()); } catch { }
                var d = Encoding.ASCII.GetBytes("."); uint ww; WriteFile(hout, d, 1, out ww, IntPtr.Zero);
            }
        });
        t.IsBackground = true;
        t.Start();
        while (stop == null || !File.Exists(stop)) Thread.Sleep(100);
        return 0;
    }
}
