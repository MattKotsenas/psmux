using System;
using System.Runtime.InteropServices;
using System.Threading;

// Generic ConPTY attach harness for the psmux docker environment.
//
// Runs INSIDE the container (compiled there with the .NET Framework csc).
// Hosts an arbitrary command (normally `psmux attach ...`) under a REAL
// pseudoconsole created by the container's own conhost (build 20348 in the
// psmux-dev image), exactly the way `docker exec -it` hosts an interactive
// process. This is the faithful non-SSH interactive attach path: stdin bytes
// written to the ConPTY input pipe are real terminal keystrokes / mouse
// escape reports, and everything the child renders is captured as the raw
// VT byte stream a user's terminal would receive.
//
// A file-based control protocol drives it (append-only, poll every 100ms):
//   TEXT <s>   -> write literal text followed by CR (submits the line)
//   TYPE <s>   -> write literal text, NO carriage return
//   CR         -> write a bare carriage return
//   HEX <h>    -> write raw bytes given as hex pairs, e.g. HEX 1b5b3c303b33303b31304d
//                 (the only way to send ESC/prefix/mouse SGR safely via docker exec)
//   QUIT       -> close the pseudoconsole and exit
//
// Usage: docker_conpty_attach_host.exe <ctrlFile> <outFile> <logFile> <cols> <rows> <command...>
//
// The child's exit is recorded in the log as "CHILD_EXIT code=N" so tests can
// prove a detach (prefix+d) really terminated the client.
class DockerConPtyAttachHost {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CreatePipe(out IntPtr hRead, out IntPtr hWrite, IntPtr sa, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint flags, out IntPtr phPC);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteFile(IntPtr h, byte[] buf, uint n, out uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetStdHandle(int nStdHandle, IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetExitCodeProcess(IntPtr h, out uint code);

    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO { public int cb; public string r1; public string r2; public string r3; public int dx,dy,dxs,dys,dxc,dyc,fa; public int flags; public short showw; public short r4; public IntPtr r5; public IntPtr si, so, se; }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new IntPtr(0x00020016);

    static object logLock = new object();
    static string logFile;
    static void Log(string s) {
        lock (logLock) {
            try { System.IO.File.AppendAllText(logFile, s + "\r\n"); } catch {}
        }
    }

    static byte[] FromHex(string h) {
        h = h.Replace(" ", "");
        var b = new byte[h.Length / 2];
        for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(h.Substring(i * 2, 2), 16);
        return b;
    }

    static void Main(string[] args) {
        if (args.Length < 6) {
            Console.Error.WriteLine("usage: <ctrlFile> <outFile> <logFile> <cols> <rows> <command...>");
            Environment.Exit(2);
        }
        string ctrlFile = args[0];
        string outFile  = args[1];
        logFile         = args[2];
        short cols = short.Parse(args[3]);
        short rows = short.Parse(args[4]);
        string cmd = string.Join(" ", args, 5, args.Length - 5);
        try { System.IO.File.Delete(logFile); } catch {}
        Log("HOST_START cmd=" + cmd);

        IntPtr inRead, inWrite, outRead, outWrite;
        CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0);
        CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0);

        COORD size; size.X = cols; size.Y = rows;
        IntPtr hPC;
        int hr = CreatePseudoConsole(size, inRead, outWrite, 0, out hPC);
        Log("CreatePseudoConsole hr=" + hr);
        if (hr != 0) Environment.Exit(3);

        IntPtr lpSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref lpSize);
        IntPtr attr = Marshal.AllocHGlobal(lpSize);
        InitializeProcThreadAttributeList(attr, 1, 0, ref lpSize);
        UpdateProcThreadAttribute(attr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);

        // Under `docker exec -d` this process has pipe/NUL std handle VALUES;
        // CreateProcess propagates those values into a ConPTY child, where
        // they are invalid: the child reads instant EOF on stdin and its
        // stdout writes vanish (only console-API output like the title OSC
        // survives). NULL them so the child binds fresh handles to the new
        // console, the same situation a GUI parent (Windows Terminal) has.
        SetStdHandle(-10, IntPtr.Zero); // STD_INPUT_HANDLE
        SetStdHandle(-11, IntPtr.Zero); // STD_OUTPUT_HANDLE
        SetStdHandle(-12, IntPtr.Zero); // STD_ERROR_HANDLE

        var siex = new STARTUPINFOEX();
        siex.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        siex.lpAttributeList = attr;
        PROCESS_INFORMATION pi;
        bool ok = CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, null, ref siex, out pi);
        Log("CreateProcess ok=" + ok + " e=" + Marshal.GetLastWin32Error() + " childPid=" + pi.pid);
        if (!ok) Environment.Exit(4);

        // Reader thread: drain the raw VT stream so the pipe never blocks.
        // FileShare.ReadWrite so tests can read the stream while we hold it.
        var outFs = new System.IO.FileStream(outFile, System.IO.FileMode.Create,
            System.IO.FileAccess.Write, System.IO.FileShare.ReadWrite);
        var reader = new Thread(() => {
            byte[] buf = new byte[8192];
            while (true) {
                uint r;
                if (!ReadFile(outRead, buf, (uint)buf.Length, out r, IntPtr.Zero) || r == 0) break;
                lock (outFs) { outFs.Write(buf, 0, (int)r); outFs.Flush(); }
            }
        });
        reader.IsBackground = true;
        reader.Start();

        // Watcher thread: record the child's exit so tests can assert on it.
        var watcher = new Thread(() => {
            WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
            uint code; GetExitCodeProcess(pi.hProcess, out code);
            Log("CHILD_EXIT code=" + code);
            Thread.Sleep(700); // let the reader drain the tail of the stream
            ClosePseudoConsole(hPC);
            Environment.Exit(0);
        });
        watcher.IsBackground = true;
        watcher.Start();

        long lastLen = 0;
        while (true) {
            Thread.Sleep(100);
            if (!System.IO.File.Exists(ctrlFile)) continue;
            string content;
            try { content = System.IO.File.ReadAllText(ctrlFile); } catch { continue; }
            if (content.Length == (int)lastLen) continue;
            string tail = content.Substring((int)lastLen);
            lastLen = content.Length;
            foreach (var rawLine in tail.Split('\n')) {
                string line = rawLine.Trim();
                if (line.Length == 0) continue;
                uint w;
                if (line.StartsWith("TEXT ")) {
                    byte[] b = System.Text.Encoding.ASCII.GetBytes(line.Substring(5) + "\r");
                    WriteFile(inWrite, b, (uint)b.Length, out w, IntPtr.Zero);
                    Log("SENT TEXT " + line.Substring(5));
                } else if (line.StartsWith("TYPE ")) {
                    byte[] b = System.Text.Encoding.ASCII.GetBytes(line.Substring(5));
                    WriteFile(inWrite, b, (uint)b.Length, out w, IntPtr.Zero);
                    Log("SENT TYPE " + line.Substring(5));
                } else if (line == "CR") {
                    WriteFile(inWrite, new byte[] { 0x0d }, 1, out w, IntPtr.Zero);
                    Log("SENT CR");
                } else if (line.StartsWith("HEX ")) {
                    byte[] b;
                    try { b = FromHex(line.Substring(4)); } catch { Log("BAD HEX " + line); continue; }
                    WriteFile(inWrite, b, (uint)b.Length, out w, IntPtr.Zero);
                    Log("SENT HEX " + line.Substring(4) + " n=" + b.Length);
                } else if (line == "QUIT") {
                    Log("QUIT");
                    ClosePseudoConsole(hPC);
                    Environment.Exit(0);
                }
            }
        }
    }
}
