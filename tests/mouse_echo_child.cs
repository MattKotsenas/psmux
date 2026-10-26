// Mouse-reporting child: runs inside a psmux pane, asks for SGR mouse reporting
// (DECSET 1000/1002/1006) by writing the escape sequences with WriteFile on the raw
// stdout handle (WriteConsole-written DECSET is swallowed by conhost), then logs every
// raw stdin byte it receives.
//
// This is the ground truth for "what exactly did psmux forward into the pane, and with
// which coordinates" when the user turns the mouse wheel over that pane.
//
// Build: csc /nologo /out:mouse_echo_child.exe mouse_echo_child.cs
// Log:   %PSMUX_MOUSE_ECHO_LOG%, or %TEMP%\psmux_mouse_echo.txt by default
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

class MouseEcho {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteFile(IntPtr h, byte[] buf, uint n, out uint written, IntPtr ov);

    const int STD_INPUT_HANDLE = -10;
    const int STD_OUTPUT_HANDLE = -11;
    const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const uint ENABLE_PROCESSED_INPUT = 0x0001;
    const uint ENABLE_LINE_INPUT = 0x0002;
    const uint ENABLE_ECHO_INPUT = 0x0004;
    const uint ENABLE_MOUSE_INPUT = 0x0010;
    const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    const uint ENABLE_EXTENDED_FLAGS = 0x0080;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    static string log;

    static void Emit(IntPtr hOut, string s) {
        byte[] b = Encoding.ASCII.GetBytes(s);
        uint w;
        WriteFile(hOut, b, (uint)b.Length, out w, IntPtr.Zero);
    }

    static int Main(string[] args) {
        string configuredLog = Environment.GetEnvironmentVariable("PSMUX_MOUSE_ECHO_LOG");
        log = string.IsNullOrWhiteSpace(configuredLog)
            ? Path.Combine(Environment.GetEnvironmentVariable("TEMP"), "psmux_mouse_echo.txt")
            : configuredLog;
        File.WriteAllText(log, "MOUSE_ECHO START\n");

        IntPtr hIn = GetStdHandle(STD_INPUT_HANDLE);
        IntPtr hOut = GetStdHandle(STD_OUTPUT_HANDLE);

        uint outMode;
        if (GetConsoleMode(hOut, out outMode))
            SetConsoleMode(hOut, outMode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);

        // Ask the terminal (psmux) for mouse reporting: normal tracking, button-event
        // tracking, any-event tracking, and SGR extended coordinates.
        Emit(hOut, "\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h");
        Emit(hOut, "MOUSE_ECHO_READY\r\n");

        uint mode;
        if (GetConsoleMode(hIn, out mode)) {
            uint newMode = (mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT | ENABLE_QUICK_EDIT_MODE))
                           | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_MOUSE_INPUT | ENABLE_EXTENDED_FLAGS;
            SetConsoleMode(hIn, newMode);
            File.AppendAllText(log, string.Format("stdin mode {0:X} -> {1:X}\n", mode, newMode));
        } else {
            File.AppendAllText(log, "GetConsoleMode(stdin) failed\n");
        }

        byte[] buf = new byte[512];
        while (true) {
            uint read;
            if (!ReadFile(hIn, buf, (uint)buf.Length, out read, IntPtr.Zero)) {
                System.Threading.Thread.Sleep(20);
                continue;
            }
            if (read == 0) { System.Threading.Thread.Sleep(10); continue; }

            var hex = new StringBuilder();
            var txt = new StringBuilder();
            for (int i = 0; i < read; i++) {
                hex.AppendFormat("{0:X2} ", buf[i]);
                byte b = buf[i];
                if (b == 0x1b) txt.Append("<ESC>");
                else if (b >= 0x20 && b < 0x7f) txt.Append((char)b);
                else txt.AppendFormat("<{0:X2}>", b);
            }
            File.AppendAllText(log, string.Format("RECV {0}  |  {1}\n", txt.ToString(), hex.ToString().Trim()));

            for (int i = 0; i < read; i++) {
                if (buf[i] == 0x1a) { // Ctrl+Z quits
                    Emit(hOut, "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l");
                    File.AppendAllText(log, "MOUSE_ECHO END\n");
                    return 0;
                }
            }
        }
    }
}
