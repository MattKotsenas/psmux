// conpty_script766.exe <childlog> <scriptfile> <command...>
//
// Issue #766 follow up host: runs a psmux CLIENT under a real pseudoconsole
// (the way a node-pty or xterm.js front end does) and plays a small script
// into its input pipe. Script lines:
//   ready <word>     wait (up to 20 s) until <childlog> contains " <word>"
//   sleep <ms>       pause
//   write <hex...>   write these bytes to the client in ONE WriteFile
//   mark <text>      append "<unix ms> <text>" to <childlog>
// Every write is also logged to <childlog> as "<unix ms> write <hex>" so the
// caller has one timeline. Closing the pseudoconsole at the end ends the
// client.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

class ConPtyScript766
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out IntPtr hRead, out IntPtr hWrite, IntPtr sa, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint flags, out IntPtr phPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr h, byte[] buf, uint n, out uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr l, int c, int f, ref IntPtr s);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr a, IntPtr v, IntPtr cb, IntPtr p, IntPtr r);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr h, uint code);

    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO { public int cb; public string r1; public string r2; public string r3; public int dx, dy, dxs, dys, dxc, dyc, fa; public int flags; public short showw; public short r4; public IntPtr r5; public IntPtr si, so, se; }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new IntPtr(0x00020016);

    static long Now() { return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); }

    static int Main(string[] args)
    {
        if (args.Length < 3)
        {
            Console.Error.WriteLine("usage: conpty_script766 <childlog> <scriptfile> <command...>");
            return 2;
        }
        string childLog = args[0];
        string[] script = File.ReadAllLines(args[1]);
        string cmd = string.Join(" ", args, 2, args.Length - 2);

        IntPtr inRead, inWrite, outRead, outWrite;
        CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0);
        CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0);
        COORD size; size.X = 120; size.Y = 30;
        IntPtr hPC;
        int hr = CreatePseudoConsole(size, inRead, outWrite, 0, out hPC);
        if (hr != 0) { Console.Error.WriteLine("CreatePseudoConsole hr=" + hr); return 3; }

        IntPtr lpSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref lpSize);
        IntPtr attr = Marshal.AllocHGlobal(lpSize);
        InitializeProcThreadAttributeList(attr, 1, 0, ref lpSize);
        UpdateProcThreadAttribute(attr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);
        var siex = new STARTUPINFOEX();
        siex.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        siex.lpAttributeList = attr;
        PROCESS_INFORMATION pi;
        if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false,
            EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, null, ref siex, out pi))
        {
            Console.Error.WriteLine("CreateProcess failed e=" + Marshal.GetLastWin32Error());
            return 4;
        }
        Console.WriteLine("client pid " + pi.pid);

        // CONPTY766_OUT=<path> keeps everything the pseudoconsole wrote toward
        // this "terminal", so a run with the pane program started directly
        // (no psmux) shows what a real terminal is told.
        string outLog = Environment.GetEnvironmentVariable("CONPTY766_OUT");
        var reader = new Thread(() =>
        {
            byte[] buf = new byte[8192];
            uint r;
            FileStream fs = string.IsNullOrEmpty(outLog) ? null : new FileStream(outLog, FileMode.Create, FileAccess.Write, FileShare.Read);
            while (ReadFile(outRead, buf, (uint)buf.Length, out r, IntPtr.Zero) && r > 0)
            {
                if (fs != null) { fs.Write(buf, 0, (int)r); fs.Flush(); }
            }
        });
        reader.IsBackground = true;
        reader.Start();

        int rc = 0;
        foreach (string raw in script)
        {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;
            int sp = line.IndexOf(' ');
            string op = sp < 0 ? line : line.Substring(0, sp);
            string arg = sp < 0 ? "" : line.Substring(sp + 1).Trim();
            if (op == "ready")
            {
                var deadline = DateTime.UtcNow.AddSeconds(20);
                bool ok = false;
                while (DateTime.UtcNow < deadline)
                {
                    try { if (File.Exists(childLog) && File.ReadAllText(childLog).Contains(" " + arg)) { ok = true; break; } }
                    catch { }
                    Thread.Sleep(50);
                }
                if (!ok) { Console.WriteLine("NOREADY " + arg); rc = 5; break; }
            }
            else if (op == "sleep") Thread.Sleep(int.Parse(arg));
            else if (op == "mark") File.AppendAllText(childLog, Now() + " " + arg + "\n");
            else if (op == "write")
            {
                var parts = arg.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                byte[] b = new byte[parts.Length];
                for (int i = 0; i < parts.Length; i++) b[i] = Convert.ToByte(parts[i], 16);
                uint w;
                File.AppendAllText(childLog, Now() + " write " + arg + "\n");
                WriteFile(inWrite, b, (uint)b.Length, out w, IntPtr.Zero);
            }
        }

        ClosePseudoConsole(hPC);
        Thread.Sleep(300);
        TerminateProcess(pi.hProcess, 0);
        return rc;
    }
}
