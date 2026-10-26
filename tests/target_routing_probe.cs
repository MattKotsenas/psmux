// target_routing_probe.exe <logfile> <stopfile> [flood]
// Used by tests\test_stalled_server_target_routing.ps1.
//
// A pane program that appends every byte it reads from its console input to
// <logfile> (raw VT input mode, flushed per read) so a test can say exactly
// which pane each key reached.  With "flood" it also writes output lines
// continuously, which keeps the pane's pty reader waking the server loop the
// whole time (a busy build or a tail -f in a real session).
// It exits when <stopfile> appears.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class TargetRoutingProbe
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
        string stop = a[1];
        bool flood = a.Length > 2 && a[2] == "flood";
        SetConsoleCP(65001); SetConsoleOutputCP(65001);
        IntPtr hin = GetStdHandle(-10), hout = GetStdHandle(-11);
        uint im, om; GetConsoleMode(hin, out im); GetConsoleMode(hout, out om);
        SetConsoleMode(hin, (im & ~0x7u) | 0x200u);
        SetConsoleMode(hout, om | 0x4u);
        var fs = new FileStream(log, FileMode.Create, FileAccess.Write, FileShare.ReadWrite);
        uint w;
        var hb = Encoding.ASCII.GetBytes("\x1b[2J\x1b[Htarget_routing_probe " + (flood ? "flood " : "") + "ready\r\n");
        WriteFile(hout, hb, (uint)hb.Length, out w, IntPtr.Zero);
        var reader = new Thread(() => {
            var buf = new byte[65536];
            for (;;) {
                uint n;
                if (!ReadFile(hin, buf, (uint)buf.Length, out n, IntPtr.Zero)) { Thread.Sleep(20); continue; }
                if (n == 0) continue;
                lock (fs) { fs.Write(buf, 0, (int)n); fs.Flush(); }
            }
        });
        reader.IsBackground = true; reader.Start();
        if (flood) {
            var f = new Thread(() => {
                long i = 0;
                for (;;) {
                    var b = Encoding.ASCII.GetBytes("flood " + (i++) + " ................................................\r\n");
                    WriteFile(hout, b, (uint)b.Length, out w, IntPtr.Zero);
                    if (i % 20 == 0) Thread.Sleep(1);
                }
            });
            f.IsBackground = true; f.Start();
        }
        while (!File.Exists(stop)) Thread.Sleep(100);
        lock (fs) { fs.Flush(); fs.Close(); }
        return 0;
    }
}
