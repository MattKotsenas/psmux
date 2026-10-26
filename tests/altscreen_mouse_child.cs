// Alternate-screen mouse child: models a full screen TUI (codex, htop, nvim) running
// inside a psmux pane, with every mouse registration channel independently switchable.
//
// Issue #598 needs the four way matrix, because tmux picks a completely different wheel
// behaviour for each cell:
//
//   alt=1 decset=1   the codex / htop case: alt screen AND the app reads the wheel
//   alt=1 decset=0   alt screen, no mouse: tmux alternate-scroll sends Up/Down keys
//   alt=0 decset=1   normal screen, app reads the wheel
//   alt=0 decset=0   normal screen, no mouse: tmux enters copy mode
//
// Every raw stdin byte is logged, so the log is the ground truth for "what exactly did
// psmux forward into the pane for one wheel notch".
//
// Build: csc /nologo /out:altscreen_mouse_child.exe altscreen_mouse_child.cs
// Usage: altscreen_mouse_child.exe [alt=0|1] [decset=0|1] [conmouse=0|1] [log=PATH]
//        defaults: alt=1 decset=1 conmouse=0
// Log:   %PSMUX_ALT_ECHO_LOG%, or %TEMP%\psmux_alt_echo.txt by default
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

class AltScreenMouseChild {
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

    static bool Flag(string[] args, string name, bool dflt) {
        foreach (string a in args) {
            if (a.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
                return a.Substring(name.Length + 1).Trim() == "1";
        }
        return dflt;
    }

    static int Main(string[] args) {
        bool alt      = Flag(args, "alt", true);
        bool decset   = Flag(args, "decset", true);
        bool conmouse = Flag(args, "conmouse", false);

        log = null;
        foreach (string a in args) {
            if (a.StartsWith("log=", StringComparison.OrdinalIgnoreCase)) log = a.Substring(4);
        }
        if (string.IsNullOrWhiteSpace(log)) log = Environment.GetEnvironmentVariable("PSMUX_ALT_ECHO_LOG");
        if (string.IsNullOrWhiteSpace(log)) log = Path.Combine(Environment.GetEnvironmentVariable("TEMP"), "psmux_alt_echo.txt");

        File.WriteAllText(log, string.Format("ALT_ECHO START alt={0} decset={1} conmouse={2}\n", alt, decset, conmouse));

        IntPtr hIn = GetStdHandle(STD_INPUT_HANDLE);
        IntPtr hOut = GetStdHandle(STD_OUTPUT_HANDLE);

        uint outMode;
        if (GetConsoleMode(hOut, out outMode))
            SetConsoleMode(hOut, outMode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);

        if (alt) Emit(hOut, "\x1b[?1049h\x1b[H\x1b[2J");
        if (decset) Emit(hOut, "\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h");

        // The banner has to be visible on whichever screen is current, so capture-pane
        // can confirm the child really started.
        Emit(hOut, "\x1b[HALT_ECHO_READY\r\n");

        uint mode;
        if (GetConsoleMode(hIn, out mode)) {
            uint newMode = mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT | ENABLE_QUICK_EDIT_MODE);
            newMode |= ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_EXTENDED_FLAGS;
            if (conmouse) newMode |= ENABLE_MOUSE_INPUT; else newMode &= ~ENABLE_MOUSE_INPUT;
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
                    if (decset) Emit(hOut, "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l");
                    if (alt) Emit(hOut, "\x1b[?1049l");
                    File.AppendAllText(log, "ALT_ECHO END\n");
                    return 0;
                }
            }
        }
    }
}
