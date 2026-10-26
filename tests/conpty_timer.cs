// conpty_timer.cs — host a command under a real ConPTY and timestamp when
// specific marker strings first appear in the output stream.
//
// This is the only honest way to measure "time until the attached psmux TUI is
// usable" or "time until the shell prompt is actually drawn in the pane" from a
// non-interactive agent shell: a plain Start-Process gives the child no console,
// so psmux never paints, and capture-pane polling measures the poll interval
// rather than the product.
//
// Modelled on tests/conptycap.cs (the known-good ConPTY host in this repo):
// do not close the PTY-owned pipe ends, drain on a reader thread.
//
// Usage:
//   conpty_timer.exe <cols> <rows> <timeoutMs> <markerFile> <command line...>
//
// markerFile is a UTF-8 text file, one marker per line. Markers are matched as
// plain substrings against the decoded output accumulated so far, in the order
// listed (marker N is only searched once marker N-1 has matched), which lets you
// time a sequence such as "first paint" then "prompt drawn".
//
// Output on stdout, one line per event, milliseconds since CreateProcess:
//   SPAWN_MS <ms>          time spent inside CreateProcess itself
//   FIRSTBYTE <ms>
//   MARKER <index> <ms>
//   EXIT <ms>
//   TIMEOUT
// Exit code 0 if every marker matched, 2 on timeout.
//
// Compile: csc /nologo /optimize /out:conpty_timer.exe conpty_timer.cs

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

static class ConPtyTimer
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out IntPtr hRead, out IntPtr hWrite, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint flags, out IntPtr phPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint toRead, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const int PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;

    static readonly object gate = new object();
    static readonly StringBuilder acc = new StringBuilder();
    static long firstByteTicks = -1;

    static int Main(string[] args)
    {
        if (args.Length < 5)
        {
            Console.Error.WriteLine("usage: conpty_timer.exe <cols> <rows> <timeoutMs> <markerFile> <command...>");
            return 1;
        }
        short cols = short.Parse(args[0]);
        short rows = short.Parse(args[1]);
        int timeoutMs = int.Parse(args[2]);
        string markerFile = args[3];
        string cmd = string.Join(" ", args, 4, args.Length - 4);

        var markers = new List<string>();
        foreach (var line in File.ReadAllLines(markerFile, Encoding.UTF8))
            if (line.Length > 0) markers.Add(line);

        IntPtr inRead, inWrite, outRead, outWrite;
        CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0);
        CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0);

        IntPtr hPC;
        var size = new COORD { X = cols, Y = rows };
        int hr = CreatePseudoConsole(size, inRead, outWrite, 0, out hPC);
        if (hr != 0) { Console.Error.WriteLine("CreatePseudoConsole failed 0x" + hr.ToString("X")); return 1; }

        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        IntPtr attrList = Marshal.AllocHGlobal(attrSize);
        InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize);
        UpdateProcThreadAttribute(attrList, 0, (IntPtr)PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);

        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        si.lpAttributeList = attrList;

        // Drain thread has to be live before the child runs or ConPTY blocks.
        var sw = Stopwatch.StartNew();
        var reader = new Thread(() =>
        {
            var buf = new byte[8192];
            var dec = Encoding.UTF8.GetDecoder();
            var chars = new char[8192 * 2];
            while (true)
            {
                uint got;
                if (!ReadFile(outRead, buf, (uint)buf.Length, out got, IntPtr.Zero) || got == 0) break;
                int n = dec.GetChars(buf, 0, (int)got, chars, 0);
                lock (gate)
                {
                    if (firstByteTicks < 0) firstByteTicks = sw.ElapsedTicks;
                    acc.Append(chars, 0, n);
                }
            }
        });
        reader.IsBackground = true;
        reader.Start();

        PROCESS_INFORMATION pi;
        long spawnStart = sw.ElapsedTicks;
        bool ok = CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false,
                                EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, null, ref si, out pi);
        long spawnEnd = sw.ElapsedTicks;
        if (!ok) { Console.Error.WriteLine("CreateProcess failed " + Marshal.GetLastWin32Error()); return 1; }

        Console.WriteLine("SPAWN_MS " + Ms(spawnEnd - spawnStart));

        int matched = 0;
        int searchFrom = 0;
        long firstByteReported = -1;
        bool timedOut = false;
        while (matched < markers.Count)
        {
            if (sw.ElapsedMilliseconds > timeoutMs) { timedOut = true; break; }
            string snap;
            long fb;
            lock (gate) { snap = acc.ToString(); fb = firstByteTicks; }
            if (firstByteReported < 0 && fb >= 0)
            {
                firstByteReported = fb;
                Console.WriteLine("FIRSTBYTE " + Ms(fb));
            }
            int idx = snap.IndexOf(markers[matched], searchFrom, StringComparison.Ordinal);
            if (idx >= 0)
            {
                Console.WriteLine("MARKER " + matched + " " + Ms(sw.ElapsedTicks));
                searchFrom = idx + markers[matched].Length;
                matched++;
                continue;
            }
            Thread.Sleep(1);
        }

        Console.WriteLine(timedOut ? "TIMEOUT" : ("EXIT " + Ms(sw.ElapsedTicks)));
        if (timedOut)
        {
            string snap;
            lock (gate) { snap = acc.ToString(); }
            int tail = Math.Min(600, snap.Length);
            Console.Error.WriteLine("TAIL: " + snap.Substring(snap.Length - tail).Replace("", "<ESC>"));
        }

        Console.Out.Flush();
        // Kill the child, then leave. ClosePseudoConsole blocks until conhost
        // has drained, and with the drain thread parked in a ReadFile on the
        // pipe we are about to close that wait never ends — the measured run is
        // already finished and printed, so exiting outright is both correct and
        // the only reliable way out. The OS reclaims every handle.
        try { TerminateProcess(pi.hProcess, 0); } catch { }
        try { WaitForSingleObject(pi.hProcess, 500); } catch { }
        Environment.Exit(timedOut ? 2 : 0);
        return timedOut ? 2 : 0;
    }

    static string Ms(long ticks)
    {
        double ms = (double)ticks * 1000.0 / Stopwatch.Frequency;
        return ms.ToString("F2", System.Globalization.CultureInfo.InvariantCulture);
    }
}
