// paste_probe719.exe <logfile> <bp:on|off> <stopfile> [noread]
// Used by tests\test_issue719_paste_bytes.ps1 (issue #719).
// Pane program for issue 719: optionally enables DECSET 2004, puts stdin in raw
// VT input mode, and logs every ReadFile chunk in hex with a ms timestamp.
// Rewrites the summary block after every chunk so the log is always readable.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class Probe719
{
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll")] static extern bool WriteFile(IntPtr h, byte[] b, uint n, out uint w, IntPtr o);
    [DllImport("kernel32.dll")] static extern bool ReadFile(IntPtr h, byte[] b, uint n, out uint r, IntPtr o);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCP(uint cp);
    [DllImport("kernel32.dll")] static extern bool SetConsoleOutputCP(uint cp);

    static MemoryStream all = new MemoryStream();
    static StringBuilder chunks = new StringBuilder();

    static int Main(string[] a)
    {
        string log = a[0];
        bool bp = a.Length > 1 && a[1] == "on";
        string stop = a.Length > 2 ? a[2] : null;
        SetConsoleCP(65001); SetConsoleOutputCP(65001);
        IntPtr hin = GetStdHandle(-10), hout = GetStdHandle(-11);
        uint im, om; GetConsoleMode(hin, out im); GetConsoleMode(hout, out om);
        SetConsoleMode(hin, (im & ~0x7u) | 0x200u);
        SetConsoleMode(hout, om | 0x4u);
        string hello = (bp ? "\x1b[?2004h" : "\x1b[?2004l") + "\x1b[2J\x1b[Hpaste_probe719 bp=" + (bp ? "on" : "off") + " ready\r\n";
        uint w; var hb = Encoding.ASCII.GetBytes(hello); WriteFile(hout, hb, (uint)hb.Length, out w, IntPtr.Zero);
        Flush(log);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var t = new Thread(() => {
            var buf = new byte[65536];
            for (;;) {
                uint n;
                if (!ReadFile(hin, buf, (uint)buf.Length, out n, IntPtr.Zero)) { Thread.Sleep(20); continue; }
                if (n == 0) continue;
                lock (all) {
                    all.Write(buf, 0, (int)n);
                    chunks.Append("CHUNK t=").Append(sw.ElapsedMilliseconds).Append(" n=").Append(n).Append(' ');
                    var sb = new StringBuilder();
                    for (int i = 0; i < n; i++) sb.Append(buf[i].ToString("x2"));
                    chunks.Append(sb).Append('\n');
                    Flush(log);
                }
                // echo a dot so the pane shows activity
                var d = Encoding.ASCII.GetBytes("."); uint ww; WriteFile(hout, d, 1, out ww, IntPtr.Zero);
            }
        });
        t.IsBackground = true;
        if (Environment.GetEnvironmentVariable("PROBE_NOREAD") == null && !(a.Length > 3 && a[3] == "noread")) t.Start();
        while (stop == null || !File.Exists(stop)) Thread.Sleep(100);
        lock (all) Flush(log);
        return 0;
    }

    static void Flush(string log)
    {
        byte[] got = all.ToArray();
        var sb = new StringBuilder();
        sb.Append(chunks);
        sb.Append("TEXT ").Append(Printable(got)).Append('\n');
        sb.Append("TOTAL ").Append(got.Length).Append('\n');
        var hx = new StringBuilder(); foreach (var x in got) hx.Append(x.ToString("x2"));
        sb.Append("HEX ").Append(hx).Append('\n');
        try { File.WriteAllText(log, sb.ToString()); } catch { }
    }

    static string Printable(byte[] b)
    {
        var sb = new StringBuilder();
        foreach (var c in b) {
            if (c == 0x1b) sb.Append("<ESC>");
            else if (c == 0x0d) sb.Append("<CR>");
            else if (c == 0x0a) sb.Append("<LF>");
            else if (c >= 32 && c < 127) sb.Append((char)c);
            else sb.Append('<').Append(c.ToString("x2")).Append('>');
        }
        return sb.ToString();
    }
}
