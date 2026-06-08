// VT-native byte-stream reader: sets ENABLE_VIRTUAL_TERMINAL_INPUT on stdin and
// reads RAW bytes via the file handle (the model a VT-mode app like a libuv/Node
// CLI uses on Windows). Logs every byte as hex. Used to determine whether psmux's
// key delivery (raw byte vs WriteConsoleInput injection) reaches a VT-mode reader.
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

class VtRead {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint read, IntPtr ov);

    const int STD_INPUT_HANDLE = -10;
    const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const uint ENABLE_PROCESSED_INPUT = 0x0001;
    const uint ENABLE_LINE_INPUT = 0x0002;
    const uint ENABLE_ECHO_INPUT = 0x0004;

    static int Main() {
        string log = Path.Combine(Environment.GetEnvironmentVariable("TEMP"), "psmux_vtread.txt");
        File.WriteAllText(log, "VTREAD START\n");
        IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
        uint mode;
        GetConsoleMode(h, out mode);
        // Raw VT input mode: VTI on, line/echo/processed off
        uint newMode = (mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)) | ENABLE_VIRTUAL_TERMINAL_INPUT;
        SetConsoleMode(h, newMode);
        File.AppendAllText(log, string.Format("mode {0:X} -> {1:X}\n", mode, newMode));
        byte[] buf = new byte[256];
        while (true) {
            uint read;
            if (!ReadFile(h, buf, (uint)buf.Length, out read, IntPtr.Zero)) {
                System.Threading.Thread.Sleep(20); continue;
            }
            if (read == 0) { System.Threading.Thread.Sleep(10); continue; }
            var sb = new StringBuilder();
            for (uint i = 0; i < read; i++) sb.AppendFormat("0x{0:X2} ", buf[i]);
            File.AppendAllText(log, sb.ToString().TrimEnd() + "\n");
            for (uint i = 0; i < read; i++) if (buf[i] == 0x1A) { File.AppendAllText(log, "VTREAD END\n"); return 0; }
        }
    }
}
