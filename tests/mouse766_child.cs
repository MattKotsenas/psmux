// mouse766_child.exe <logfile> [plain] [libuv] [again] [nomouse]
//
// The pane program for the #766 follow up "a mouse mode requested at pane
// start is lost": a fullscreen app that writes its mode requests as its VERY
// FIRST output and never again. Unless "plain" is given it writes
//   ESC[?1049h ESC[?2004h ESC[?1000h ESC[?1003h ESC[?1006h
// (the reporter's sequence) before anything else, puts its console input in
// raw VT mode, then logs every chunk read from stdin as
// "<unix ms> stdin <n>B <hex bytes>". The "ready" line is written to the log
// only AFTER the request went out, so the host knows when to start.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

class Mouse766Child
{
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(IntPtr h, byte[] buf, uint n, out uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleCP(uint cp);

    static long Now() { return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); }

    static int Main(string[] args)
    {
        string log = args[0];
        IntPtr hin = GetStdHandle(-10);
        IntPtr hout = GetStdHandle(-11);
        // The request is the first thing this process does: nothing (not
        // even the console mode calls) runs ahead of it.
        uint omode; GetConsoleMode(hout, out omode);
        SetConsoleMode(hout, omode | 0x0004);
        // "nomouse" is the #598 control: a full screen app that never asks
        // for the mouse (alternate screen and bracketed paste only).
        byte[] req = Encoding.ASCII.GetBytes(Array.IndexOf(args, "nomouse") > 0
            ? "\x1b[?1049h\x1b[?2004h"
            : "\x1b[?1049h\x1b[?2004h\x1b[?1000h\x1b[?1003h\x1b[?1006h");
        bool plain = Array.IndexOf(args, "plain") > 0;
        uint w;
        if (!plain)
        {
            WriteFile(hout, req, (uint)req.Length, out w, IntPtr.Zero);
            File.AppendAllText(log, Now() + " requested\n");
        }
        uint mode; GetConsoleMode(hin, out mode);
        // "libuv" assigns the input mode wholesale the way libuv's raw mode
        // (node's process.stdin.setRawMode) does: ENABLE_WINDOW_INPUT |
        // ENABLE_VIRTUAL_TERMINAL_INPUT, which drops ENABLE_MOUSE_INPUT and
        // ENABLE_EXTENDED_FLAGS. Otherwise only line, echo and processed
        // input are cleared and VT input is added.
        bool libuv = Array.IndexOf(args, "libuv") > 0;
        SetConsoleMode(hin, libuv ? 0x0208u : ((mode & ~0x0007u) | 0x0200u));
        uint after; GetConsoleMode(hin, out after);
        File.AppendAllText(log, Now() + " inmode " + mode.ToString("x") + " -> " + after.ToString("x") + "\n");
        SetConsoleCP(65001);
        // "again" repeats the request 2 s later on a background thread, the
        // reporter's control case.
        if (!plain && Array.IndexOf(args, "again") > 0)
        {
            var t = new System.Threading.Thread(() =>
            {
                System.Threading.Thread.Sleep(2000);
                uint w2; WriteFile(hout, req, (uint)req.Length, out w2, IntPtr.Zero);
                File.AppendAllText(log, Now() + " requested again\n");
            });
            t.IsBackground = true;
            t.Start();
        }
        File.AppendAllText(log, Now() + " ready\n");
        byte[] buf = new byte[8192];
        while (true)
        {
            uint n;
            if (!ReadFile(hin, buf, (uint)buf.Length, out n, IntPtr.Zero) || n == 0) break;
            var sb = new StringBuilder();
            sb.Append(Now()).Append(" stdin ").Append(n).Append("B");
            for (int i = 0; i < n; i++) sb.Append(' ').Append(buf[i].ToString("x2"));
            sb.Append('\n');
            File.AppendAllText(log, sb.ToString());
        }
        return 0;
    }
}
