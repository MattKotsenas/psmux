// Issue #662: a pane program that turns on exactly the mouse modes it is told to,
// one DECSET at a time, so `#{mouse_standard_flag}` and friends can be read back
// for each one separately.
//
// altscreen_mouse_child.cs enables 1000+1002+1003+1006 in one burst, which is the
// right shape for the wheel gate tests but cannot tell the six #662 flags apart.
//
// Build: csc /nologo /out:issue662_mouse_mode_child.exe issue662_mouse_mode_child.cs
// Usage: issue662_mouse_mode_child.exe set=1000,1006 [rst=1000] [alt=0|1] [log=PATH]
//        `set` and `rst` are comma separated private mode numbers, written in the
//        order given as ESC[?Nh / ESC[?Nl with a short pause between them so the
//        server's data tick sees each transition.
// Keys:  1 -> ESC[?1000h   2 -> ESC[?1002h   3 -> ESC[?1003h
//        5 -> ESC[?1005h   6 -> ESC[?1006h   0 -> ESC[?1000l1002l1003l1005l1006l
//        a -> ESC[?1049h   n -> ESC[?1049l   Ctrl+Z quits
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

class Issue662MouseModeChild {
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
    const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    const uint ENABLE_EXTENDED_FLAGS = 0x0080;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    static string log;
    static IntPtr hOut;

    static void Emit(string s) {
        byte[] b = Encoding.ASCII.GetBytes(s);
        uint w;
        WriteFile(hOut, b, (uint)b.Length, out w, IntPtr.Zero);
    }

    static string Arg(string[] args, string name, string dflt) {
        foreach (string a in args) {
            if (a.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
                return a.Substring(name.Length + 1).Trim();
        }
        return dflt;
    }

    static void Apply(string list, char terminator) {
        if (string.IsNullOrWhiteSpace(list)) return;
        foreach (string raw in list.Split(',')) {
            string n = raw.Trim();
            if (n.Length == 0) continue;
            Emit("\x1b[?" + n + terminator);
            File.AppendAllText(log, "EMIT ESC[?" + n + terminator + "\n");
            System.Threading.Thread.Sleep(350);
        }
    }

    static int Main(string[] args) {
        string set = Arg(args, "set", "");
        string rst = Arg(args, "rst", "");
        bool alt = Arg(args, "alt", "0") == "1";

        log = Arg(args, "log", null);
        if (string.IsNullOrWhiteSpace(log))
            log = Path.Combine(Environment.GetEnvironmentVariable("TEMP"), "psmux_i662_child.txt");
        File.WriteAllText(log, "I662 START set=" + set + " rst=" + rst + " alt=" + alt + "\n");

        IntPtr hIn = GetStdHandle(STD_INPUT_HANDLE);
        hOut = GetStdHandle(STD_OUTPUT_HANDLE);

        uint outMode;
        if (GetConsoleMode(hOut, out outMode))
            SetConsoleMode(hOut, outMode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);

        Emit("I662_READY\r\n");
        if (alt) Emit("\x1b[?1049h\x1b[H\x1b[2JI662_READY\r\n");

        // The console mode goes FIRST, deliberately.  Measured on Windows 11
        // 26200: switching stdin to raw (ENABLE_VIRTUAL_TERMINAL_INPUT |
        // ENABLE_EXTENDED_FLAGS, no ENABLE_MOUSE_INPUT) makes conhost publish
        // ESC[?1003h ESC[?1006h upstream on its own, with the application
        // having asked for nothing.  Doing it before the DECSETs means the
        // sequences this child writes are the LAST word on the pane's mouse
        // state, which is what a per mode measurement needs.
        uint mode;
        if (GetConsoleMode(hIn, out mode)) {
            uint newMode = mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT | ENABLE_QUICK_EDIT_MODE);
            newMode |= ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_EXTENDED_FLAGS;
            SetConsoleMode(hIn, newMode);
            File.AppendAllText(log, string.Format("stdin mode {0:X} -> {1:X}\n", mode, newMode));
        }
        System.Threading.Thread.Sleep(400);

        Apply(set, 'h');
        Apply(rst, 'l');
        Emit("I662_ARMED\r\n");
        // The reading end polls for this line before it measures anything, and
        // before it sends a key: a fixed sleep raced the startup pause above and
        // read the pane a beat before the DECSET landed.
        File.AppendAllText(log, "ARMED\n");

        byte[] buf = new byte[512];
        while (true) {
            uint read;
            if (!ReadFile(hIn, buf, (uint)buf.Length, out read, IntPtr.Zero)) {
                System.Threading.Thread.Sleep(20);
                continue;
            }
            if (read == 0) { System.Threading.Thread.Sleep(10); continue; }

            var txt = new StringBuilder();
            for (int i = 0; i < read; i++) {
                byte b = buf[i];
                if (b == 0x1b) txt.Append("<ESC>");
                else if (b >= 0x20 && b < 0x7f) txt.Append((char)b);
                else txt.AppendFormat("<{0:X2}>", b);
            }
            File.AppendAllText(log, "RECV " + txt + "\n");

            for (int i = 0; i < read; i++) {
                switch (buf[i]) {
                    case (byte)'1': Emit("\x1b[?1000h"); File.AppendAllText(log, "EMIT ESC[?1000h\n"); break;
                    case (byte)'2': Emit("\x1b[?1002h"); File.AppendAllText(log, "EMIT ESC[?1002h\n"); break;
                    case (byte)'3': Emit("\x1b[?1003h"); File.AppendAllText(log, "EMIT ESC[?1003h\n"); break;
                    case (byte)'5': Emit("\x1b[?1005h"); File.AppendAllText(log, "EMIT ESC[?1005h\n"); break;
                    case (byte)'6': Emit("\x1b[?1006h"); File.AppendAllText(log, "EMIT ESC[?1006h\n"); break;
                    case (byte)'0':
                        Emit("\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l");
                        File.AppendAllText(log, "EMIT all off\n");
                        break;
                    case (byte)'a': Emit("\x1b[?1049h"); File.AppendAllText(log, "EMIT ESC[?1049h\n"); break;
                    case (byte)'n': Emit("\x1b[?1049l"); File.AppendAllText(log, "EMIT ESC[?1049l\n"); break;
                    case 0x1a:
                        File.AppendAllText(log, "I662 END\n");
                        return 0;
                }
            }
        }
    }
}
